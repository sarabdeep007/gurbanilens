import Foundation
@preconcurrency import whisper

/// One-shot whisper.cpp wrapper for v1 voice-search. Loads a `ggml-*.bin`
/// model once and exposes a single `transcribe(samples:)` entry point.
/// Mirrors `android/.../domain/WhisperAsr.kt`.
///
/// Phase 1 deterministic-ASR config (locked in ``AsrConfig.default``):
///   - sampling = greedy (no temperature ladder)
///   - temperature = 0.0
///   - temperature_inc = 0.0          (no fallback)
///   - language = "pa"
///   - translate = false
///   - suppress_blank = true
///   - n_threads = config.maxThreads
///   - greedy.best_of = 1             (deterministic; mirrors fixed-seed
///                                     intent — whisper.cpp's public API
///                                     does not expose a numeric `seed`)
///
/// Phase 1 finding: Whisper transcribes Punjabi audio to Devanagari even
/// with `language="pa"`. That's fine — the ``Latin`` normaliser handles both.
public actor WhisperOneShot: Asr {

    public enum WhisperError: LocalizedError {
        case modelLoadFailed(URL)
        case transcribeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let url):
                return "Couldn't load the Whisper model at \(url.lastPathComponent). " +
                       "Run `bash scripts/fetch_ios_deps.sh` and rebuild."
            case .transcribeFailed(let code):
                return "whisper.cpp transcribe failed (code \(code))."
            }
        }
    }

    private let modelURL: URL
    private var ctx: OpaquePointer?  // whisper_context*
    public nonisolated var isReady: Bool { true }

    public init(modelURL: URL) throws {
        self.modelURL = modelURL
        var params = whisper_context_default_params()
        params.use_gpu = true   // CoreML / Metal if available
        guard let c = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw WhisperError.modelLoadFailed(modelURL)
        }
        self.ctx = c
    }

    deinit {
        if let c = ctx { whisper_free(c) }
    }

    public func transcribe(_ samples: [Float], config: AsrConfig) async throws -> AsrTranscript {
        guard let c = ctx else { throw WhisperError.modelLoadFailed(modelURL) }
        let start = Date()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = (config.language as NSString).utf8String
        params.translate = config.translate
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.single_segment = false
        params.suppress_blank = true
        params.no_speech_thold = 0.6
        params.temperature = config.temperature
        params.temperature_inc = config.noTemperatureFallback ? 0.0 : 0.2
        params.n_threads = config.maxThreads
        params.greedy.best_of = 1   // deterministic intent; closest knob to "fixed seed"

        let rc = samples.withUnsafeBufferPointer { ptr -> Int32 in
            whisper_full(c, params, ptr.baseAddress, Int32(samples.count))
        }
        guard rc == 0 else { throw WhisperError.transcribeFailed(rc) }

        let segCount = whisper_full_n_segments(c)
        var text = ""
        text.reserveCapacity(Int(segCount) * 32)
        for i in 0..<segCount {
            guard let cstr = whisper_full_get_segment_text(c, i) else { continue }
            text.append(String(cString: cstr))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper output may be in Gurmukhi or Devanagari; normalise to
        // Latin so the matcher sees the same surface as Phase 1.
        let latin = Latin.from(trimmed)
        let elapsed = Int64(Date().timeIntervalSince(start) * 1000)
        return AsrTranscript(text: latin, language: config.language, durationMs: elapsed)
    }
}
