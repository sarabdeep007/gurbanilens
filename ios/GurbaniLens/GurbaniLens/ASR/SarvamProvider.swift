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

    // Defaults exposed as `public static let` so the `public nonisolated
    // static func transcribeOneShot(... model: String = defaultModel,
    // ...)` batch helper below can reference them in its default-argument
    // expressions. Swift requires default-argument symbols to be at least
    // as visible as the enclosing function — bumping these from private to
    // public is the minimum-friction fix and matches `batchEndpoint`.
    public static let defaultEndpoint = URL(string: "wss://api.sarvam.ai/speech-to-text/ws")!
    public static let defaultModel = "saaras:v3"
    public static let defaultLanguage = "pa-IN"

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

        // Build the WebSocket URL with config as query params per the
        // AVR production reference (agentvoiceresponse/avr-asr-sarvam,
        // index.js) + Sarvam docs. Param-name details that matter:
        //   - `language-code` uses a HYPHEN, not an underscore (was a
        //     bug in hotfix-4: `language_code`).
        //   - `input_audio_codec=pcm_s16le` declares the wire format;
        //     CloudMicCapture emits 16 kHz mono s16le. Required.
        //   - `sample_rate=16000` is explicit even though docs say it
        //     defaults to 16000 — safer.
        //   - `mode=transcribe` is the documented default but we set it
        //     explicitly so model-config drift can't surprise us.
        //   - `high_vad_sensitivity=true` improves cut-in for short
        //     Pangti recitations.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "model", value: model))
        queryItems.append(URLQueryItem(name: "language-code", value: language))
        queryItems.append(URLQueryItem(name: "mode", value: "transcribe"))
        queryItems.append(URLQueryItem(name: "sample_rate", value: "16000"))
        queryItems.append(URLQueryItem(name: "input_audio_codec", value: "pcm_s16le"))
        queryItems.append(URLQueryItem(name: "high_vad_sensitivity", value: "true"))
        components?.queryItems = queryItems
        guard let urlWithParams = components?.url else {
            throw SarvamError.webSocketFailed(underlying: NSError(domain: "SarvamProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build URL with query params"]))
        }
        var req = URLRequest(url: urlWithParams)
        // Header name is case-insensitive per HTTP, but mirror AVR's
        // exact spelling (`Api-Subscription-Key`) for parity.
        req.setValue(apiKey, forHTTPHeaderField: "Api-Subscription-Key")

        let urlSession = URLSession(configuration: .default)
        self.session = urlSession
        let wsTask = urlSession.webSocketTask(with: req)
        self.task = wsTask
        wsTask.resume()

        NSLog("[DIAG] SarvamProvider WS connecting to \(urlWithParams.absoluteString.replacingOccurrences(of: apiKey, with: "<KEY>"))")

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
        // Per AVR reference, end-of-stream is just a WS close — Sarvam
        // does NOT take a `{"type":"stop"}` message (previous impl sent
        // one speculatively; harmless if ignored but cleaner to drop).
        if let task = task {
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

    /// Send one s16le audio chunk to Sarvam as a JSON-wrapped base64
    /// text frame per AVR `index.js`:
    ///
    /// ```
    /// sarvamWs.send(JSON.stringify({
    ///   audio: {
    ///     data: Buffer.from(chunk).toString('base64'),
    ///     sample_rate: "16000",
    ///     encoding: "audio/wav"
    ///   }
    /// }));
    /// ```
    ///
    /// The previous impl sent `chunk` as a raw binary WebSocket frame
    /// (`.data(chunk)`) which Sarvam rejected by closing the
    /// connection — Deep's [DIAG] logs showed `readLoop terminated:
    /// Socket is not connected` ~500-700 ms after the first audio
    /// frame, on 4/4 attempts. JSON-wrapping is the fix.
    private func sendAudio(_ chunk: Data) async {
        guard let task = task else { return }
        let base64 = chunk.base64EncodedString()
        let payload: [String: Any] = [
            "audio": [
                "data": base64,
                "sample_rate": "16000",
                "encoding": "audio/wav"
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            NSLog("[DIAG] SarvamProvider sendAudio JSON serialize FAILED chunkBytes=\(chunk.count)")
            return
        }
        do {
            try await task.send(.string(jsonString))
        } catch {
            NSLog("[DIAG] SarvamProvider sendAudio FAILED: \(error.localizedDescription) chunkBytes=\(chunk.count)")
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

        // Sarvam server envelope (per AVR `index.js` + docs):
        //   { "type": "data" | "events" | "error", "data": { ... } }
        // The transcript path is type=="data", data.transcript.
        // VAD events arrive as type=="events" (when vad_signals=true) —
        // we don't surface those to the UI yet, just log.
        if let type = dict["type"] as? String {
            switch type {
            case "data":
                break // fall through to extractTranscript below
            case "events":
                if let inner = dict["data"] as? [String: Any] {
                    NSLog("[DIAG] SarvamProvider VAD event: \(inner)")
                }
                return
            case "error":
                let msg = (dict["data"] as? [String: Any])?["message"] as? String
                    ?? "unknown Sarvam error"
                NSLog("[DIAG] SarvamProvider server error: \(msg) full=\(String(jsonStr.prefix(200)))")
                return
            default:
                NSLog("[DIAG] SarvamProvider unknown message type=\(type) head=\(String(jsonStr.prefix(120)))")
                return
            }
        }

        // Legacy / fallback path: some Sarvam endpoints return a flat
        // `{transcript: ...}` or `{error: ...}` without the type
        // envelope. Surface server errors so they don't silently get
        // treated as transcripts.
        if let err = dict["error"] as? String ?? (dict["error"] as? [String: Any])?["message"] as? String {
            NSLog("[DIAG] SarvamProvider server error (no-type envelope): \(err)")
            return
        }

        // extractSarvamTranscript handles `transcript`, `text`,
        // `data.transcript`, `data.text`, and Google-style
        // `results.alternatives.transcript`. Covers both type-enveloped
        // and flat shapes.
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

    // MARK: - Pure parsing helpers (thin wrappers over CloudParsing)

    /// Pluck the transcript text out of a parsed Sarvam JSON envelope.
    /// Thin wrapper over ``CloudParsing/extractSarvamTranscript`` so the
    /// provider keeps its own type-level API surface while the actual
    /// parsing rules live in `GurbaniLensCore` (testable via swift test).
    public nonisolated static func extractTranscript(from dict: [String: Any]) -> String? {
        return CloudParsing.extractSarvamTranscript(from: dict)
    }

    /// Re-exported script kind to keep call-sites readable.
    public typealias ScriptKind = CloudParsing.ScriptKind

    public nonisolated static func detectScript(_ text: String) -> ScriptKind {
        return CloudParsing.detectScript(text)
    }

    /// Produce a fully-populated ``Partial`` from a raw Sarvam transcript.
    /// Exposed for tests + ``CompareScreen``.
    public nonisolated static func makePartial(
        raw: String,
        isSpeaking: Bool,
        bufferEnergy: Float
    ) -> Partial {
        let script = CloudParsing.detectScript(raw)
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

    // MARK: - Batch helper (used by CompareScreen)

    /// REST batch endpoint for one-shot Saaras transcription. Streaming
    /// is the live-search path; Compare mode (record-once-then-compare)
    /// needs a synchronous request/response per recording.
    ///
    /// Endpoint: POST https://api.sarvam.ai/speech-to-text
    ///   - multipart/form-data with `file` (WAV blob), `model`, `language_code`
    ///   - header `api-subscription-key: <key>`
    ///   - response JSON: { "transcript": "..." }
    public static let batchEndpoint = "https://api.sarvam.ai/speech-to-text"

    /// One-shot transcribe of a WAV blob via Sarvam's REST batch endpoint.
    /// Used by ``CompareScreen``. Returns the transcript text (Gurmukhi
    /// or Devanagari depending on what the model emits — caller routes
    /// through `Latin.from` / `Gurmukhi.fromDevanagari` for display).
    public nonisolated static func transcribeOneShot(
        wav: Data,
        apiKey: String,
        endpoint: String = batchEndpoint,
        model: String = defaultModel,
        languageCode: String = "pa-IN",
        urlSession: URLSession = .shared
    ) async throws -> String {
        if apiKey.isEmpty { throw SarvamError.missingApiKey }
        guard let url = URL(string: endpoint) else { throw SarvamError.invalidEndpoint }

        // Build a tiny multipart/form-data body.
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", model)
        appendField("language_code", languageCode)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"compare.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SarvamError.webSocketFailed(underlying: NSError(
                domain: "SarvamProvider", code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(String(bodyStr.prefix(200)))"]
            ))
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return extractTranscript(from: dict) ?? ""
    }

}
