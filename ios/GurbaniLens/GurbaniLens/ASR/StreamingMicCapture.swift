import Foundation
import AVFoundation

/// **Streaming mic capture** for Brief #9-iOS. Sibling to
/// ``CloudMicCapture`` but designed for continuous-streaming ASR:
/// emits fixed-size PCM16 chunks (~100 ms each) to a callback
/// instead of buffering a full utterance.
///
/// Audio pipeline mirrors `CloudMicCapture`:
///   native sample rate Float32  →  16 kHz Float32 (AVAudioConverter)
///                              →  s16le mono bytes  →  chunked emit
///
/// **Differences from `CloudMicCapture`:**
///   - No VAD gating. Chunks flow continuously the whole time the
///     mic is open. The server's streaming ASR sees the full audio
///     timeline including silence — that's what it needs to
///     boundary-detect utterances itself.
///   - No pre-speech ring buffer or silence-trail auto-finish.
///     Those are utterance-segmentation concerns the buffered
///     provider handles client-side. The streaming server handles
///     them itself.
///   - No internal utterance buffer. Bytes accumulate ONLY until a
///     full 3 200-byte chunk is ready, then are flushed and the
///     accumulator's slack is kept for the next chunk.
///   - Silero VAD still runs over the 16 kHz stream for the
///     `onActivity(_:_:_:)` callback so the UI's `audioState`
///     waveform/recording transitions still work. It does NOT gate
///     transport.
///
/// Co-existence: like `CloudMicCapture`, this MUST NOT run while
/// WhisperKit's AudioProcessor (or another mic capture instance) is
/// alive. The streaming engine owns the lifecycle and stops the
/// capture before the buffered engine starts, and vice versa.
public final class StreamingMicCapture {

    // MARK: - Errors

    public enum CaptureError: LocalizedError {
        case sessionConfigurationFailed(underlying: Error)
        case engineStartFailed(underlying: Error)
        case converterInitFailed
        case permissionDenied
        case permissionRequested

        public var errorDescription: String? {
            switch self {
            case .sessionConfigurationFailed(let e):
                return "Couldn't configure the audio session for streaming ASR: \(e.localizedDescription)"
            case .engineStartFailed(let e):
                return "Couldn't start the audio engine for streaming ASR: \(e.localizedDescription)"
            case .converterInitFailed:
                return "Couldn't build the audio converter to 16 kHz s16le."
            case .permissionDenied:
                return "Microphone permission was denied. Enable it in iOS Settings → Privacy → Microphone → GurbaniLens."
            case .permissionRequested:
                return "Microphone permission requested — please allow and try again."
            }
        }
    }

    // MARK: - Constants

    /// Output chunk size in bytes (s16le). 3 200 B = 1 600 samples =
    /// 100 ms @ 16 kHz mono. Matches
    /// ``StreamingProvider/expectedChunkBytes``.
    public static let chunkBytes: Int = 3_200
    /// VAD probability threshold — for audioState transitions only.
    /// Matches CloudMicCapture's 0.3 (Brief #7.1 tuning).
    public static let vadThreshold: Float = 0.3

    // MARK: - State

    private let engine = AVAudioEngine()
    private let outputSampleRate: Double = 16_000
    private let outputFormatF32: AVAudioFormat
    private var nativeFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private let stateLock = NSLock()
    private var _isRunning: Bool = false
    private var notificationObservers: [NSObjectProtocol] = []

    /// Accumulator for s16le bytes between chunk emits.
    private var byteAccumulator = Data()
    /// VAD window buffer (16 kHz Float32 samples) feeding Silero.
    private var vadWindowBuffer: [Float] = []

    private var silero: SileroVAD?
    private var sileroLoadAttempted: Bool = false

    private static var tapCallCount: Int = 0

    // MARK: - Callbacks

    /// **Chunk emit** — fires once per 3 200-byte fill. Called from
    /// the AVAudioEngine tap thread; the engine consumer is
    /// responsible for hopping to its isolation domain.
    public var onChunk: ((_ pcm16: Data, _ chunkNumber: Int) -> Void)?

    /// Activity callback for the UI waveform / audioState. Identical
    /// shape to `CloudMicCapture.onActivity`. Called from the tap
    /// thread.
    public var onActivity: ((_ peak: Float, _ rms: Float, _ vadActive: Bool) -> Void)?

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    // MARK: - Init

