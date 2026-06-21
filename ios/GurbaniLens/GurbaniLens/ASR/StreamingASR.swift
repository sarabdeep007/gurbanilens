import Foundation
import GurbaniLensCore
import WhisperKit

/// v2 streaming ASR — wraps WhisperKit's `AudioStreamTranscriber` actor
/// (public, ships in WhisperKit ≥ 1.0.0 at
/// `Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift`).
///
/// ### Phase A.3 architectural reset (2026-06-21)
///
/// Phase A through A.2 split `State.currentText` into separate
/// `confirmedSegments` (concatenated) and `unconfirmedText` (concatenated)
/// fields, then re-joined them downstream. WhisperKit's
/// `confirmedSegments` array **accumulates across the session** — every
/// re-decode appends another segment, so joining the array produces
/// growing concatenated garbage. The header on Deep's 2026-06-21
/// screenshot showed exactly that: `तत् ट्वम् असि तत्…` repeating
/// indefinitely, with `Waiting for speech…` / U+FFFD fragments mixed in.
///
/// **Reset.** `State.currentText` IS the live transcript — WhisperKit
/// curates it as a single best-guess REPLACEMENT string. We use it
/// directly. Drop the segment split, drop the confirmed-vs-unconfirmed
/// pair on `Partial`, drop the same pair on `VoiceSearchSession.State`.
/// One string flows from `currentText` → `latin` (matcher input) and
/// `gurmukhi` (UI display). Phase B can re-introduce the confirmed /
/// unconfirmed visual split when the architecture is stable.
///
/// ### Filters applied in order (any failure → skip the partial)
///
/// 1. Trim whitespace.
/// 2. **Bug C** — `currentText.contains("\u{FFFD}")` → skip. WhisperKit
///    occasionally emits the Unicode REPLACEMENT character mid-grapheme;
///    next callback typically arrives with the complete sequence.
/// 3. **Bug L / Bug O** — non-empty `currentText` must contain at least
///    one Devanagari codepoint (U+0900..U+097F). Filters out English
///    placeholders like `Waiting for speech…`, WhisperKit special tokens
///    `<|…|>`, etc. Empty `currentText` passes through (initial empty
///    `.listening` state).
/// 4. Literal blocklist for absolute safety — `Waiting for speech...`
///    and variants — even if it somehow contains a stray Devanagari mark.
/// 5. **Bug G** — repetition hallucination guard reused from `WhisperOneShot`.
/// 6. **Bug G** — sustained-low-energy guard. If last 8 partials all read
///    below 0.1 AND text grew, suppress (mic-silence hallucination).
public actor StreamingASR {

    /// One incremental update from the streaming pipeline. **Single
    /// `text` field** (Phase A.3 reset) — no confirmed / unconfirmed
    /// split. WhisperKit's `currentText` is the authoritative live
    /// transcript and we mirror it directly.
    public struct Partial: Sendable {
        /// `State.currentText` (Devanagari, trimmed, filtered).
        public let text: String
        /// `Latin.from(text)` — matcher input.
        public let latin: String
        /// `Gurmukhi.fromDevanagari(text)` — UI display.
        public let gurmukhi: String
        /// `State.isRecording`. False means VAD has stopped the stream OR
        /// `stop()` was called.
        public let isSpeaking: Bool
        /// Last frame's energy (for VU bar). 0 if no buffer yet.
        public let bufferEnergy: Float

        public init(
            text: String,
            latin: String,
            gurmukhi: String,
            isSpeaking: Bool,
            bufferEnergy: Float
        ) {
            self.text = text
            self.latin = latin
            self.gurmukhi = gurmukhi
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

    // Literal blocklist (Bug L / Bug O). Order matters only for log
    // readability. All checked via `hasPrefix` after trimming.
    private static let placeholderBlocklist: [String] = [
        "Waiting for speech",
        "<|"  // WhisperKit special tokens
    ]

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

    // Bug M warmup grace window. WhisperKit can fire isRecording=false
    // within tens of milliseconds of stream start, before any real audio
    // has arrived (bufferEnergy still 0). VAD-stop honoured only after
    // EITHER `warmupGracePeriod` elapsed OR `maxEnergySeen` cleared
    // `realAudioEnergyThreshold` — whichever comes first.
    private var streamStartTime: Date?
    private var maxEnergySeen: Float = 0
    private let warmupGracePeriod: TimeInterval = 1.5
    private let realAudioEnergyThreshold: Float = 0.1

    /// - Parameters:
    ///   - pipe: a constructed `WhisperKit` (typically obtained via
    ///     `WhisperOneShot.sharedPipe()` so v1 and v2 share one load).
    ///   - language: ISO language code. `"pa"` is silently remapped to
    ///     `"hi"` to dodge Whisper-small's Punjabi training gap (same
    ///     workaround as `WhisperOneShot`).
    ///   - silenceThreshold: WhisperKit's VAD silence threshold. Phase A.1
    ///     default 0.6 (Settings exposes loose=0.4 / balanced=0.6 /
    ///     tight=0.8 for power-user tuning).
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
    public func partials() async throws -> AsyncStream<Partial> {
        if transcriber != nil { throw StreamingError.alreadyStreaming }
        guard let tokenizer = pipe.tokenizer else {
            throw StreamingError.missingTokenizer
        }

        NSLog("[DIAG] StreamingASR.partials() starting language=\(effectiveLanguage) silenceThreshold=\(silenceThreshold) useVAD=true")

        // Bug M: anchor the warmup grace window at stream start. Reset
        // maxEnergySeen so a previous session's reading can't leak in.
        self.streamStartTime = Date()
        self.maxEnergySeen = 0
        self.energyHistory.removeAll(keepingCapacity: true)
        self.lastEmittedTextLength = 0

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

        cont.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        Task {
            do {
                try await t.startStreamTranscription()
            } catch {
                NSLog("[DIAG] StreamingASR.startStreamTranscription threw: \(error.localizedDescription)")
                self.finishStream()
            }
        }

        return stream
    }

    /// Stop the stream cleanly. Idempotent.
    public func stop() {
        guard let t = transcriber else { return }
        NSLog("[DIAG] StreamingASR.stop()")
        Task { await t.stopStreamTranscription() }
        transcriber = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal

    /// Static helper exposed for unit tests + reuse in
    /// `VoiceSearchSession.commit` where we need to validate a snapshot
    /// taken from `.listening` before running the full fuzzy matcher.
    public static func hasDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            scalar.value >= 0x0900 && scalar.value <= 0x097F
        }
    }

    private func handleStateChange(
        old: AudioStreamTranscriber.State,
        new: AudioStreamTranscriber.State
    ) {
        // Phase A.3 reset: use State.currentText DIRECTLY. WhisperKit
        // curates it as the single best-guess replacement string. The
        // segment-split path through `confirmedSegments` / `unconfirmedText`
        // accumulates concatenated garbage across the session and was
        // the root of bugs N, O, P from Deep's 2026-06-21 screenshot.
        let currentText = new.currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter 1 — Bug C: U+FFFD mid-grapheme replacement char.
        if currentText.contains("\u{FFFD}") {
            NSLog("[DIAG] StreamingASR skipping partial — U+FFFD in currentText (len=\(currentText.count))")
            return
        }

        // Filter 2 — Bug L / Bug O: literal blocklist (defence in depth
        // even if a placeholder somehow carries a stray Devanagari char).
        for prefix in Self.placeholderBlocklist {
            if currentText.hasPrefix(prefix) {
                NSLog("[DIAG] StreamingASR placeholder blocklist matched (prefix=\"\(prefix)\")")
                return
            }
        }

        // Filter 3 — Bug O: non-empty currentText must contain at least
        // one Devanagari codepoint. Empty text passes through so the
        // initial empty listening state is correctly published.
        if !currentText.isEmpty && !Self.hasDevanagari(currentText) {
            NSLog("[DIAG] StreamingASR placeholder filter suppressed non-Devanagari partial (head60=\"\(String(currentText.prefix(60)))\")")
            return
        }

        // Filter 4 — Bug G: repetition hallucination.
        if WhisperOneShot.isRepetitionHallucination(currentText) {
            NSLog("[DIAG] StreamingASR suppressed repetition hallucination on partial (len=\(currentText.count))")
            return
        }

        // Filter 5 — Bug G: sustained low-energy + text growth.
        let energy = new.bufferEnergy.last ?? 0
        energyHistory.append(energy)
        if energyHistory.count > energyHistorySize {
            energyHistory.removeFirst()
        }
        if energy > maxEnergySeen { maxEnergySeen = energy }
        let sustainedLowEnergy = energyHistory.count >= energyHistorySize
            && energyHistory.allSatisfy { $0 < lowEnergyThreshold }
        let textGrew = currentText.count > lastEmittedTextLength
        if sustainedLowEnergy && textGrew {
            NSLog("[DIAG] StreamingASR low-energy hallucination guard tripped — energy<\(lowEnergyThreshold) for \(energyHistorySize) partials, currentText grew \(lastEmittedTextLength)→\(currentText.count)")
            return
        }
        lastEmittedTextLength = currentText.count

        // All filters passed — transliterate once for matcher (Latin)
        // and once for display (Gurmukhi). Both produced from the same
        // currentText so they're guaranteed in sync.
        let latin = Latin.from(currentText)
        let gurmukhi = Gurmukhi.fromDevanagari(currentText)

        let partial = Partial(
            text: currentText,
            latin: latin,
            gurmukhi: gurmukhi,
            isSpeaking: new.isRecording,
            bufferEnergy: energy
        )

        NSLog("[DIAG] StreamingASR partial isSpeaking=\(new.isRecording) text.len=\(currentText.count) latin.head60=\"\(String(latin.prefix(60)))\" gurmukhi.head60=\"\(String(gurmukhi.prefix(60)))\" energy=\(String(format: "%.3f", energy))")

        continuation?.yield(partial)

        // Bug M: VAD-stop gate.
        if !new.isRecording && old.isRecording {
            let elapsed = streamStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let realAudio = maxEnergySeen > realAudioEnergyThreshold
            if elapsed < warmupGracePeriod && !realAudio {
                NSLog("[DIAG] StreamingASR VAD-stop SUPPRESSED (warmup or no-real-audio: elapsedMs=\(Int(elapsed * 1000)) maxEnergy=\(String(format: "%.3f", maxEnergySeen)))")
            } else {
                NSLog("[DIAG] StreamingASR VAD-stop detected, finishing stream (elapsedMs=\(Int(elapsed * 1000)) maxEnergy=\(String(format: "%.3f", maxEnergySeen)))")
                finishStream()
            }
        }
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }
}
