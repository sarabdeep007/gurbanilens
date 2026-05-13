import Foundation
import AVFoundation

/// Live mic capture via AVAudioEngine. Resamples the device's native input
/// format to 16 kHz mono Float32 — the format whisper.cpp expects.
///
/// Background-tolerant: the audio session category `.playAndRecord` plus the
/// `audio` value in `UIBackgroundModes` (Info.plist) keeps the mic active
/// when the screen is off / the app is backgrounded.
///
/// Handles AVAudioSession interruptions (incoming call, headphone unplugged)
/// by stopping cleanly on `.began` and reactivating on `.ended` with the
/// `.shouldResume` option.
public final class MicSource: AudioSource {

    // MARK: - State

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []

    public private(set) var isRunning: Bool = false

    public var configurationDescription: String {
        let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
        return String(
            format: "Mic — native %.0f Hz / %d ch → 16 kHz mono Float32",
            nativeFormat.sampleRate, Int(nativeFormat.channelCount)
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

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRunning else { return }
        self.onBuffer = onBuffer

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
        onBuffer = nil
        unregisterObservers()

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
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
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

    // MARK: - Tap installation + resampling

    private func installTap() {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: nativeFormat, to: outputFormat)

        // Tap returns native-format buffers; we resample inside the handler.
        let tapBufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: nativeFormat
        ) { [weak self] buffer, time in
            guard let self, let converter = self.converter, let onBuffer = self.onBuffer else { return }
            self.resample(buffer, time: time, converter: converter, deliver: onBuffer)
        }
    }

    private func resample(
        _ input: AVAudioPCMBuffer,
        time: AVAudioTime,
        converter: AVAudioConverter,
        deliver: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        // Approximate output frame count after resample
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        var inputBufferAlreadyProvided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputBufferAlreadyProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBufferAlreadyProvided = true
            outStatus.pointee = .haveData
            return input
        }
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil, output.frameLength > 0 else { return }
        deliver(output, time)
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
        // The most common case: user unplugs headphones mid-session.
        // We don't need to do anything special — the session's
        // .defaultToSpeaker option will route audio appropriately and
        // the mic input continues from the new input route.
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
