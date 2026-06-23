import Foundation
import SwiftUI
import GurbaniLensCore

/// App-scoped orchestrator. Owns the corpus + matcher (lazy), the ASR engine
/// (lazy), the recording capture, the ``VoiceSearchSession`` state, and the
/// ``NavigationStack`` path. Mirrors `android/.../MainActivity.kt`'s role.
@MainActor
final class AppContainer: ObservableObject {

    // ── Published UI state ───────────────────────────────────────────────
    @Published var path: [Route] = []
    @Published var session = VoiceSearchSession()
    @Published var showErrorAlert: Bool = false

    /// Phase A.4a: live WhisperKit model-download progress (0.0..1.0).
    /// Set non-nil while a fresh model is downloading; cleared back to
    /// nil once the pipe is loaded. LiveResultsScreen swaps the
    /// "ਸੁਣ ਰਿਹਾ ਹਾਂ…" placeholder for a progress UI while non-nil.
    @Published var modelDownloadProgress: Float?

    // ── Backing pipeline (lazy because each is heavy) ────────────────────
    private var corpus: Corpus?
    private var matcher: Matcher?
    private var asr: Asr?
    private let capture = RecordingCapture()

    // v2 streaming pipeline. Lazy — built on first .live tap. Shares the
    // WhisperKit pipe with the v1 `WhisperOneShot` so model load + cold
    // start are paid once.
    private var streamingAsr: StreamingASR?
    private var streamingTask: Task<Void, Never>?

    /// Auto-open-shabad task scheduled by ``handleStateChange`` when
    /// the matcher returns a single high-confidence match. Cancelled on
    /// any subsequent state change so the user remains in control: if
    /// the user keeps speaking and a different match wins, the prior
    /// auto-open never fires. 1 s visual delay so the user sees what
    /// matched before the navigation happens.
    private var autoOpenTask: Task<Void, Never>?
    /// The line.id the currently-scheduled auto-open is targeting. Used
    /// to detect "same target, keep the task" vs "different target,
    /// reschedule". Without this, every fresh `.listening` partial
    /// would cancel + reschedule the 1-second delay and the auto-open
    /// would never actually fire while the user keeps speaking.
    private var scheduledAutoOpenLineId: String?
    private static let autoOpenScoreThreshold: Double = 90.0
    private static let autoOpenDelaySec: Double = 1.0
    private static let autoOpenSettingKey = "settings.autoOpenExactMatches"

    // Bug I single-fire flag. `commitLiveStream` is async, so the
    // `guard case .listening = session.state` at its top doesn't gate
    // concurrent calls — multiple Stop taps (or a Stop tap + a
    // silence-VAD auto-commit firing at the same time, etc.) can pass
    // the guard before any of them awaits `ensureStreamingAsr` /
    // `session.commit`. Set this flag SYNCHRONOUSLY at entry; reset in
    // defer so the next legitimate commit cycle can run.
    private var commitInFlight: Bool = false

    /// Bug J helper. Clear the streaming ASR with a logged reason so the
    /// next on-device test reveals exactly which terminal cleanup path
    /// released the instance. Idempotent — clearing a nil field logs and
    /// returns without further effect.
    private func clearStreamingAsr(reason: String) {
        if streamingAsr != nil {
            NSLog("[DIAG] AppContainer.streamingAsr nilled (reason=\(reason))")
        }
        streamingAsr = nil
    }

    private var recordingTask: Task<Void, Never>?

    init() {
        capture.onPeak = { [weak self] peak in
            // Trampoline back to main; SwiftUI views must be touched on @MainActor.
            Task { @MainActor in self?.session.setRecording(peak: peak) }
        }
    }

    // ── User intents ─────────────────────────────────────────────────────

