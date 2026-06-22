import Foundation
import AVFoundation

/// Mic capture for cloud ASR providers (``SarvamProvider``,
/// ``GeminiProvider``). Streams 16 kHz mono PCM s16le `Data` chunks live
/// during capture via an ``AsyncStream``, so a WebSocket / chunked-HTTP
/// uploader can push audio to the server as it arrives.
///
/// Sibling to ``MicSource`` (Float32, bulk-convert-at-stop) — they share
/// the AVAudioEngine pattern but the cloud capture path needs incremental
/// emission and a different output sample format. Splitting them avoids
/// retrofitting incremental Int16 emission into MicSource's bulk model
/// which v1 depends on.
///
/// **Co-existence rule.** Cloud capture MUST NOT run while WhisperKit's
/// AudioProcessor is alive (Bug F class — two captures fight over the
/// AVAudioSession). ``StreamingASR`` enforces this by instantiating
/// exactly one provider per session; cloud providers own the
/// CloudMicCapture lifecycle for their session and stop it on
/// ``ASRProvider/stop()``.
///
/// **Output contract.** Each emitted `Data` chunk is interleaved s16le,
/// 16 kHz, mono — i.e. `chunk.count / 2` samples. Chunk cadence follows
/// the input tap (~85 ms at 16k / 1024-frame native buffers) but the
/// caller should NOT rely on a fixed chunk size; Sarvam's streaming
/// endpoint and Gemini's 2-sec buffer both treat boundaries as
/// implementation details.
public final class CloudMicCapture {

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
                return "Couldn't configure the audio session for cloud ASR: \(e.localizedDescription)"
            case .engineStartFailed(let e):
                return "Couldn't start the audio engine for cloud ASR: \(e.localizedDescription)"
            case .converterInitFailed:
                return "Couldn't build the audio converter to 16 kHz s16le."
            case .permissionDenied:
                return "Microphone permission was denied. Enable it in iOS Settings → Privacy → Microphone → GurbaniLens."
            case .permissionRequested:
                return "Microphone permission requested — please allow and try again."
            }
        }
    }

    // MARK: - State

    private let engine = AVAudioEngine()
    private let outputSampleRate: Double = 16_000
    private let outputFormatF32: AVAudioFormat
    private var nativeFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private let stateLock = NSLock()
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var _isRunning: Bool = false
    private var notificationObservers: [NSObjectProtocol] = []

    /// Diagnostic-only counter for `handleTapBuffer` invocations. Process-
    /// wide static (across all CloudMicCapture instances within a run)
    /// — fine because we recreate the object per session anyway. Used by
    /// the [DIAG] logs to distinguish "tap fires once" vs "tap fires
    /// repeatedly but yields stop" vs "converter starves" failure modes.
    private static var tapCallCount: Int = 0

    /// Per-tap peak amplitude (0..1) for VU display.
    public var onPeak: ((Float) -> Void)?

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    public init() {
        // Intermediate float32 mono target; we then int-encode to s16le
        // for emission. AVAudioConverter handles the resample +
        // channel-mix portion; the Float→Int16 step is a tight loop
        // below that's not worth giving to AVAudioConverter (which
        // resists writing into a raw byte buffer).
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("CloudMicCapture: failed to build 16 kHz Float32 output format")
        }
        self.outputFormatF32 = f
    }

    // MARK: - Lifecycle

    /// Begin capture. Returns an `AsyncStream<Data>` that yields s16le PCM
    /// chunks until ``stop()`` is called (or the stream's iterator is
    /// dropped). Subsequent ``start()`` calls after a ``stop()`` produce a
    /// fresh stream.
    public func start() throws -> AsyncStream<Data> {
        stateLock.lock()
        if _isRunning {
            stateLock.unlock()
            // Idempotent-ish: if already running, hand back the same
            // continuation's stream. We don't have a way to recreate it
            // without dropping data, so we surface a synthetic empty
            // stream that finishes immediately. Callers shouldn't hit
            // this in practice — StreamingASR gates the lifecycle.
            NSLog("[DIAG] CloudMicCapture.start REENTRY — returning empty stream")
            return AsyncStream { $0.finish() }
        }
        stateLock.unlock()

        try configureSession()
        try requestPermissionIfNeeded()

        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        stateLock.lock()
        self.chunkContinuation = cont
        stateLock.unlock()

        installTap()

        do {
            try engine.start()
        } catch {
            cont.finish()
            stateLock.lock()
            self.chunkContinuation = nil
            stateLock.unlock()
            throw CaptureError.engineStartFailed(underlying: error)
        }

        stateLock.lock()
        _isRunning = true
        stateLock.unlock()

        registerInterruptionObservers()

        cont.onTermination = { [weak self] _ in
            self?.stop()
        }

        NSLog("[DIAG] CloudMicCapture.start nativeSR=\(nativeFormat?.sampleRate ?? -1) → 16000 mono s16le")
        return stream
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = _isRunning
        let cont = chunkContinuation
        chunkContinuation = nil
        _isRunning = false
        stateLock.unlock()

        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        unregisterObservers()
        cont?.finish()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        NSLog("[DIAG] CloudMicCapture.stop")
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
            // Same Bug R-equivalent strategy as MicSource: fire async
            // and throw — user grants then retries.
            session.requestRecordPermission { _ in /* result handled on next tap */ }
            throw CaptureError.permissionRequested
        @unknown default:
            throw CaptureError.permissionDenied
        }
    }

    // MARK: - Tap install + per-tap encode

    private func installTap() {
        let inputNode = engine.inputNode
        let nf = inputNode.outputFormat(forBus: 0)
        self.nativeFormat = nf

        guard let monoNative = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nf.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        self.converter = AVAudioConverter(from: monoNative, to: outputFormatF32)

        NSLog("[DIAG] CloudMicCapture.installTap native sampleRate=\(nf.sampleRate) channels=\(nf.channelCount)")

        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: nf
        ) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer)
        }
    }

    private func handleTapBuffer(_ buf: AVAudioPCMBuffer) {
        Self.tapCallCount += 1
        let tapNum = Self.tapCallCount
        if tapNum <= 5 || tapNum % 50 == 0 {
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) fired frames=\(buf.frameLength)")
        }
        guard buf.format.commonFormat == .pcmFormatFloat32,
              let chanData = buf.floatChannelData,
              let nf = nativeFormat else {
            return
        }
        let nch = Int(buf.format.channelCount)
        let frames = Int(buf.frameLength)
        if frames == 0 { return }

        // Downmix to mono + per-tap peak.
        var monoChunk = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        if nch == 1 {
            let chan = chanData[0]
            for i in 0..<frames {
                let v = chan[i]
                monoChunk[i] = v
                let a = abs(v); if a > peak { peak = a }
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
            }
        }
        onPeak?(peak)

        // Wrap the mono float chunk in a PCMBuffer for AVAudioConverter.
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

        // Resample to 16 kHz Float32. Output capacity scales by ratio.
        let ratio = outputFormatF32.sampleRate / nf.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormatF32,
            frameCapacity: outCap
        ), let converter = self.converter else { return }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) early-return: converter error=\(error?.localizedDescription ?? "nil") status=\(status.rawValue)")
            }
            return
        }

        // Float32 → Int16 little-endian, in-place into a Data buffer.
        let outFrames = Int(outBuf.frameLength)
        if outFrames == 0 {
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) early-return: outFrames=0 (converter produced no output)")
            }
            return
        }
        guard let chan = outBuf.floatChannelData?[0] else { return }

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

        // Hand the chunk to the consumer.
        stateLock.lock()
        let cont = chunkContinuation
        stateLock.unlock()
        if tapNum <= 5 || tapNum % 50 == 0 {
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) yielding bytes=\(bytes.count) hasConsumer=\(cont != nil)")
        }
        cont?.yield(bytes)
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

// MARK: - WAV builder (used by CompareScreen + GeminiProvider chunking)

public enum WavBuilder {
    /// Wrap a raw s16le mono `Data` buffer in a 44-byte WAV header so it
    /// can be sent as `audio/wav` to providers that won't accept raw PCM
    /// (Gemini). Sample rate hard-coded to match ``CloudMicCapture``'s
    /// emission (16 kHz, mono).
    public static func wavFromS16LE(pcm: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        func append(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(chunkSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                  // fmt chunk size
        append(UInt16(1))                   // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(16))                  // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        var out = Data(capacity: 44 + dataSize)
        out.append(header)
        out.append(pcm)
        return out
    }
}
