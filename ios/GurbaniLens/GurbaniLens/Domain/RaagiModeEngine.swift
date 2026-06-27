import Foundation
import SwiftUI
import GurbaniLensCore

/// **Raagi Mode engine** — continuous-listening loop that drives the
/// Raagi-follow UI. Brief #8 (2026-06-27), reshaped in Brief #8.1
/// the same day after Deep's first iPhone test showed the original
/// state-enum design flashing the idle "ਪਾਠ ਸ਼ੁਰੂ ਕਰੋ" screen
/// between utterances.
///
/// **Sticky display architecture** (Brief #8.1). The engine separates
/// two orthogonal things:
///   - **`audioState`** — what the mic / VAD / pipeline is doing.
///     Cycles `.listening` → `.recording` → `.processing` →
///     `.listening` continuously, independent of UI content.
///   - **`currentShabad` + `currentLineId`** — the shabad on screen.
///     STICKY. Only mutates on a confirmed match or session exit.
///     Persists across audio-state cycles so the UI never loses the
///     page.
///
/// **Plus** `activeJaikara: String?` — the 3-second auto-fading
/// overlay banner, independent of both.
///
/// The continuous loop runs one utterance per iteration: spin a fresh
/// `StreamingASR`, subscribe to its partials, drive audioState from
/// the Silero-emitted `isSpeaking` flag (Brief #7.2), capture the
/// final transcript on stream close, decide jaikara / match-update /
/// no-op, restart for the next utterance. The sticky display NEVER
/// drops during this cycle.
@MainActor
public final class RaagiModeEngine: ObservableObject {

    // MARK: - Published state

    // ── Sticky display (Brief #8.1) ────────────────────────────────
    /// The shabad currently on screen. Sticky across utterances —
    /// only mutates on a confirmed match (≥ 70 score) or
    /// session exit. UI uses `currentShabad != nil` to decide
    /// between the entry hint and the shabad view.
    @Published public private(set) var currentShabad: FullShabad?
    /// SGGS Line.id of the highlighted pangti in the currently-
    /// displayed shabad. nil iff `currentShabad` is nil.
    @Published public private(set) var currentLineId: String?

    // ── Audio pipeline (separate from sticky display) ─────────────
    /// Mic / VAD / transcribe / matcher pipeline state. Cycles
    /// independently of `currentShabad`. The UI surfaces this in the
    /// bottom status bar — it does NOT control what's on the main
    /// content area.
    @Published public private(set) var audioState: RaagiAudioState = .idle
    /// Live RMS for the waveform — set from per-tap energy Partials
    /// the providers yield (Brief #7.1's per-tap empty-text Partials).
    @Published public private(set) var bufferEnergy: Float = 0
    /// Provider name for the bottom-of-screen caption — snapshotted at
    /// `start()` from the first `StreamingASR.activeProviderDisplayName`.
    @Published public private(set) var providerLabel: String = ""

    // ── Overlays ──────────────────────────────────────────────────
    /// Jaikara banner text — non-nil while the 3-s fade is in flight.
    @Published public private(set) var activeJaikara: String?

    // MARK: - Deps + private state

    private let matcher: Matcher
    private let corpus: Corpus
    private let cache: ShabadCache
    private let jaikaraDetector: JaikaraDetector
    private static let matchConfidenceThreshold: Double = 70.0
    private static let jaikaraBannerSeconds: Double = 3.0

    private var loopTask: Task<Void, Never>?
    private var currentAsr: StreamingASR?
    private var jaikaraFadeTask: Task<Void, Never>?

    public init(matcher: Matcher, corpus: Corpus) {
        self.matcher = matcher
        self.corpus = corpus
        self.cache = ShabadCache(corpus: corpus)
        self.jaikaraDetector = JaikaraDetector()
        NSLog("[DIAG] RaagiModeEngine.init")
    }

    // MARK: - Public API

    /// Begin the continuous-listen loop. Idempotent — repeated calls
    /// while already running are no-ops.
    public func start() {
        if loopTask != nil {
            NSLog("[DIAG] RaagiModeEngine.start ignored — already running")
            return
        }
        NSLog("[DIAG] RaagiModeEngine.start")
        setAudioState(.listening)
        bufferEnergy = 0
        activeJaikara = nil
        // Sticky display stays as-is if the user re-entered Raagi
        // Mode without an explicit stop (rare path; we leave it for
        // continuity). The normal Home→mic flow goes through start
        // after stop, in which case sticky was cleared in stop().
        loopTask = Task { [weak self] in
            await self?.runContinuousLoop()
        }
    }

    /// Stop the loop, tear down the ASR, drop sticky state, clear
    /// the cache. Called from exitRaagiMode.
    public func stop() {
        NSLog("[DIAG] RaagiModeEngine.stop")
        loopTask?.cancel()
        loopTask = nil
        jaikaraFadeTask?.cancel()
        jaikaraFadeTask = nil
        let asrToStop = currentAsr
        currentAsr = nil
        let cacheRef = cache
        Task {
            await asrToStop?.stop()
            await cacheRef.clear()
        }
        setAudioState(.idle)
        bufferEnergy = 0
        activeJaikara = nil
        // Sticky display cleared so re-entering Raagi Mode shows the
        // entry hint again.
        currentShabad = nil
        currentLineId = nil
    }

    // MARK: - Loop

