import Foundation
import GurbaniLensCore

/// Google Gemini 2.5 Flash audio ASR backend. Conforms to ``ASRProvider``.
///
/// Gemini Flash is REST not WebSocket, so the "streaming" approximation
/// here is chunked: ``CloudMicCapture`` produces s16le frames, we
/// accumulate ~2 sec of audio per chunk, wrap it in a 44-byte WAV header
/// (Gemini's `audio/wav` inline part), base64-encode the bytes, and POST
/// `generateContent` with a fixed transcription prompt. Each response
/// adds to a running concatenated transcript; the UI receives a
/// ``Partial`` per chunk so the live transcript view updates ~every 2-4
/// seconds (vs Sarvam's ~sub-second).
///
/// **API contract (verify against ai.google.dev/api/generate-content).**
///   - Endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=<KEY>`
///   - Body:
///       { "contents": [{ "role": "user",
///                        "parts": [
///                          { "text": "<prompt>" },
///                          { "inline_data": { "mime_type": "audio/wav",
///                                             "data": "<base64>" } }
///                        ] }],
///         "generationConfig": { "temperature": 0 } }
///   - Response: candidates[0].content.parts[0].text
///
/// If Gemini's audio input contract drifts, surface in HOLD; the chunk
/// buffer + AsyncStream wiring stays.
///
/// **Long-term TODO.** Route through Taaj backend (api.taajsingh.com)
/// so the GEMINI_API_KEY never ships to a user device. v1 is
/// direct-to-Gemini for the Compare-mode A/B test only.
public actor GeminiProvider: ASRProvider {

    // MARK: - Errors

    public enum GeminiError: LocalizedError {
        case missingApiKey
        case invalidEndpoint
        case captureFailed(underlying: Error)
        case requestFailed(underlying: Error)
        case responseUnparseable(body: String)

        public var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "GEMINI_API_KEY missing. Add it to .env at the repo root and rebuild."
            case .invalidEndpoint:
                return "Gemini endpoint URL is not parseable."
            case .captureFailed(let e):
                return "Gemini mic capture failed: \(e.localizedDescription)"
            case .requestFailed(let e):
                return "Gemini request failed: \(e.localizedDescription)"
            case .responseUnparseable(let body):
                return "Gemini response was not parseable. Head: \(String(body.prefix(120)))"
            }
        }
    }

    // MARK: - ASRProvider identity

    public nonisolated let providerId: ASRProviderId = .gemini
    public nonisolated let displayName: String = "Gemini 2.5 Flash"
    public nonisolated let requiresNetwork: Bool = true

    // MARK: - Config

    public static let defaultEndpointBase = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    public static let defaultPrompt = "Transcribe this Punjabi Gurbani recitation. Output ONLY the transcribed text in Gurmukhi script. No translation, no commentary, no metadata."
    public static let defaultChunkSeconds: Double = 2.0

    private let endpointBase: String
    private let apiKey: String
    private let prompt: String
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
        apiKey: String? = nil,
        endpointBase: String? = nil,
        prompt: String? = nil,
        chunkSeconds: Double? = nil
    ) {
        let envKey = apiKey
            ?? Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String
            ?? ""
        self.apiKey = envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpointBase = endpointBase ?? Self.defaultEndpointBase
        self.prompt = prompt ?? Self.defaultPrompt
        self.chunkSeconds = chunkSeconds ?? Self.defaultChunkSeconds
        self.capture = CloudMicCapture()

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)

        if self.apiKey.isEmpty {
            NSLog("[DIAG] GeminiProvider.init no API key (will fail at start) — populate GEMINI_API_KEY in .env")
        } else {
            NSLog("[DIAG] GeminiProvider.init endpoint=\(self.endpointBase) chunkSec=\(self.chunkSeconds) keyLen=\(self.apiKey.count)")
        }
    }

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        if apiKey.isEmpty { throw GeminiError.missingApiKey }

        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont
        self.bufferAccumulator.removeAll(keepingCapacity: true)
        self.transcriptAccumulator = ""

        do {
            let chunkStream = try capture.start()
            capture.onPeak = { [weak self] peak in
                guard let self else { return }
                Task { await self.recordPeak(peak) }
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
            NSLog("[DIAG] GeminiProvider capture.start FAILED: \(error.localizedDescription)")
            throw GeminiError.captureFailed(underlying: error)
        }

        NSLog("[DIAG] GeminiProvider.start streaming begun (chunkBytes=\(chunkSizeBytes))")
    }

    public func stop() async {
        NSLog("[DIAG] GeminiProvider.stop()")
        captureTask?.cancel()
        captureTask = nil
        capture.stop()
        // Wait briefly for any in-flight requests to land their final
        // partials. Cancel anything still pending.
        for task in inFlightTasks { task.cancel() }
        inFlightTasks.removeAll(keepingCapacity: false)
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func recordPeak(_ peak: Float) {
        lastEnergy = peak
        lastIsSpeaking = peak > 0.02
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
        // Only flush if at least ~0.3 sec of audio — otherwise the tail
        // is too short to transcribe and wastes a request.
        if tail.count >= Int(16000.0 * 2.0 * 0.3) {
            await dispatchChunkRequest(pcm: tail)
        }
    }

    private func handleCaptureEnded() {
        // Don't finish the partials stream here — let stop() do it, so
        // any in-flight chunk request can land its final response.
        // If stop() hasn't been called (silence-VAD style), we still
        // need the stream to finish; trip a deferred finish.
        Task { [weak self] in
            // Give in-flight requests up to 6 sec to land.
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
            await self?.transcribeChunk(pcm: pcm, energy: snapshotEnergy, isSpeaking: snapshotSpeaking)
        }
        inFlightTasks.append(task)
    }

    private func transcribeChunk(pcm: Data, energy: Float, isSpeaking: Bool) async {
        let chunkSec = Double(pcm.count) / (16000.0 * 2.0)
        let start = Date()
        let wav = WavBuilder.wavFromS16LE(pcm: pcm)
        let base64 = wav.base64EncodedString()

        guard var components = URLComponents(string: endpointBase) else {
            NSLog("[DIAG] GeminiProvider chunk endpoint unparseable: \(endpointBase)")
            return
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return }

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "audio/wav",
                        "data": base64
                    ]]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "candidateCount": 1
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        do {
            let (data, response) = try await urlSession.data(for: req)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8) ?? ""
            if status != 200 {
                NSLog("[DIAG] GeminiProvider chunk HTTP \(status) elapsedMs=\(elapsedMs) bodyHead=\"\(String(respStr.prefix(200)))\"")
                return
            }

            let text = Self.extractText(fromResponseJson: data) ?? ""
            let head80 = String(text.prefix(80))
            NSLog("[DIAG] GeminiProvider chunk.sec=\(String(format: "%.2f", chunkSec)) elapsedMs=\(elapsedMs) response.len=\(text.count) response.head80=\"\(head80)\"")
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
            NSLog("[DIAG] GeminiProvider chunk threw after \(elapsedMs)ms: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure parsing helpers (exposed for tests)

    /// Pull the text out of a Gemini `generateContent` JSON response.
    /// Returns nil if no `candidates[0].content.parts[].text` is present.
    public nonisolated static func extractText(fromResponseJson data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let candidates = parsed["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        let collected = parts.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitize(collected).isEmpty ? nil : sanitize(collected)
    }

    /// Build a ``Partial`` for an arbitrary accumulated Gemini transcript.
    /// Exposed for tests + ``CompareScreen``.
    public nonisolated static func makePartial(
        text: String,
        isSpeaking: Bool,
        bufferEnergy: Float
    ) -> Partial {
        let raw = text
        // Gemini's prompt asks for Gurmukhi; treat that as the native
        // script. If the model returns Devanagari (shouldn't, but
        // defensively), Latin.from will pick it up via script detect.
        let latin = Latin.from(raw)
        let gurmukhi: String
        // Reuse Sarvam's detect for consistency.
        switch SarvamProvider.detectScript(raw) {
        case .gurmukhi: gurmukhi = raw
        case .devanagari: gurmukhi = Gurmukhi.fromDevanagari(raw)
        case .other: gurmukhi = raw
        }
        return Partial(
            text: raw,
            latin: latin,
            gurmukhi: gurmukhi,
            isSpeaking: isSpeaking,
            bufferEnergy: bufferEnergy
        )
    }

    /// Join the running accumulated transcript with the latest chunk.
    /// Gemini returns each chunk as its own complete transcript (not
    /// incremental), so we concat with a separating space — but if the
    /// new chunk already starts with the tail of the previous, we skip
    /// the overlap to avoid duplicate words at chunk boundaries.
    public nonisolated static func joinAccumulator(prev: String, next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return n }
        if n.isEmpty { return p }
        // Cheap overlap dedup: if the last 20 chars of prev appear at
        // the start of next, drop the duplicate from next.
        let tailLen = min(20, p.count)
        let tail = String(p.suffix(tailLen))
        if !tail.isEmpty && n.hasPrefix(tail) {
            return p + String(n.dropFirst(tail.count))
        }
        return p + " " + n
    }

    private nonisolated static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let dropPrefixes = ["Transcript:", "transcript:", "Text:", "Transcription:", "transcription:"]
        for p in dropPrefixes where out.hasPrefix(p) {
            out = String(out.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a leading/trailing triple-backtick block — Gemini
        // sometimes wraps output in ``` even when prompted not to.
        if out.hasPrefix("```") {
            // Drop the opening fence (and optional language tag) up to newline.
            if let nl = out.firstIndex(of: "\n") {
                out = String(out[out.index(after: nl)...])
            } else {
                out = String(out.dropFirst(3))
            }
        }
        if out.hasSuffix("```") {
            out = String(out.dropLast(3))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synchronous one-shot transcribe of a WAV blob. Used by
    /// ``CompareScreen`` to run all three providers in parallel against
    /// the same recorded audio buffer. Skips the streaming path.
    public nonisolated static func transcribeOneShot(
        wav: Data,
        apiKey: String,
        endpointBase: String = defaultEndpointBase,
        prompt: String = defaultPrompt,
        urlSession: URLSession = .shared
    ) async throws -> String {
        if apiKey.isEmpty { throw GeminiError.missingApiKey }
        guard var components = URLComponents(string: endpointBase) else {
            throw GeminiError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw GeminiError.invalidEndpoint }

        let base64 = wav.base64EncodedString()
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "audio/wav",
                        "data": base64
                    ]]
                ]
            ]],
            "generationConfig": ["temperature": 0, "candidateCount": 1]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw GeminiError.requestFailed(underlying: NSError(domain: "GeminiProvider", code: 1))
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.responseUnparseable(body: "HTTP \(status): \(body)")
        }
        return extractText(fromResponseJson: data) ?? ""
    }
}