    public init() {
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("StreamingMicCapture: failed to build 16 kHz Float32 output format")
        }
        self.outputFormatF32 = f
    }

    // MARK: - Lifecycle

    public func start() throws {
        stateLock.lock()
        if _isRunning {
            stateLock.unlock()
            NSLog("[DIAG] StreamingMicCapture.start REENTRY — ignoring")
            return
        }
        stateLock.unlock()

        try configureSession()
        try requestPermissionIfNeeded()

        ensureSilero()
        silero?.reset()
        vadWindowBuffer.removeAll(keepingCapacity: true)
        byteAccumulator.removeAll(keepingCapacity: true)
        chunkCounter = 0
        // Brief #9.5: drop the prior session's converter + cached
        // native format so the lazy-init path rebuilds them on the
        // first tap with the current (possibly different) hardware
        // format.
        converter = nil
        nativeFormat = nil

        installTap()

        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(underlying: error)
        }

        stateLock.lock()
        _isRunning = true
        stateLock.unlock()

        registerInterruptionObservers()

        NSLog("[DIAG] StreamingMicCapture.start nativeSR=\(nativeFormat?.sampleRate ?? -1) → 16000 mono s16le chunkBytes=\(Self.chunkBytes)")
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = _isRunning
        _isRunning = false
        stateLock.unlock()
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        unregisterObservers()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        NSLog("[DIAG] StreamingMicCapture.stop chunksEmitted=\(chunkCounter)")
    }

    // MARK: - Audio session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(outputSampleRate)
            try session.setPreferredIOBufferDuration(0.020)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw CaptureError.sessionConfigurationFailed(underlying: error)
        }
    }

    private func requestPermissionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw CaptureError.permissionDenied
        case .undetermined:
            session.requestRecordPermission { _ in /* result handled on next tap */ }
            throw CaptureError.permissionRequested
        @unknown default:
            throw CaptureError.permissionDenied
        }
    }

    // MARK: - Silero

    private func ensureSilero() {
        if sileroLoadAttempted { return }
        sileroLoadAttempted = true
        guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            NSLog("[DIAG] StreamingMicCapture Silero VAD model not bundled — falling back to peak-threshold for audioState only")
            return
        }
        do {
            silero = try SileroVAD(modelPath: url.path)
            NSLog("[DIAG] StreamingMicCapture Silero VAD loaded (used for audioState only — does not gate transport)")
        } catch {
            NSLog("[DIAG] StreamingMicCapture Silero VAD init failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tap install + per-tap encode + chunked emit

    private var chunkCounter: Int = 0

    private func installTap() {
        let inputNode = engine.inputNode
        // Brief #9.5: log both formats to diagnose route-change /
        // sample-rate drift. inputFormat is what the hardware delivers
        // INTO the node; outputFormat is what the tap sees coming OUT.
        // They can differ if the node has internal conversion.
        let preInput = inputNode.inputFormat(forBus: 0)
        let preOutput = inputNode.outputFormat(forBus: 0)
        NSLog("[DIAG] StreamingMicCapture.installTap PRE inputFormat sampleRate=\(preInput.sampleRate) channels=\(preInput.channelCount) outputFormat sampleRate=\(preOutput.sampleRate) channels=\(preOutput.channelCount)")

        // Brief #9.5 FIX: pass `format: nil` so AVFoundation uses
        // whatever the bus is ACTUALLY committed to at install time.
        // Previously this was `format: nf` where nf was queried a
        // moment earlier — between query and install the bus format
        // could change (route swap, Bluetooth handoff, hardware
        // sample-rate flip), and AVFoundation would either crash
        // (Run 2: 48 kHz client format vs 24 kHz hardware) or
        // silently drop buffers (Run 1: zero chunks emitted despite
        // start() succeeding). With nil, the tap always matches.
        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer)
        }

        // After install, the bus is committed to a specific format.
        // Query it for the install-time log; the per-buffer
        // `buf.format` is the truth used by the lazy converter init.
        let postFormat = inputNode.outputFormat(forBus: 0)
        self.nativeFormat = postFormat
        NSLog("[DIAG] StreamingMicCapture.installTap POST committed sampleRate=\(postFormat.sampleRate) channels=\(postFormat.channelCount)")
        // Note: converter is built lazily on the first tap buffer
        // (handleTapBuffer) from `buf.format` — that's the
        // ground-truth format and survives any race between install
        // time and first delivery.
    }

    private func handleTapBuffer(_ buf: AVAudioPCMBuffer) {
        Self.tapCallCount += 1
        let tapNum = Self.tapCallCount

        // Brief #9.5: lazy-build the converter on the first tap so
        // its source format ALWAYS matches what AVFoundation is
        // actually delivering. Avoids the stale-format mismatch that
        // caused Run 1 (silent drop) and Run 2 (crash). The buf.format
        // is the ground truth — whatever the bus committed to on
        // install, regardless of what we predicted earlier.
        if converter == nil {
            guard let monoNative = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buf.format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let conv = AVAudioConverter(from: monoNative, to: outputFormatF32) else {
                NSLog("[DIAG] StreamingMicCapture first-tap converter init FAILED — buf.format sampleRate=\(buf.format.sampleRate) channels=\(buf.format.channelCount) — dropping tap")
                return
            }
            self.converter = conv
            self.nativeFormat = buf.format
            NSLog("[DIAG] StreamingMicCapture first tap delivered — sampleRate=\(buf.format.sampleRate) channels=\(buf.format.channelCount) frames=\(buf.frameLength) converter built ratio=\(String(format: "%.4f", outputFormatF32.sampleRate / buf.format.sampleRate))")
        }

        guard buf.format.commonFormat == .pcmFormatFloat32,
              let chanData = buf.floatChannelData,
              let nf = nativeFormat else {
            if tapNum <= 5 {
                NSLog("[DIAG] StreamingMicCapture tap #\(tapNum) early-return: commonFormat=\(buf.format.commonFormat.rawValue) hasChanData=\(buf.floatChannelData != nil) hasNF=\(nativeFormat != nil)")
            }
            return
        }
        let nch = Int(buf.format.channelCount)
        let frames = Int(buf.frameLength)
        if frames == 0 { return }

        // Downmix to mono + per-tap peak + native-rate RMS.
        var monoChunk = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        var sumSqNative: Float = 0
        if nch == 1 {
            let chan = chanData[0]
            for i in 0..<frames {
                let v = chan[i]
                monoChunk[i] = v
                let a = abs(v); if a > peak { peak = a }
                sumSqNative += v * v
            }
        } else {
            let inv = 1.0 / Float(nch)
            for c in 0..<nch {
                let ch = chanData[c]
                for i in 0..<frames { monoChunk[i] += ch[i] }
            }
            for i in 0..<frames {
                monoChunk[i] *= inv
                let a = abs(monoChunk[i]); if a > peak { peak = a }
                sumSqNative += monoChunk[i] * monoChunk[i]
            }
        }
        let rmsNative = frames > 0 ? (sumSqNative / Float(frames)).squareRoot() : 0

        // Wrap in PCMBuffer for AVAudioConverter.
        guard let monoNative = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nf.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let inBuf = AVAudioPCMBuffer(
            pcmFormat: monoNative,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        if let dst = inBuf.floatChannelData?[0] {
            monoChunk.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: frames)
                }
            }
        }

        let ratio = outputFormatF32.sampleRate / nf.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormatF32,
            frameCapacity: outCap
        ), let converter = self.converter else { return }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        converter.reset()
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil { return }

        let outFrames = Int(outBuf.frameLength)
        if outFrames == 0 { return }
        guard let chan = outBuf.floatChannelData?[0] else { return }

        // VAD over the converted 16 kHz frame (audioState only).
        var chunkVADActive = false
        if let silero = silero {
            for i in 0..<outFrames { vadWindowBuffer.append(chan[i]) }
            while vadWindowBuffer.count >= SileroVAD.windowSamples {
                let window = Array(vadWindowBuffer.prefix(SileroVAD.windowSamples))
                vadWindowBuffer.removeFirst(SileroVAD.windowSamples)
                let prob = silero.probability(samples: window)
                if prob >= Self.vadThreshold { chunkVADActive = true }
            }
        } else {
            chunkVADActive = peak > 0.02
        }

        onActivity?(peak, rmsNative, chunkVADActive)

        // Float32 → Int16 little-endian into Data.
        var bytes = Data(count: outFrames * 2)
        bytes.withUnsafeMutableBytes { raw in
            guard let basePtr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<outFrames {
                var v = chan[i]
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                let s = Int16(v * 32767.0)
                basePtr[i] = s.littleEndian
            }
        }

        // Accumulate + emit 3 200-byte chunks.
        byteAccumulator.append(bytes)
        while byteAccumulator.count >= Self.chunkBytes {
            let chunk = byteAccumulator.prefix(Self.chunkBytes)
            byteAccumulator.removeFirst(Self.chunkBytes)
            chunkCounter += 1
            let n = chunkCounter
            if n <= 3 || n % 50 == 0 {
                NSLog("[DIAG] StreamingMicCapture sent chunk \(n) bytes=\(chunk.count)")
            }
            onChunk?(Data(chunk), n)
        }
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
            engine.pause()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? engine.start()
            }
        @unknown default:
            break
        }
    }

    deinit {
        unregisterObservers()
    }
}
