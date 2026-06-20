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
        session.reset()
        returnHome()
    }

    func returnHome() {
        path.removeAll()
        session.reset()
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
        Task { [weak self] in
            await self?.streamingAsr?.stop()
        }
        session.reset()
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
        case .done:
            // Auto-advance once: replace the recording / liveRecording
            // screen with results (so swipe-back from Results goes Home,
            // not back into recording).
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
            showErrorAlert = true
        default:
            break
        }
    }

    func acknowledgeError() {
        showErrorAlert = false
        session.reset()
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

    /// Get / build the v2 streaming ASR. Shares the WhisperKit pipe with
    /// `ensureAsr()` so model load + CoreML cold-start are paid once
    /// across both v1 and v2 modes.
    private func ensureStreamingAsr() async throws -> StreamingASR {
        if let s = streamingAsr { return s }
        let oneShot = ensureAsr()
        let pipe = try await oneShot.sharedPipe()
        let s = StreamingASR(pipe: pipe, language: "pa")
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
        do {
            let asr = try await ensureStreamingAsr()
            let matcher = try ensureMatcher()
            try await session.startStreaming(asr: asr, matcher: matcher)
            NSLog("[DIAG] AppContainer.startLiveStreamAndAwait stream finished (VAD or stop)")
            // Stream finished naturally — VAD detected silence. Commit.
            // Don't pass a preselected match — let the user choose from
            // the final Results screen.
            await commitLiveStream(preselected: nil)
        } catch {
            NSLog("[DIAG] AppContainer.startLiveStreamAndAwait threw: \(error.localizedDescription)")
            session.setError(error.localizedDescription)
        }
    }

    private func commitLiveStream(preselected: Match?) async {
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
            let asr = try await ensureStreamingAsr()
            let matcher = try ensureMatcher()
            let result = await session.commit(asr: asr, matcher: matcher)
            NSLog("[DIAG] AppContainer.commitLiveStream done matches=\(result.matches.count) preselected=\(preselected?.line.id ?? "nil")")

            // If the user tapped a row, open that Shabad directly instead
            // of routing through Results. handleStateChange() already moved
            // us to Results when .done fired; pop it back off + push Shabad.
            if let preselected = preselected {
                // Wait one runloop turn for handleStateChange to push
                // .results, then replace with the shabad route. Cleaner
                // than racing handleStateChange.
                await MainActor.run {
                    if case .results = self.path.last {
                        self.path.removeLast()
                    }
                    self.openShabad(for: preselected)
                }
            }
        } catch {
            NSLog("[DIAG] AppContainer.commitLiveStream threw: \(error.localizedDescription)")
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
