import Foundation

/// Pre-trained OpenAI Whisper model variant. Names map to the
/// `huggingface.co/argmaxinc/whisperkit-coreml` repo subdirectories
/// (CoreML-converted by argmax). Larger models = better accuracy on
/// non-English / low-resource audio, larger download.
///
/// Phase A.4a default flipped from `.small` → `.largeV3`. Phase 1
/// evaluation showed Whisper-small drifts to Telugu on clean Punjabi
/// recitation; large-v3 scored 96.6 on Japji and is reliable. iPhone
/// Neural Engine inference is 1–2 s per ~5 s clip — acceptable.
public enum WhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case largeV3 = "openai_whisper-large-v3"
    case medium  = "openai_whisper-medium"
    case small   = "openai_whisper-small"
    case base    = "openai_whisper-base"
    case tiny    = "openai_whisper-tiny"

    public var id: String { rawValue }

    /// Long-form name for the Settings picker row.
    public var displayName: String {
        switch self {
        case .largeV3: return "Large v3 — best Punjabi accuracy"
        case .medium:  return "Medium — balanced"
        case .small:   return "Small — fastest decode, low Punjabi accuracy"
        case .base:    return "Base — small download, weak accuracy"
        case .tiny:    return "Tiny — smallest, English-leaning"
        }
    }

    /// Compact name for `WhisperKitProvider.displayName` and the model
    /// pill in the LiveResultsScreen footer.
    public var shortDisplayName: String {
        switch self {
        case .largeV3: return "large-v3"
        case .medium:  return "medium"
        case .small:   return "small"
        case .base:    return "base"
        case .tiny:    return "tiny"
        }
    }

    /// Approximate on-disk size after CoreML conversion. Helps the user
    /// understand the first-launch download cost.
    public var approximateSize: String {
        switch self {
        case .largeV3: return "≈ 1.5 GB"
        case .medium:  return "≈ 770 MB"
        case .small:   return "≈ 250 MB"
        case .base:    return "≈ 150 MB"
        case .tiny:    return "≈ 75 MB"
        }
    }

    /// Machine-readable size in bytes — used by ``WhisperKitProvider``'s
    /// download-progress polling task to compute fraction-of-total from
    /// the on-disk model directory size. Numbers mirror
    /// ``approximateSize`` (slightly rounded down to be defensive — if
    /// the actual download is a bit smaller, we cap at 0.95 anyway and
    /// then jump to 1.0 when WhisperKit init returns).
    public var approximateBytes: Int64 {
        switch self {
        case .largeV3: return 1_550_000_000
        case .medium:  return   770_000_000
        case .small:   return   245_000_000
        case .base:    return   145_000_000
        case .tiny:    return    75_000_000
        }
    }
}
