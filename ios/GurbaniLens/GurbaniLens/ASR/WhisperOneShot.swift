import Foundation
import CoreML
import GurbaniLensCore
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
/// Language remap (v1 ship, 2026-06-20)
/// ------------------------------------
/// Whisper-small was severely undertrained on Punjabi. Even with explicit
/// `language="pa"` + `detectLanguage=false`, the decoder routinely drifts
/// to Telugu glyphs (the closest Indic-script cluster in the model's
/// embedding space) for clean Punjabi recitation — Deep's on-device test
/// captured 88000 samples of clean "ek oankaar sat naam karataa purakh"
/// and got back ~3000 chars of the single Telugu glyph ఀ repeating.
///
/// Workaround: silently remap `pa` → `hi` (Hindi) at the WhisperKit call
/// boundary. Hindi has orders-of-magnitude more training data, Whisper-
/// small's Hindi transcription is reliable, and Devanagari output is
/// exactly what `Latin.from` already handles (Phase 1 found Whisper
/// transcribes Punjabi audio to Devanagari on the medium model anyway).
/// v2's Punjabi-fine-tuned model can drop this remap.
///
/// Phase 1 deterministic-ASR config (locked in `DecodingOptions`):
///   - task = .transcribe
///   - language = config.language (remapped per above)
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

        public var errorDescription: String? {
            switch self {
            case .pipeInitFailed(let e):
                return "Couldn't load WhisperKit (\(e.localizedDescription)). " +
                       "Check network on first launch — the model auto-downloads from " +
                       "huggingface.co/argmaxinc/whisperkit-coreml. Or run " +
                       "`bash scripts/fetch_ios_deps.sh --bundle-model` to pre-bundle it."
            case .transcribeFailed(let e):
                return "WhisperKit transcribe failed: \(e.localizedDescription)"
            }
        }
    }

    /// Repetition / length thresholds for ``isRepetitionHallucination(_:)``.
    public enum HallucinationGuard {
        /// Any single char repeating this many times consecutively trips the guard.
        public static let maxConsecutiveChar = 10
        /// Any 2-char pair repeating this many times consecutively trips the guard.
        public static let maxConsecutivePair = 5
        /// Any transcript longer than this many compacted chars trips the guard.
        /// 5 s of honest recitation is usually < 100 chars; 500 is generously above
        /// any honest length and well below the matcher-blocking threshold.
        public static let maxTranscriptLength = 500
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

    /// Expose the lazy-constructed WhisperKit instance to v2's
    /// ``StreamingASR``. Sharing a single pipe means model load + cold-start
    /// cost is paid once across both v1 and v2 modes (the user can flip
    /// search-mode in Settings without re-downloading the CoreML tree).
    public func sharedPipe() async throws -> WhisperKit {
        return try await ensurePipe()
    }

    private func ensurePipe() async throws -> WhisperKit {
        if let p = pipe { return p }
        do {
            // Compute units: WhisperKit's defaults are already
            // textDecoderCompute = .cpuAndNeuralEngine and
            // audioEncoderCompute = .cpuAndNeuralEngine on iOS 17+. We pass
            // the struct explicitly so future WhisperKit bumps or default
            // changes can't silently regress us to CPU-only. Setting these
            // does NOT close Deep's 6.4× realtime gap on its own — that's
            // first-launch CoreML cold-start cost, not a wrong-device
            // assignment. Subsequent runs warm the model and run faster.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: modelFolder,
                computeOptions: compute,
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

        // Language remap — see file-level kdoc.
        let effectiveLanguage: String = (config.language == "pa") ? "hi" : config.language
        if effectiveLanguage != config.language {
            NSLog("[DIAG] WhisperOneShot.transcribe language remap \(config.language) → \(effectiveLanguage) (small-model Punjabi workaround)")
        }

        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: effectiveLanguage,
            temperature: config.temperature,
            // Re-enable the temperature ladder. At T=0 with no fallback,
            // the decoder can lock into a single-glyph repetition loop on
            // ambiguous Indic-script audio (Deep's on-device test caught
            // this). The ladder retries at slightly higher temperatures,
            // which usually breaks the lock. We accept the determinism
            // trade-off — Phase 1's "no fallback" finding was about the
            // medium model; the small model needs the retry.
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            // Force the explicit language above. WhisperKit's DecodingOptions
            // treats `detectLanguage: nil` as "auto" on some paths, which
            // can override our `language:` and is one of the hypothesised
            // causes of the nukta/Telugu hallucination.
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

        // Hallucination guard. Treat detection as "no speech" — empty
        // transcript → matcher receives empty query → SearchResult with
        // no matches → UI lands on Results screen's "No matches found,
        // try again" empty state. No throw; this is a model failure mode,
        // not an app crash, and a red Error alert would be the wrong UX.
        if Self.isRepetitionHallucination(trimmed) {
            NSLog("[DIAG] WhisperOneShot suppressed repetition hallucination (raw.len=\(trimmed.count) prefix=\"\(String(trimmed.prefix(40)))\")")
            let elapsed = Int64(Date().timeIntervalSince(start) * 1000)
            return AsrTranscript(text: "", language: effectiveLanguage, durationMs: elapsed)
        }

        // Whisper output may be in Gurmukhi or Devanagari; normalise to
        // Latin so the matcher sees the same surface as Phase 1. ALSO
        // produce a Gurmukhi-script rendering for display (Bug H —
        // Sangat expect Gurmukhi, not Devanagari, in the UI).
        let latin = Latin.from(trimmed)
        let gurmukhi = Gurmukhi.fromDevanagari(trimmed)
        let elapsed = Int64(Date().timeIntervalSince(start) * 1000)
        NSLog("[DIAG] WhisperOneShot.transcribe latin.len=\(latin.count) latin.head120=\"\(String(latin.prefix(120)))\" gurmukhi.len=\(gurmukhi.count) gurmukhi.head60=\"\(String(gurmukhi.prefix(60)))\" elapsedMs=\(elapsed)")
        return AsrTranscript(text: latin, gurmukhi: gurmukhi, language: effectiveLanguage, durationMs: elapsed)
    }

    // MARK: - Hallucination heuristic

    /// Returns true if `text` looks like a Whisper repetition-loop
    /// hallucination. Tripwires:
    ///   - Compacted (whitespace-stripped) length above
    ///     ``HallucinationGuard/maxTranscriptLength``.
    ///   - Any single char repeating ``HallucinationGuard/maxConsecutiveChar``
    ///     times in a row.
    ///   - Any 2-char pair repeating
    ///     ``HallucinationGuard/maxConsecutivePair`` times in a row.
    nonisolated static func isRepetitionHallucination(_ text: String) -> Bool {
        if text.isEmpty { return false }
        // Strip whitespace — Whisper sometimes interleaves repeats with
        // single spaces and we want to catch those too.
        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        if compact.isEmpty { return false }

        if compact.count > HallucinationGuard.maxTranscriptLength {
            return true
        }

        // Rule 1: any single char repeats > maxConsecutiveChar times in a row.
        var prev: Character? = nil
        var run = 1
        for ch in compact {
            if ch == prev {
                run += 1
                if run >= HallucinationGuard.maxConsecutiveChar { return true }
            } else {
                prev = ch
                run = 1
            }
        }

        // Rule 2: any 2-char pair repeats > maxConsecutivePair times in a row.
        let chars = Array(compact)
        if chars.count >= HallucinationGuard.maxConsecutivePair * 2 + 2 {
            var prevPair: (Character, Character)? = nil
            var pairRun = 1
            var i = 0
            while i + 1 < chars.count {
                let p: (Character, Character) = (chars[i], chars[i + 1])
                if let pp = prevPair, pp.0 == p.0 && pp.1 == p.1 {
                    pairRun += 1
                    if pairRun >= HallucinationGuard.maxConsecutivePair { return true }
                } else {
                    prevPair = p
                    pairRun = 1
                }
                i += 2
            }
        }

        return false
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
