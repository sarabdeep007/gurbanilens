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
    public private(set) var isRunning: Bool = false

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

        isRunning = true
        task = Task.detached(priority: .userInitiated) { [weak self, outputFormat] in
            await self?.streamFile(
                file: file,
                converter: converter,
                outputFormat: outputFormat,
                deliver: onBuffer
            )
            await MainActor.run { self?.isRunning = false }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
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

            let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inputBuf.frameLength) * ratio + 32)
            guard let outputBuf = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outCapacity
            ) else { break }

            var consumed = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return inputBuf
            }
            converter.convert(to: outputBuf, error: &error, withInputFrom: inputBlock)
            if outputBuf.frameLength == 0 { continue }

            let time = AVAudioTime(sampleTime: startSampleTime, atRate: outputFormat.sampleRate)
            startSampleTime += AVAudioFramePosition(outputBuf.frameLength)
            deliver(outputBuf, time)

            // Pace at roughly real time so downstream code (ASR) sees a
            // realistic stream. Use Task.sleep so cancellation works.
            try? await Task.sleep(nanoseconds: UInt64(chunkDuration * 1_000_000_000))
        }
    }
}
