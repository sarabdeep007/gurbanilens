import Foundation

/// **Streaming WebSocket client** for the GurbaniLens ASR backend.
/// Brief #9-iOS (2026-06-27). Establishes a `wss://asr.gurbanilens.com/stream`
/// connection with `Authorization: Bearer <token>`, sends an `init`
/// JSON frame, streams PCM16 audio chunks (~100 ms each), and emits
/// parsed server messages as ``StreamingEvent`` values on an
/// ``AsyncStream``.
///
/// Co-exists with the existing buffered ``GurbaniLensCloudProvider``
/// — the user toggles between them via the streaming-mode setting.
/// One ``StreamingProvider`` instance is built lazily by AppContainer
/// and shared across Raagi-mode sessions; `connect()` is idempotent
/// (no-op while already connected).
///
/// **Wire protocol** (must match `Brief #9-Server`):
///   - Client → Server:
///       text  `{"type":"init","session_id":"<UUID>","sample_rate":16000,"format":"pcm16"}`
///       binary PCM16 mono 16 kHz (3 200 bytes per ~100 ms chunk)
///       text  `{"type":"pong"}` reply to server ping
///       text  `{"type":"reset_session"}` on Raagi-mode re-entry
///   - Server → Client:
///       `{"type":"ready","session_id":"…"}`
///       `{"type":"partial","seq":N,"transcript":"…","is_final":false|true}`
///       `{"type":"match","seq":N,"shabad_id":"…","line_id":"…","score":N,
///                  "tier":N,"ang":N,"transcript":"…"}`
///       `{"type":"jaikara","seq":N,"phrase":"…"}`
///       `{"type":"no_match","seq":N,"reason":"…","tier3_top":N}`
///       `{"type":"ping"}` heartbeat (~30 s)
///
/// **Reconnect.** On WebSocket close or receive error, retries with
/// exponential backoff (1, 2, 4, 8, 16, 30 s ceiling) until
/// ``disconnect()`` is called. Each retry rebuilds the task; the
/// engine's session_id and any in-flight server-side state are reset
/// on the server's side via the fresh `init` frame.
public final class StreamingProvider: @unchecked Sendable {

