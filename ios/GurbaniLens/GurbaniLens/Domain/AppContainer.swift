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

    private func ensureAsr() async -> Asr {
        if let a = asr { return a }
        do {
            let modelURL = try Self.findBundledWhisperModel()
            let one = try WhisperOneShot(modelURL: modelURL)
            asr = one
            return one
        } catch {
            // Graceful: keep the UI usable with a canned transcript so Deep
            // can exercise nav before the model is in place. The error label
            // explains the fallback so it's visible in QA.
            NSLog("AppContainer: Whisper init failed (\(error)). Falling back to MockAsr.")
            let mock = MockAsr()
            asr = mock
            return mock
        }
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
            let asr = await ensureAsr()
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

    private static func findBundledWhisperModel() throws -> URL {
        // small is the Phase 2A v1 default; base/medium can be downloaded
        // from Settings in a v1.1 follow-up.
        for name in ["ggml-small", "ggml-base", "ggml-medium", "ggml-tiny"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "bin") {
                return url
            }
        }
        throw NSError(
            domain: "GurbaniLens", code: 11,
            userInfo: [NSLocalizedDescriptionKey:
                "No Whisper ggml-*.bin bundled. Run `bash scripts/fetch_ios_deps.sh` then re-run XcodeGen."]
        )
    }
}