    func startRecording() {
        // Bug F guard. v1 one-shot mode must never start MicSource while a
        // v2 streaming session is active — they fight over the AVAudioSession
        // and the WhisperKit AudioProcessor mic, producing two parallel
        // captures (Deep's 2026-06-20 device test, Bug F). If we got here
        // while streaming or in any live state, refuse and log.
        if streamingAsr != nil {
            NSLog("[DIAG] AppContainer.startRecording REFUSED — streamingAsr active (Bug F guard)")
            return
        }
        switch session.state {
        case .listening, .committing:
            NSLog("[DIAG] AppContainer.startRecording REFUSED — session in live state \(String(describing: session.state)) (Bug F guard)")
            return
        default:
            break
        }
        // Push the Recording screen immediately so the UI feels responsive
        // even if mic permission needs to be requested.
        path.append(.recording)
        session.setRecording(peak: 0)
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            await self?.startCaptureAndAwait()
        }
    }

    func stopRecording() {
        // Bug F guard — same reason as startRecording: never run the v1
        // bulk-MicSource → WhisperOneShot batch path while a v2 stream is
        // active. The live commit path uses the streamed transcript, not
        // a fresh MicSource buffer.
        if streamingAsr != nil {
            NSLog("[DIAG] AppContainer.stopRecording REFUSED — streamingAsr active (Bug F guard)")
            return
        }
        // Idempotency guard. After the user taps Done we transition
        // session state out of .recording and immediately disable the
        // Done button — but SwiftUI can still deliver a queued tap before
        // the disabled re-render lands. Without this guard those late
        // taps call capture.stop() on an already-stopped mic (returns []),
        // then runSearchAndDone(samples: 0) fires
        // "No audio captured. Try again." while the original transcribe
        // is mid-flight. Net: a confusing error alert behind a valid
        // Results screen.
        guard case .recording = session.state else {
            NSLog("[DIAG] AppContainer.stopRecording ignored (state != .recording)")
            return
        }
        let samples = capture.stop()
        Task { [weak self] in await self?.runSearchAndDone(samples: samples) }
    }

    func cancelRecording() {
        // Mic + capture-task teardown is only meaningful while we're
        // actually recording. If the user backs out from the Recording
        // screen during transcribing / matching / done / error states,
        // those resources are already stopped — calling capture.cancel()
        // again is a no-op but capture.stop() inside it returns [] and
        // there's nothing useful to do. Skip cleanly.
        if case .recording = session.state {
            recordingTask?.cancel()
            capture.cancel()
        } else {
            NSLog("[DIAG] AppContainer.cancelRecording skipping mic/task teardown (state=\(String(describing: session.state)))")
        }
        session.reset(reason: "cancelRecording")
        returnHome()
    }

    func returnHome() {
        // Bug J: returnHome is reached from the Results screen's "Back" /
        // "Try again" callbacks. Either path is a terminal state — release
        // the streaming ASR so the next mic tap (live OR oneShot) isn't
        // blocked by the Bug F guard. Idempotent: nil-ing nil is fine.
        clearStreamingAsr(reason: "returnHome")
        path.removeAll()
        session.reset(reason: "returnHome")
    }

    // ── v2 (.live) user intents ──────────────────────────────────────────

    /// Phase A v2 entry point. Push the LiveResultsScreen, build / reuse
    /// the StreamingASR, kick off VoiceSearchSession.startStreaming, and
    /// let the for-await loop drive UI updates until either the user taps
    /// Stop (commitLive), taps a row (commitLive(match:)), or
    /// WhisperKit's silence-VAD finishes the stream.
    func startLiveRecording() {
        // Bug F defence — ensure no stale v1 MicSource / RecordingCapture
        // task is still alive. If a user toggled Settings.searchMode
        // mid-session, capture might still be running from a v1 attempt.
        // Force-clean before WhisperKit grabs the mic.
        recordingTask?.cancel()
        capture.cancel()

        path.append(.liveRecording)
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            await self?.startLiveStreamAndAwait()
        }
    }

    /// Stop the stream + run the full commit-time matcher + transition
    /// session to .done. If `match` is supplied (tap-row path), navigate
    /// to that match's Shabad screen as soon as the full match returns
    /// — the user already picked, the Results screen is unnecessary.
    func commitLive(match preselected: Match? = nil) {
        Task { [weak self] in
            await self?.commitLiveStream(preselected: preselected)
        }
    }

    func cancelLiveRecording() {
        streamingTask?.cancel()
        let asrToStop = streamingAsr
        // Bug J: nil out the streaming ASR BEFORE the async stop so a
        // subsequent startRecording / startLiveRecording isn't blocked
        // by the Phase A.1 Bug F guard that checks `streamingAsr != nil`.
        // The instance is held in `asrToStop` so the async stop still
        // runs cleanly against the original actor.
        clearStreamingAsr(reason: "cancelLive")
        Task { await asrToStop?.stop() }
        session.reset(reason: "cancelLive")
        returnHome()
    }

    func openShabad(for match: Match) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let corpus = try self.ensureCorpus()
                let lines = try corpus.shabadLines(shabadId: match.line.shabadId)
                let payload = ShabadPayload(
                    shabadId: match.line.shabadId,
                    focusLineId: match.line.id,
                    lines: lines
                )
                await MainActor.run { self.path.append(.shabad(payload)) }
            } catch {
                await MainActor.run {
                    self.session.setError("Couldn't load Shabad: \(error.localizedDescription)")
                }
            }
        }
    }

    func handleStateChange() {
        switch session.state {
        case .listening(_, let liveMatches, _):
            // Eligibility check. We schedule (or keep) an auto-open
            // when all of the following hold:
            //   1. Setting enabled (default ON).
            //   2. Exactly one match in the confidence-filtered list.
            //   3. That match's score is ≥ autoOpenScoreThreshold.
            let autoOpenEnabled = (UserDefaults.standard.object(forKey: Self.autoOpenSettingKey) as? Bool) ?? true
            guard autoOpenEnabled,
                  liveMatches.count == 1,
                  let top = liveMatches.first,
                  top.score >= Self.autoOpenScoreThreshold else {
                if autoOpenTask != nil {
                    NSLog("[DIAG] AppContainer auto-open cancelled (eligibility lost)")
                }
                autoOpenTask?.cancel()
                autoOpenTask = nil
                scheduledAutoOpenLineId = nil
                return
            }
            // Same target already scheduled? Leave the in-flight task
            // alone — otherwise every fresh partial would reset the 1 s
            // delay and auto-open would never fire while the Raagi is
            // singing the very pangti we want to open.
            if scheduledAutoOpenLineId == top.line.id, autoOpenTask != nil {
                return
            }
            autoOpenTask?.cancel()
            scheduledAutoOpenLineId = top.line.id
            NSLog("[DIAG] AppContainer auto-open scheduled topScore=\(String(format: "%.1f", top.score)) ang=\(top.line.ang) pankti=\(top.line.pangti ?? -1) lineId=\(top.line.id) — firing in \(Self.autoOpenDelaySec)s unless cancelled")
            autoOpenTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.autoOpenDelaySec * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                NSLog("[DIAG] AppContainer auto-open firing — navigatingTo ang=\(top.line.ang) pankti=\(top.line.pangti ?? -1)")
                self.commitLive(match: top)
            }
        case .done:
            // Auto-advance once: replace the recording / liveRecording
            // screen with results (so swipe-back from Results goes Home,
            // not back into recording).
            autoOpenTask?.cancel()
            autoOpenTask = nil
            scheduledAutoOpenLineId = nil
            let lastIsRecordingMode: Bool = {
                guard let last = path.last else { return false }
                if case .recording = last { return true }
                if case .liveRecording = last { return true }
                return false
            }()
            let alreadyOnResults = path.contains { route in
                if case .results = route { return true } else { return false }
            }
            if lastIsRecordingMode {
                path = Array(path.dropLast()) + [.results]
            } else if !alreadyOnResults {
                path.append(.results)
            }
        case .error:
            autoOpenTask?.cancel()
            autoOpenTask = nil
            scheduledAutoOpenLineId = nil
            showErrorAlert = true
        default:
            autoOpenTask?.cancel()
            autoOpenTask = nil
            scheduledAutoOpenLineId = nil
        }
    }

    func acknowledgeError() {
        showErrorAlert = false
        // Bug J: error acknowledgement is a terminal cleanup point —
        // release the streaming ASR so a subsequent attempt is unblocked.
        clearStreamingAsr(reason: "acknowledgeError")
        session.reset(reason: "acknowledgeError")
        path.removeAll()
    }

    // ── Lazy init ────────────────────────────────────────────────────────

    private func ensureCorpus() throws -> Corpus {
        if let c = corpus { return c }
        let url = try Self.findBundledCorpus()
        let c = try Corpus(dbPath: url)
        corpus = c
        return c
    }

    private func ensureMatcher() throws -> Matcher {
        if let m = matcher { return m }
        let m = try Matcher(corpus: try ensureCorpus())
        matcher = m
        return m
    }

    private func ensureAsr() -> WhisperOneShot {
        if let existing = asr as? WhisperOneShot { return existing }
        // WhisperKit loads + downloads lazily on the first transcribe(), so
        // constructing WhisperOneShot is free — no fallback path needed at
        // this layer. If WhisperKit can't reach huggingface.co on first
        // launch, the error bubbles through `session.runSearch` and surfaces
        // as a user-visible alert. MockAsr is reserved for SwiftUI previews
        // and unit tests.
        let modelFolder = Self.findBundledWhisperModelFolder()
        let one = WhisperOneShot(
            modelName: "openai_whisper-small",
            modelFolder: modelFolder
        )
        asr = one
        return one
    }

    /// Get / build the v2 streaming ASR (Phase A.4a facade). The
    /// underlying provider is selected from Settings — see
    /// ``StreamingASR/init()``. WhisperKitProvider manages its own
    /// WhisperKit pipe; v1's `WhisperOneShot` continues to manage its
    /// own. The cold-start cost is paid once per provider; toggling
    /// model size in Settings forces a re-load on the next session.
    private func ensureStreamingAsr() -> StreamingASR {
        if let s = streamingAsr { return s }
        let s = StreamingASR()
        streamingAsr = s
        return s
    }

    // ── Pipeline ────────────────────────────────────────────────────────

    private func startCaptureAndAwait() async {
        do {
            try capture.start()
        } catch {
            session.setError(error.localizedDescription)
        }
        // We don't await here — the user signals stop via the UI. The
        // recordingTask exists so cancelRecording() can drop us out.
    }

    // ── v2 (.live) pipeline ──────────────────────────────────────────────

    private func startLiveStreamAndAwait() async {
        NSLog("[DIAG] AppContainer.startLiveStreamAndAwait entry")

        // Phase A.4a: spin up a download-progress mirror Task if the
        // active provider is WhisperKit. WhisperKitProvider yields 0.0
        // at init start and 1.0 once the pipe loads; we mirror those
        // into `modelDownloadProgress` so LiveResultsScreen can render
        // a progress UI in the header instead of "ਸੁਣ ਰਿਹਾ ਹਾਂ…".
        let asr = ensureStreamingAsr()
        if let progress = asr.whisperDownloadProgress {
            Task { [weak self] in
                for await value in progress {
                    await MainActor.run {
                        // 1.0 means "loaded" → clear after a beat so the
                        // header swaps back to the live-listening UI.
                        if value >= 1.0 {
                            self?.modelDownloadProgress = nil
                        } else {
                            self?.modelDownloadProgress = value
                        }
                    }
                }
                await MainActor.run { self?.modelDownloadProgress = nil }
            }
        }

        // Bug A: establish .listening state on @MainActor BEFORE we await
        // anything heavy (matcher build, WhisperKit pipe construction,
        // stream startup). Otherwise the first ~30 s of cold-start
        // happens with session.state == .idle, and a user who taps Stop
        // during that window hits `case .listening = state` guards that
        // refuse the commit (Deep's 2026-06-20 log: three consecutive
        // "[DIAG] AppContainer.commitLiveStream skipping (state=idle)"
        // lines before the user gave up).
        //
        // Explicit `[Match]()` rather than `[]` and explicit `Float(0)`
        // so type inference can't get confused by the parallel A.4a/A.4b
        // merge — Xcode 16 has been seen to fail to infer empty-literal
        // types in some merge-conflict-adjacent contexts.
        session.setListening(
            text: "",
            liveMatches: [Match](),
            bufferEnergy: Float(0)
        )

        do {
            let matcher = try ensureMatcher()
            try await session.startStreaming(asr: asr, matcher: matcher)
            NSLog("[DIAG] AppContainer.startLiveStreamAndAwait stream finished (VAD or stop)")
            // Stream finished naturally — VAD detected silence. Commit.
            await commitLiveStream(preselected: nil)
        } catch {
            NSLog("[DIAG] AppContainer.startLiveStreamAndAwait threw: \(error.localizedDescription)")
            session.setError(error.localizedDescription)
        }
    }

    private func commitLiveStream(preselected: Match?) async {
        // Bug I: single-fire flag set SYNCHRONOUSLY before any await so
        // concurrent commit calls (rapid Stop taps, Stop + silence-VAD
        // firing simultaneously, etc.) are guaranteed to no-op except
        // for the first one. The state guard below is necessary but not
        // sufficient — by the time we await ensureStreamingAsr the second
        // caller might still see state == .listening because setCommitting
        // hasn't run yet on the first caller.
        if commitInFlight {
            NSLog("[DIAG] AppContainer.commitLiveStream re-entry blocked (commitInFlight=true)")
            return
        }
        commitInFlight = true
        defer { commitInFlight = false }

        // Guard: only commit while we're actually listening / committing.
        // If the session is already .done (e.g. duplicate Stop tap), no-op.
        guard case .listening = session.state else {
            if case .committing = session.state {
                NSLog("[DIAG] AppContainer.commitLiveStream already .committing — skipping")
            } else {
                NSLog("[DIAG] AppContainer.commitLiveStream skipping (state=\(String(describing: session.state)))")
            }
            return
        }
        do {
            let asr = ensureStreamingAsr()
            let matcher = try ensureMatcher()
            // Phase A.4b — spend a cloud trial credit BEFORE the commit
            // network call if the active provider is cloud. By the time
            // we reach commitLiveStream the cost has been incurred
            // whether the matcher returns anything or not (Sarvam WS /
            // Gemini chunked POSTs ran during the listening phase).
            // Charging on commit keeps the counter honest. If the trial
            // is already exhausted on entry, force the user back to
            // Whisper + surface the message; don't run commit.
            let activeProvider = asr.activeProviderId
            if activeProvider != .whisperKit {
                if let remaining = CloudTrialPolicy.tryConsume() {
                    NSLog("[DIAG] AppContainer cloud trial consumed (provider=\(activeProvider.rawValue) remaining=\(remaining))")
                    if remaining == 0 {
                        CloudTrialPolicy.forceDisable()
                        // Don't block this in-flight commit — the user
                        // has already spoken; the result still lands.
                        // Next session uses Whisper.
                    }
                } else {
                    CloudTrialPolicy.forceDisable()
                    clearStreamingAsr(reason: "cloudTrialExhausted")
                    session.setError("Free cloud trial used up for this month. Switched back to Local Whisper — try again.")
                    return
                }
            }
            let result = await session.commit(asr: asr, matcher: matcher)
            NSLog("[DIAG] AppContainer.commitLiveStream done matches=\(result.matches.count) preselected=\(preselected?.line.id ?? "nil")")

            // Bug J: now that the commit fully landed, release the
            // streaming ASR so the Bug F guards stop refusing future
            // startRecording / startLiveRecording calls. The instance has
            // already stopped its mic via session.commit → asr.stop().
            clearStreamingAsr(reason: "commitDone")

            // If the user tapped a row (or auto-open fired), open that
            // Shabad directly. handleStateChange() already pushed
            // .results when .done fired — KEEP it in the back stack so
            // swipe-back from .shabad returns to the results list
            // instead of dropping the user to Home. Path winds up as
            // [.results, .shabad].
            if let preselected = preselected {
                await MainActor.run {
                    self.openShabad(for: preselected)
                }
            }
        } catch {
            NSLog("[DIAG] AppContainer.commitLiveStream threw: \(error.localizedDescription)")
            // Bug J: also release on the error path so a retry isn't
            // permanently blocked by the Bug F guard.
            clearStreamingAsr(reason: "commitError")
            session.setError(error.localizedDescription)
        }
    }

    // ── v1 (.oneShot) pipeline ───────────────────────────────────────────

    private func runSearchAndDone(samples: [Float]) async {
        NSLog("[DIAG] AppContainer.runSearchAndDone entry samples=\(samples.count)")
        if samples.isEmpty {
            session.setError("No audio captured. Try again.")
            return
        }
        // Persist the captured clip to Documents/ before we hand it to
        // WhisperKit. Lets us extract it via Xcode → Devices → Download
        // Container and listen to exactly what the ASR received. Failure to
        // write is non-fatal — we still try to transcribe.
        do {
            let url = try WaveWriter.saveCaptureToDocuments(samples: samples)
            NSLog("[DIAG] AppContainer.runSearchAndDone wrote capture WAV to \(url.path)")
        } catch {
            NSLog("[DIAG] AppContainer.runSearchAndDone WAV write FAILED: \(error.localizedDescription)")
        }
        do {
            let asr = ensureAsr()
            let matcher = try ensureMatcher()
            _ = try await session.runSearch(samples: samples, asr: asr, matcher: matcher)
            NSLog("[DIAG] AppContainer.runSearchAndDone runSearch returned cleanly")
        } catch {
            NSLog("[DIAG] AppContainer.runSearchAndDone runSearch threw: \(error.localizedDescription)")
            session.setError(error.localizedDescription)
        }
    }

    // ── Bundle lookups ──────────────────────────────────────────────────

    private static func findBundledCorpus() throws -> URL {
        for name in ["app_database", "sggs", "database"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "sqlite") {
                return url
            }
        }
        throw NSError(
            domain: "GurbaniLens", code: 10,
            userInfo: [NSLocalizedDescriptionKey:
                "Bundled SGGS database missing. Run `bash scripts/fetch_ios_deps.sh` then re-run XcodeGen."]
        )
    }

    /// Look for a pre-bundled WhisperKit CoreML model directory in the app
    /// bundle (e.g. Resources/Models/openai_whisper-small/). Returns the
    /// absolute path so WhisperKit can load it without hitting the network.
    /// Returns nil when no pre-bundled model is present — caller passes nil
    /// to WhisperKit, which then auto-downloads from
    /// huggingface.co/argmaxinc/whisperkit-coreml on first launch.
    private static func findBundledWhisperModelFolder() -> String? {
        let candidates = [
            "openai_whisper-small",
            "openai_whisper-base",
            "openai_whisper-tiny",
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               (try? url.checkResourceIsReachable()) == true {
                return url.path
            }
        }
        return nil
    }
}
