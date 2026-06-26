import Foundation
import GurbaniLensCore

/// Self-hosted GurbaniLens IndicConformer Punjabi ASR backend. Conforms
/// to ``ASRProvider``.
///
/// Production endpoint (Deep's 2026-06-25 deploy):
///   - URL:    https://asr.gurbanilens.com/transcribe
///   - Auth:   `Authorization: Bearer <token>` (bearer token injected
///             from .env via scripts/inject_env_to_plist.sh, read at
///             runtime via Bundle.main.object(forInfoDictionaryKey:))
///   - Body:   multipart/form-data with single field `audio` carrying
///             a WAV file (16 kHz mono s16le inside a 44-byte RIFF
///             header)
///   - Reply:  `{ "transcript": String, "language": "pa",
///                "model": "indicconformer_pa", "duration_ms": Int }`
///
/// **Streaming approximation.** The server is a stateless REST
/// endpoint, so "streaming" here is the same chunked approximation
/// ``GeminiProvider`` uses: ``CloudMicCapture`` produces s16le frames,
/// we accumulate ``chunkSeconds`` of audio per chunk, wrap in WAV,
/// POST as multipart, and append the response transcript to a running
/// concatenated transcript. The UI receives a ``Partial`` per chunk so
/// the live view updates ~every 2 s (vs Sarvam's sub-second
/// WebSocket VAD segments). 420 ms round-trip per chunk measured in
/// prod gives a comfortable ~1 chunk-behind-realtime feel.
///
/// **Why self-hosted.** Sarvam is fast and accurate but costs per
/// search, and free competitors exist for the kirtan-companion use
/// case — we cannot ship a paid Seva app. IndicConformer is MIT
/// licensed and the model is Punjabi-specific. The server bears the
/// cost; the user pays nothing.
///
/// **Token hygiene.** The bearer token is read once at init and
/// stored on the actor. Never logged in full — diagnostic NSLog lines
/// use ``redactToken(_:)`` (first 8 + last 4 chars, joined by `…`).
/// The `.env` template ships a placeholder; the real token only
/// reaches the device via build-time PlistBuddy injection.
public actor GurbaniLensCloudProvider: ASRProvider {

    // MARK: - Errors

    public enum GLCloudError: LocalizedError {
        case missingURL
        case missingToken
        case invalidEndpoint(String)
        case captureFailed(underlying: Error)
        case requestFailed(underlying: Error)
        case httpError(status: Int, bodyHead: String)
        case responseUnparseable(bodyHead: String)

        public var errorDescription: String? {
            switch self {
            case .missingURL:
                return "GurbaniLens ASR URL missing. Add GURBANILENS_ASR_URL to .env at the repo root and rebuild."
            case .missingToken:
                return "GurbaniLens ASR token missing. Add GURBANILENS_ASR_TOKEN to .env at the repo root and rebuild."
            case .invalidEndpoint(let s):
                return "GurbaniLens ASR endpoint URL is not parseable: \(s)"
            case .captureFailed(let e):
                return "Mic capture failed: \(e.localizedDescription)"
            case .requestFailed(let e):
                return "Cloud ASR request failed: \(e.localizedDescription)"
            case .httpError(let status, let head):
                return "Cloud ASR HTTP \(status): \(head)"
            case .responseUnparseable(let head):
                return "Cloud ASR response was not parseable. Head: \(head)"
            }
        }
    }

    // MARK: - ASRProvider identity

    public nonisolated let providerId: ASRProviderId = .gurbanilensCloud
    public nonisolated let displayName: String = "GurbaniLens Cloud"
    public nonisolated let requiresNetwork: Bool = true

    // MARK: - Config

    public static let defaultEndpoint = "https://asr.gurbanilens.com/transcribe"
    public static let defaultChunkSeconds: Double = 2.0

    private let endpoint: String
    private let bearerToken: String
    private let chunkSeconds: Double

    // s16le bytes per chunk = sampleRate * 2 bytes * chunkSeconds
    private var chunkSizeBytes: Int { Int(16000.0 * 2.0 * chunkSeconds) }

    // MARK: - Streaming state

    private let capture: CloudMicCapture
    private let urlSession: URLSession

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

    private var captureTask: Task<Void, Never>?
    private var inFlightTasks: [Task<Void, Never>] = []
    private var bufferAccumulator = Data()
    private var transcriptAccumulator = ""

    private var lastEnergy: Float = 0
    private var lastIsSpeaking: Bool = false

    // MARK: - Init

    public init(
        endpoint: String? = nil,
        bearerToken: String? = nil,
        chunkSeconds: Double? = nil
    ) {
        let envEndpoint = endpoint
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRURL") as? String
            ?? Self.defaultEndpoint
        let envToken = bearerToken
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRToken") as? String
            ?? ""
        self.endpoint = envEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bearerToken = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chunkSeconds = chunkSeconds ?? Self.defaultChunkSeconds
        self.capture = CloudMicCapture()

        // 30 s per-request + 60 s total resource — matches Gemini
        // provider's tuning. The server's nginx vhost has a 30 s
        // proxy timeout so anything slower than that is a server-side
        // problem we want to surface promptly.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)

        if self.bearerToken.isEmpty {
            NSLog("[DIAG] GurbaniLensCloud.init no bearer token (will fail at start) — populate GURBANILENS_ASR_TOKEN in .env")
        } else {
            NSLog("[DIAG] GurbaniLensCloud.init endpoint=\(self.endpoint) chunkSec=\(self.chunkSeconds) token=\(Self.redactToken(self.bearerToken))")
        }
    }

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        if endpoint.isEmpty { throw GLCloudError.missingURL }
        if bearerToken.isEmpty { throw GLCloudError.missingToken }
        guard URL(string: endpoint) != nil else {
            throw GLCloudError.invalidEndpoint(endpoint)
        }

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont
        self.bufferAccumulator.removeAll(keepingCapacity: true)
        self.transcriptAccumulator = ""

        do {
            let chunkStream = try capture.start()
            capture.onActivity = { [weak self] peak, rms, vadActive in
                guard let self else { return }
                Task { await self.recordActivity(peak: peak, rms: rms, vadActive: vadActive) }
            }
            self.captureTask = Task { [weak self] in
                guard let self else { return }
                for await chunk in chunkStream {
                    await self.appendChunk(chunk)
                }
                await self.flushFinalChunk()
                await self.handleCaptureEnded()
            }
        } catch {
            NSLog("[DIAG] GurbaniLensCloud capture.start FAILED: \(error.localizedDescription)")
            throw GLCloudError.captureFailed(underlying: error)
        }

        NSLog("[DIAG] GurbaniLensCloud.start streaming begun (chunkBytes=\(chunkSizeBytes))")
    }

    public func stop() async {
        NSLog("[DIAG] GurbaniLensCloud.stop()")
        captureTask?.cancel()
        captureTask = nil
        capture.stop()
        for task in inFlightTasks { task.cancel() }
        inFlightTasks.removeAll(keepingCapacity: false)
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func recordActivity(peak: Float, rms: Float, vadActive: Bool) {
        // Brief #7.1 (2026-06-26): yield an energy-only Partial on
        // every audio-tap so the UI's waveform + state machine see
        // bufferEnergy / isSpeaking updates between transcript
        // responses. Without this the UI freezes on
        // `.listening(bufferEnergy: 0)` forever because the only
        // Partials this provider yields are full transcript responses
        // — and those never arrive while VAD gates the whole stream.
        // Mirrors SarvamProvider.recordActivity.
        lastEnergy = rms
        lastIsSpeaking = vadActive
        partialsContinuation?.yield(Partial(
            text: "",
            latin: "",
            gurmukhi: "",
            isSpeaking: vadActive,
            bufferEnergy: rms
        ))
    }

    private func appendChunk(_ chunk: Data) async {
        bufferAccumulator.append(chunk)
        while bufferAccumulator.count >= chunkSizeBytes {
            let pcmSlice = bufferAccumulator.prefix(chunkSizeBytes)
            bufferAccumulator.removeFirst(chunkSizeBytes)
            await dispatchChunkRequest(pcm: Data(pcmSlice))
        }
    }

    private func flushFinalChunk() async {
        guard !bufferAccumulator.isEmpty else { return }
        let tail = bufferAccumulator
        bufferAccumulator.removeAll(keepingCapacity: false)
        // Skip < 0.3 s tail — too short to transcribe and a wasted request.
        if tail.count >= Int(16000.0 * 2.0 * 0.3) {
            await dispatchChunkRequest(pcm: tail)
        }
    }

    private func handleCaptureEnded() {
        // Mirror GeminiProvider — let stop() finish the stream so in-
        // flight requests can land. If stop() never comes (silence-VAD
        // path), trip a deferred finish after a grace window.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self?.finishStreamIfStillOpen()
        }
    }

    private func finishStreamIfStillOpen() {
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    private func dispatchChunkRequest(pcm: Data) async {
        let snapshotEnergy = lastEnergy
        let snapshotSpeaking = lastIsSpeaking
        let task = Task { [weak self] in
            guard let self else { return }
            await self.transcribeChunk(
                pcm: pcm,
                energy: snapshotEnergy,
                isSpeaking: snapshotSpeaking
            )
        }
        inFlightTasks.append(task)
    }

    private func transcribeChunk(pcm: Data, energy: Float, isSpeaking: Bool) async {
        let chunkSec = Double(pcm.count) / (16000.0 * 2.0)
        let start = Date()
        let wav = WavBuilder.wavFromS16LE(pcm: pcm)

        guard let url = URL(string: endpoint) else {
            NSLog("[DIAG] GurbaniLensCloud chunk endpoint unparseable: \(endpoint)")
            return
        }

        let boundary = "----GurbaniLensBoundary\(UUID().uuidString)"
        let body = Self.multipartBody(
            wav: wav,
            fieldName: "audio",
            filename: "chunk.wav",
            boundary: boundary
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (data, response) = try await urlSession.data(for: req)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status != 200 {
                let bodyHead = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                // Distinguish the most common server-side rejection
                // codes so DIAG logs steer the next debug step.
                let label: String
                switch status {
                case 401: label = "auth_failure (check bearer token)"
                case 413: label = "payload_too_large (chunk > 10 MB upload limit)"
                case 429: label = "rate_limited (server allows 20 req/min)"
                case 500...599: label = "server_error"
                default: label = "unexpected_status"
                }
                NSLog("[DIAG] GurbaniLensCloud chunk HTTP \(status) [\(label)] elapsedMs=\(elapsedMs) bodyHead=\"\(bodyHead)\"")
                return
            }

            guard let parsed = Self.parseResponse(data) else {
                let head = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                NSLog("[DIAG] GurbaniLensCloud chunk unparseable elapsedMs=\(elapsedMs) head=\"\(head)\"")
                return
            }
            let text = parsed.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let head80 = String(text.prefix(80))
            NSLog("[DIAG] GurbaniLensCloud chunk.sec=\(String(format: "%.2f", chunkSec)) elapsedMs=\(elapsedMs) serverDurMs=\(parsed.durationMs) response.len=\(text.count) response.head80=\"\(head80)\"")
            if text.isEmpty { return }

            transcriptAccumulator = Self.joinAccumulator(prev: transcriptAccumulator, next: text)
            let partial = Self.makePartial(
                text: transcriptAccumulator,
                isSpeaking: isSpeaking,
                bufferEnergy: energy
            )
            partialsContinuation?.yield(partial)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            // Network timeouts / TLS failures / DNS errors land here.
            NSLog("[DIAG] GurbaniLensCloud chunk threw after \(elapsedMs)ms: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers (nonisolated static — testable + reusable)

    /// Build a minimal multipart/form-data body for a single binary
    /// `audio/wav` field. No third-party multipart lib — same hand-
    /// rolled pattern Sarvam's transcribeOneShot uses.
    public nonisolated static func multipartBody(
        wav: Data,
        fieldName: String,
        filename: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Server response shape (subset).
    public struct Response: Sendable, Equatable {
        public let transcript: String
        public let language: String
        public let model: String
        public let durationMs: Int
    }

    public nonisolated static func parseResponse(_ data: Data) -> Response? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else { return nil }
        let transcript = (dict["transcript"] as? String) ?? ""
        let language = (dict["language"] as? String) ?? "pa"
        let model = (dict["model"] as? String) ?? ""
        let durationMs = (dict["duration_ms"] as? Int) ?? 0
        return Response(
            transcript: transcript,
            language: language,
            model: model,
            durationMs: durationMs
        )
    }

    /// Token redactor for [DIAG] logs — keeps enough chars to
    /// distinguish two tokens at a glance without leaking the secret.
    /// "<first 8>…<last 4>". Empty / very short tokens return a fixed
    /// placeholder so the log line still parses.
    public nonisolated static func redactToken(_ raw: String) -> String {
        guard raw.count > 12 else { return "<short token len=\(raw.count)>" }
        let head = raw.prefix(8)
        let tail = raw.suffix(4)
        return "\(head)…\(tail)"
    }

    /// Same join semantics ``GeminiProvider`` uses — thin wrapper.
    public nonisolated static func joinAccumulator(prev: String, next: String) -> String {
        return CloudParsing.joinAccumulator(prev: prev, next: next)
    }

    /// Build a fully-populated ``Partial`` from a running accumulated
    /// transcript. IndicConformer outputs Gurmukhi; we still route
    /// through detectScript defensively in case a future model variant
    /// emits Devanagari.
    public nonisolated static func makePartial(
        text: String,
        isSpeaking: Bool,
        bufferEnergy: Float
    ) -> Partial {
        let latin = Latin.from(text)
        let gurmukhi: String
        switch SarvamProvider.detectScript(text) {
        case .gurmukhi:   gurmukhi = text
        case .devanagari: gurmukhi = Gurmukhi.fromDevanagari(text)
        case .other:      gurmukhi = text
        }
        return Partial(
            text: text,
            latin: latin,
            gurmukhi: gurmukhi,
            isSpeaking: isSpeaking,
            bufferEnergy: bufferEnergy
        )
    }
}
