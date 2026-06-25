import Foundation

/// Identifier for the ASR backend that produced (or will produce) a
/// `Partial`. Used by `StreamingASR` (the facade) to pick the right
/// provider based on `@AppStorage("settings.asrProvider")`, and by the
/// Settings UI to render the current selection.
///
/// **Phase A.4a (2026-06-21).** Only `.whisperKit` is wired right now.
/// `.sarvam` and `.gemini` are reserved for Phase A.4b which is running
/// in parallel; that dispatch adds `SarvamProvider` + `GeminiProvider`
/// files conforming to ``ASRProvider`` and wires them through
/// `StreamingASR`. Until A.4b merges, picking either cloud provider in
/// Settings falls back to WhisperKit with a DIAG log.
public enum ASRProviderId: String, Codable, CaseIterable, Sendable {
    case whisperKit
    case sarvam
    case gemini
    /// **Dual mode** — runs WhisperKit-small on-device and Sarvam in
    /// parallel against the same mic stream. Whisper's rolling
    /// transcripts show first (sub-second cadence) so the user sees
    /// text immediately; Sarvam's higher-quality Punjabi segments
    /// replace them when each VAD chunk closes. Implemented by
    /// ``DualLiveProvider`` over a ``ChunkBroadcaster``.
    case dual
    /// **GurbaniLens Cloud** — self-hosted IndicConformer Punjabi ASR
    /// (asr.gurbanilens.com). Free for end users; bearer-token
    /// authenticated server-side; ~420 ms round-trip per ~2 s WAV
    /// chunk (Deep's 2026-06-25 prod test). v1 production default —
    /// gives Punjabi-quality transcription without Sarvam's per-search
    /// cost. Implemented by ``GurbaniLensCloudProvider``.
    case gurbanilensCloud

    public var displayName: String {
        switch self {
        case .whisperKit:       return "On-device (Whisper)"
        case .sarvam:           return "Sarvam (cloud)"
        case .gemini:           return "Gemini (cloud)"
        case .dual:             return "Dual (Whisper live + Sarvam refine)"
        case .gurbanilensCloud: return "GurbaniLens Cloud (recommended)"
        }
    }
}

/// One incremental update from any streaming ASR backend. Single text
/// field per Phase A.3 reset — the WhisperKit segment-split that
/// produced concatenated junk is gone. Each backend is responsible for
/// producing the same shape:
///   - `text` — provider-native script (Devanagari for WhisperKit,
///     Gurmukhi for Sarvam, depends on Gemini model selection).
///   - `latin` — Latin-normalised form for matcher input.
///   - `gurmukhi` — Gurmukhi-script rendering for UI display.
///
/// Providers MUST run `Latin.from` + `Gurmukhi.fromDevanagari` (or the
/// script-appropriate equivalent) so consumers don't need to know which
/// backend produced a partial.
public struct Partial: Sendable {
    /// Where the partial came from. Used by ``DualLiveProvider`` to tag
    /// each emit so the consumer (VoiceSearchSession) can bypass the
    /// freeze-last-good shrink guard when authoritative Sarvam segments
    /// arrive shorter than the rolling Whisper transcript. Defaults to
    /// nil for backwards compatibility — single-provider modes don't
    /// need to set it.
    public enum Source: Sendable, Equatable {
        case whisperLive
        case sarvam
    }

    /// Native-script transcript, post-filtering.
    public let text: String
    /// `Latin.from(text)` — matcher input.
    public let latin: String
    /// Script-normalised display string — Gurmukhi.
    public let gurmukhi: String
    /// True while the underlying backend reports active speech. Flips
    /// to false on VAD-stop / silence / explicit `stop()`.
    public let isSpeaking: Bool
    /// Last frame's energy 0..1 (VU bar). 0 when no audio yet.
    public let bufferEnergy: Float
    /// Optional source tag for dual-provider mode. nil for single-
    /// provider flows; consumers ignore nil and use existing logic.
    public let source: Source?

    public init(
        text: String,
        latin: String,
        gurmukhi: String,
        isSpeaking: Bool,
        bufferEnergy: Float,
        source: Source? = nil
    ) {
        self.text = text
        self.latin = latin
        self.gurmukhi = gurmukhi
        self.isSpeaking = isSpeaking
        self.bufferEnergy = bufferEnergy
        self.source = source
    }
}

/// Pluggable streaming-ASR backend.
///
/// **Locked Phase A.4 contract** (do not deviate — Phase A.4b's
/// `SarvamProvider` + `GeminiProvider` conform to this exact signature):
///
/// - Actor-constrained for safe cross-task state.
/// - `partials` is a property, not a function — call `start()` first,
///   then iterate `await provider.partials` while it emits.
/// - `start()` may be called repeatedly (after each `stop()`); each
///   call should produce a fresh stream from `partials`.
/// - `stop()` is idempotent. After it returns, `partials` MUST finish.
/// - `requiresNetwork` should reflect whether the backend needs internet
///   for THIS call (e.g. WhisperKit's first-time model download counts;
///   subsequent calls don't).
public protocol ASRProvider: Actor {
    nonisolated var providerId: ASRProviderId { get }
    nonisolated var displayName: String { get }
    nonisolated var requiresNetwork: Bool { get }
    func start() async throws
    func stop() async
    var partials: AsyncStream<Partial> { get }
}
