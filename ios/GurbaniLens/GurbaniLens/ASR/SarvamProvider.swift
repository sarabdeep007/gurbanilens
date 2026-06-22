import Foundation
import GurbaniLensCore
import Starscream

/// Sarvam Saaras-v3 ASR backend. Conforms to ``ASRProvider`` so it slots
/// into ``StreamingASR``'s `@AppStorage("settings.asrProvider")` switch.
///
/// **v1 live path: Starscream WebSocket streaming.** The Sarvam streaming
/// WS API works on every platform we've tried *except* Apple's
/// ``URLSessionWebSocketTask``, which fails with "Socket is not
/// connected" ~500 ms after the first audio frame (4/4 attempts). The
/// wire format itself is correct — same JSON-wrapped base64 chunks the
/// Linux validation script uses successfully — but URLSessionWebSocketTask
/// can't keep the socket alive on iOS. Starscream is built on
/// `Network.framework` / NWConnection and is production-proven for iOS
/// WebSockets (Lyft, Square, Trello). See
/// `scripts/sarvam-investigation/WORKING_PROTOCOL.md` for the wire format.
///
/// **UX.** Live segment-by-segment transcripts: as Sarvam's server-side
/// VAD closes each utterance, a ``Partial`` arrives with the accumulated
/// transcript. ``VoiceSearchSession`` runs `matchByFirstLetters` on each
/// growing partial, so search results refresh as the user speaks.
///
/// **Why Saaras.** Phase 1 measured Whisper-medium at ~31% confident-match
/// rate on sung Kirtan because Whisper's Indic-script training is shallow.
/// Sarvam's Saaras family is purpose-built for Indian languages (native
/// Punjabi without a `pa→hi` remap).
///
/// **Long-term TODO.** Route through Taaj backend (api.taajsingh.com) so
/// the Sarvam API key never ships to a user device.
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
                return "Sarvam request failed: \(e.localizedDescription)"
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

    public static let defaultEndpoint = URL(string: "wss://api.sarvam.ai/speech-to-text/ws")!
    public static let defaultModel = "saaras:v3"
    public static let defaultLanguage = "pa-IN"

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let language: String

    // MARK: - Streaming state

    private let capture: CloudMicCapture
    /// When non-nil, ``start()`` skips `capture.start()` and uses this
    /// pre-built stream as the audio source. Set by ``DualLiveProvider``
    /// so a single ``CloudMicCapture`` feeds both Whisper + Sarvam via a
    /// ``ChunkBroadcaster``. Cleared on stop().
    private var externalAudioStream: AsyncStream<Data>?
    private var handler: SarvamStreamingHandler?
    private var audioConsumerTask: Task<Void, Never>?

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

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
            NSLog("[DIAG] SarvamProvider.init model=\(self.model) language=\(self.language) keyLen=\(self.apiKey.count)")
        }
    }

    /// **Dual-provider hook.** Inject an externally-managed audio stream
    /// (typically from a ``ChunkBroadcaster`` consumer) before
    /// ``start()`` is called. The provider will skip its own
    /// `CloudMicCapture.start()` and consume the supplied stream
    /// instead. Pass nil to clear and fall back to owning capture.
    public func useExternalAudioStream(_ stream: AsyncStream<Data>?) {
        self.externalAudioStream = stream
    }

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        if apiKey.isEmpty { throw SarvamError.missingApiKey }

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont

        NSLog("[DIAG] SarvamProvider.start (Starscream streaming mode)")

        // Build WS URL with the exact query params validated against
        // Sarvam's live endpoint from Linux. Note the inconsistent
        // separator convention: `language-code` is hyphenated, the
        // rest use underscores. That's Sarvam's API — don't normalise.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language-code", value: language),
            URLQueryItem(name: "mode", value: "transcribe"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "input_audio_codec", value: "pcm_s16le"),
            URLQueryItem(name: "high_vad_sensitivity", value: "true"),
        ]
        guard let url = components?.url else {
            partialsContinuation?.finish()
            partialsContinuation = nil
            throw SarvamError.invalidEndpoint
        }

        let keyRedacted = url.absoluteString.replacingOccurrences(of: apiKey, with: "<KEY>")
        NSLog("[DIAG] SarvamProvider WS connecting to \(keyRedacted)")

        // Capture the continuation locally so the handler closures (which
        // run on Starscream's callback queue, off-actor) can yield without
        // crossing the actor boundary. AsyncStream.Continuation is Sendable.
        let contRef = cont
        let h = SarvamStreamingHandler(
            url: url,
            apiKey: apiKey,
            onPartial: { partial in
                // Re-wrap with .sarvam source so DualLiveProvider /
                // VoiceSearchSession can tell who emitted which partial.
                let tagged = Partial(
                    text: partial.text,
                    latin: partial.latin,
                    gurmukhi: partial.gurmukhi,
                    isSpeaking: partial.isSpeaking,
                    bufferEnergy: partial.bufferEnergy,
                    source: .sarvam
                )
                contRef.yield(tagged)
            }
        )
        self.handler = h
        h.connect()

        do {
            // Two audio paths:
            //   1. external (dual-provider mode) — broadcaster already
            //      owns the CloudMicCapture; skip our own.
            //   2. own capture (sarvam-only mode) — behaviour as before.
            let chunkStream: AsyncStream<Data>
            if let external = externalAudioStream {
                NSLog("[DIAG] SarvamProvider using EXTERNAL audio stream (dual-provider mode)")
                chunkStream = external
            } else {
                chunkStream = try capture.start()
                // Per-tap VU peak → forward as a transcript-less Partial
                // so the level meter animates. Bug-B freeze-last-good in
                // VoiceSearchSession prevents these empty-text partials
                // from clobbering accumulated transcript text.
                capture.onPeak = { [weak self] peak in
                    guard let self else { return }
                    Task { await self.recordPeak(peak) }
                }
            }

            // Audio consumer runs OUTSIDE the actor (Task.detached) so the
            // high-frequency chunk arrival is not gated on the actor's
            // mailbox — see hotfix-5. The handler's sendAudio is itself
            // lock-protected.
            let handlerRef = h
            self.audioConsumerTask = Task.detached(priority: .userInitiated) {
                var loopCount = 0
                for await chunk in chunkStream {
                    handlerRef.sendAudio(chunk)
                    loopCount += 1
                    if loopCount <= 5 || loopCount % 50 == 0 {
                        NSLog("[DIAG] SarvamProvider audioConsumer chunk #\(loopCount) size=\(chunk.count) connected=\(handlerRef.isConnected)")
                    }
                }
                NSLog("[DIAG] SarvamProvider audioConsumer loop EXITED totalChunks=\(loopCount)")
            }
        } catch {
            NSLog("[DIAG] SarvamProvider capture.start FAILED: \(error.localizedDescription)")
            h.disconnect()
            self.handler = nil
            partialsContinuation?.finish()
            partialsContinuation = nil
            throw SarvamError.captureFailed(underlying: error)
        }
    }

    public func stop() async {
        NSLog("[DIAG] SarvamProvider.stop() external=\(externalAudioStream != nil)")
        // Only stop our own capture if we own it. In dual-provider mode
        // the broadcaster's upstream is the one to stop — owned by
        // DualLiveProvider, not us.
        if externalAudioStream == nil {
            capture.stop()
        }

        // Drain audio consumer so any in-flight chunk is sent before we
        // close the socket. In external mode the consumer exits when
        // the broadcaster finishes the downstream.
        await audioConsumerTask?.value
        audioConsumerTask = nil

        // Grace window for the server to flush the final VAD segment
        // after the last audio frame. 300 ms tracks Sarvam's observed
        // segment-emit cadence from Linux validation.
        try? await Task.sleep(nanoseconds: 300_000_000)

        handler?.disconnect()
        handler = nil
        externalAudioStream = nil

        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func recordPeak(_ peak: Float) {
        let speaking = peak > 0.02
        partialsContinuation?.yield(Partial(
            text: "",
            latin: "",
            gurmukhi: "",
            isSpeaking: speaking,
            bufferEnergy: peak
        ))
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

    /// REST batch endpoint for one-shot Saaras transcription. Compare
    /// mode (record-once-then-compare-three-engines) calls this directly
    /// — the live streaming path above is for the search flow.
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

/// Starscream-backed Sarvam streaming session. Lives outside the actor
/// so the WebSocket callback queue (Starscream's default DispatchQueue)
/// can deliver `didReceive` events without crossing the actor boundary.
/// All mutable state is NSLock-protected; the audio-send path is
/// callable from any thread.
private final class SarvamStreamingHandler: NSObject, WebSocketDelegate, @unchecked Sendable {

    private let socket: WebSocket
    private let onPartial: @Sendable (Partial) -> Void

    private let lock = NSLock()
    private var _isConnected: Bool = false
    private var pendingAudio: [Data] = []
    private var transcriptParts: [String] = []

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    init(
        url: URL,
        apiKey: String,
        onPartial: @escaping @Sendable (Partial) -> Void
    ) {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        req.timeoutInterval = 10
        self.socket = WebSocket(request: req)
        self.onPartial = onPartial
        super.init()
        self.socket.delegate = self
    }

    func connect() {
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
    }

    /// Send a 100 ms s16le mono PCM chunk to the live Sarvam stream.
    /// If the WebSocket hasn't finished its handshake yet (we get audio
    /// from the mic before `.connected` fires), queue it and flush on
    /// connect. Called off-actor from the detached audio consumer.
    func sendAudio(_ chunk: Data) {
        lock.lock()
        if !_isConnected {
            pendingAudio.append(chunk)
            lock.unlock()
            return
        }
        lock.unlock()
        writeChunk(chunk)
    }

    private func writeChunk(_ chunk: Data) {
        // Sarvam's wire format (validated from Linux):
        //   {"audio": {"data": "<b64>", "sample_rate": "16000", "encoding": "audio/wav"}}
        // sample_rate is a STRING, not a number. encoding is "audio/wav"
        // even though we're sending raw PCM — Sarvam treats it as a
        // content-type label, not a parser hint.
        let b64 = chunk.base64EncodedString()
        let payload: [String: Any] = [
            "audio": [
                "data": b64,
                "sample_rate": "16000",
                "encoding": "audio/wav"
            ]
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: json, encoding: .utf8) else {
            return
        }
        socket.write(string: str)
    }

    // MARK: - WebSocketDelegate

    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected:
            lock.lock()
            _isConnected = true
            let queued = pendingAudio
            pendingAudio = []
            lock.unlock()
            NSLog("[DIAG] SarvamProvider WS connected — flushing pending=\(queued.count) chunks")
            for chunk in queued { writeChunk(chunk) }
        case .text(let str):
            handleText(str)
        case .binary(let data):
            if let s = String(data: data, encoding: .utf8) { handleText(s) }
        case .disconnected(let reason, let code):
            NSLog("[DIAG] SarvamProvider WS disconnected reason='\(reason)' code=\(code)")
            lock.lock(); _isConnected = false; lock.unlock()
        case .error(let err):
            NSLog("[DIAG] SarvamProvider WS error: \(err?.localizedDescription ?? "nil")")
            lock.lock(); _isConnected = false; lock.unlock()
        case .cancelled:
            NSLog("[DIAG] SarvamProvider WS cancelled")
            lock.lock(); _isConnected = false; lock.unlock()
        case .peerClosed:
            NSLog("[DIAG] SarvamProvider WS peerClosed")
            lock.lock(); _isConnected = false; lock.unlock()
        default:
            break
        }
    }

    private func handleText(_ str: String) {
        guard let data = str.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Sarvam envelope (validated): {"type": "data", "data": {"transcript": "..."}}.
        // Type "config" / "events" arrive too — log and ignore.
        if let type = parsed["type"] as? String {
            switch type {
            case "data":
                if let inner = parsed["data"] as? [String: Any],
                   let transcript = inner["transcript"] as? String, !transcript.isEmpty {
                    appendSegmentAndEmit(transcript)
                }
                return
            case "events":
                return
            case "config":
                return
            case "error":
                let msg = (parsed["data"] as? [String: Any])?["message"] as? String ?? "unknown"
                NSLog("[DIAG] SarvamProvider server error: \(msg)")
                return
            default:
                break
            }
        }

        // Fallback for non-enveloped shapes (flat {"transcript": "..."} etc).
        if let transcript = SarvamProvider.extractTranscript(from: parsed), !transcript.isEmpty {
            appendSegmentAndEmit(transcript)
        }
    }

    private func appendSegmentAndEmit(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        transcriptParts.append(trimmed)
        let full = transcriptParts.joined(separator: " ")
        lock.unlock()

        let script = SarvamProvider.detectScript(trimmed)
        NSLog("[DIAG] SarvamProvider segment received len=\(trimmed.count) script=\(script.rawValue) first40='\(String(trimmed.prefix(40)))'")
        NSLog("[DIAG] SarvamProvider full transcript so far len=\(full.count)")

        let partial = SarvamProvider.makePartial(raw: full, isSpeaking: false, bufferEnergy: 0)
        onPartial(partial)
    }
}
