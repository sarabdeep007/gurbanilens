import Foundation

/// One-shot single-buffer ASR. v1 voice-search captures a fixed-duration clip
/// (tap-to-record) and hands the whole PCM buffer to the engine — no streaming.
///
/// Phase 1 deterministic-ASR settings (`temperature=0`, no fallback, fixed
/// seed where supported, `language="pa"`) are baked into the default
/// ``AsrConfig``. Don't relax these without updating CLAUDE.md "Known Phase 2A
/// gating items" — that finding came from real Phase 1 evaluation.
///
/// Mirrors `android/.../domain/Asr.kt`. The continuous-listen ``WhisperASR``
/// next to this in `ASR/WhisperASR.swift` is the v2 reference implementation —
/// v1 uses ``WhisperOneShot`` instead.
public protocol Asr: AnyObject {
    /// Transcribe 16 kHz mono Float32 PCM samples in [-1.0, 1.0].
    func transcribe(_ samples: [Float], config: AsrConfig) async throws -> AsrTranscript

    /// Whether the engine is loaded and ready.
    var isReady: Bool { get }
}

public extension Asr {
    func transcribe(_ samples: [Float]) async throws -> AsrTranscript {
        try await transcribe(samples, config: .default)
    }
}

public struct AsrConfig: Sendable, Equatable {
    public var language: String
    public var temperature: Float
    public var noTemperatureFallback: Bool
    public var seed: Int32
    public var maxThreads: Int32
    public var translate: Bool

    public init(
        language: String = "pa",
        temperature: Float = 0.0,
        noTemperatureFallback: Bool = true,
        seed: Int32 = 1,
        maxThreads: Int32 = 4,
        translate: Bool = false
    ) {
        self.language = language
        self.temperature = temperature
        self.noTemperatureFallback = noTemperatureFallback
        self.seed = seed
        self.maxThreads = maxThreads
        self.translate = translate
    }

    public static let `default` = AsrConfig()
}

public struct AsrTranscript: Sendable, Equatable {
    /// Latin-normalised transcript — matcher input.
    public let text: String
    /// Gurmukhi-script rendering of the source Devanagari transcript —
    /// what the UI should display in "You said: …" surfaces. Empty when
    /// the source wasn't Devanagari (e.g. MockAsr canned text); callers
    /// should fall back to ``text`` for display in that case.
    public let gurmukhi: String
    public let language: String
    public let durationMs: Int64
    public init(text: String, gurmukhi: String = "", language: String, durationMs: Int64) {
        self.text = text
        self.gurmukhi = gurmukhi
        self.language = language
        self.durationMs = durationMs
    }
}
