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
/// **Buffered utterance mode (Brief #7.3, 2026-06-27).** This provider
/// used to mimic Gemini's chunked-streaming pattern: every ~2 seconds
/// of audio was POSTed as an independent /transcribe call and the
/// fragments were concatenated client-side. That worked for
/// generative-LM providers (Gemini / Sarvam) but produced GIBBERISH
/// against IndicConformer because IndicConformer is a **one-shot**
/// model — each 2-second slice was transcribed without sentence
/// context, so it returned initial-syllable fragments like "ਸ ਤ ਮ"
/// instead of the full Pangti. Deep's symptoms: "ਅਉਖੀ ਘੜੀ ਨ ਦੇਖਣ ਦੇਈ"
/// → "ਸ ਸ ਸ ਸ ਅਉ ਰਿਧ ਸਮ ਸ", confidence stuck around topScore=32.
///
/// New flow: buffer ALL s16le bytes from `start()` until the audio
/// stream closes (either via Silero VAD silence-trail auto-finish or
/// an explicit `stop()`). On close, build a single WAV and POST once.
/// One transcribe call per utterance, no fragmentation, full
/// sentence-level context for the model. This matches IndicConformer's
/// natural mode and aligns with Raagi Mode's one-utterance-per-Pangti
/// pattern.
///
/// VAD + state-machine plumbing is unchanged from Brief #7.2; only
/// the "what to do with the buffered audio" logic moves.
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
    /// Below this many s16le bytes (0.5 s @ 16 kHz) we don't bother
    /// hitting the server — utterance is too short to transcribe
    /// meaningfully. Saves a wasted round-trip + bandwidth.
    public static let minUtteranceBytes: Int = 16_000
    /// At this many bytes (30 s) we still send but log a warning.
    /// The server's nginx vhost has a 10 MB upload cap and a 30 s
    /// proxy timeout, both of which bound utterance length well
    /// before this fires in practice.
    public static let warnUtteranceBytes: Int = 960_000

    private let endpoint: String
    private let bearerToken: String

    // MARK: - State

    private let capture: CloudMicCapture
    private let urlSession: URLSession

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

    private var captureTask: Task<Void, Never>?
    private var bufferAccumulator = Data()
    /// One-shot guard so a race between Silero's silence-trail
    /// auto-finish (via handleCaptureEnded) and an explicit `stop()`
    /// doesn't double-POST. The check + set happens synchronously
    /// inside `sendUtterance()` before any await; actor isolation
    /// means re-entry sees the flag already true.
    private var utteranceSent: Bool = false

    private var lastEnergy: Float = 0
    private var lastIsSpeaking: Bool = false

    // MARK: - Init

    public init(
        endpoint: String? = nil,
        bearerToken: String? = nil
    ) {
        let envEndpoint = endpoint
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRURL") as? String
            ?? Self.defaultEndpoint
        let envToken = bearerToken
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRToken") as? String
            ?? ""
        self.endpoint = envEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bearerToken = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.capture = CloudMicCapture()

        // 30 s per-request + 60 s total resource — matches the
        // server's nginx vhost proxy timeout. Anything slower than
        // that is a server-side problem we want to surface promptly.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)

        if self.bearerToken.isEmpty {
            NSLog("[DIAG] GurbaniLensCloud.init no bearer token (will fail at start) — populate GURBANILENS_ASR_TOKEN in .env")
        } else {
            NSLog("[DIAG] GurbaniLensCloud.init endpoint=\(self.endpoint) token=\(Self.redactToken(self.bearerToken)) mode=buffered_utterance")
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
        self.utteranceSent = false

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
                // Stream closed — either Silero VAD silence-trail
                // auto-finished it, or stop() called capture.stop().
                // Either way, time to POST what we have.
                await self.handleCaptureEnded()
            }
        } catch {
            NSLog("[DIAG] GurbaniLensCloud capture.start FAILED: \(error.localizedDescription)")
            throw GLCloudError.captureFailed(underlying: error)
        }

        NSLog("[DIAG] GurbaniLensCloud.start streaming begun (buffered utterance mode)")
    }

    public func stop() async {
        NSLog("[DIAG] GurbaniLensCloud.stop()")
        captureTask?.cancel()
        captureTask = nil
        capture.stop()
        // Idempotent — handleCaptureEnded may have already sent (and
        // would have, on Silero auto-finish). The flag inside
        // sendUtterance gates this.
        await sendUtterance(reason: "stop")
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

    private func appendChunk(_ chunk: Data) {
        // Buffered-utterance mode: just append. No per-chunk dispatch.
        bufferAccumulator.append(chunk)
    }

    private func handleCaptureEnded() async {
        await sendUtterance(reason: "capture_ended")
        // Give the partial-stream consumer (VoiceSearchSession) a
        // beat to ingest the final transcript Partial before we
        // finish the stream and close the for-await loop.
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    /// Build a single WAV from the accumulated s16le buffer and POST
    /// it to /transcribe. Idempotent — the `utteranceSent` flag means
    /// a race between auto-finish + explicit stop won't double-send.
    private func sendUtterance(reason: String) async {
        if utteranceSent {
            NSLog("[DIAG] GurbaniLensCloud sendUtterance skipped (reason=\(reason), already sent)")
            return
        }
        utteranceSent = true

        let bufferedBytes = bufferAccumulator.count
        let totalSec = Double(bufferedBytes) / (16_000.0 * 2.0)

        // Too-short utterance: don't waste a round-trip. Yield an
        // empty final Partial so the consumer's snappy update
        // doesn't keep the prior text indefinitely.
        if bufferedBytes < Self.minUtteranceBytes {
            NSLog("[DIAG] GurbaniLensCloud utterance.bufferedBytes=\(bufferedBytes) totalSec=\(String(format: "%.2f", totalSec)) — below minUtteranceBytes=\(Self.minUtteranceBytes), skipping POST (reason=\(reason))")
            partialsContinuation?.yield(Self.makePartial(
                text: "",
                isSpeaking: false,
                bufferEnergy: lastEnergy
            ))
            return
        }

        if bufferedBytes > Self.warnUtteranceBytes {
            NSLog("[DIAG] GurbaniLensCloud utterance over warnUtteranceBytes (\(bufferedBytes) > \(Self.warnUtteranceBytes)) — sending anyway (reason=\(reason))")
        }

        guard let url = URL(string: endpoint) else {
            NSLog("[DIAG] GurbaniLensCloud utterance endpoint unparseable: \(endpoint)")
            return
        }

        let start = Date()
        NSLog("[DIAG] GurbaniLensCloud utterance buffered \(bufferedBytes) bytes (\(String(format: "%.2f", totalSec)) sec) — sending (reason=\(reason))")

        let wav = WavBuilder.wavFromS16LE(pcm: bufferAccumulator)
        let boundary = "----GurbaniLensBoundary\(UUID().uuidString)"
        let body = Self.multipartBody(
            wav: wav,
            fieldName: "audio",
            filename: "utterance.wav",
            boundary: boundary
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        // Snapshot energy/speaking BEFORE awaiting the request so the
        // final Partial reflects the moment the user finished, not
        // the moment the server replied.
        let energySnapshot = lastEnergy
        let speakingSnapshot = lastIsSpeaking

        do {
            let (data, response) = try await urlSession.data(for: req)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status != 200 {
                let bodyHead = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                let label: String
                switch status {
                case 401: label = "auth_failure (check bearer token)"
                case 413: label = "payload_too_large (utterance > 10 MB upload limit)"
                case 429: label = "rate_limited (server allows 20 req/min)"
                case 500...599: label = "server_error"
                default: label = "unexpected_status"
                }
                NSLog("[DIAG] GurbaniLensCloud utterance HTTP \(status) [\(label)] elapsedMs=\(elapsedMs) bodyHead=\"\(bodyHead)\"")
                return
            }

            guard let parsed = Self.parseResponse(data) else {
                let head = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                NSLog("[DIAG] GurbaniLensCloud utterance unparseable elapsedMs=\(elapsedMs) head=\"\(head)\"")
                return
            }
            let text = parsed.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let head80 = String(text.prefix(80))
            NSLog("[DIAG] GurbaniLensCloud utterance response elapsedMs=\(elapsedMs) serverDurMs=\(parsed.durationMs) bufferSec=\(String(format: "%.2f", totalSec)) transcript.len=\(text.count) transcript.head80=\"\(head80)\"")

            if text.isEmpty {
                partialsContinuation?.yield(Self.makePartial(
                    text: "",
                    isSpeaking: false,
                    bufferEnergy: energySnapshot
                ))
                return
            }

            partialsContinuation?.yield(Self.makePartial(
                text: text,
                isSpeaking: speakingSnapshot,
                bufferEnergy: energySnapshot
            ))
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[DIAG] GurbaniLensCloud utterance threw after \(elapsedMs)ms: \(error.localizedDescription)")
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

    /// Build a fully-populated ``Partial`` from a transcript string.
    /// IndicConformer outputs Gurmukhi; we still route through
    /// detectScript defensively in case a future model variant emits
    /// Devanagari.
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
