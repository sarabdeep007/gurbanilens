import Foundation
import AVFoundation

/// Stream a pre-recorded audio file as if it were live mic input. Intended
/// for Simulator testing of the full ASR + matcher pipeline without a real
/// microphone, and for deterministic CI / regression runs.
///
/// Reads the file in chunks of `preferredBufferFrames`, resamples to
/// 16 kHz mono Float32, and dispatches each chunk on a background queue
/// at roughly real-time pacing (sleep between chunks = chunk duration).
public final class FileSource: AudioSource {

    private let url: URL
    private let outputFormat: AVAudioFormat
    private var task: Task<Void, Never>?
    private let runningLock = NSLock()
    private var _isRunning: Bool = false

    public var isRunning: Bool {
        runningLock.lock(); defer { runningLock.unlock() }
        return _isRunning
    }

    private func setRunning(_ v: Bool) {
        runningLock.lock(); _isRunning = v; runningLock.unlock()
    }

    public var configurationDescription: String {
        "File: \(url.lastPathComponent) → 16 kHz mono Float32"
    }

    public init(url: URL) {
        self.url = url
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRunning else { return }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioSourceError.fileLoadFailed(url, underlying: error)
        }
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioSourceError.fileLoadFailed(
                url,
                underlying: NSError(domain: "FileSource", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"])
            )
        }

        setRunning(true)
        task = Task.detached(priority: .userInitiated) { [weak self, outputFormat] in
            await self?.streamFile(
                file: file,
                converter: converter,
                outputFormat: outputFormat,
                deliver: onBuffer
            )
            self?.setRunning(false)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        setRunning(false)
    }

    private func streamFile(
        file: AVAudioFile,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        deliver: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async {
        let chunkFrames = Self.preferredBufferFrames
        let sourceFormat = file.processingFormat
        guard let inputBuf = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: chunkFrames
        ) else { return }

        let chunkDuration = Double(chunkFrames) / outputFormat.sampleRate
        var startSampleTime: AVAudioFramePosition = 0

        while !Task.isCancelled {
            inputBuf.frameLength = 0
            do {
                try file.read(into: inputBuf, frameCount: chunkFrames)
            } catch {
                NSLog("FileSource: read error \(error)")
                break
            }
            if inputBuf.frameLength == 0 { break }

            guard let outputBuf = Self.convertChunk(
                input: inputBuf,
                converter: converter,
                outputFormat: outputFormat
            ) else { continue }

            let time = AVAudioTime(sampleTime: startSampleTime, atRate: outputFormat.sampleRate)
            startSampleTime += AVAudioFramePosition(outputBuf.frameLength)
            deliver(outputBuf, time)

            // Pace at roughly real time so downstream code (ASR) sees a
            // realistic stream. Use Task.sleep so cancellation works.
            try? await Task.sleep(nanoseconds: UInt64(chunkDuration * 1_000_000_000))
        }
    }

    /// Sync helper. `consumed` and `error` are local-only — they never
    /// escape across an `await`, so the closure can capture them safely
    /// even under Swift 6 strict concurrency checking. The previous inline
    /// version lived inside the `async` streamFile and tripped a
    /// `unsafeForcedSync` warning because the compiler couldn't prove the
    /// closure didn't suspend.
    private static func convertChunk(
        input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 32)
        guard let outputBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outCapacity
        ) else { return nil }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        converter.convert(to: outputBuf, error: &error, withInputFrom: inputBlock)
        if outputBuf.frameLength == 0 { return nil }
        return outputBuf
    }
}