    // MARK: - Public types

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attemptSeconds: Int)
    }

    /// Default endpoint. Overridden by the `GurbaniLensASRStreamURL`
    /// Info.plist key (build-time injected by inject_env_to_plist.sh
    /// from .env, if the streaming variable is present).
    public static let defaultEndpoint: String = "wss://asr.gurbanilens.com/stream"

    /// Backoff schedule for reconnect (seconds). Stops doubling once
    /// the 30-s ceiling is hit.
    public static let backoffSchedule: [Int] = [1, 2, 4, 8, 16, 30]

    /// Chunk size emitted by ``StreamingMicCapture`` (3 200 bytes =
    /// 100 ms @ 16 kHz mono s16le). Exposed for the capture side to
    /// match the wire contract.
    public static let expectedChunkBytes: Int = 3_200

    // MARK: - Config

    private let endpoint: URL
    private let bearerToken: String

    // MARK: - State (lock-protected — receive runs off main)

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var explicitDisconnect: Bool = false
    private var connectionState: ConnectionState = .disconnected
    private var nextBackoffIndex: Int = 0

    // Single AsyncStream subscriber. `events()` replaces it.
    private var eventsContinuation: AsyncStream<StreamingEvent>.Continuation?

    // MARK: - Init

    public init(endpoint: String? = nil, bearerToken: String? = nil) {
        let envEndpoint = endpoint
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRStreamURL") as? String
            ?? Self.defaultEndpoint
        let envToken = bearerToken
            ?? Bundle.main.object(forInfoDictionaryKey: "GurbaniLensASRToken") as? String
            ?? ""
        // Force-unwrap with a fatal init message if endpoint is
        // malformed — this is a build-time misconfiguration, not a
        // runtime user error.
        guard let url = URL(string: envEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            NSLog("[DIAG] StreamingProvider.init FATAL — endpoint URL unparseable: \(envEndpoint)")
            self.endpoint = URL(string: Self.defaultEndpoint)!
            self.bearerToken = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
            self.session = URLSession(configuration: .default)
            return
        }
        self.endpoint = url
        self.bearerToken = envToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dedicated URLSession so other app traffic doesn't get
        // tangled with the long-lived WS task.
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 0  // no overall cap — WS is long-lived
        self.session = URLSession(configuration: cfg)
        NSLog("[DIAG] StreamingProvider.init endpoint=\(self.endpoint.absoluteString) tokenLen=\(self.bearerToken.count)")
    }

    deinit {
        receiveLoopTask?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Public API

    /// Fresh AsyncStream for events. Calling this replaces any prior
    /// subscription — the old stream is finished. Single-subscriber
    /// by design; the engine is the only consumer.
    public func events() -> AsyncStream<StreamingEvent> {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream()
        lock.lock()
        eventsContinuation?.finish()
        eventsContinuation = cont
        lock.unlock()
        cont.onTermination = { [weak self] _ in
            self?.lock.lock()
            self?.eventsContinuation = nil
            self?.lock.unlock()
        }
        return stream
    }

    /// Establish (or re-establish) the WebSocket. Idempotent — if
    /// already connected, this is a no-op. Throws only on synchronous
    /// setup failures (missing token); transport errors flow through
    /// the event stream as `.disconnected`.
    public func connect(token: String? = nil) async throws {
        // Allow callers to override the build-time token at runtime
        // (useful for testing). When nil, fall back to init value.
        let effectiveToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? bearerToken
        if effectiveToken.isEmpty {
            NSLog("[DIAG] StreamingProvider.connect FAILED — bearer token missing")
            throw StreamingError.missingToken
        }

        lock.lock()
        explicitDisconnect = false
        switch connectionState {
        case .connected, .connecting:
            lock.unlock()
            NSLog("[DIAG] StreamingProvider.connect ignored — state=\(connectionState)")
            return
        case .disconnected, .reconnecting:
            connectionState = .connecting
        }
        lock.unlock()

        NSLog("[DIAG] StreamingProvider.connect opening \(endpoint.absoluteString)")
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        let wsTask = session.webSocketTask(with: req)

        lock.lock()
        self.task = wsTask
        nextBackoffIndex = 0
        lock.unlock()

        wsTask.resume()
        startReceiveLoop(for: wsTask)
        // Optimistically transition; receive loop will downgrade to
        // disconnected on error. URLSessionWebSocketTask doesn't fire
        // a "handshake completed" callback we can hook here.
        lock.lock()
        connectionState = .connected
        lock.unlock()
    }

    /// Send the `init` JSON frame announcing this session.
    public func sendInit(sessionId: String) {
        let payload: [String: Any] = [
            "type": "init",
            "session_id": sessionId,
            "sample_rate": 16_000,
            "format": "pcm16"
        ]
        sendJSON(payload, label: "init")
        NSLog("[DIAG] StreamingProvider init sent session_id=\(sessionId)")
    }

    /// Send a binary PCM16 audio chunk. Caller is responsible for
    /// chunk size (the wire expects ~100 ms = 3 200 bytes per chunk,
    /// but the server treats boundaries as best-effort).
    public func sendAudio(_ pcm16: Data) {
        lock.lock()
        let activeTask = task
        let state = connectionState
        lock.unlock()
        guard let t = activeTask, case .connected = state else {
            // Drop the chunk — without a connection, queuing would
            // grow unbounded and we'd send stale audio on reconnect.
            return
        }
        let bytes = pcm16.count
        t.send(.data(pcm16)) { [weak self] error in
            if let error = error {
                NSLog("[DIAG] StreamingProvider sendAudio failed bytes=\(bytes) error=\(error.localizedDescription)")
                self?.handleTransportError(error)
            }
        }
    }

    /// Send `reset_session` so the server clears any sticky state for
    /// a fresh user session without tearing down the WebSocket.
    public func resetSession() {
        sendJSON(["type": "reset_session"], label: "reset_session")
        NSLog("[DIAG] StreamingProvider reset_session sent")
    }

    /// Tear down the connection and stop reconnecting. After this,
    /// `connect()` must be called again to come back online.
    public func disconnect() {
        NSLog("[DIAG] StreamingProvider.disconnect")
        lock.lock()
        explicitDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        let t = task
        task = nil
        connectionState = .disconnected
        lock.unlock()
        t?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Receive loop

    private func startReceiveLoop(for wsTask: URLSessionWebSocketTask) {
        let loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await wsTask.receive()
                    guard let self else { return }
                    self.handleIncomingMessage(msg)
                } catch {
                    guard let self else { return }
                    NSLog("[DIAG] StreamingProvider receive error: \(error.localizedDescription)")
                    self.handleTransportError(error)
                    return
                }
            }
        }
        lock.lock()
        receiveLoopTask?.cancel()
        receiveLoopTask = loop
        lock.unlock()
    }

    private func handleIncomingMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .data(let data):
            // Binary frames from server are not part of the v1
            // protocol — log and ignore. A future "compressed match"
            // payload could land here.
            NSLog("[DIAG] StreamingProvider unexpected binary frame bytes=\(data.count)")
        case .string(let text):
            handleJSONText(text)
        @unknown default:
            NSLog("[DIAG] StreamingProvider received @unknown message type")
        }
    }

    private func handleJSONText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any] else {
            NSLog("[DIAG] StreamingProvider JSON parse failed head100=\"\(String(text.prefix(100)))\"")
            return
        }
        let type = (dict["type"] as? String) ?? ""
        switch type {
        case "ready":
            let sid = (dict["session_id"] as? String) ?? ""
            NSLog("[DIAG] StreamingProvider received event=ready session_id=\(sid)")
            emit(.ready(sessionId: sid))

        case "partial":
            let seq = (dict["seq"] as? Int) ?? -1
            let transcript = (dict["transcript"] as? String) ?? ""
            let isFinal = (dict["is_final"] as? Bool) ?? false
            NSLog("[DIAG] StreamingProvider received event=partial seq=\(seq) isFinal=\(isFinal) len=\(transcript.count)")
            emit(.partial(seq: seq, transcript: transcript, isFinal: isFinal))

        case "match":
            let seq = (dict["seq"] as? Int) ?? -1
            let shabadId = (dict["shabad_id"] as? String) ?? ""
            let lineId = (dict["line_id"] as? String) ?? ""
            let score = (dict["score"] as? Double) ?? 0
            let tier = (dict["tier"] as? Int) ?? 0
            let ang = (dict["ang"] as? Int) ?? 0
            let transcript = (dict["transcript"] as? String) ?? ""
            NSLog("[DIAG] StreamingProvider received event=match seq=\(seq) score=\(String(format: "%.1f", score)) tier=\(tier) shabadId=\(shabadId) lineId=\(lineId) ang=\(ang)")
            emit(.match(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier, ang: ang, transcript: transcript))

        case "jaikara":
            let seq = (dict["seq"] as? Int) ?? -1
            let phrase = (dict["phrase"] as? String) ?? ""
            NSLog("[DIAG] StreamingProvider received event=jaikara seq=\(seq) phrase=\"\(phrase)\"")
            emit(.jaikara(seq: seq, phrase: phrase))

        case "no_match":
            let seq = (dict["seq"] as? Int) ?? -1
            let reason = (dict["reason"] as? String) ?? ""
            let tier3Top = dict["tier3_top"] as? Double
            NSLog("[DIAG] StreamingProvider received event=no_match seq=\(seq) reason=\(reason) tier3_top=\(tier3Top.map { String(format: "%.1f", $0) } ?? "nil")")
            emit(.noMatch(seq: seq, reason: reason, tier3Top: tier3Top))

        case "ping":
            NSLog("[DIAG] StreamingProvider received event=ping → auto-pong")
            sendJSON(["type": "pong"], label: "pong")

        default:
            NSLog("[DIAG] StreamingProvider received unknown event type=\(type) head100=\"\(String(text.prefix(100)))\"")
        }
    }

    private func sendJSON(_ payload: [String: Any], label: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("[DIAG] StreamingProvider sendJSON encode failed label=\(label)")
            return
        }
        lock.lock()
        let t = task
        lock.unlock()
        guard let activeTask = t else {
            NSLog("[DIAG] StreamingProvider sendJSON dropped (no task) label=\(label)")
            return
        }
        activeTask.send(.string(text)) { [weak self] error in
            if let error = error {
                NSLog("[DIAG] StreamingProvider sendJSON failed label=\(label) error=\(error.localizedDescription)")
                self?.handleTransportError(error)
            }
        }
    }

    // MARK: - Reconnect

    private func handleTransportError(_ error: Error) {
        lock.lock()
        let explicit = explicitDisconnect
        if explicit {
            lock.unlock()
            return
        }
        let nextBackoff = Self.backoffSchedule[min(nextBackoffIndex, Self.backoffSchedule.count - 1)]
        nextBackoffIndex += 1
        connectionState = .reconnecting(attemptSeconds: nextBackoff)
        let oldTask = task
        task = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        lock.unlock()
        oldTask?.cancel(with: .abnormalClosure, reason: nil)

        let reason = error.localizedDescription
        NSLog("[DIAG] StreamingProvider transport error — scheduling reconnect in \(nextBackoff)s reason=\(reason)")
        emit(.disconnected(reason: reason))

        scheduleReconnect(after: nextBackoff)
    }

    private func scheduleReconnect(after seconds: Int) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                try await self.connect()
            } catch {
                NSLog("[DIAG] StreamingProvider reconnect attempt failed: \(error.localizedDescription)")
                // Backoff will re-trigger on the next receive error.
            }
        }
        lock.lock()
        reconnectTask?.cancel()
        reconnectTask = task
        lock.unlock()
    }

    // MARK: - Emit

    private func emit(_ event: StreamingEvent) {
        lock.lock()
        let cont = eventsContinuation
        lock.unlock()
        cont?.yield(event)
    }
}

// MARK: - Events + errors

public enum StreamingEvent: Sendable {
    case ready(sessionId: String)
    case partial(seq: Int, transcript: String, isFinal: Bool)
    case match(seq: Int, shabadId: String, lineId: String, score: Double, tier: Int, ang: Int, transcript: String)
    case jaikara(seq: Int, phrase: String)
    case noMatch(seq: Int, reason: String, tier3Top: Double?)
    /// Transport-level disconnect or transient error. The provider
    /// auto-reconnects (exponential backoff) unless ``StreamingProvider/disconnect()``
    /// was called explicitly.
    case disconnected(reason: String)
}

public enum StreamingError: LocalizedError {
    case missingToken
    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Streaming ASR token missing. Add GURBANILENS_ASR_TOKEN to .env and rebuild."
        }
    }
}