    private func runContinuousLoop() async {
        while !Task.isCancelled {
            await runOneUtterance()
            if Task.isCancelled { break }
            // Tiny inter-utterance pause so a runaway loop (e.g.
            // capture.start throws synchronously every time) can't
            // burn 100 % CPU. Real utterances are seconds long; 100
            // ms here is invisible.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[DIAG] RaagiModeEngine continuous loop exited")
    }

    private func runOneUtterance() async {
        let asr = StreamingASR()
        currentAsr = asr
        let label = asr.activeProviderDisplayName
        if providerLabel != label { providerLabel = label }

        // Always back to .listening at the top of each iteration. The
        // sticky shabad (if any) stays on screen — only the bottom
        // status bar reflects this audio-state change.
        setAudioState(.listening)

        let stream: AsyncStream<Partial>
        do {
            stream = try await asr.partials()
        } catch {
            NSLog("[DIAG] RaagiModeEngine asr.partials() threw: \(error.localizedDescription)")
            currentAsr = nil
            setAudioState(.error(error.localizedDescription))
            try? await Task.sleep(nanoseconds: 800_000_000)
            return
        }

        var finalTranscript = ""
        for await partial in stream {
            if Task.isCancelled { break }
            if partial.bufferEnergy != bufferEnergy {
                bufferEnergy = partial.bufferEnergy
            }
            // VAD speech → recording. Sticky shabad stays put.
            if partial.isSpeaking {
                if case .recording = audioState {} else {
                    setAudioState(.recording)
                }
            }
            if !partial.gurmukhi.isEmpty {
                finalTranscript = partial.gurmukhi
            }
        }
        // Stream closed — VAD silence trail or stop() called.
        await asr.stop()
        currentAsr = nil

        if Task.isCancelled { return }
        if finalTranscript.isEmpty {
            // Silence / sub-threshold utterance / VAD blip. Don't
            // touch sticky display. Next loop iteration will set
            // audioState back to .listening.
            NSLog("[DIAG] RaagiModeEngine utterance empty — keeping sticky display")
            return
        }

        await processUtterance(finalTranscript)
    }

    private func processUtterance(_ transcript: String) async {
        NSLog("[DIAG] RaagiModeEngine processUtterance head60=\"\(String(transcript.prefix(60)))\" len=\(transcript.count)")
        setAudioState(.processing)

        // Jaikara check first — overlay banner, sticky shabad untouched.
        if let jaikara = jaikaraDetector.detect(transcript: transcript) {
            NSLog("[DIAG] RaagiModeEngine JAIKARA detected text=\"\(jaikara)\" — skipping matcher")
            showJaikara(jaikara)
            return
        }

        let queryLatin = Latin.from(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if queryLatin.isEmpty {
            NSLog("[DIAG] RaagiModeEngine queryLatin empty — keeping sticky display")
            return
        }

        let matcherRef = matcher
        let q = queryLatin
        let matches = await Task.detached(priority: .userInitiated) {
            matcherRef.match(q, topN: 5)
        }.value

        guard let top = matches.first, top.score >= Self.matchConfidenceThreshold else {
            let topScore = matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a"
            NSLog("[DIAG] RaagiModeEngine no confident match topScore=\(topScore) threshold=\(Self.matchConfidenceThreshold) — keeping sticky display")
            return
        }

        let matchedShabadId = top.line.shabadId
        let matchedLineId = top.line.id
        NSLog("[DIAG] RaagiModeEngine match topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) ang=\(top.line.ang)")

        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: matchedShabadId)
        } catch {
            NSLog("[DIAG] RaagiModeEngine shabad fetch failed: \(error.localizedDescription) — keeping sticky display")
            return
        }

        // Sticky display update logic. This is THE place where the
        // shabad and line on screen change. Anywhere else is wrong.
        if currentShabad?.id == matchedShabadId {
            // Same shabad: highlight move only.
            let oldLine = currentLineId ?? "nil"
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: same-shabad highlight from=\(oldLine) to=\(matchedLineId)")
        } else if let prev = currentShabad {
            // Cross-shabad swap.
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: shabad swap from=\(prev.id) to=\(matchedShabadId) lineId=\(matchedLineId)")
        } else {
            // First-ever match — currentShabad goes from nil → set.
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: first shabad shabadId=\(matchedShabadId) lineId=\(matchedLineId)")
        }
        NSLog("[DIAG] RaagiModeEngine.currentShabad sticky shabadId=\(matchedShabadId) lineId=\(matchedLineId)")
    }

    /// Show the jaikara banner for ~3 s. Cancels any in-flight fade
    /// so back-to-back jaikaras chain cleanly (banner stays up across
    /// repeated calls — the timer just gets reset).
    private func showJaikara(_ text: String) {
        jaikaraFadeTask?.cancel()
        activeJaikara = text
        jaikaraFadeTask = Task { [weak self] in
            let nanos = UInt64(Self.jaikaraBannerSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            guard let self else { return }
            self.activeJaikara = nil
        }
    }

    /// Set audio state with a single DIAG line per transition so
    /// `[DIAG] RaagiModeEngine.audioState:` traces are easy to grep.
    private func setAudioState(_ next: RaagiAudioState) {
        if audioState == next { return }
        NSLog("[DIAG] RaagiModeEngine.audioState: \(audioState) → \(next)")
        audioState = next
    }
}
