import Foundation
import AVFoundation
import WhisperKit

/// **v2 placeholder — not used by the v1 voice-search flow.**
///
/// Streaming-style WhisperKit wrapper. Accepts 16 kHz mono Float32 PCM
/// buffers from any ``AudioSource``, accumulates a rolling window, and
/// yields ``ASRSegment``s to a callback.
///
/// The v1 (tap-to-record one-shot) path uses ``WhisperOneShot`` — not this
/// type. This file exists as a stake-in-the-ground for the v2 continuous-
/// listen Paath companion. The interface mirrors what we'll need once Phase
/// 2B's Kirtan fine-tune unblocks v2; the implementation is intentionally
/// minimal until then.
///
/// Threading: ``feed`` is safe to call from any queue; transcription happens
/// inside the actor.
public actor WhisperASR {

    // MARK: - Public

    public struct Config {
        /// WhisperKit model id (e.g. "openai_whisper-small"). Auto-downloads
        /// from huggingface.co/argmaxinc/whisperkit-coreml unless overridden
        /// by `modelFolder`.
        public var model: String
        /// Optional pre-bundled CoreML model directory.
        public var modelFolder: String?
        /// Language hint. Phase 1 finding: Whisper transcribes Punjabi audio
        /// to Devanagari even with "pa", which is fine — we Latin-normalise
        /// either way.
        public var language: String = "pa"
        /// Sliding window duration in seconds. Whisper processes a chunk per
        /// transcription call; longer windows = better context, more latency.
        public var windowSeconds: Double = 5.0
        /// Step between transcription calls. Smaller step = lower latency,
        /// more compute.
        public var stepSeconds: Double = 1.0
        /// Disable temperature fallback (deterministic output — addresses
        /// Phase 1 Whisper-non-determinism finding).
        public var temperature: Float = 0.0

        public init(model: String = "openai_whisper-small", modelFolder: String? = nil) {
            self.model = model
            self.modelFolder = modelFolder
        }
    }

    public struct ASRSegment {
        public let startTime: Double  // seconds from the start of capture
        public let endTime: Double
        public let text: String        // raw transcript (Gurmukhi or Devanagari)
        public let textLatin: String   // Latin-normalised, ready for matcher
    }

    public typealias SegmentCallback = (ASRSegment) -> Void

    public enum ASRError: LocalizedError {
        case pipeInitFailed(underlying: Error)
        case transcribeFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .pipeInitFailed(let e):
                return "Couldn't initialise WhisperKit: \(e.localizedDescription)"
            case .transcribeFailed(let e):
                return "WhisperKit transcribe failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Internal state

    private let config: Config
    private var pipe: WhisperKit?
    private var pcmRing: [Float] = []
    private var captureStartTime: Double = 0
    private var lastTranscribeAt: Double = 0
    private var captureFrameCount: AVAudioFramePosition = 0
    private var onSegment: SegmentCallback?

    public init(config: Config) async throws {
        self.config = config
        do {
            let kitConfig = WhisperKitConfig(
                model: config.model,
                modelFolder: config.modelFolder,
                verbose: false,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: config.modelFolder == nil
            )
            self.pipe = try await WhisperKit(kitConfig)
        } catch {
            throw ASRError.pipeInitFailed(underlying: error)
        }
    }

    /// Begin emitting segments via `callback`. Subsequent ``feed`` calls
    /// accumulate audio; whenever ``stepSeconds`` of audio has accumulated
    /// since the last transcription, we transcribe a ``windowSeconds``
    /// window and emit the resulting segment.
    public func attach(_ callback: @escaping SegmentCallback) {
        self.onSegment = callback
        self.captureStartTime = currentMonotonicSeconds()
        self.lastTranscribeAt = self.captureStartTime
        self.captureFrameCount = 0
        self.pcmRing.removeAll(keepingCapacity: true)
    }

    /// Feed a buffer from an AudioSource. The buffer's audio is 16 kHz mono
    /// Float32 (non-interleaved).
    public func feed(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        guard let chan = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        pcmRing.append(contentsOf: UnsafeBufferPointer(start: chan, count: frames))
        captureFrameCount += AVAudioFramePosition(frames)

        // Trim the ring to a max of 2× windowSeconds so memory stays bounded.
        let maxRingSamples = Int(2.0 * config.windowSeconds * AudioSourceConstants.sampleRate)
        if pcmRing.count > maxRingSamples {
            pcmRing.removeFirst(pcmRing.count - maxRingSamples)
        }

        let now = currentMonotonicSeconds()
        if (now - lastTranscribeAt) >= config.stepSeconds {
            await transcribeRecentWindow()
            lastTranscribeAt = now
        }
    }

    public func stop() {
        onSegment = nil
        pcmRing.removeAll(keepingCapacity: false)
    }

    // MARK: - Transcription

    private func transcribeRecentWindow() async {
        guard let pipe = pipe, let onSegment = onSegment else { return }
        let needed = Int(config.windowSeconds * AudioSourceConstants.sampleRate)
        let window = Array(pcmRing.suffix(needed))
        if window.count < Int(AudioSourceConstants.sampleRate * 0.5) {
            return  // less than half a second
        }

        let totalSec = Double(captureFrameCount) / AudioSourceConstants.sampleRate
        let windowEndSec = totalSec
        let windowStartSec = totalSec - Double(window.count) / AudioSourceConstants.sampleRate

        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: config.language,
            temperature: config.temperature,
            temperatureIncrementOnFallback: 0.0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: window, decodeOptions: decode)
        } catch {
            NSLog("WhisperASR: transcribe error \(error)")
            return
        }

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }

        let segment = ASRSegment(
            startTime: windowStartSec,
            endTime: windowEndSec,
            text: text,
            textLatin: Latin.from(text)
        )
        onSegment(segment)
    }

    private func currentMonotonicSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000.0
    }
}

/// Mirror of ``AudioSource.sampleRate`` so the ASR code doesn't depend on
/// the protocol type. Both live in the same module so they can't diverge.
enum AudioSourceConstants {
    static let sampleRate: Double = 16_000.0
}
