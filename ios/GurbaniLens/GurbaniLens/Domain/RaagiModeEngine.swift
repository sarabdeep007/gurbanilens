import Foundation
import SwiftUI
import GurbaniLensCore

/// **Raagi Mode engine** — continuous-listening loop that drives the
/// Raagi-follow UI. Brief #8 (2026-06-27), reshaped in Brief #8.1 for
/// sticky display, and rebuilt again in Brief #8.2 the same day for
/// responsive per-pangti tracking after Deep's iPhone test showed the
/// 1.2-sec stop/restart gap + 15-sec silence-trail cut producing
/// stuck multi-pangti blobs.
///
/// **Sticky display** (Brief #8.1, preserved). Two orthogonal things:
///   - **`audioState`** — what the mic / VAD / pipeline is doing.
///     Cycles `.listening` / `.recording` / `.processing` constantly,
///     independent of UI content.
///   - **`currentShabad` + `currentLineId`** — the shabad on screen.
///     STICKY. Only mutates on a confirmed match or session exit.
///
/// **Continuous capture + async dispatch** (Brief #8.2). Replaces the
/// old "one StreamingASR per utterance, full stop/restart cycle"
/// design. New flow:
///
///   1. `start()` builds ONE ``CloudMicCapture`` and calls
///      ``CloudMicCapture/startContinuous()``. Mic stays hot for the
///      entire Raagi-mode session.
///   2. At each VAD-detected utterance boundary (silence-trail OR
///      max-recording cap), CloudMicCapture snapshots the bytes,
///      resets VAD, **keeps recording**, and fires
///      ``CloudMicCapture/onUtteranceComplete``.
///   3. The engine assigns the snapshot a monotonic `utteranceSeq`,
///      bumps `inflightCount`, and spawns a `Task` that POSTs to
///      `https://asr.gurbanilens.com/transcribe`. Multiple
///      concurrent /transcribe calls are fine — IndicConformer
///      handles them in parallel; results arrive in some order.
///   4. When a transcript returns, the engine compares the
///      utterance's seq to `currentDisplaySeq`. Stale results
///      (older seq than the current display) are dropped. Fresh
///      results run through the jaikara detector + matcher + cache
///      and update the sticky display.
///   5. `inflightCount` is capped at ``maxInflightTranscriptions``.
///      Overflow snapshots queue in `pendingUtterances` (FIFO).
///
/// This eliminates two pathologies from the old design:
///   - The ~1.2-sec deaf window per utterance (mic stopped during
///     server roundtrip + restart).
///   - The 15-sec stuck-buffer that happened when raagi sang
///     through the (formerly 1500 ms) silence trail. Silence trail
///     is now 500 ms (Brief #8.2 tuning), max-recording 7 sec, so
///     even continuous recitation cuts at sane pangti-sized
///     boundaries.
///
/// **Provider lock-in.** The engine talks directly to
/// `CloudMicCapture` + URLSession and bypasses the
/// ``StreamingASR`` factory. Raagi mode is locked to the self-hosted
/// `GurbaniLensCloudProvider` endpoint — the only provider whose
/// one-shot buffered-utterance semantics match this design. Switching
/// providers (Sarvam streaming, WhisperKit on-device) is a separate
/// task; Brief #8.2 stays focused on responsiveness for the production
/// IndicConformer path.
@MainActor
public final class RaagiModeEngine: ObservableObject {

    // MARK: - Published state

    // ── Sticky display (Brief #8.1) ────────────────────────────────
    /// The shabad currently on screen. Sticky across utterances —
    /// only mutates on a confirmed match (≥ 70 score with seq ≥
    /// `currentDisplaySeq`) or session exit.
    @Published public private(set) var currentShabad: FullShabad?
    /// SGGS Line.id of the highlighted pangti in the currently-
    /// displayed shabad. nil iff `currentShabad` is nil.
    @Published public private(set) var currentLineId: String?

    // ── Audio pipeline (separate from sticky display) ─────────────
    /// Mic / VAD / transcribe pipeline state. Cycles independently of
    /// `currentShabad`. The UI surfaces this in the bottom status bar.
    @Published public private(set) var audioState: RaagiAudioState = .idle
    /// Live RMS for the waveform — set from per-tap energy callbacks
    /// the CloudMicCapture emits (matches Brief #7.1's pattern).
    @Published public private(set) var bufferEnergy: Float = 0
    /// Provider name for diagnostics. Brief #8.2 hardcodes
    /// "GurbaniLens Cloud" since the engine bypasses StreamingASR.
    @Published public private(set) var providerLabel: String = "GurbaniLens Cloud"

    // ── Overlays ──────────────────────────────────────────────────
    /// Jaikara banner text — non-nil while the 3-s fade is in flight.
    @Published public private(set) var activeJaikara: String?

    // MARK: - Deps

