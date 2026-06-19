import Foundation
import GurbaniLensCore

/// v1 surfaces user-facing labels, never raw matcher scores. Bands derived
/// from Phase 1 thresholds (`MATCH_THRESHOLD = 75`, `TOKEN_MATCH_THRESHOLD = 55`).
///
/// Mirrors `android/.../domain/Confidence.kt`.
public enum ConfidenceLabel: String, CaseIterable, Sendable {
    case strong, possible, low

    public var display: String {
        switch self {
        case .strong:   return "Strong match"
        case .possible: return "Possible match"
        case .low:      return "Low confidence"
        }
    }

    public static func forScore(_ score: Double) -> ConfidenceLabel {
        // 75 = Matcher's strong-match threshold (Phase 1 calibration); 50 = "we found
        // tokens but not enough coverage to be confident."
        if score >= 75.0 { return .strong }
        if score >= 50.0 { return .possible }
        return .low
    }
}
