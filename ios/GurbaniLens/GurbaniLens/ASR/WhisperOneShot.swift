import Foundation
import WhisperKit

/// One-shot WhisperKit wrapper for v1 voice-search. Loads a WhisperKit pipe
/// once (CoreML-backed, optimised for Apple Neural Engine / GPU) and exposes
/// a single `transcribe(_:config:)` entry point that satisfies the ``Asr``
/// protocol. Mirrors `android/.../domain/WhisperAsr.kt`.
///
/// Model loading
/// -------------
/// Two paths, in priority order:
///   1. **Bundled** — if a `Resources/Models/openai_whisper-small` directory
///      (or whichever variant) is in the app bundle, point WhisperKit at it
///      via `modelFolder:`. No network needed at first launch.
///   2. **Auto-download** — otherwise WhisperKit pulls the recommended
///      CoreML model from huggingface.co/argmaxinc/whisperkit-coreml on
///      first launch and caches it. Requires network on first run.
///
/// The bundled path is gated on `scripts/fetch_ios_deps.sh --bundle-model`;
/// the auto-download path is the default behaviour and works out of the box.
///
/// Phase 1 deterministic-ASR config (locked in `DecodingOptions`):
///   - task = .transcribe
///   - language = config.language ("pa" by default)
///   - temperature = 0.0
///   - temperatureFallbackCount = 0          (no fallback ladder)
///   - withoutTimestamps = true              (one-shot — we don't need timing)
///   - suppressBlank = true
///   - usePrefillPrompt = true
///   - skipSpecialTokens = true              (clean text out)
///
/// Limitation: WhisperKit's public DecodingOptions does not expose a numeric
/// `seed`. Greedy decoding with `temperature=0` and a disabled fallback ladder
/// is deterministic in practice; this is the closest equivalent to Phase 1's
/// "fixed seed where supported" finding.
///
/// Output text from WhisperKit is the decoded transcript. For Punjabi audio,
/// Whisper-family models often emit Devanagari (Phase 1 finding). The
/// returned string is Latin-normalised via ``Latin`` so the matcher sees the
/// same surface regardless of the original script.
public actor WhisperOneShot: Asr {

    public enum WhisperError: LocalizedError {
        case pipeInitFailed(underlying: Error)
        case transcribeFailed(underlying: Error)
        case emptyResult

        public var errorDescription: String? {
            switch self {
            case .pipeInitFailed(let e):
                return "Couldn't load WhisperKit (\(e.localizedDescription)). " +
                       "Check network on first launch — the model auto-downloads from " +
                       "huggingface.co/argmaxinc/whisperkit-coreml. Or run " +
                       "`bash scripts/fetch_ios_deps.sh --bundle-model` to pre-bundle it."
            case .transcribeFailed(let e):
                return "WhisperKit transcribe failed: \(e.localizedDescription)"
            case .emptyResult:
                return "WhisperKit returned no transcription segments."
            }
        }
    }

    private let modelName: String
    private let modelFolder: String?
    private var pipe: WhisperKit?
    public nonisolated var isReady: Bool { true }

    /// - Parameters:
    ///   - modelName: WhisperKit model id, e.g. "openai_whisper-small". When
    ///     `modelFolder` is nil this is used to resolve the auto-downloaded
    ///     model on huggingface.co/argmaxinc/whisperkit-coreml.
    ///   - modelFolder: Absolute path to a pre-bundled WhisperKit CoreML
    ///     model directory (containing AudioEncoder.mlmodelc,
    ///     TextDecoder.mlmodelc, MelSpectrogram.mlmodelc, tokenizer files).
    ///     Pass nil to let WhisperKit auto-download.
    public init(modelName: String = "openai_whisper-small", modelFolder: String? = nil) {
        self.modelName = modelName
        self.modelFolder = modelFolder
    }

    private func ensurePipe() async throws -> WhisperKit {
        if let p = pipe { return p }
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: modelFolder,
                verbose: false,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: modelFolder == nil   // only download if we're not bundled
            )
            let p = try await WhisperKit(config)
            pipe = p
            return p
        } catch {
            throw WhisperError.pipeInitFailed(underlying: error)
        }
    }

    public func transcribe(_ samples: [Float], config: AsrConfig) async throws -> AsrTranscript {
        let start = Date()
        let pipe = try await ensurePipe()

        let audioSec = Double(samples.count) / 16_000.0
        let stats = sampleStats(samples)
        let head = samples.prefix(20).map { String(format: "%.4f", $0) }.joined(separator: ",")
        NSLog("[DIAG] WhisperOneShot.transcribe input samples=\(samples.count) sec=\(String(format: "%.3f", audioSec)) min=\(stats.min) max=\(stats.max) mean|abs|=\(stats.meanAbs) head20=[\(head)]")

        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: config.language,
            temperature: config.temperature,
            temperatureIncrementOnFallback: 0.0,
            temperatureFallbackCount: config.noTemperatureFallback ? 0 : 5,
            usePrefillPrompt: true,
            // Force the explicit language above. WhisperKit's DecodingOptions
            // treats `detectLanguage: nil` as "auto" on some paths, which
            // can override our `language: "pa"` for short or noisy clips
            // and is one of the hypothesised causes of the nukta-spam.
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            // Tighten loop-detection: when Whisper repeats the same token
            // (hallucination), compression ratio of the output spikes.
            // Default 2.4 lets a lot through; 2.0 catches loops earlier.
            compressionRatioThreshold: 2.0,
            logProbThreshold: -1.0,
            // Default 0.6 is aggressive — Whisper flags borderline-speech
            // clips as silence and the prefill prompt then dominates the
            // decode (= hallucination). 0.45 lets quieter recitations
            // through without disabling the silence filter entirely.
            noSpeechThreshold: 0.45
        )
        NSLog("[DIAG] WhisperOneShot.transcribe decode task=transcribe language=\(decode.language ?? "nil") temperature=\(decode.temperature) tempFallback=\(decode.temperatureFallbackCount) compressionRatioThold=\(String(describing: decode.compressionRatioThreshold)) noSpeechThold=\(String(describing: decode.noSpeechThreshold)) withoutTimestamps=\(decode.withoutTimestamps) suppressBlank=\(decode.suppressBlank)")

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: decode
            )
        } catch {
            NSLog("[DIAG] WhisperOneShot.transcribe THROW \(error.localizedDescription)")
            throw WhisperError.transcribeFailed(underlying: error)
        }

        // WhisperKit returns one TranscriptionResult per chunked window. For a
        // tap-to-record clip well under 30 s (Whisper's native context window),
        // there's typically exactly one result. Concatenate defensively in
        // case the user recited > 30 s.
        let combined = results.map(\.text).joined(separator: " ")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[DIAG] WhisperOneShot.transcribe raw segments=\(results.count) rawText.len=\(trimmed.count) rawText.head120=\"\(String(trimmed.prefix(120)))\"")

        if trimmed.isEmpty && results.isEmpty {
            throw WhisperError.emptyResult
        }
        // Whisper output may be in Gurmukhi or Devanagari; normalise to
        // Latin so the matcher sees the same surface as Phase 1.
        let latin = Latin.from(trimmed)
        let elapsed = Int64(Date().timeIntervalSince(start) * 1000)
        NSLog("[DIAG] WhisperOneShot.transcribe latin.len=\(latin.count) latin.head120=\"\(String(latin.prefix(120)))\" elapsedMs=\(elapsed)")
        return AsrTranscript(text: latin, language: config.language, durationMs: elapsed)
    }

    private nonisolated func sampleStats(_ s: [Float]) -> (min: Float, max: Float, meanAbs: Float) {
        if s.isEmpty { return (0, 0, 0) }
        var lo: Float = .infinity, hi: Float = -.infinity, sum: Float = 0
        for v in s {
            if v < lo { lo = v }
            if v > hi { hi = v }
            sum += abs(v)
        }
        return (lo, hi, sum / Float(s.count))
    }
}
