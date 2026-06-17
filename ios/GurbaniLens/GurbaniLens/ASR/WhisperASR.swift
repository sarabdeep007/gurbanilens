import Foundation
import AVFoundation
@preconcurrency import whisper

/// Streaming ASR over whisper.cpp. Accepts 16 kHz mono Float32 PCM buffers
/// from any ``AudioSource``, accumulates a rolling window, and yields
/// ``ASRSegment``s to a callback.
///
/// Threading: ``feed`` is safe to call from any queue; transcription happens
/// on an internal serial queue.
public actor WhisperASR {

    // MARK: - Public

    public struct Config {
        /// Path to the ggml model file (typically bundled in Resources/Models).
        public var modelPath: URL
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
        /// Whether to disable VAD inside whisper.cpp. Phase 1 finding: Silero
        /// VAD eats sung Kirtan; leave VAD off.
        public var disableVAD: Bool = true

        public init(modelPath: URL) {
            self.modelPath = modelPath
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
        case modelLoadFailed(URL)
        case transcribeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let url):
                return "Failed to load Whisper model at \(url.lastPathComponent). "
                     + "Check that the file is bundled in Resources/Models."
            case .transcribeFailed(let code):
                return "whisper.cpp transcribe failed (code \(code))."
            }
        }
    }

    // MARK: - Internal state

    private let config: Config
    private var context: OpaquePointer?  // whisper_context*
    private var pcmRing: [Float] = []
    private var captureStartTime: Double = 0
    private var lastTranscribeAt: Double = 0
    private var captureFrameCount: AVAudioFramePosition = 0
    private var onSegment: SegmentCallback?

    public init(config: Config) throws {
        self.config = config
        var params = whisper_context_default_params()
        // Use CoreML if the model has a paired .mlmodelc file in the same dir
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(
            config.modelPath.path, params
        ) else {
            throw ASRError.modelLoadFailed(config.modelPath)
        }
        self.context = ctx
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }

    /// Begin emitting segments via `callback`. Subsequent ``feed`` calls
    /// accumulate audio; whenever ``stepSeconds`` of audio has accumulated
    /// since the last transcription, we transcribe a ``windowSeconds``
    /// window and emit the resulting segments.
    public func attach(_ callback: @escaping SegmentCallback) {
        self.onSegment = callback
        self.captureStartTime = currentMonotonicSeconds()
        self.lastTranscribeAt = self.captureStartTime
        self.captureFrameCount = 0
        self.pcmRing.removeAll(keepingCapacity: true)
    }

    /// Feed a buffer from an AudioSource. The buffer's audio is 16 kHz mono
    /// Float32 (non-interleaved).
    public func feed(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let chan = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        pcmRing.append(contentsOf: UnsafeBufferPointer(start: chan, count: frames))
        captureFrameCount += AVAudioFramePosition(frames)

        // Trim the ring to a max of 2× windowSeconds so memory stays bounded
        let maxRingSamples = Int(2.0 * config.windowSeconds * AudioSourceConstants.sampleRate)
        if pcmRing.count > maxRingSamples {
            pcmRing.removeFirst(pcmRing.count - maxRingSamples)
        }

        let now = currentMonotonicSeconds()
        if (now - lastTranscribeAt) >= config.stepSeconds {
            transcribeRecentWindow()
            lastTranscribeAt = now
        }
    }

    public func stop() {
        onSegment = nil
        pcmRing.removeAll(keepingCapacity: false)
    }

    // MARK: - Transcription

    private func transcribeRecentWindow() {
        guard let ctx = context, let onSegment = onSegment else { return }
        let needed = Int(config.windowSeconds * AudioSourceConstants.sampleRate)
        let windowSamples = pcmRing.suffix(needed)
        if windowSamples.count < Int(AudioSourceConstants.sampleRate * 0.5) {
            // Less than half a second; skip
            return
        }

        // Compute absolute time anchor for this window
        let totalSec = Double(captureFrameCount) / AudioSourceConstants.sampleRate
        let windowEndSec = totalSec
        let windowStartSec = totalSec - Double(windowSamples.count) / AudioSourceConstants.sampleRate

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = (config.language as NSString).utf8String
        params.translate = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.single_segment = false
        params.suppress_blank = true
        params.temperature = config.temperature
        params.temperature_inc = 0.0  // disable fallback
        params.no_speech_thold = 0.6
        params.suppress_nst = false
        params.no_context = false

        let samples = Array(windowSamples)
        let result = samples.withUnsafeBufferPointer { ptr -> Int32 in
            return whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }
        if result != 0 {
            NSLog("WhisperASR: whisper_full returned \(result)")
            return
        }

        let segCount = whisper_full_n_segments(ctx)
        for i in 0..<segCount {
            guard let cstr = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cstr).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let relStart = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
            let relEnd = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            let segment = ASRSegment(
                startTime: windowStartSec + relStart,
                endTime: windowStartSec + relEnd,
                text: text,
                textLatin: Latin.from(text)
            )
            // Hop out of the actor to call user code
            Task {
                onSegment(segment)
            }
        }
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
