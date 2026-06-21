import Foundation
import GurbaniLensCore

/// Sarvam Saaras-v3 streaming ASR backend. Conforms to ``ASRProvider``
/// so it slots into ``StreamingASR``'s `@AppStorage("settings.asrProvider")`
/// switch.
///
/// **Why Saaras.** Phase 1 measured Whisper-medium at ~31% confident-match
/// rate on sung Kirtan because Whisper's Indic-script training is shallow.
/// Sarvam's Saaras family is purpose-built for Indian languages (the
/// docs claim native Punjabi support without a `pa→hi` remap) — the
/// hypothesis being tested in Compare mode is that for spoken Punjabi
/// recitation Sarvam beats Whisper-large-v3.
///
/// **API contract (verify against docs.sarvam.ai).**
///   - Endpoint: `wss://api.sarvam.ai/speech-to-text/streaming`
///   - Auth:    `api-subscription-key: <SARVAM_API_KEY>` header on the
///              upgrade request
///   - Audio:   binary frames carrying 16 kHz mono s16le PCM, ~100 ms each
///   - Init:    a JSON config message before audio:
///                { "type": "config", "model": "saaras:v3",
///                  "language": "pa", "encoding": "linear16",
///                  "sample_rate": 16000 }
///   - Result:  text frames with JSON `{ "transcript": "...", "is_final": bool, ... }`
///   - Stop:    send `{ "type": "stop" }` then close
///
/// If the live Sarvam streaming spec differs once Deep populates the
/// .env and tries Compare mode, surface in the HOLD and Deep will patch
/// the config message / response parser inline. The rest of the surface
/// (AsyncStream wiring, script auto-detect, energy accounting) stays.
///
/// **Long-term TODO.** Route through Taaj backend (api.taajsingh.com) so
/// the Sarvam API key never ships to a user device. v1 is direct-to-Sarvam
/// for the Compare-mode A/B test only.
public actor SarvamProvider: ASRProvider {

    // MARK: - Errors

    public enum SarvamError: LocalizedError {
        case missingApiKey
        case invalidEndpoint
        case webSocketFailed(underlying: Error)
        case captureFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "SARVAM_API_KEY missing. Add it to .env at the repo root and rebuild."
            case .invalidEndpoint:
                return "Sarvam endpoint URL is not parseable."
            case .webSocketFailed(let e):
                return "Sarvam WebSocket connection failed: \(e.localizedDescription)"
            case .captureFailed(let e):
                return "Sarvam mic capture failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - ASRProvider identity

    public nonisolated let providerId: ASRProviderId = .sarvam
    public nonisolated let displayName: String = "Sarvam Saaras-v3"
    public nonisolated let requiresNetwork: Bool = true

    // MARK: - Config

    private static let defaultEndpoint = URL(string: "wss://api.sarvam.ai/speech-to-text/streaming")!
    private static let defaultModel = "saaras:v3"
    private static let defaultLanguage = "pa"

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let language: String

    // MARK: - Streaming state

    private let capture: CloudMicCapture
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

    private var lastEnergy: Float = 0
    private var lastIsSpeaking: Bool = false

    // MARK: - Init

    public init(
        apiKey: String? = nil,
        endpoint: URL? = nil,
        model: String? = nil,
        language: String? = nil
    ) {
        let envKey = apiKey
            ?? Bundle.main.object(forInfoDictionaryKey: "SARVAM_API_KEY") as? String
            ?? ""
        self.apiKey = envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.model = model ?? Self.defaultModel
        self.language = language ?? Self.defaultLanguage
        self.capture = CloudMicCapture()

        if self.apiKey.isEmpty {
            NSLog("[DIAG] SarvamProvider.init no API key (will fail at start) — populate SARVAM_API_KEY in .env")
        } else {
            NSLog("[DIAG] SarvamProvider.init endpoint=\(self.endpoint.absoluteString) model=\(self.model) language=\(self.language) keyLen=\(self.apiKey.count)")
        }
    }

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        if apiKey.isEmpty { throw SarvamError.missingApiKey }

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont

        // Build WebSocket task with the API key on the upgrade request.
        var req = URLRequest(url: endpoint)
        req.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        req.setValue(apiKey, forHTTPHeaderField: "Authorization") // some Sarvam endpoints use Bearer-style — send both, server picks one

        let urlSession = URLSession(configuration: .default)
        self.session = urlSession
        let wsTask = urlSession.webSocketTask(with: req)
        self.task = wsTask
        wsTask.resume()

        // Tell the server what's coming. Config message format follows
        // Sarvam's documented streaming setup; adjust here if the live
        // contract differs.
        let configMessage: [String: Any] = [
            "type": "config",
            "model": model,
            "language": language,
            "encoding": "linear16",
            "sample_rate": 16000,
            "interim_results": true
        ]
        if let configData = try? JSONSerialization.data(withJSONObject: configMessage),
           let configStr = String(data: configData, encoding: .utf8) {
            do {
                try await wsTask.send(.string(configStr))
                NSLog("[DIAG] SarvamProvider config sent: \(configStr)")
            } catch {
                NSLog("[DIAG] SarvamProvider config send FAILED: \(error.localizedDescription)")
                throw SarvamError.webSocketFailed(underlying: error)
            }
        }

        // Start the read loop and the mic uploader. Both are detached
        // Tasks; they share the `task` socket and exit when stop() is
        // called or the socket fails.
        Task { [weak self] in await self?.readLoop() }

        do {
            let chunkStream = try capture.start()
            // Per-tap VU peak — wire onto our tracked energy + speaking
            // state so partials reflect liveness.
            capture.onPeak = { [weak self] peak in
                guard let self else { return }
                Task { await self.recordPeak(peak) }
            }
            Task { [weak self] in
                guard let self else { return }
                for await chunk in chunkStream {
                    await self.sendAudio(chunk)
                }
                await self.handleCaptureEnded()
            }
        } catch {
            NSLog("[DIAG] SarvamProvider capture.start FAILED: \(error.localizedDescription)")
            throw SarvamError.captureFailed(underlying: error)
        }

        NSLog("[DIAG] SarvamProvider.start streaming begun")
    }

    public func stop() async {
        NSLog("[DIAG] SarvamProvider.stop()")
        // Tell server we're done. Best-effort — the close itself stops the stream.
        if let task = task {
            let stopMsg = #"{"type":"stop"}"#
            try? await task.send(.string(stopMsg))
            task.cancel(with: .normalClosure, reason: nil)
        }
        capture.stop()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func recordPeak(_ peak: Float) {
        lastEnergy = peak
        lastIsSpeaking = peak > 0.02
    }

    private func sendAudio(_ chunk: Data) async {
        guard let task = task else { return }
        do {
            try await task.send(.data(chunk))
        } catch {
            NSLog("[DIAG] SarvamProvider sendAudio FAILED: \(error.localizedDescription)")
        }
    }

    private func handleCaptureEnded() {
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    private func readLoop() async {
        guard let task = task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let s):
                    handleServerJson(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        handleServerJson(s)
                    }
                @unknown default:
                    break
                }
            } catch {
                NSLog("[DIAG] SarvamProvider readLoop terminated: \(error.localizedDescription)")
                partialsContinuation?.finish()
                partialsContinuation = nil
                return
            }
        }
    }

    private func handleServerJson(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            NSLog("[DIAG] SarvamProvider received non-JSON or unparseable message: \(String(jsonStr.prefix(120)))")
            return
        }

        // Surface server errors so they don't silently get treated as transcripts.
        if let err = dict["error"] as? String ?? (dict["error"] as? [String: Any])?["message"] as? String {
            NSLog("[DIAG] SarvamProvider server error: \(err)")
            return
        }

        // Sarvam's interim/final result shape (verify against docs.sarvam.ai):
        //   { "transcript": "...", "is_final": bool, ... }
        // Other endpoints may use { "data": { "transcript": "..." } }.
        let transcript = Self.extractTranscript(from: dict)
        guard let raw = transcript, !raw.isEmpty else { return }

        let partial = Self.makePartial(
            raw: raw,
            isSpeaking: lastIsSpeaking,
            bufferEnergy: lastEnergy
        )
        let script = Self.detectScript(raw)
        NSLog("[DIAG] SarvamProvider partial transcript.len=\(raw.count) script=\(script.rawValue) latin.head60=\"\(String(partial.latin.prefix(60)))\" gurmukhi.head60=\"\(String(partial.gurmukhi.prefix(60)))\"")
        partialsContinuation?.yield(partial)
    }

    // MARK: - Pure parsing helpers (exposed for tests)

    /// Pluck the transcript text out of a parsed Sarvam JSON envelope.
    /// Handles the common shapes documented for the streaming endpoint
    /// at the time of writing; falls back to the most likely candidate
    /// keys if the wire format drifts. Returns nil when no plausible
    /// transcript field is present.
    public nonisolated static func extractTranscript(from dict: [String: Any]) -> String? {
        if let s = dict["transcript"] as? String { return Self.sanitize(s) }
        if let s = dict["text"] as? String { return Self.sanitize(s) }
        if let data = dict["data"] as? [String: Any] {
            if let s = data["transcript"] as? String { return Self.sanitize(s) }
            if let s = data["text"] as? String { return Self.sanitize(s) }
        }
        if let results = dict["results"] as? [[String: Any]],
           let first = results.first,
           let alternatives = first["alternatives"] as? [[String: Any]],
           let alt = alternatives.first,
           let s = alt["transcript"] as? String { return Self.sanitize(s) }
        return nil
    }

    public enum ScriptKind: String {
        case gurmukhi
        case devanagari
        case other
    }

    public nonisolated static func detectScript(_ text: String) -> ScriptKind {
        var g = 0, d = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A00...0x0A7F: g += 1
            case 0x0900...0x097F: d += 1
            default: break
            }
        }
        if g == 0 && d == 0 { return .other }
        return g >= d ? .gurmukhi : .devanagari
    }

    /// Produce a fully-populated ``Partial`` from a raw Sarvam transcript.
    /// Exposed for tests + ``CompareScreen``.
    public nonisolated static func makePartial(
        raw: String,
        isSpeaking: Bool,
        bufferEnergy: Float
    ) -> Partial {
        let script = detectScript(raw)
        let latin = Latin.from(raw)
        let gurmukhi: String
        switch script {
        case .gurmukhi:
            gurmukhi = raw
        case .devanagari:
            gurmukhi = Gurmukhi.fromDevanagari(raw)
        case .other:
            gurmukhi = raw
        }
        return Partial(
            text: raw,
            latin: latin,
            gurmukhi: gurmukhi,
            isSpeaking: isSpeaking,
            bufferEnergy: bufferEnergy
        )
    }

    private nonisolated static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop common LLM/transcription prefixes that sometimes leak.
        let dropPrefixes = ["Transcript:", "transcript:", "Text:"]
        for p in dropPrefixes where out.hasPrefix(p) {
            out = String(out.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip stray triple-backtick wrappers.
        if out.hasPrefix("```") && out.hasSuffix("```") {
            out = String(out.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}
