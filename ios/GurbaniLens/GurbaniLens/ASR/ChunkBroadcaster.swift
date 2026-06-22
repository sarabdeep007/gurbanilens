import Foundation

/// Fan-out wrapper around an `AsyncStream<Data>` so a single
/// ``CloudMicCapture`` can feed N consumers without each spinning up
/// its own AVAudioSession (iOS only permits one capture session at a
/// time). Used by ``DualLiveProvider`` to drive
/// ``WhisperLiveTranscriber`` and ``SarvamProvider`` from the same mic.
///
/// **Lifecycle.** The pump Task is detached and consumes the upstream
/// stream until it finishes (CloudMicCapture.stop) or the broadcaster
/// is explicitly `finish()`-ed. On either path, every downstream
/// consumer's continuation is `finish()`-ed too. Consumers added after
/// the upstream has already completed get an immediately-finished
/// stream — defensive only; the dual provider creates all consumers
/// before kicking off capture.
///
/// **Thread-safety.** All shared state lives behind a single `NSLock`.
/// The pump Task takes a snapshot of `consumers` per chunk so a
/// concurrent `newConsumer()` call can't race with the yield loop.
public final class ChunkBroadcaster: @unchecked Sendable {

    private let lock = NSLock()
    private var consumers: [AsyncStream<Data>.Continuation] = []
    private var pumpTask: Task<Void, Never>?
    private var upstreamFinished = false

    public init(upstream: AsyncStream<Data>) {
        self.pumpTask = Task.detached { [weak self] in
            for await chunk in upstream {
                guard let self else { return }
                self.lock.lock()
                let snapshot = self.consumers
                self.lock.unlock()
                for cont in snapshot { cont.yield(chunk) }
            }
            // Upstream finished — propagate to all downstreams.
            guard let self else { return }
            self.lock.lock()
            self.upstreamFinished = true
            let snapshot = self.consumers
            self.consumers.removeAll()
            self.lock.unlock()
            for cont in snapshot { cont.finish() }
            NSLog("[DIAG] ChunkBroadcaster upstream finished — closed downstreams=\(snapshot.count)")
        }
    }

    /// Create a new downstream stream that gets every chunk the upstream
    /// emits from this call forward. Call before the upstream starts
    /// emitting; chunks that arrive between upstream-start and
    /// newConsumer-call are not back-filled.
    public func newConsumer() -> AsyncStream<Data> {
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        lock.lock()
        if upstreamFinished {
            lock.unlock()
            cont.finish()
            return stream
        }
        consumers.append(cont)
        lock.unlock()
        return stream
    }

    /// Idempotent teardown. Cancels the pump and finishes every
    /// downstream consumer. Safe to call from any thread.
    public func finish() {
        pumpTask?.cancel()
        pumpTask = nil
        lock.lock()
        let snapshot = consumers
        consumers.removeAll()
        upstreamFinished = true
        lock.unlock()
        for cont in snapshot { cont.finish() }
    }
}
