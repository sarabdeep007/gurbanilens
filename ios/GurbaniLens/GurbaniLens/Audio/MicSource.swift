import Foundation
import AVFoundation

/// Live mic capture via AVAudioEngine.
///
/// **v1 bulk-convert model (2026-06-20):** the tap returns native-format
/// buffers; we copy their samples into an in-memory mono `[Float]` ring at
/// the input node's NATIVE sample rate, and at `stop()` we run a single
/// `AVAudioConverter` pass over the entire collected ring to produce the
/// 16 kHz mono Float32 buffer that WhisperKit needs.
///
/// Why: the previous streaming model called `AVAudioConverter.convert(to:…)`
/// per ~21 ms tap buffer with a one-shot input block. `AVAudioConverter`
/// needs filter-priming samples to produce stable resampled output; the
/// first few calls often returned zero output frames and the rest were
/// truncated. Cumulative effect: WhisperKit received much less audio than
/// the user spoke, and Whisper hallucinated to fill the gap (the
/// "nukta-spam" symptom). One bulk convert at end-of-capture sidesteps the
/// priming problem entirely.
///
/// The AudioSource protocol's "16 kHz mono Float32" contract is preserved:
/// the `onBuffer` callback fires once at `stop()` time with the fully-
/// converted 16 kHz mono Float32 buffer. v1 callers (`RecordingCapture`)
/// also receive a `onPeakNative` per-tap callback for the live VU meter,
/// computed on the native-format samples before downmix.
///
/// Background-tolerant via Info.plist `UIBackgroundModes: audio` + session
/// category `.playAndRecord`. Handles AVAudioSession interruptions
/// (incoming call, headphone unplugged) by pausing on `.began` and
/// reactivating on `.ended` with `.shouldResume`.
public final class MicSource: AudioSource {

    // MARK: - State

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat        // 16 kHz mono Float32
    private var nativeFormat: AVAudioFormat?       // set by installTap()
    private var collectedMono: [Float] = []        // mono samples at NATIVE sr
    private let lock = NSLock()
    private var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var onPeakNative: ((Float) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []

    public private(set) var isRunning: Bool = false

    // Diagnostics
    private var diagTapCallCount: Int = 0
    private var diagNativeFramesIn: Int = 0

    public var configurationDescription: String {
        let nf = engine.inputNode.outputFormat(forBus: 0)
        return String(
            format: "Mic — native %.0f Hz / %d ch → 16 kHz mono Float32 (bulk-converted at stop)",
            nf.sampleRate, Int(nf.channelCount)
        )
    }

    public init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Lifecycle

    /// AudioSource conformance. The `onBuffer` callback fires exactly once
    /// at `stop()` time with the full resampled 16 kHz mono Float32 capture.
    /// Use ``startWithPeakMeter(onPeak:onFinal:)`` if you also need live
    /// peak amplitudes for a VU bar.
    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        try startWithPeakMeter(onPeak: nil, onFinal: onBuffer)
    }