    private let matcher: Matcher
    private let corpus: Corpus
    private let cache: ShabadCache
    private let jaikaraDetector: JaikaraDetector

    // MARK: - Tunables

    private static let matchConfidenceThreshold: Double = 70.0
    private static let jaikaraBannerSeconds: Double = 3.0
    /// Cap on concurrent in-flight /transcribe requests. Brief #8.2:
    /// 3 is chosen so a fast singer cutting one pangti every ~600 ms
    /// (rare but possible) still queues smoothly; we never want the
    /// server to see a thundering herd.
    private static let maxInflightTranscriptions: Int = 3

    // MARK: - Continuous-capture state (Brief #8.2)

    private var capture: CloudMicCapture?
    private var jaikaraFadeTask: Task<Void, Never>?

    /// Monotonic 1-based utterance counter for the current session.
    /// Distinct from CloudMicCapture's internal `utteranceCounter` —
    /// this one tracks the engine's view (in case mic + engine ever
    /// drift, the engine's seq is the source of truth for display
    /// ordering).
    private var utteranceSeq: Int = 0
    /// The seq of the most recent utterance whose match updated the
    /// display. Used to drop out-of-order stale results: if
    /// utterance N returns AFTER utterance N+k (k > 0) already
    /// updated the display, N's match is dropped.
    private var currentDisplaySeq: Int = 0
    /// Currently in-flight /transcribe Tasks. Capped at
    /// `maxInflightTranscriptions`.
    private var inflightCount: Int = 0
    /// FIFO queue of (seq, audio) waiting for an in-flight slot.
    /// Bounded only by memory — overflows happen only if the user
    /// sings 4+ utterances within a typical server response window
    /// (~500-800 ms). In practice this stays empty.
    private var pendingUtterances: [(Int, Data)] = []

    // MARK: - ASR endpoint (mirrors GurbaniLensCloudProvider's init)

    private let asrEndpoint: String
    private let asrBearerToken: String
    private let urlSession: URLSession

    // MARK: - Init

