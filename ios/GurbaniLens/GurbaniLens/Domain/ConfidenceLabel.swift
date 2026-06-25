import Foundation
import GurbaniLensCore

/// 5-tier confidence labels surfaced in Results UI. Bands derived from
/// real-world testing 2026-06-25 — Deep's 7/10-correct kirtan-search
/// test showed users could distinguish "this is the exact pangti I
/// said" from "the matcher made a fuzzy guess" and the UI should be
/// honest about which is which.
///
/// Score scale matches ``Matcher``: 0–100 (`partial_ratio × coverage`).
///
/// Tier thresholds:
///   - `.found`        — score ≥ 95
///   - `.bestMatch`    — score 85–94
///   - `.likelyMatch`  — score 70–84
///   - `.didYouMean`   — score 50–69 (no single auto-pick)
///   - `.noClearMatch` — score < 50 (sorry-couldn't-find)
///
/// Ambiguity gate: when the top match and runner-up are within 2 points
/// of each other AND the top is in the .found or .bestMatch band, drop
/// one tier — "we found two equally good matches" is a different signal
/// than "we found one clear winner". This avoids surfacing "Found ✓"
/// when there's actually a tie.
///
/// Mirrors `android/.../domain/Confidence.kt` (will need a corresponding
/// Android update in a future dispatch).
public enum ConfidenceLabel: String, CaseIterable, Sendable {
    case found
    case bestMatch
    case likelyMatch
    case didYouMean
    case noClearMatch

    /// Header / pill text shown to the user.
    public var display: String {
        switch self {
        case .found:        return "Found ✓"
        case .bestMatch:    return "Best match"
        case .likelyMatch:  return "Likely match"
        case .didYouMean:   return "Did you mean…"
        case .noClearMatch: return "Couldn't find a clear match"
        }
    }

    /// `true` for the top two tiers — UI should auto-select / hide
    /// alternatives by default.
    public var isHighConfidence: Bool {
        switch self {
        case .found, .bestMatch: return true
        default: return false
        }
    }

    /// True when the matcher gave up — no auto-pick, UI surfaces the
    /// transcript prominently so user can judge whether ASR or
    /// matching was the failure.
    public var isNoMatch: Bool {
        self == .noClearMatch
    }

    /// Map a raw matcher score (0–100) onto a tier. Doesn't apply the
    /// ambiguity check — use ``forScores(top:runnerUp:)`` when you
    /// have a runner-up to compare against.
    public static func forScore(_ score: Double) -> ConfidenceLabel {
        if score >= 95.0 { return .found }
        if score >= 85.0 { return .bestMatch }
        if score >= 70.0 { return .likelyMatch }
        if score >= 50.0 { return .didYouMean }
        return .noClearMatch
    }

    /// Score-with-ambiguity check. When `top` is in `.found` /
    /// `.bestMatch` AND `runnerUp` is within 2 points of it, drop one
    /// tier — "two near-equal high matches" is materially different
    /// from "one clear winner".
    public static func forScores(top: Double, runnerUp: Double?) -> ConfidenceLabel {
        let raw = forScore(top)
        guard raw.isHighConfidence,
              let runnerUp = runnerUp,
              (top - runnerUp) < 2.0 else {
            return raw
        }
        switch raw {
        case .found:     return .bestMatch
        case .bestMatch: return .likelyMatch
        default:         return raw
        }
    }
}