    /// v1 entry point: live per-tap peak for the VU bar, plus a
    /// once-at-stop final buffer in 16 kHz mono Float32.
    public func startWithPeakMeter(
        onPeak: ((Float) -> Void)?,
        onFinal: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        guard !isRunning else { return }
        self.onPeakNative = onPeak
        self.onBuffer = onFinal

        try configureSession()
        try requestPermissionIfNeeded()
        installTap()

        do {
            try engine.start()
            isRunning = true
        } catch {
            throw AudioSourceError.engineStartFailed(underlying: error)
        }

        registerInterruptionObservers()
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        unregisterObservers()

        // Bulk convert the entire native-rate mono ring into one 16 kHz buffer.
        lock.lock()
        let mono = collectedMono
        collectedMono.removeAll(keepingCapacity: false)
        let tapCalls = diagTapCallCount
        let nativeIn = diagNativeFramesIn
        lock.unlock()

        let nativeSampleRate = nativeFormat?.sampleRate ?? Self.sampleRate
        NSLog("[DIAG] MicSource.stop tapCalls=\(tapCalls) nativeFramesIn=\(nativeIn) nativeSec=\(String(format: "%.3f", Double(nativeIn) / nativeSampleRate)) nativeSR=\(nativeSampleRate)")

        if let finalBuf = bulkConvertToOutput(monoNativeSamples: mono),
           let onBuffer = self.onBuffer {
            let time = AVAudioTime(
                sampleTime: AVAudioFramePosition(finalBuf.frameLength),
                atRate: outputFormat.sampleRate
            )
            onBuffer(finalBuf, time)
        } else {
            NSLog("[DIAG] MicSource.stop bulk convert produced NO output buffer (mono.count=\(mono.count))")
        }

        self.onBuffer = nil
        self.onPeakNative = nil

        // Deactivate the session politely so other audio apps regain control.
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Audio session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // v1: tap-to-record one-shot. `.measurement` mode minimises iOS
            // signal processing (no AGC/EQ). `.allowBluetoothHFP` lets the
            // user record via AirPods if they prefer (modern enum spelling;
            // the older `.allowBluetooth` is deprecated since iOS 8 — same
            // semantics, no behaviour change). `.defaultToSpeaker` keeps
            // the VU pulse visible (no muting via the earpiece). We drop
            // `.mixWithOthers` for v1 — it triggered a categoryChange
            // route notification mid-record and risked silent input.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setPreferredIOBufferDuration(0.020) // ~20 ms
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioSourceError.sessionConfigurationFailed(underlying: error)
        }
    }

    private func requestPermissionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw AudioSourceError.microphonePermissionDenied
        case .undetermined:
            // We block here briefly. In the UI we'll call this from a Task
            // and surface the prompt before the user taps "listen".
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            session.requestRecordPermission { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            if !granted { throw AudioSourceError.microphonePermissionDenied }
        @unknown default:
            throw AudioSourceError.microphonePermissionDenied
        }
    }

    // MARK: - Tap installation + per-tap downmix

    private func installTap() {
        let inputNode = engine.inputNode
        let nf = inputNode.outputFormat(forBus: 0)
        self.nativeFormat = nf

        NSLog("[DIAG] MicSource.installTap nativeFormat sampleRate=\(nf.sampleRate) channels=\(nf.channelCount) commonFormat=\(nf.commonFormat.rawValue) interleaved=\(nf.isInterleaved)")

        // Reset counters
        diagTapCallCount = 0
        diagNativeFramesIn = 0

        // Larger tap buffer keeps the engine thread happy and reduces
        // notification chatter. We don't resample inside the tap any more
        // so the size only affects per-callback overhead.
        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: nf
        ) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer)
        }
    }

    /// Tap callback. Runs on AVAudioEngine's render thread. Downmixes to
    /// mono on the fly and appends to the accumulator. Computes peak for
    /// the VU bar.
    private func handleTapBuffer(_ buf: AVAudioPCMBuffer) {
        guard buf.format.commonFormat == .pcmFormatFloat32,
              let chanData = buf.floatChannelData else {
            NSLog("[DIAG] MicSource.handleTapBuffer non-Float32 format=\(buf.format.commonFormat.rawValue) — dropping")
            return
        }
        let nch = Int(buf.format.channelCount)
        let frames = Int(buf.frameLength)
        if frames == 0 { return }

        var peak: Float = 0
        var monoChunk = [Float](repeating: 0, count: frames)

        if nch == 1 {
            let chan = chanData[0]
            for i in 0..<frames {
                let v = chan[i]
                monoChunk[i] = v
                let a = abs(v)
                if a > peak { peak = a }
            }
        } else {
            // Downmix: average across channels per frame.
            let inv = 1.0 / Float(nch)
            for c in 0..<nch {
                let ch = chanData[c]
                for i in 0..<frames {
                    monoChunk[i] += ch[i]
                }
            }
            for i in 0..<frames {
                monoChunk[i] *= inv
                let a = abs(monoChunk[i])
                if a > peak { peak = a }
            }
        }

        lock.lock()
        diagTapCallCount += 1
        diagNativeFramesIn += frames
        collectedMono.append(contentsOf: monoChunk)
        lock.unlock()

        onPeakNative?(peak)
    }

    // MARK: - Bulk conversion at stop()

    /// Convert the accumulated native-rate mono Float32 samples to a 16 kHz
    /// mono Float32 buffer via a single AVAudioConverter pass. Returns nil
    /// when there's nothing to convert.
    private func bulkConvertToOutput(monoNativeSamples mono: [Float]) -> AVAudioPCMBuffer? {
        if mono.isEmpty { return nil }
        guard let nf = nativeFormat else { return nil }

        // Source format: mono Float32 at the input node's native sample rate.
        guard let monoNativeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nf.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        // Wrap the [Float] in a single big AVAudioPCMBuffer.
        guard let inputBuf = AVAudioPCMBuffer(
            pcmFormat: monoNativeFormat,
            frameCapacity: AVAudioFrameCount(mono.count)
        ) else { return nil }
        inputBuf.frameLength = AVAudioFrameCount(mono.count)
        guard let dst = inputBuf.floatChannelData?[0] else { return nil }
        mono.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                dst.update(from: base, count: mono.count)
            }
        }

        guard let converter = AVAudioConverter(from: monoNativeFormat, to: outputFormat) else {
            NSLog("[DIAG] MicSource.bulkConvert AVAudioConverter init FAILED native=\(nf.sampleRate) → 16000")
            return nil
        }

        let ratio = outputFormat.sampleRate / monoNativeFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(mono.count) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outCap
        ) else { return nil }

        // Single-shot input block: hand over the whole buffer, then signal
        // end-of-stream so the converter flushes its filter properly.
        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuf
        }
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            NSLog("[DIAG] MicSource.bulkConvert ERROR status=\(status.rawValue) error=\(String(describing: error))")
            return nil
        }
        NSLog("[DIAG] MicSource.bulkConvert in.frames=\(mono.count) inSec=\(String(format: "%.3f", Double(mono.count) / monoNativeFormat.sampleRate)) out.frames=\(outBuf.frameLength) outSec=\(String(format: "%.3f", Double(outBuf.frameLength) / outputFormat.sampleRate)) status=\(status.rawValue)")
        return outBuf
    }

    // MARK: - Interruption handling

    private func registerInterruptionObservers() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                self?.handleInterruption(note)
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                self?.handleRouteChange(note)
            }
        )
    }

    private func unregisterObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver(_:))
        notificationObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // Stop cleanly; resume when notified.
            engine.pause()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                do {
                    try engine.start()
                } catch {
                    NSLog("MicSource: failed to resume after interruption: \(error)")
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        NSLog("MicSource: route change reason=\(reason.rawValue)")
    }

    deinit {
        unregisterObservers()
    }
}