    public init(matcher: Matcher, corpus: Corpus) {
        self.matcher = matcher
        self.corpus = corpus
        self.cache = ShabadCache(corpus: corpus)
        self.jaikaraDetector = JaikaraDetector()

        // Mirror GurbaniLensCloudProvider's Info.plist read pattern.
        // The bearer token + URL are injected at build time by
        // scripts/inject_env_to_plist.sh from the repo-root .env.
        let envEndpoint = (Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRURL") as? String)
            ?? GurbaniLensCloudProvider.defaultEndpoint
        let envToken = (Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRToken") as? String) ?? ""
        self.asrEndpoint = envEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.asrBearerToken = envToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)

        NSLog("[DIAG] RaagiModeEngine.init endpoint=\(self.asrEndpoint) tokenLen=\(self.asrBearerToken.count) maxInflight=\(Self.maxInflightTranscriptions)")
    }

    // MARK: - Public API

    /// Begin the continuous-capture session. Idempotent — repeated
    /// calls while already running are no-ops.
    public func start() {
        if capture != nil {
            NSLog("[DIAG] RaagiModeEngine.start ignored — already running")
            return
        }
        if asrBearerToken.isEmpty {
            NSLog("[DIAG] RaagiModeEngine.start FAILED — missing bearer token (populate GURBANILENS_ASR_TOKEN)")
            setAudioState(.error("ASR token missing"))
            return
        }

        NSLog("[DIAG] RaagiModeEngine.start (continuous-capture mode)")
        setAudioState(.listening)
        bufferEnergy = 0
        activeJaikara = nil
        utteranceSeq = 0
        currentDisplaySeq = 0
        inflightCount = 0
        pendingUtterances.removeAll(keepingCapacity: true)
        // Sticky display stays as-is if the user re-entered Raagi
        // Mode without an explicit stop. The normal Home→mic flow
        // goes through start AFTER stop, where stop() cleared it.

        let cap = CloudMicCapture()
        // Wire callbacks BEFORE startContinuous() — the tap fires
        // immediately after start and the callbacks are read on the
        // tap thread without locks.
        cap.onActivity = { [weak self] _, rms, vadActive in
            // Trampoline to main; the published state lives there.
            // Outer [weak self] keeps self optional; inner Task
            // inherits the weak reference.
            Task { @MainActor in
                self?.handleActivity(rms: rms, vadActive: vadActive)
            }
        }
        cap.onUtteranceComplete = { [weak self] data, micUtteranceNum in
            // Same trampoline. The utterance Data crosses thread
            // boundaries here — Data has value semantics, so the
            // copy is safe.
            Task { @MainActor in
                self?.handleUtteranceReady(audio: data, micUtteranceNum: micUtteranceNum)
            }
        }
        do {
            try cap.startContinuous()
            self.capture = cap
        } catch {
            NSLog("[DIAG] RaagiModeEngine startContinuous threw: \(error.localizedDescription)")
            setAudioState(.error(error.localizedDescription))
        }
    }

    /// Stop the continuous-capture session, tear down mic, clear
    /// sticky display + shabad cache. In-flight transcriptions are
    /// allowed to complete but their results are dropped (the stale
    /// check vs. reset `currentDisplaySeq` ensures they can't mutate
    /// the next session's display).
    public func stop() {
        NSLog("[DIAG] RaagiModeEngine.stop (utteranceSeq=\(utteranceSeq) inflight=\(inflightCount) pending=\(pendingUtterances.count))")
        capture?.stop()
        capture = nil
        jaikaraFadeTask?.cancel()
        jaikaraFadeTask = nil
        let cacheRef = cache
        Task { await cacheRef.clear() }
        setAudioState(.idle)
        bufferEnergy = 0
        activeJaikara = nil
        currentShabad = nil
        currentLineId = nil
        utteranceSeq = 0
        currentDisplaySeq = 0
        inflightCount = 0
        pendingUtterances.removeAll(keepingCapacity: true)
    }

    // MARK: - Activity → audioState (called per-tap, ~85 ms cadence)

    private func handleActivity(rms: Float, vadActive: Bool) {
        // Continuous bufferEnergy update for the waveform.
        if abs(rms - bufferEnergy) > 0.0001 {
            bufferEnergy = rms
        }
        // Don't override a sticky error — the user can see what
        // happened until they re-enter Raagi mode.
        if case .error = audioState { return }
        // Priority: recording > processing > listening. Recording
        // wins immediately on VAD-active so the singer sees instant
        // feedback even while a previous utterance is mid-flight.
        if vadActive {
            setAudioState(.recording)
        } else if inflightCount > 0 {
            setAudioState(.processing)
        } else {
            setAudioState(.listening)
        }
    }

    // MARK: - Utterance pipeline (called from CloudMicCapture callback)

    private func handleUtteranceReady(audio: Data, micUtteranceNum: Int) {
        utteranceSeq += 1
        let seq = utteranceSeq
        let bytes = audio.count
        let sec = Double(bytes) / (16_000.0 * 2.0)
        NSLog("[DIAG] RaagiModeEngine utterance #\(seq) ready bytes=\(bytes) sec=\(String(format: "%.2f", sec)) micNum=\(micUtteranceNum)")

        if inflightCount >= Self.maxInflightTranscriptions {
            pendingUtterances.append((seq, audio))
            NSLog("[DIAG] RaagiModeEngine utterance #\(seq) queued (inflight=\(inflightCount) pending=\(pendingUtterances.count))")
            return
        }
        dispatchTranscription(seqNum: seq, audio: audio)
    }

    private func dispatchTranscription(seqNum: Int, audio: Data) {
        inflightCount += 1
        NSLog("[DIAG] RaagiModeEngine async dispatch utterance #\(seqNum) inflight=\(inflightCount)")
        Task { [weak self] in
            guard let self else { return }
            let transcript = await self.transcribe(audio: audio, seqNum: seqNum)
            await self.completeTranscription(seqNum: seqNum, transcript: transcript)
        }
    }

    /// POST to /transcribe. Returns the transcript on success or nil
    /// on any failure path (HTTP error, unparseable response, network
    /// throw). The MainActor isolation costs nothing here — the
    /// `await session.data(for:)` suspends and runs off-main.
    private func transcribe(audio: Data, seqNum: Int) async -> String? {
        guard let url = URL(string: asrEndpoint) else {
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) endpoint unparseable: \(asrEndpoint)")
            return nil
        }
        let wav = WavBuilder.wavFromS16LE(pcm: audio)
        let boundary = "----GurbaniLensBoundary\(UUID().uuidString)"
        let body = GurbaniLensCloudProvider.multipartBody(
            wav: wav, fieldName: "audio", filename: "utterance.wav", boundary: boundary
        )
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(asrBearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let start = Date()
        do {
            let (data, response) = try await urlSession.data(for: req)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status != 200 {
                let bodyHead = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) HTTP \(status) elapsedMs=\(elapsedMs) bodyHead=\"\(bodyHead)\"")
                return nil
            }
            guard let parsed = GurbaniLensCloudProvider.parseResponse(data) else {
                let head = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) unparseable elapsedMs=\(elapsedMs) head=\"\(head)\"")
                return nil
            }
            let text = parsed.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let head80 = String(text.prefix(80))
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) response elapsedMs=\(elapsedMs) serverDurMs=\(parsed.durationMs) transcript.len=\(text.count) head80=\"\(head80)\"")
            return text.isEmpty ? nil : text
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) threw after \(elapsedMs)ms: \(error.localizedDescription)")
            return nil
        }
    }

    private func completeTranscription(seqNum: Int, transcript: String?) async {
        inflightCount -= 1
        if inflightCount < 0 { inflightCount = 0 }  // defensive
        // Pop one queued utterance into the freed slot.
        if !pendingUtterances.isEmpty {
            let (nextSeq, nextAudio) = pendingUtterances.removeFirst()
            NSLog("[DIAG] RaagiModeEngine utterance #\(nextSeq) dequeued (pending=\(pendingUtterances.count))")
            dispatchTranscription(seqNum: nextSeq, audio: nextAudio)
        }

        // Stale check #1 (transport): utterance returned after a
        // newer match already updated display.
        if seqNum < currentDisplaySeq {
            let resultLabel = transcript == nil ? "stale_failure" : "stale"
            NSLog("[DIAG] RaagiModeEngine match returned utterance #\(seqNum) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq) result=\(resultLabel)")
            return
        }
        guard let transcript = transcript else {
            NSLog("[DIAG] RaagiModeEngine match returned utterance #\(seqNum) result=transcript_nil")
            return
        }
        await processTranscript(transcript: transcript, seqNum: seqNum)
    }

    private func processTranscript(transcript: String, seqNum: Int) async {
        NSLog("[DIAG] RaagiModeEngine processTranscript utterance #\(seqNum) head60=\"\(String(transcript.prefix(60)))\" len=\(transcript.count)")

        // Jaikara check — overlay banner only, sticky shabad untouched.
        // Don't advance currentDisplaySeq; a jaikara isn't a shabad
        // update, and future pangti matches with lower seq should
        // still win against later jaikaras.
        if let jaikara = jaikaraDetector.detect(transcript: transcript) {
            NSLog("[DIAG] RaagiModeEngine JAIKARA detected utterance #\(seqNum) text=\"\(jaikara)\" — skipping matcher")
            showJaikara(jaikara)
            return
        }

        let queryLatin = Latin.from(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if queryLatin.isEmpty {
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) queryLatin empty — skipping match")
            return
        }

        let matcherRef = matcher
        let q = queryLatin
        let matches = await Task.detached(priority: .userInitiated) {
            matcherRef.match(q, topN: 5)
        }.value

        guard let top = matches.first, top.score >= Self.matchConfidenceThreshold else {
            let topScore = matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a"
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) no confident match topScore=\(topScore) threshold=\(Self.matchConfidenceThreshold)")
            return
        }

        // Stale check #2 (post-matcher): matcher took time on the
        // detached thread; a newer utterance may have completed
        // and updated display in the interim.
        if seqNum < currentDisplaySeq {
            NSLog("[DIAG] RaagiModeEngine match returned utterance #\(seqNum) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-matcher)")
            return
        }

        let matchedShabadId = top.line.shabadId
        let matchedLineId = top.line.id
        NSLog("[DIAG] RaagiModeEngine match utterance #\(seqNum) topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) ang=\(top.line.ang)")

        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: matchedShabadId)
        } catch {
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) shabad fetch failed: \(error.localizedDescription) — keeping sticky display")
            return
        }

        // Stale check #3 (post-fetch): cache miss may have hit the
        // corpus + parsed lines on a background queue. One more
        // gate before mutating display.
        if seqNum < currentDisplaySeq {
            NSLog("[DIAG] RaagiModeEngine match returned utterance #\(seqNum) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch)")
            return
        }

        // Sticky-display update (Brief #8.1 logic preserved, gated by
        // seqNum). THIS is the only place currentShabad / currentLineId
        // mutate during a session.
        if currentShabad?.id == matchedShabadId {
            let oldLine = currentLineId ?? "nil"
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: same-shabad highlight from=\(oldLine) to=\(matchedLineId) seqNum=\(seqNum)")
        } else if let prev = currentShabad {
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: shabad swap from=\(prev.id) to=\(matchedShabadId) lineId=\(matchedLineId) seqNum=\(seqNum)")
        } else {
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: first shabad shabadId=\(matchedShabadId) lineId=\(matchedLineId) seqNum=\(seqNum)")
        }
        currentDisplaySeq = seqNum
        NSLog("[DIAG] RaagiModeEngine.currentShabad sticky shabadId=\(matchedShabadId) lineId=\(matchedLineId) currentDisplaySeq=\(seqNum)")
    }

    // MARK: - Jaikara

    /// Show the jaikara banner for ~3 s. Cancels any in-flight fade
    /// so back-to-back jaikaras chain cleanly.
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

    // MARK: - Audio-state helper

    /// Set audio state with a single DIAG line per transition so
    /// `[DIAG] RaagiModeEngine.audioState:` traces are easy to grep.
    private func setAudioState(_ next: RaagiAudioState) {
        if audioState == next { return }
        NSLog("[DIAG] RaagiModeEngine.audioState: \(audioState) → \(next)")
        audioState = next
    }
}
