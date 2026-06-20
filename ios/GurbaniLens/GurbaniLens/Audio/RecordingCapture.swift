import Foundation
import AVFoundation

/// One-shot mic capture for the v1 voice-search flow. Owns a ``MicSource``,
/// accumulates the resampled 16 kHz mono Float32 samples into a single
/// buffer, and emits peak-amplitude updates so the recording UI's VU bar
/// can animate.
///
/// Lifecycle: ``start`` → caller awaits user → ``stop()`` returns the
/// captured PCM. ``cancel()`` drops the buffer. Idempotent.
public final class RecordingCapture {
    private let mic = MicSource()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var startedAt: Date?

    /// Called on the audio thread for each delivered buffer.
    public var onPeak: ((Float) -> Void)?

    public var isRunning: Bool { mic.isRunning }

    public init() {}

    public func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        startedAt = Date()
        NSLog("[DIAG] RecordingCapture.start")
        try mic.start { [weak self] buffer, _ in
            guard let self, let chan = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<frames {
                let v = abs(chan[i])
                if v > peak { peak = v }
            }
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: chan, count: frames))
            self.lock.unlock()
            self.onPeak?(peak)
        }
    }

    /// Stops the mic and returns the captured PCM samples (16 kHz mono Float32).
    @discardableResult
    public func stop() -> [Float] {
        mic.stop()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: false)
        let wallDur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let audioDur = Double(out.count) / 16_000.0
        let stats = quickStats(out)
        NSLog("[DIAG] RecordingCapture.stop samples=\(out.count) audioSec=\(String(format: "%.3f", audioDur)) wallSec=\(String(format: "%.3f", wallDur)) min=\(stats.min) max=\(stats.max) mean|abs|=\(stats.meanAbs)")
        return out
    }

    public func cancel() {
        mic.stop()
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        NSLog("[DIAG] RecordingCapture.cancel")
    }

    private func quickStats(_ s: [Float]) -> (min: Float, max: Float, meanAbs: Float) {
        if s.isEmpty { return (0, 0, 0) }
        var lo: Float = .infinity, hi: Float = -.infinity, sum: Float = 0
        for v in s {
            if v < lo { lo = v }
            if v > hi { hi = v }
            sum += abs(v)
        }
        return (lo, hi, sum / Float(s.count))
    }
}
