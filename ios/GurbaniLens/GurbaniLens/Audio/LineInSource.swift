import Foundation
import AVFoundation

/// Placeholder for Phase 2C: USB or external mixer-console line-in capture
/// for Gurdwara projector use. The protocol shape matches MicSource so the
/// downstream pipeline doesn't change when the implementation lands.
///
/// Phase 2A intentionally fails fast if anything tries to instantiate this.
public final class LineInSource: AudioSource {
    public init() {
        // Don't fatal here so we can ship the symbol; fail at start() instead
        // and surface a clear error to the caller.
    }

    public var isRunning: Bool { false }

    public var configurationDescription: String {
        "LineIn — Phase 2C placeholder"
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        throw AudioSourceError.unimplemented("LineInSource (Phase 2C)")
    }

    public func stop() { /* nothing to stop */ }
}
