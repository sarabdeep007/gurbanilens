import Foundation
import AVFoundation

/// One-shot mic capture for the v1 voice-search flow. Wraps ``MicSource``'s
/// bulk-convert-at-stop model: live per-tap peak amplitudes drive the VU
/// meter while recording, then on `stop()` the entire native-rate buffer is
/// resampled to 16 kHz mono Float32 in one AVAudioConverter pass and
/// returned as a `[Float]`.
///
/// Lifecycle: ``start`` → caller awaits user → ``stop()`` returns the PCM.
/// ``cancel()`` drops the buffer. Idempotent.
public final class RecordingCapture {
    private let mic = MicSource()
    private var finalSamples: [Float] = []
    private let lock = NSLock()
    private var startedAt: Date?

    /// Called on the audio thread for each delivered tap buffer (live VU).
    public var onPeak: ((Float) -> Void)?

    public var isRunning: Bool { mic.isRunning }

    public init() {}

    public func start() throws {
        lock.lock(); finalSamples.removeAll(keepingCapacity: false); lock.unlock()
        startedAt = Date()
        NSLog("[DIAG] RecordingCapture.start")
        try mic.startWithPeakMeter(
            onPeak: { [weak self] peak in
                self?.onPeak?(peak)
            },
            onFinal: { [weak self] buffer, _ in
                guard let self, let chan = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                self.lock.lock()
                self.finalSamples = Array(UnsafeBufferPointer(start: chan, count: frames))
                self.lock.unlock()
            }
        )
    }

    /// Stops the mic, runs MicSource's bulk-convert pass, and returns the
    /// captured PCM samples (16 kHz mono Float32).
    @discardableResult
    public func stop() -> [Float] {
        mic.stop()  // MicSource fires onFinal synchronously inside stop()
        lock.lock(); defer { lock.unlock() }
        let out = finalSamples
        finalSamples.removeAll(keepingCapacity: false)
        let wallDur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let audioDur = Double(out.count) / 16_000.0
        let stats = quickStats(out)
        NSLog("[DIAG] RecordingCapture.stop samples=\(out.count) audioSec=\(String(format: "%.3f", audioDur)) wallSec=\(String(format: "%.3f", wallDur)) min=\(stats.min) max=\(stats.max) mean|abs|=\(stats.meanAbs)")
        return out
    }

    public func cancel() {
        mic.stop()
        lock.lock()
        finalSamples.removeAll(keepingCapacity: false)
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
