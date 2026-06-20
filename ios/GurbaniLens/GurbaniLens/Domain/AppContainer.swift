import Foundation
import SwiftUI
import GurbaniLensCore

/// App-scoped orchestrator. Owns the corpus + matcher (lazy), the ASR engine
/// (lazy), the recording capture, the ``VoiceSearchSession`` state, and the
/// ``NavigationStack`` path. Mirrors `android/.../MainActivity.kt`'s role.
@MainActor
public final class AppContainer: ObservableObject {

    // ── Published UI state ───────────────────────────────────────────────
    @Published public var path: [Route] = []
    @Published public var session = VoiceSearchSession()
    @Published public var showErrorAlert: Bool = false

    // ── Backing pipeline (lazy because each is heavy) ────────────────────
    private var corpus: Corpus?
    private var matcher: Matcher?
    private var asr: Asr?
    private let capture = RecordingCapture()

    private var recordingTask: Task<Void, Never>?

    public init() {
        capture.onPeak = { [weak self] peak in
            // Trampoline back to main; SwiftUI views must be touched on @MainActor.
            Task { @MainActor in self?.session.setRecording(peak: peak) }
        }
    }

    // ── User intents ─────────────────────────────────────────────────────

    public func startRecording() {
        // Push the Recording screen immediately so the UI feels responsive
        // even if mic permission needs to be requested.
        path.append(.recording)
        session.setRecording(peak: 0)
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            await self?.startCaptureAndAwait()
        }
    }

    public func stopRecording() {
        let samples = capture.stop()
        Task { [weak self] in await self?.runSearchAndDone(samples: samples) }
    }

    public func cancelRecording() {
        recordingTask?.cancel()
        capture.cancel()
        session.reset()
        returnHome()
    }

    public func returnHome() {
        path.removeAll()
        session.reset()
    }

    public func openShabad(for match: Match) {
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

    public func handleStateChange() {
        switch session.state {
        case .done:
            // Auto-advance once: replace the recording screen with results
            // (so swipe-back from Results goes Home, not back into Recording).
            let lastIsRecording: Bool = {
                guard let last = path.last else { return false }
                if case .recording = last { return true }
                return false
            }()
            let alreadyOnResults = path.contains { route in
                if case .results = route { return true } else { return false }
            }
            if lastIsRecording {
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

    public func acknowledgeError() {
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

    private func ensureAsr() -> Asr {
        if let a = asr { return a }
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

    private func runSearchAndDone(samples: [Float]) async {
        if samples.isEmpty {
            session.setError("No audio captured. Try again.")
            return
        }
        do {
            let asr = ensureAsr()
            let matcher = try ensureMatcher()
            _ = try await session.runSearch(samples: samples, asr: asr, matcher: matcher)
        } catch {
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
