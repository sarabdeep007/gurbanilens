import Foundation
import GurbaniLensCore
import WhisperKit

/// v2 streaming ASR — wraps WhisperKit's `AudioStreamTranscriber` actor
/// (public, ships in WhisperKit ≥ 1.0.0 at
/// `Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift`).
///
/// Architecture
/// ------------
/// `AudioStreamTranscriber` owns the mic (via WhisperKit's `AudioProcessor`
/// — an `AVAudioEngine` wrapper) and runs CoreML decode on confirmed
/// buffer windows in the background. It delivers partial transcripts via a
/// `stateChangeCallback(old: State, new: State)` whose `State` exposes
/// `currentText`, `confirmedSegments`, `unconfirmedSegments`,
/// `unconfirmedText`, `bufferEnergy`, and `isRecording`.
///
/// This actor bridges that callback-driven API into an
/// `AsyncStream<Partial>` so `VoiceSearchSession` (a `@MainActor`
/// `ObservableObject`) can drive UI updates with a clean `for await`
/// loop.
///
/// Configuration
/// -------------
/// Same `DecodingOptions` shape as v1's `WhisperOneShot`:
///   - `task = .transcribe`, `detectLanguage = false`, `usePrefillPrompt = true`,
///     `skipSpecialTokens = true`, `withoutTimestamps = true`,
///     `suppressBlank = true`.
///   - `temperature = 0` with `temperatureFallbackCount = 5` +
///     `temperatureIncrementOnFallback = 0.2` — Whisper-small needs the
///     ladder to escape repetition lock-in on Indic-script audio.
///   - `compressionRatioThreshold = 2.0`, `noSpeechThreshold = 0.45`.
///   - `language` remapped `pa` → `hi` at the call boundary, same as
///     `WhisperOneShot`. Whisper-small was severely undertrained on
///     Punjabi (Phase 1 + Deep's v1 on-device tests both observed
///     Telugu drift); Hindi has orders-of-magnitude more training data
///     and emits Devanagari which the matcher's `Latin.from` already
///     handles.
///
/// `AudioStreamTranscriber` init knobs:
///   - `silenceThreshold = 0.3` (default) — VAD trips after ~2 s silence.
///   - `useVAD = true` — built-in energy VAD; auto-commits the stream
///     when the user stops speaking. The session observes
///     `Partial.isSpeaking == false` and triggers commit.
///   - `requiredSegmentsForConfirmation = 2` (default) — segments stay
///     "unconfirmed" until two passes agree.
///
/// Hallucination guard
/// -------------------
/// Each emitted `Partial`'s `currentText` is checked against
/// `WhisperOneShot.isRepetitionHallucination(_:)` (the same guard v1
/// uses on completed transcripts). If a partial trips the guard, we
/// suppress it — the consumer sees no update for that callback. UI
/// stays on the last good partial instead of flashing garbage Devanagari
/// or Telugu.
public actor StreamingASR {

    /// One incremental update from the streaming pipeline.
    public struct Partial: Sendable {
        /// `State.currentText` — Whisper's "best guess so far" (confirmed
        /// + latest unconfirmed). Devanagari or Latin depending on model.
        public let text: String
        /// Confirmed segments concatenated (raw Devanagari from WhisperKit).
        public let confirmedText: String
        /// Unconfirmed segments — Whisper may revise these.
        public let unconfirmedText: String
        /// `Latin.from(text)` — what the matcher should see.
        public let latin: String
        /// `Gurmukhi.fromDevanagari(confirmedText)` — for UI display.
        public let confirmedGurmukhi: String
        /// `Gurmukhi.fromDevanagari(unconfirmedText)` — for UI display.
        public let unconfirmedGurmukhi: String
        /// `State.isRecording` — false means VAD has stopped the stream
        /// (silence-based auto-commit) or `stop()` was called.
        public let isSpeaking: Bool
        /// Last frame's energy (for VU bar). 0 if no buffer yet.
        public let bufferEnergy: Float

        public init(
            text: String,
            confirmedText: String,
            unconfirmedText: String,
            latin: String,
            confirmedGurmukhi: String,
            unconfirmedGurmukhi: String,
            isSpeaking: Bool,
            bufferEnergy: Float
        ) {
            self.text = text
            self.confirmedText = confirmedText
            self.unconfirmedText = unconfirmedText
            self.latin = latin
            self.confirmedGurmukhi = confirmedGurmukhi
            self.unconfirmedGurmukhi = unconfirmedGurmukhi
            self.isSpeaking = isSpeaking
            self.bufferEnergy = bufferEnergy
        }
    }

    public enum StreamingError: LocalizedError {
        case alreadyStreaming
        case missingTokenizer
        case startFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .alreadyStreaming:
                return "StreamingASR is already running."
            case .missingTokenizer:
                return "WhisperKit instance has no tokenizer loaded — model load may have failed."
            case .startFailed(let e):
                return "WhisperKit streaming failed to start: \(e.localizedDescription)"
            }
        }
    }

    private let pipe: WhisperKit
    private let decodeOptions: DecodingOptions
    private let effectiveLanguage: String
    private let silenceThreshold: Float
    private var transcriber: AudioStreamTranscriber?
    private var continuation: AsyncStream<Partial>.Continuation?

    // Bug G low-energy hallucination guard. Track recent per-partial
    // energies; if the last `energyHistorySize` partials all read below
    // `lowEnergyThreshold`, we're getting near-silence from the mic but
    // Whisper is still producing tokens — classic small-model
    // hallucination. Suppress partials in this regime UNTIL the text
    // stops growing OR energy rises.
    private var energyHistory: [Float] = []
    private var lastEmittedTextLength: Int = 0
    private let energyHistorySize: Int = 8
    private let lowEnergyThreshold: Float = 0.1

    /// - Parameters:
    ///   - pipe: a constructed `WhisperKit` (typically obtained via
    ///     `WhisperOneShot.sharedPipe()` so v1 and v2 share one load).
    ///   - language: ISO language code. `"pa"` is silently remapped to
    ///     `"hi"` to dodge Whisper-small's Punjabi training gap (same
    ///     workaround as `WhisperOneShot`).
    ///   - silenceThreshold: WhisperKit's VAD silence threshold. Phase A
    ///     used the WhisperKit default 0.3; Deep's 2026-06-20 device test
    ///     showed that wipes the transcript mid-sentence on a brief
    ///     breath pause. Phase A.1 default is 0.6 (Settings exposes
    ///     loose=0.4 / balanced=0.6 / tight=0.8 for power-user tuning).
    public init(pipe: WhisperKit, language: String = "pa", silenceThreshold: Float = 0.6) {
        self.pipe = pipe
        self.effectiveLanguage = (language == "pa") ? "hi" : language
        self.silenceThreshold = silenceThreshold
        if self.effectiveLanguage != language {
            NSLog("[DIAG] StreamingASR.init language remap \(language) → \(self.effectiveLanguage) (small-model Punjabi workaround)")
        }
        NSLog("[DIAG] StreamingASR.init silenceThreshold=\(silenceThreshold)")
        self.decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: self.effectiveLanguage,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.0,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.45
        )
    }

    /// Begin streaming. Returns an `AsyncStream<Partial>` that yields one
    /// `Partial` per WhisperKit state-change callback. The stream finishes
    /// when WhisperKit's VAD detects sustained silence OR ``stop()`` is
    /// called by the caller (whichever fires first — per the v2 spec's
    /// dual stop mechanism).
    ///
    /// Throws if streaming is already in progress or the WhisperKit pipe
    /// has no tokenizer (model load failed).
    public func partials() async throws -> AsyncStream<Partial> {
        if transcriber != nil { throw StreamingError.alreadyStreaming }
        guard let tokenizer = pipe.tokenizer else {
            throw StreamingError.missingTokenizer
        }

        NSLog("[DIAG] StreamingASR.partials() starting language=\(effectiveLanguage) silenceThreshold=\(silenceThreshold) useVAD=true")

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.continuation = cont

        let cb: AudioStreamTranscriberCallback = { [weak self] (old, new) in
            Task { await self?.handleStateChange(old: old, new: new) }
        }

        let t = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: decodeOptions,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: silenceThreshold,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: cb
        )
        self.transcriber = t

        // Termination side: if the consumer cancels its for-await loop,
        // make sure we tear down the WhisperKit transcriber too.
        cont.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        // Kick off mic + decode on a child Task so we can return the
        // stream synchronously. Errors here finish the stream cleanly so
        // the consumer's for-await loop exits.
        Task {
            do {
                try await t.startStreamTranscription()
            } catch {
                NSLog("[DIAG] StreamingASR.startStreamTranscription threw: \(error.localizedDescription)")
                await self.finishStream()
            }
        }

        return stream
    }

    /// Stop the stream cleanly. Idempotent — calling twice does nothing
    /// extra. Used by both the explicit Stop button path and the v2 spec's
    /// silence-VAD auto-commit (WhisperKit fires `isRecording=false` in
    /// the callback; we observe and call `stop()` from the consumer side).
    public func stop() {
        guard let t = transcriber else { return }
        NSLog("[DIAG] StreamingASR.stop()")
        Task { await t.stopStreamTranscription() }
        transcriber = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal

    private func handleStateChange(
        old: AudioStreamTranscriber.State,
        new: AudioStreamTranscriber.State
    ) {
        let currentText = new.currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bug C: WhisperKit's streaming tokenizer occasionally emits a
        // U+FFFD (Unicode replacement char) mid-grapheme when a multi-byte
        // Devanagari sequence is still being decoded. Latin.from on such a
        // string corrupts the transliteration ("तत्�" → "tat�").
        // Drop the partial; the next callback will have the complete
        // grapheme and we recover cleanly.
        if currentText.contains("\u{FFFD}") {
            NSLog("[DIAG] StreamingASR skipping partial — U+FFFD in currentText (len=\(currentText.count))")
            return
        }

        // Hallucination guard. If the running currentText looks like a
        // repetition loop, swallow the update entirely — UI keeps the
        // last good partial.
        if WhisperOneShot.isRepetitionHallucination(currentText) {
            NSLog("[DIAG] StreamingASR suppressed repetition hallucination on partial (len=\(currentText.count))")
            return
        }

        // Bug G: low-energy hallucination guard. Track the last
        // `energyHistorySize` partial energies; if all of them are below
        // `lowEnergyThreshold` AND the text is still growing, we're
        // hallucinating on near-silence. Suppress the partial.
        let energy = new.bufferEnergy.last ?? 0
        energyHistory.append(energy)
        if energyHistory.count > energyHistorySize {
            energyHistory.removeFirst()
        }
        let sustainedLowEnergy = energyHistory.count >= energyHistorySize
            && energyHistory.allSatisfy { $0 < lowEnergyThreshold }
        let textGrew = currentText.count > lastEmittedTextLength
        if sustainedLowEnergy && textGrew {
            NSLog("[DIAG] StreamingASR low-energy hallucination guard tripped — energy<\(lowEnergyThreshold) for \(energyHistorySize) partials, currentText grew \(lastEmittedTextLength)→\(currentText.count)")
            return
        }
        lastEmittedTextLength = currentText.count

        let confirmed = new.confirmedSegments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let unconfirmed = new.unconfirmedText.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = Latin.from(currentText)
        let confirmedGurmukhi = Gurmukhi.fromDevanagari(confirmed)
        let unconfirmedGurmukhi = Gurmukhi.fromDevanagari(unconfirmed)
        let energy = new.bufferEnergy.last ?? 0

        let partial = Partial(
            text: currentText,
            confirmedText: confirmed,
            unconfirmedText: unconfirmed,
            latin: latin,
            confirmedGurmukhi: confirmedGurmukhi,
            unconfirmedGurmukhi: unconfirmedGurmukhi,
            isSpeaking: new.isRecording,
            bufferEnergy: energy
        )

        NSLog("[DIAG] StreamingASR partial isSpeaking=\(new.isRecording) confirmed.len=\(confirmed.count) unconfirmed.len=\(unconfirmed.count) latin.head60=\"\(String(latin.prefix(60)))\" gurmukhi.head60=\"\(String(confirmedGurmukhi.prefix(60)))\" energy=\(String(format: "%.3f", energy))")

        continuation?.yield(partial)

        // If WhisperKit's VAD just flipped isRecording false → finish the
        // stream so the consumer's for-await loop exits and can transition
        // to .committing.
        if !new.isRecording && old.isRecording {
            NSLog("[DIAG] StreamingASR VAD-stop detected, finishing stream")
            finishStream()
        }
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        // Don't nil out `transcriber` here — `stop()` does that; clearing
        // it here would race with VoiceSearchSession's `commit()` which
        // may still be inspecting state via the WhisperKit instance.
    }
}
