import Foundation

/// Brief #9.30 Fix 2: pure decision function for the sung-mode
/// DISCOVERING fast-lock path in
/// `StreamingRaagiModeEngine.handleSungModeDiscoveringMatch`. Factored
/// out of the engine so the ambiguity guard is unit-testable in
/// GurbaniLensCore without an @MainActor + ShabadCache + provider
/// harness.
///
/// ## The bug (Deep's 2026-07-14 sung-mode session)
///
/// Deep sang "ਕਰੋ ਕਿਰਪਾ ਗੋਪਾਲ ਗੋਬਿੰਦੇ" — a common Waheguru-name phrase
/// shared by many shabads — in sung mode. The engine fast-locked to the
/// WRONG shabad because the first qualifying partial (score ≥ 90,
/// tier ≤ 1, within the first 3 partials of DISCOVERING) fired
/// immediately, before the candidate cloud ever had a chance to engage
/// past the ≥ 5-partial threshold. The 1632-shabad ``AmbiguousShabadSet``
/// (built by `scripts/build_ambiguous_shabad_set.py`) encodes exactly
/// this "common phrase" set.
///
/// ## The fix
///
/// - Non-ambiguous shabads: fast-lock fires as before (clear
///   distinctive openings stay instant).
/// - Ambiguous shabads in **sung mode**: fast-lock is DEFERRED. The
///   engine drops through to the accumulator + candidate cloud path
///   so competing shabads get a fair chance to accumulate evidence.
/// - Ambiguous shabads in **speech mode**: fast-lock still fires.
///   Speech input rarely surfaces the ambiguous common-phrase pattern
///   in isolation, and Deep values speed there.
///
/// The engine keeps its own copies of the score / tier / partials
/// constants for backwards compatibility with pre-#9.30 callers of
/// `sungFastLockScoreThreshold` (e.g. `forceLockFromCloud`); this
/// struct re-declares the same values so the pure function is
/// self-contained. Keep the two in sync when tuning.
public struct FastLockDecision: Equatable {

    /// Which mode the engine is operating in. The ambiguity guard
    /// applies to `sung` only.
    public enum Mode: String, Equatable {
        case sung
        case speech
    }

    /// Fast-lock partial-count gate. Fires only within the first N
    /// server-matches of DISCOVERING. Matches
    /// `StreamingRaagiModeEngine.sungFastLockMaxPartials`.
    public static let sungMaxPartials: Int = 3

    /// Fast-lock score gate. Matches
    /// `StreamingRaagiModeEngine.sungFastLockScoreThreshold`.
    public static let sungMinScore: Double = 90.0

    /// Fast-lock tier gate. Matches
    /// `StreamingRaagiModeEngine.sungFastLockMaxTier`.
    public static let sungMaxTier: Int = 1

    /// Return `true` when the fast-lock should fire immediately.
    ///
    /// Contract:
    ///   - All three gates (partialIndex, score, tier) must pass.
    ///   - In `sung` mode an additional gate applies: if the
    ///     candidate shabad is in the AmbiguousShabadSet
    ///     (`isAmbiguous == true`), fast-lock is DEFERRED so the
    ///     accumulator + candidate cloud can arbitrate.
    ///   - In `speech` mode the ambiguity flag is ignored — historical
    ///     fast-lock behavior is byte-identical for speech.
    public static func shouldFastLock(
        score: Double,
        tier: Int,
        partialIndex: Int,
        isAmbiguous: Bool,
        mode: Mode
    ) -> Bool {
        guard partialIndex <= sungMaxPartials else { return false }
        guard score >= sungMinScore else { return false }
        guard tier <= sungMaxTier else { return false }
        if mode == .sung && isAmbiguous { return false }
        return true
    }
}
