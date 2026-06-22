import Foundation
import GurbaniLensCore

/// Sarvam Saaras-v3 ASR backend. Conforms to ``ASRProvider`` so it slots
/// into ``StreamingASR``'s `@AppStorage("settings.asrProvider")` switch.
///
/// **v1 path: REST batch (this file).** The Sarvam streaming WebSocket
/// API works fine when driven from Linux (see
/// `scripts/sarvam-investigation/WORKING_PROTOCOL.md`) but Apple's
/// `URLSessionWebSocketTask` hits an unresolved `Socket is not connected`
/// failure ~500-700 ms after the first audio frame on iOS. Rather than
/// hold v1 on a platform debugging spike, this provider's
/// `start/stop/partials` lifecycle buffers PCM during capture and submits
/// a single WAV to the synchronous REST endpoint on stop. UX is
/// record→stop→3-5s→transcript. The iOS streaming bug is tracked for a
/// later v2 dispatch.
///
/// **Why Saaras.** Phase 1 measured Whisper-medium at ~31% confident-match
/// rate on sung Kirtan because Whisper's Indic-script training is shallow.
/// Sarvam's Saaras family is purpose-built for Indian languages (native
/// Punjabi without a `pa→hi` remap). The Compare-mode A/B test uses
/// ``transcribeOneShot`` directly to evaluate Sarvam vs Whisper-large-v3.
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

    // `defaultEndpoint` is preserved as a data constant even though the
    // batch path uses `batchEndpoint` instead — keeping it harmless avoids
    // touching call sites outside this file.
    public static let defaultEndpoint = URL(string: "wss://api.sarvam.ai/speech-to-text/ws")!
    public static let defaultModel = "saaras:v3"
    public static let defaultLanguage = "pa-IN"

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let language: String

    // MARK: - Capture state

    private let capture: CloudMicCapture
    private let audioBuffer = SarvamAudioBuffer()
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

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        if apiKey.isEmpty { throw SarvamError.missingApiKey }

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont
        // Defensive reset in case a prior session left bytes around.
        _ = audioBuffer.snapshotAndReset()

        NSLog("[DIAG] SarvamProvider.start (batch mode) — buffering audio via SarvamAudioBuffer (lock-protected, off-actor)")

        do {
            let chunkStream = try capture.start()

            // Per-tap VU peak → forward as a transcript-less Partial so
            // the level meter animates while the user is recording.
            // Hop into the actor from the non-isolated callback.
            capture.onPeak = { [weak self] peak in
                guard let self else { return }
                Task { await self.recordPeak(peak) }
            }

            // Audio consumer runs OUTSIDE the actor (Task.detached) so the
            // high-frequency chunk arrival is not gated on the actor's
            // mailbox — see SarvamAudioBuffer comment + hotfix-5.
            let buffer = self.audioBuffer
            self.audioConsumerTask = Task.detached(priority: .userInitiated) {
                var loopCount = 0
                for await chunk in chunkStream {
                    buffer.append(chunk)
                    loopCount += 1
                    if loopCount <= 5 || loopCount % 50 == 0 {
                        NSLog("[DIAG] SarvamProvider audioConsumer chunk #\(loopCount) size=\(chunk.count) bufferTotal=\(buffer.currentBytes)")
                    }
                }
                NSLog("[DIAG] SarvamProvider audioConsumer loop EXITED totalChunks=\(loopCount) bufferTotal=\(buffer.currentBytes)")
            }
        } catch {
            NSLog("[DIAG] SarvamProvider capture.start FAILED: \(error.localizedDescription)")
            partialsContinuation?.finish()
            partialsContinuation = nil
            throw SarvamError.captureFailed(underlying: error)
        }
    }

    public func stop() async {
        NSLog("[DIAG] SarvamProvider.stop()")
        capture.stop()

        // Drain the chunk consumer so the final tap-buffer makes it into
        // audioBuffer before we snapshot. capture.stop() finishes the
        // AsyncStream's continuation; the for-await loop drains and exits.
        await audioConsumerTask?.value
        audioConsumerTask = nil

        let pcm = audioBuffer.snapshotAndReset()

        // Gate: 0.5 sec @ 16 kHz mono s16le = 16_000 bytes. Below that,
        // the user almost certainly tapped through by accident — skip
        // the network round-trip and emit an empty final partial.
        let minBytes = 16_000
        guard pcm.count >= minBytes else {
            NSLog("[DIAG] SarvamProvider.stop — pcmBytes=\(pcm.count) below 0.5s threshold, skipping API call")
            partialsContinuation?.yield(
                Partial(text: "", latin: "", gurmukhi: "", isSpeaking: false, bufferEnergy: 0)
            )
            partialsContinuation?.finish()
            partialsContinuation = nil
            return
        }

        let wav = Self.buildWav(fromS16LE: pcm, sampleRate: 16_000, channels: 1)
        NSLog("[DIAG] SarvamProvider.stop — wavBytes=\(wav.count) pcmBytes=\(pcm.count), calling transcribeOneShot")

        do {
            let transcript = try await Self.transcribeOneShot(
                wav: wav,
                apiKey: apiKey,
                model: model,
                languageCode: language
            )
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                NSLog("[DIAG] SarvamProvider.stop transcribeOneShot returned empty transcript")
                partialsContinuation?.yield(
                    Partial(text: "", latin: "", gurmukhi: "", isSpeaking: false, bufferEnergy: 0)
                )
            } else {
                let partial = Self.makePartial(raw: trimmed, isSpeaking: false, bufferEnergy: 0)
                let script = Self.detectScript(trimmed)
                NSLog("[DIAG] SarvamProvider.stop final transcript.len=\(trimmed.count) script=\(script.rawValue) latin.head60=\"\(String(partial.latin.prefix(60)))\" gurmukhi.head60=\"\(String(partial.gurmukhi.prefix(60)))\"")
                partialsContinuation?.yield(partial)
            }
        } catch {
            NSLog("[DIAG] SarvamProvider.stop transcribeOneShot FAILED: \(error.localizedDescription)")
            partialsContinuation?.yield(
                Partial(text: "", latin: "", gurmukhi: "", isSpeaking: false, bufferEnergy: 0)
            )
        }

        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func recordPeak(_ peak: Float) {
        let speaking = peak > 0.02
        // Transcript-less partial: UI uses bufferEnergy for the VU bar
        // and isSpeaking for the "listening" indicator while the
        // recording is in flight. Transcript only arrives in stop().
        partialsContinuation?.yield(Partial(
            text: "",
            latin: "",
            gurmukhi: "",
            isSpeaking: speaking,
            bufferEnergy: peak
        ))
    }

    // MARK: - WAV builder (inline; no third-party)

    /// Build a 44-byte RIFF/WAVE header + payload for s16le PCM. Inline
    /// per the v1 dispatch — keeps SarvamProvider self-contained.
    private nonisolated static func buildWav(
        fromS16LE pcm: Data,
        sampleRate: UInt32,
        channels: UInt16
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let blockAlign: UInt16 = channels * bytesPerSample
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        let pcmLen = UInt32(pcm.count)
        let riffSize: UInt32 = 36 + pcmLen

        var header = Data(capacity: 44)
        func appendU32LE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        func appendU16LE(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }

        header.append(contentsOf: Array("RIFF".utf8))
        appendU32LE(riffSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendU32LE(16)              // fmt chunk size (PCM)
        appendU16LE(1)               // PCM format
        appendU16LE(channels)
        appendU32LE(sampleRate)
        appendU32LE(byteRate)
        appendU16LE(blockAlign)
        appendU16LE(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        appendU32LE(pcmLen)

        var out = Data(capacity: 44 + pcm.count)
        out.append(header)
        out.append(pcm)
        return out
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

    // MARK: - Batch helper (used by CompareScreen AND by stop() above)

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

/// Lock-protected audio buffer that lives OUTSIDE SarvamProvider's actor
/// isolation. The audio consumer Task can append chunks directly without
/// hopping into the actor for every 100ms chunk — critical because the
/// actor's mailbox is busy with recordPeak's high-frequency partial
/// yields. See hotfix-5.
private final class SarvamAudioBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private(set) var chunkCount: Int = 0

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        chunkCount += 1
        lock.unlock()
    }

    func snapshotAndReset() -> Data {
        lock.lock()
        let snapshot = data
        data = Data()
        chunkCount = 0
        lock.unlock()
        return snapshot
    }

    var currentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }
}
