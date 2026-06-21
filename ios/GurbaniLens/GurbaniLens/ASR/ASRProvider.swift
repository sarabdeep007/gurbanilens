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

    public var displayName: String {
        switch self {
        case .whisperKit: return "On-device (Whisper)"
        case .sarvam:     return "Sarvam (cloud)"
        case .gemini:     return "Gemini (cloud)"
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

    public init(
        text: String,
        latin: String,
        gurmukhi: String,
        isSpeaking: Bool,
        bufferEnergy: Float
    ) {
        self.text = text
        self.latin = latin
        self.gurmukhi = gurmukhi
        self.isSpeaking = isSpeaking
        self.bufferEnergy = bufferEnergy
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
