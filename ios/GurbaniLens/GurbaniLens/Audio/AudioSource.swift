import Foundation
import AVFoundation

/// Anything that streams 16 kHz mono Float32 PCM buffers via a callback.
///
/// Three implementations:
/// - ``MicSource``     — live mic (AVAudioEngine), Phase 2A primary
/// - ``FileSource``    — pre-recorded file, for Simulator testing
/// - ``LineInSource``  — USB / mixer console line-in, Phase 2C placeholder
public protocol AudioSource: AnyObject {
    /// Begin streaming buffers via `onBuffer`. The buffer's audio is
    /// 16 kHz mono Float32 (non-interleaved). The buffer's frame count is
    /// implementation-defined but bounded by ``preferredBufferFrames``.
    ///
    /// Throws if the audio session can't be configured or permissions are
    /// missing.
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws

    /// Stop streaming. Idempotent.
    func stop()

    /// Whether ``start`` was called and ``stop`` has not yet been called.
    var isRunning: Bool { get }

    /// Plain-English description for telemetry, e.g. "Mic (16 kHz, 1024-frame buffers)".
    var configurationDescription: String { get }
}

public extension AudioSource {
    /// All sources emit at this rate; matches whisper.cpp's input expectation.
    static var sampleRate: Double { 16_000.0 }

    /// Preferred audio buffer size; sources may emit smaller buffers.
    static var preferredBufferFrames: AVAudioFrameCount { 1024 }
}

/// Errors thrown by audio sources.
public enum AudioSourceError: LocalizedError {
    case microphonePermissionDenied
    case sessionConfigurationFailed(underlying: Error)
    case engineStartFailed(underlying: Error)
    case fileLoadFailed(URL, underlying: Error)
    case unimplemented(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied. Enable it in iOS Settings → Privacy → Microphone → GurbaniLens."
        case .sessionConfigurationFailed(let e):
            return "Couldn't configure the audio session: \(e.localizedDescription)"
        case .engineStartFailed(let e):
            return "Couldn't start the audio engine: \(e.localizedDescription)"
        case .fileLoadFailed(let url, let e):
            return "Couldn't load audio file \(url.lastPathComponent): \(e.localizedDescription)"
        case .unimplemented(let what):
            return "\(what) is not yet implemented."
        }
    }
}
