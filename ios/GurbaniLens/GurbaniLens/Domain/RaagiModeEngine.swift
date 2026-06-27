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

    /// Acceptance floor for tier 1 / tier 2 / tier 3 matches.
    /// Brief #8.5 (2026-06-27): lowered 70 → 60 after Deep's #8.4
    /// trace showed several genuinely-correct Tier 1 hits stranded
    /// at topEff=69.7 (one point shy of 70) because the multiplicative
    /// `eff = partialRatio × coverage` scoring drags an 87.5/0.80
    /// case below threshold. Threshold 60 catches that band without
    /// substantially loosening the false-positive boundary — the
    /// 1.8× runner-up confidence gate (Brief #8.5 commit 2) handles
    /// even lower-scoring confident matches.
    private static let matchConfidenceThreshold: Double = 60.0
    private static let jaikaraBannerSeconds: Double = 3.0
    /// Cap on concurrent in-flight /transcribe requests. Brief #8.2:
    /// 3 is chosen so a fast singer cutting one pangti every ~600 ms
    /// (rare but possible) still queues smoothly; we never want the
    /// server to see a thundering herd.
    private static let maxInflightTranscriptions: Int = 3
    /// Below this many transcript chars (grapheme clusters), only a
    /// Tier 1 hit at ``shortTranscriptTier1Threshold`` or above is
    /// accepted — anything else is dropped. Brief #8.3 short-
    /// transcript guard. Example: "ਰਹਾਉ" alone is ~3 chars and
    /// shouldn't shift display unless it's a same-shabad highlight
    /// landing high-confidence. Prevents one-syllable noise (mic
    /// false-positive, distant cough, brief alaap fragment) from
    /// flicking the display to whichever pangti loosely matches.
    private static let shortTranscriptCharThreshold: Int = 6
    /// Confidence floor for Tier 1 hits on short transcripts. Set
    /// higher than the normal `matchConfidenceThreshold` (60, lowered
    /// from 70 in Brief #8.5) so a 60-84 same-shabad hit on a 3-
    /// char transcript is rejected as too speculative. Brief #8.5
    /// constraint: short-transcript guard untouched.
    private static let shortTranscriptTier1Threshold: Double = 85.0
    /// **Confidence acceptance floor** (Brief #8.5, 2026-06-27).
    /// Below `matchConfidenceThreshold` (60) but at or above this
    /// value, a Tier 1 / Tier 2 hit can still be accepted IF the
    /// top match is at least ``confidenceRatioThreshold`` times the
    /// runner-up's score. Deep's #8.4 trace showed correct matches
    /// at topEff=46.4 with runner-ups at 20.4 (2.27× gap) — the
    /// absolute score is low but the candidate clearly stands out
    /// from the rest of the scope, so the matcher is confident.
    /// Floor is 40 (below this, even a strong gap is too noisy).
    private static let confidenceAcceptanceFloor: Double = 40.0
    /// **Confidence ratio threshold** (Brief #8.5). The
    /// top-vs-runner-up gap required for a sub-threshold match to be
    /// accepted. 1.8 = the top is at least 80 % higher than #2 —
    /// strong dominance, signal not noise. Combined with the floor
    /// to avoid runaway low-confidence matches.
    private static let confidenceRatioThreshold: Double = 1.8

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
    /// Shabad IDs the engine has successfully fetched + cached this
    /// session. Tracked here (rather than queried from ``ShabadCache``)
    /// so the Tier 2 candidate set can be built synchronously on the
    /// main actor without crossing an actor boundary. Brief #8.3.
    /// Stays in sync with `cache` because every fetch path inserts
    /// here on success; the cache only grows during a session.
    private var cachedShabadIds: Set<String> = []
    /// In-flight Tier 3 (full-SGGS) match tasks keyed by utterance
    /// seqNum. Brief #8.4 — when a newer utterance updates display
    /// via Tier 1 or Tier 2, any older Tier 3 work for seq < N is
    /// cancelled to free the iPhone CPU. The `Matcher.match` body
    /// checks `Task.isCancelled` at stage boundaries and returns
    /// `[]` early; the engine sees an empty match and skips display
    /// mutation via the existing stale check.
    private var inflightTier3Tasks: [Int: Task<[Match], Never>] = [:]

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
        cachedShabadIds.removeAll(keepingCapacity: true)
        // inflightTier3Tasks should already be empty (stop() drained
        // them on the previous session exit), but be defensive.
        cancelAllTier3Tasks(reason: "session_start")
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
        cachedShabadIds.removeAll(keepingCapacity: true)
        cancelAllTier3Tasks(reason: "session_stop")
    }

    /// Cancel all Tier 3 tasks with seq strictly less than `upToSeq`.
    /// Called after a successful display update so older Tier 3 work
    /// stops burning CPU. Brief #8.4 Bug 2.
    private func cancelStaleTier3Tasks(upToSeq: Int) {
        let staleKeys = inflightTier3Tasks.keys.filter { $0 < upToSeq }
        if staleKeys.isEmpty { return }
        for k in staleKeys.sorted() {
            NSLog("[DIAG] RaagiModeEngine cancelling stale tier=3 task for utterance #\(k) (newer utterance #\(upToSeq) updated display)")
            inflightTier3Tasks[k]?.cancel()
            inflightTier3Tasks.removeValue(forKey: k)
        }
    }

    /// Cancel every in-flight Tier 3 task — used on session
    /// start/stop to leave no orphans. Reason is logged once.
    private func cancelAllTier3Tasks(reason: String) {
        if inflightTier3Tasks.isEmpty { return }
        NSLog("[DIAG] RaagiModeEngine cancelling all \(inflightTier3Tasks.count) tier=3 tasks reason=\(reason)")
        for task in inflightTier3Tasks.values {
            task.cancel()
        }
        inflightTier3Tasks.removeAll(keepingCapacity: true)
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

        // Three-tier scoped match cascade (Brief #8.3).
        guard let (top, tier) = await runScopedCascade(
            queryLatin: queryLatin,
            transcript: transcript,
            seqNum: seqNum
        ) else {
            // Cascade already logged the rejection reason (no confident
            // match, short-transcript guard reject, or stale).
            return
        }

        let matchedShabadId = top.line.shabadId
        let matchedLineId = top.line.id
        NSLog("[DIAG] RaagiModeEngine match utterance #\(seqNum) tier=\(tier) topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) ang=\(top.line.ang)")

        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: matchedShabadId)
            // Track for Tier 2 on subsequent utterances. Insert
            // unconditionally — the cache de-dupes by id internally,
            // we de-dupe by Set semantics.
            cachedShabadIds.insert(matchedShabadId)
        } catch {
            NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) shabad fetch failed: \(error.localizedDescription) — keeping sticky display")
            return
        }

        // Stale check (post-fetch): cache miss may have hit the corpus +
        // parsed lines on a background queue. One more gate before
        // mutating display.
        if seqNum < currentDisplaySeq {
            NSLog("[DIAG] RaagiModeEngine match result tier=\(tier) topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) — dropped (stale post-fetch) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq)")
            return
        }

        // Sticky-display update (Brief #8.1 logic preserved, gated by
        // seqNum). THIS is the only place currentShabad / currentLineId
        // mutate during a session.
        if currentShabad?.id == matchedShabadId {
            let oldLine = currentLineId ?? "nil"
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: same-shabad highlight from=\(oldLine) to=\(matchedLineId) seqNum=\(seqNum) tier=\(tier)")
        } else if let prev = currentShabad {
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: shabad swap from=\(prev.id) to=\(matchedShabadId) lineId=\(matchedLineId) seqNum=\(seqNum) tier=\(tier)")
        } else {
            currentShabad = fetched
            currentLineId = matchedLineId
            NSLog("[DIAG] RaagiModeEngine display update: first shabad shabadId=\(matchedShabadId) lineId=\(matchedLineId) seqNum=\(seqNum) tier=\(tier)")
        }
        currentDisplaySeq = seqNum
        // Brief #8.4 Bug 2: cancel any older Tier 3 work that's now
        // pointless because this seqNum has advanced display.
        cancelStaleTier3Tasks(upToSeq: seqNum)
        NSLog("[DIAG] RaagiModeEngine match result tier=\(tier) topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) — used seqNum=\(seqNum)")
        NSLog("[DIAG] RaagiModeEngine.currentShabad sticky shabadId=\(matchedShabadId) lineId=\(matchedLineId) currentDisplaySeq=\(seqNum)")
    }

    /// **Tier 1 / Tier 2 acceptance decision** (Brief #8.5).
    /// Returns `true` if the cascade should accept the top match
    /// for `tier` and short-circuit the cascade, logging the
    /// outcome. The decision tree:
    ///
    ///   - `topScore >= matchConfidenceThreshold (60)` → ACCEPT
    ///     (normal path; no extra DIAG line — the existing
    ///     `display update tier=N` log carries the story).
    ///   - `topScore >= confidenceAcceptanceFloor (40)` AND
    ///     `topScore >= confidenceRatioThreshold (1.8) × runnerUp`
    ///     → ACCEPT as "confident-but-low" — the top stands out
    ///     dominantly from the rest of the candidate pool. Logs an
    ///     explicit `accepting confident match` line.
    ///   - `topScore >= confidenceAcceptanceFloor (40)` but the gap
    ///     is too small → REJECT, log explicit `rejecting low
    ///     confidence` so on-device traces show every near-miss.
    ///   - Below the floor → REJECT silently; the caller's
    ///     existing "no confident match" path covers this.
    ///
    /// Tier 3 retains the simple `>= matchConfidenceThreshold`
    /// check — its candidate pool is the whole corpus, so a 40-
    /// score-with-1.8×-gap match isn't trustworthy at that scope.
    /// The short-transcript guard path inside Tier 1 is untouched
    /// per Brief #8.5 constraint.
    private func shouldAcceptTierMatch(
        matches: [Match],
        tier: Int,
        seqNum: Int
    ) -> Bool {
        guard let top = matches.first else { return false }
        let runnerUp = matches.count > 1 ? matches[1].score : 0
        let ratio = runnerUp > 0 ? top.score / runnerUp : .infinity

        if top.score >= Self.matchConfidenceThreshold {
            return true
        }
        if top.score >= Self.confidenceAcceptanceFloor {
            let ratioStr = ratio == .infinity ? "∞" : String(format: "%.2f", ratio)
            if ratio >= Self.confidenceRatioThreshold {
                NSLog("[DIAG] RaagiModeEngine tier=\(tier) accepting confident match topEff=\(String(format: "%.1f", top.score)) runnerUpEff=\(String(format: "%.1f", runnerUp)) ratio=\(ratioStr) (below threshold \(Self.matchConfidenceThreshold) but confident) utterance #\(seqNum)")
                return true
            }
            NSLog("[DIAG] RaagiModeEngine tier=\(tier) rejecting low confidence topEff=\(String(format: "%.1f", top.score)) runnerUpEff=\(String(format: "%.1f", runnerUp)) ratio=\(ratioStr) utterance #\(seqNum)")
        }
        return false
    }

    /// **Three-tier scoped match cascade** (Brief #8.3). Tries
    /// progressively wider candidate sets until a confident match
    /// lands or all tiers are exhausted.
    ///
    ///   - **Tier 1**: lines in `currentShabad` only (~20 lines, ~5 ms).
    ///     The hot path — most utterances during a shabad are
    ///     same-shabad pangti movements.
    ///   - **Tier 2**: lines in cached shabads minus current
    ///     (~80–300 lines, ~10–50 ms). Catches shabad switches
    ///     back to one we've already followed in this session.
    ///   - **Tier 3**: full SGGS (~56 K lines, ~17 s on iPhone).
    ///     The cold path — only a true brand-new shabad reaches
    ///     here. Runs `Task.detached` so main is free during the
    ///     long match; stale check guards the result.
    ///
    /// Tiers 1 and 2 run synchronously on main — they're fast
    /// enough that blocking is invisible and avoids the overhead +
    /// stale-window of a `Task.detached`. Tier 3 is async because
    /// it's the only one whose latency exceeds the inter-utterance
    /// gap.
    ///
    /// Short-transcript guard: transcripts under
    /// ``shortTranscriptCharThreshold`` chars only accept a Tier 1
    /// hit at ``shortTranscriptTier1Threshold`` or above. Otherwise
    /// the cascade short-circuits and returns nil.
    ///
    /// Returns `(top match, tier)` on success, nil on
    /// no-confident-match / short-transcript reject / stale.
    private func runScopedCascade(
        queryLatin: String,
        transcript: String,
        seqNum: Int
    ) async -> (Match, Int)? {
        let isShort = transcript.count < Self.shortTranscriptCharThreshold

        // ── Tier 1: currentShabad ─────────────────────────────────
        if let currentShabadId = currentShabad?.id {
            let tier1ShabadIds: Set<String> = [currentShabadId]
            let tier1Count = matcher.shabadIndex[currentShabadId]?.count ?? 0
            let tier1Start = Date()
            let tier1Matches = matcher.match(
                queryLatin,
                restrictedToShabadIds: tier1ShabadIds,
                topN: 5
            )
            let tier1Ms = Int(Date().timeIntervalSince(tier1Start) * 1000)
            let tier1Top = tier1Matches.first?.score ?? 0
            NSLog("[DIAG] RaagiModeEngine scopedMatch tier=1 candidates=\(tier1Count) topScore=\(String(format: "%.1f", tier1Top)) ms=\(tier1Ms)")

            // Short-transcript guard: accept only Tier 1 at a high bar.
            if isShort {
                if let top = tier1Matches.first, top.score >= Self.shortTranscriptTier1Threshold {
                    NSLog("[DIAG] RaagiModeEngine short-transcript guard utterance #\(seqNum) transcript.len=\(transcript.count) tier1Top=\(String(format: "%.1f", tier1Top)) result=accept")
                    return (top, 1)
                }
                NSLog("[DIAG] RaagiModeEngine short-transcript guard utterance #\(seqNum) transcript.len=\(transcript.count) tier1Top=\(String(format: "%.1f", tier1Top)) result=reject")
                return nil
            }

            if let top = tier1Matches.first,
               shouldAcceptTierMatch(matches: tier1Matches, tier: 1, seqNum: seqNum) {
                return (top, 1)
            }
        } else if isShort {
            // No current shabad to match against AND transcript too
            // short to risk a Tier 2/3 attempt. Reject early.
            NSLog("[DIAG] RaagiModeEngine short-transcript guard utterance #\(seqNum) transcript.len=\(transcript.count) tier1Top=n/a (no_current_shabad) result=reject")
            return nil
        }

        // ── Tier 2: cached shabads (excluding current) ────────────
        let tier2ShabadIds = currentShabad.map { cachedShabadIds.subtracting([$0.id]) }
            ?? cachedShabadIds
        if !tier2ShabadIds.isEmpty {
            var tier2Count = 0
            for sid in tier2ShabadIds {
                tier2Count += matcher.shabadIndex[sid]?.count ?? 0
            }
            let tier2Start = Date()
            let tier2Matches = matcher.match(
                queryLatin,
                restrictedToShabadIds: tier2ShabadIds,
                topN: 5
            )
            let tier2Ms = Int(Date().timeIntervalSince(tier2Start) * 1000)
            let tier2Top = tier2Matches.first?.score ?? 0
            NSLog("[DIAG] RaagiModeEngine scopedMatch tier=2 candidates=\(tier2Count) topScore=\(String(format: "%.1f", tier2Top)) ms=\(tier2Ms)")

            if let top = tier2Matches.first,
               shouldAcceptTierMatch(matches: tier2Matches, tier: 2, seqNum: seqNum) {
                return (top, 2)
            }
        }

        // Pre-Tier-3 stale check: Tier 1/2 already took a few ms; if
        // a newer utterance landed and updated display while we were
        // here, skip the expensive Tier 3 entirely.
        if seqNum < currentDisplaySeq {
            NSLog("[DIAG] RaagiModeEngine cascade aborted utterance #\(seqNum) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq) result=stale (skipping_tier3)")
            return nil
        }

        // ── Tier 3: full SGGS, async + cancellable ────────────────
        // The Task is stored in inflightTier3Tasks under this
        // utterance's seqNum so a newer utterance's display update
        // can cancel it via cancelStaleTier3Tasks. `Matcher.match`
        // checks Task.isCancelled at each stage boundary and returns
        // [] early — we see an empty match below and the no-confident
        // path fires.
        let tier3Count = matcher.lines.count
        let tier3Start = Date()
        let matcherRef = matcher
        let q = queryLatin
        let task = Task.detached(priority: .userInitiated) { () -> [Match] in
            matcherRef.match(q, topN: 5)
        }
        inflightTier3Tasks[seqNum] = task
        let tier3Matches = await task.value
        inflightTier3Tasks.removeValue(forKey: seqNum)
        let tier3Ms = Int(Date().timeIntervalSince(tier3Start) * 1000)
        let tier3Top = tier3Matches.first?.score ?? 0
        let wasCancelled = tier3Matches.isEmpty && Task.isCancelled
        NSLog("[DIAG] RaagiModeEngine scopedMatch tier=3 candidates=\(tier3Count) topScore=\(String(format: "%.1f", tier3Top)) ms=\(tier3Ms) cancelled=\(wasCancelled)")

        // Post-Tier-3 stale check: the long one. Most stale drops
        // land here.
        if seqNum < currentDisplaySeq {
            NSLog("[DIAG] RaagiModeEngine match result tier=3 topScore=\(String(format: "%.1f", tier3Top)) — dropped (stale post-tier3) seqNum=\(seqNum) currentDisplaySeq=\(currentDisplaySeq)")
            return nil
        }

        if let top = tier3Matches.first, top.score >= Self.matchConfidenceThreshold {
            return (top, 3)
        }
        NSLog("[DIAG] RaagiModeEngine utterance #\(seqNum) no confident match across all tiers (tier3Top=\(String(format: "%.1f", tier3Top)) threshold=\(Self.matchConfidenceThreshold))")
        return nil
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
