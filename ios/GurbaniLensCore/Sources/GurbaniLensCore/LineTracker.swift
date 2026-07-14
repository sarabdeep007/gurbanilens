import Foundation

/// Brief #9.29: structure-prior line tracker for the LOCKED state
/// in ``StreamingRaagiModeEngine``. Replaces the per-commit-site
/// FL decision layer that Briefs #9.19 through #9.28 accreted around
/// the first-letter fast path.
///
/// ## Root cause the tracker fixes
///
/// Every prior FL-commit site (safe-unique starter, safe-unique
/// bigram, first-two-word, longest-common-substring) treated every
/// pangti of a locked shabad as equally likely a priori. In dense
/// shabads (Anand Sahib — many pangtis sharing first letters like
/// "ਸਚਾ ਨਾਮੁ ਮੇਰਾ ਆਧਾਰੋ" vs "ਸਾਚਾ ਨਾਮੁ ਆਧਾਰੁ ਮੇਰਾ") the FL signal is
/// intrinsically ambiguous. Debounce (#9.27), safe-unique
/// (#9.19/#9.28), and ping-pong guards (#9.27) all suppress
/// SYMPTOMS but cannot manufacture the missing signal: a movement
/// prior.
///
/// ## The raagi movement model (from Deep)
///
/// Kirtan: pick a hook (any pangti), sing it 2×, jump to shabad
/// beginning, progress sequentially with periodic hook returns.
/// Paath: 95%+ strictly sequential 1→2→3→...
///
/// Encoded as multipliers on evidence strength, indexed by candidate
/// line relative to `currentLineIndex` and `hookLineIndex`:
///
/// | Transition | Kirtan | Paath |
/// |---|---|---|
/// | Stay (line == current)     | 1.0  | 1.0 |
/// | Next (line == current + 1) | 1.0  | 1.0 |
/// | Hook (line == hookLineIdx) | 1.0  | 0.3 |
/// | Prev (line == current - 1) | 0.5  | 0.5 |
/// | Any other pangti           | 0.15 | 0.1 |
///
/// When two priors apply to the same line (e.g. hook == next),
/// the MAX is used.
///
/// ## Evidence strengths
///
/// - `serverMatch`: `score / 100` (server confidence is the strongest
///   signal we have; a score of 92 contributes 0.92 raw strength).
/// - `flSafeUnique`: `0.6` fixed (safe-unique starter/bigram/
///   first-2-word — signals that carry a zero-false-positive-within-
///   shabad guarantee by construction).
/// - `flAmbiguous`: `0.25` distributed evenly across the subset of
///   candidates that are already prior-favored (stay/next/hook).
///   Zero weight ever goes to non-favored candidates — an ambiguous
///   FL signal cannot teleport the highlight to a random pangti.
///
/// ## Decision rule
///
/// The tracker maintains a per-candidate-line evidence accumulator
/// with a 4-second exponential half-life. On every ingest:
///
/// 1. Decay every accumulator to the ingest time.
/// 2. Add this evidence's strength to its target line(s).
/// 3. Compute `bestScore = max(accumulator[i] × prior(i))` across
///    all tracked lines.
/// 4. If `bestScore < changeThreshold` → stay.
/// 5. If the winning candidate == `currentLineIndex` → stay-confirmed
///    (increment confirmation for hook tracking, no display change).
/// 6. If the winning candidate is a NEW line AND `time - lastChangeAt
///    >= minChangeIntervalSeconds` → commit the change, reset the
///    winning line's accumulator (already fired), promote hook if the
///    new count exceeds hook count by ``hookPromotionMargin``.
///
/// The 800 ms `minChangeIntervalSeconds` preserves Brief #9.27's
/// output-side debounce as a final choke point inside the tracker.
///
/// ## Hook tracking
///
/// - Initialized to `initialLineIndex` at construction.
/// - Every confirmed decision (stay-confirm or commit) increments
///   `confirmationCounts[lineIndex]`.
/// - When any line's count exceeds the hook's by ``hookPromotionMargin``
///   or more, that line becomes the new hook (the raagi's true hook
///   accumulates the most returns).
///
/// ## Scope
///
/// Pure value type — no I/O, no actor, no `NSLog`. The engine
/// (`StreamingRaagiModeEngine`) owns the DIAG surface and translates
/// between the tracker's `Int` line indexes and the engine's
/// `String` line ids via a snapshot map built at lock time.
public struct LineTracker: Equatable {

    // MARK: - Public types

    /// Mode of the currently-locked material. Selects between the two
    /// prior tables. Chosen at construction and immutable for the
    /// tracker's lifetime — a mode change means the engine re-locks
    /// and constructs a fresh tracker.
    public enum Mode: String, Equatable {
        case kirtan
        case paath
    }

    /// Evidence contribution for a single ingest. See the top-of-file
    /// docblock for strength constants and how each variant is scored.
    public enum Evidence: Equatable {
        /// Server verdict for a specific line at score in [0, 100].
        case serverMatch(lineIndex: Int, score: Double)
        /// FL fast-path hit that carries the zero-false-positive-within-
        /// shabad guarantee (safe-unique starter / bigram / first-two-
        /// word).
        case flSafeUnique(lineIndex: Int)
        /// FL longest-common-substring or other non-guaranteed match.
        /// Distributed only to candidates that are prior-favored
        /// (stay/next/hook).
        case flAmbiguous(candidates: [Int])
    }

    /// The tracker's answer to a single ingest. `newLineIndex == nil`
    /// means the engine should not touch the display; `reason` is a
    /// short human-readable string suitable for DIAG logs.
    ///
    /// Brief #9.30 Fix 1: `diagnostics` carries zero or more auxiliary
    /// trace lines (e.g. departed-line suppression events) produced
    /// while processing this ingest. The tracker stays pure — the
    /// engine loops over these strings and NSLogs them prefixed with
    /// `[DIAG] LineTracker `.
    public struct Decision: Equatable {
        public let newLineIndex: Int?
        public let reason: String
        public let diagnostics: [String]
        public init(newLineIndex: Int?, reason: String, diagnostics: [String] = []) {
            self.newLineIndex = newLineIndex
            self.reason = reason
            self.diagnostics = diagnostics
        }
    }

    // MARK: - Tunables

    /// Prior multiplier when the candidate line == the current line.
    public static let priorStay: Double = 1.0
    /// Prior multiplier when the candidate line == current + 1
    /// (natural sequential progression).
    public static let priorNext: Double = 1.0
    /// Prior multiplier when the candidate line == hook (kirtan mode).
    /// Same weight as `next` — hook returns are the raagi's structural
    /// pattern in kirtan.
    public static let priorHookKirtan: Double = 1.0
    /// Prior multiplier when the candidate line == hook (paath mode).
    /// Paath has no hook concept but Brief #9.29 keeps a mild boost
    /// so a paathi who genuinely returns can still be tracked.
    public static let priorHookPaath: Double = 0.3
    /// Prior multiplier when the candidate line == current - 1
    /// (raagi went back one line — legitimate but less common).
    public static let priorPrev: Double = 0.5
    /// Prior multiplier for any other pangti in a kirtan-mode shabad.
    /// Deliberately small so a stray FL hit for a random pangti cannot
    /// teleport the highlight; only sustained server evidence for a
    /// specific line can overcome this.
    public static let priorOtherKirtan: Double = 0.15
    /// Prior multiplier for any other pangti in paath mode. Slightly
    /// tighter than kirtan since paath is 95%+ strictly sequential.
    public static let priorOtherPaath: Double = 0.1

    /// Fixed strength for a `flSafeUnique` evidence event.
    public static let flSafeUniqueStrength: Double = 0.6
    /// Total strength for a `flAmbiguous` event, distributed evenly
    /// across the subset of candidates that are prior-favored
    /// (stay/next/hook). Non-favored candidates receive zero.
    public static let flAmbiguousStrength: Double = 0.25

    /// A change fires when `max(accumulator × prior) ≥ this`.
    public static let changeThreshold: Double = 0.55

    /// Half-life for exponential decay of the per-line accumulators.
    /// 4 s covers the typical span of one hook-return or one skipped-
    /// line moment; beyond that a stray match should not linger.
    public static let evidenceHalfLifeSeconds: TimeInterval = 4.0

    /// Minimum wall-clock interval between committed line changes.
    /// Same value as Brief #9.27's debounce; retained inside the
    /// tracker as the single output-side choke point.
    public static let minChangeIntervalSeconds: TimeInterval = 0.8

    /// A pangti's `confirmationCounts` must exceed the current hook's
    /// by this many to promote it. Two is enough that a single
    /// stay-confirm on the new line doesn't upstage the initial hook.
    public static let hookPromotionMargin: Int = 2

    // MARK: - Departed-line suppression (Brief #9.30 Fix 1)

    /// Seconds of stale-audio suppression after a commit A→B: subsequent
    /// evidence for line A is discounted for this many seconds because
    /// the server's rolling audio window still contains A's audio for
    /// several seconds after the raagi has moved to B. Roughly matches
    /// the server's sung-mode window length (5.5s upper bound, 4s
    /// covers the paath case).
    public static let departedSuppressionSec: TimeInterval = 4.0
    /// Strength multiplier applied to evidence for a departed line
    /// within `departedSuppressionSec`. 0.2 keeps stale server audio
    /// from re-firing a backward commit while letting sustained real
    /// evidence eventually break through.
    public static let departedDiscount: Double = 0.2
    /// Kirtan-mode exception when the departed line IS the current
    /// hook: raagis genuinely return to the hook within seconds in
    /// fast kirtan, so a lighter discount preserves that path.
    public static let departedDiscountHookKirtan: Double = 0.6
    /// Maximum number of departed lines tracked simultaneously. Two
    /// covers the typical A→B→C cadence; older entries drop out.
    public static let departedRecentMaxEntries: Int = 2

    // MARK: - Instance state

    public let mode: Mode
    public let lineCount: Int
    public private(set) var currentLineIndex: Int
    public private(set) var hookLineIndex: Int
    public private(set) var confirmationCounts: [Int: Int]
    public private(set) var lastChangeAt: TimeInterval?

    /// Weight + last-touched time for each candidate line currently
    /// carrying evidence. Decayed to the ingest time at the top of
    /// every `ingest(_:at:)` call and dropped when weight falls below
    /// a small epsilon.
    private struct LineEvidence: Equatable {
        var weight: Double
        var updatedAt: TimeInterval
    }
    private var lineEvidence: [Int: LineEvidence] = [:]

    /// Brief #9.30 Fix 1: recently-departed lines with the wall-clock
    /// time they were left. Evidence for a line in this list within
    /// `departedSuppressionSec` is multiplied by `departedDiscount`
    /// (or `departedDiscountHookKirtan` when kirtan mode + hook line)
    /// before entering the accumulator. Capped at
    /// `departedRecentMaxEntries`; entries are effectively expired by
    /// the age check on lookup so no eager pruning is needed.
    private struct DepartedLine: Equatable {
        var lineIndex: Int
        var departedAt: TimeInterval
    }
    private var recentlyDeparted: [DepartedLine] = []

    // MARK: - Init

    public init(mode: Mode, lineCount: Int, initialLineIndex: Int, now: TimeInterval) {
        precondition(lineCount > 0, "LineTracker requires at least one line")
        precondition(
            initialLineIndex >= 0 && initialLineIndex < lineCount,
            "initialLineIndex \(initialLineIndex) out of range for lineCount \(lineCount)"
        )
        self.mode = mode
        self.lineCount = lineCount
        self.currentLineIndex = initialLineIndex
        self.hookLineIndex = initialLineIndex
        self.confirmationCounts = [initialLineIndex: 1]
        self.lastChangeAt = nil
        _ = now
    }

    // MARK: - Public entry

    /// Ingest a single evidence event and return the tracker's
    /// decision. Idempotent w.r.t. mode + tunables (a fresh tracker
    /// replaying the same event stream produces the same decisions).
    public mutating func ingest(_ evidence: Evidence, at time: TimeInterval) -> Decision {
        decayEvidence(to: time)

        var diagnostics: [String] = []

        switch evidence {
        case .serverMatch(let idx, let score):
            let clamped = max(0.0, min(100.0, score))
            addEvidence(lineIndex: idx, strength: clamped / 100.0, at: time, diagnostics: &diagnostics)

        case .flSafeUnique(let idx):
            addEvidence(lineIndex: idx, strength: Self.flSafeUniqueStrength, at: time, diagnostics: &diagnostics)

        case .flAmbiguous(let candidates):
            let favored = candidates.filter { inRange($0) && isPriorFavored(lineIndex: $0) }
            if favored.isEmpty {
                return Decision(
                    newLineIndex: nil,
                    reason: "flAmbiguous-noFavoredCandidates(candidates=\(candidates))",
                    diagnostics: diagnostics
                )
            }
            let per = Self.flAmbiguousStrength / Double(favored.count)
            for idx in favored {
                addEvidence(lineIndex: idx, strength: per, at: time, diagnostics: &diagnostics)
            }
        }

        // Find the candidate line with the highest post-prior score.
        var bestIdx: Int? = nil
        var bestScore: Double = 0
        for (idx, ev) in lineEvidence {
            let s = ev.weight * priorFor(lineIndex: idx)
            if s > bestScore {
                bestScore = s
                bestIdx = idx
            }
        }

        guard let winner = bestIdx, bestScore >= Self.changeThreshold else {
            return Decision(
                newLineIndex: nil,
                reason: "belowThreshold(bestScore=\(fmt(bestScore)))",
                diagnostics: diagnostics
            )
        }

        if winner == currentLineIndex {
            confirmationCounts[winner, default: 0] += 1
            maybePromoteHook()
            return Decision(
                newLineIndex: nil,
                reason: "stay-confirmed(line=\(winner) strength=\(fmt(bestScore)))",
                diagnostics: diagnostics
            )
        }

        if let last = lastChangeAt, time - last < Self.minChangeIntervalSeconds {
            let msSince = Int((time - last) * 1000)
            return Decision(
                newLineIndex: nil,
                reason: "debounced(msSinceLastChange=\(msSince) proposed=\(winner))",
                diagnostics: diagnostics
            )
        }

        let previous = currentLineIndex
        currentLineIndex = winner
        lastChangeAt = time
        confirmationCounts[winner, default: 0] += 1
        // The winning accumulator has fired — drop it so residual weight
        // doesn't immediately re-fire on the next ingest.
        lineEvidence[winner] = nil
        // Brief #9.30 Fix 1: mark the line we just left as recently
        // departed so any stale-audio evidence for it over the next
        // few seconds gets discounted before it can bounce us back.
        recordDeparture(previous: previous, at: time)
        maybePromoteHook()
        return Decision(
            newLineIndex: winner,
            reason: "commit(from=\(previous) to=\(winner) strength=\(fmt(bestScore)))",
            diagnostics: diagnostics
        )
    }

    // MARK: - Test-visible introspection

    /// Public read of the raw (undecayed-since-last-ingest) accumulator
    /// for a specific line. Exposed for tests that assert accumulator
    /// growth across multiple events. Callers must not mutate.
    public func evidenceWeight(forLineIndex idx: Int) -> Double {
        lineEvidence[idx]?.weight ?? 0
    }

    // MARK: - Internals

    private func inRange(_ idx: Int) -> Bool {
        idx >= 0 && idx < lineCount
    }

    private mutating func addEvidence(
        lineIndex: Int,
        strength: Double,
        at time: TimeInterval,
        diagnostics: inout [String]
    ) {
        guard inRange(lineIndex), strength > 0 else { return }
        // Brief #9.30 Fix 1: apply departed-line suppression BEFORE the
        // accumulator addition so a stream of stale server matches for
        // the just-left line can never accrete past the change threshold.
        var effectiveStrength = strength
        if let dep = recentlyDeparted.last(where: { $0.lineIndex == lineIndex }) {
            let age = time - dep.departedAt
            if age >= 0, age < Self.departedSuppressionSec {
                let discount: Double
                if mode == .kirtan && lineIndex == hookLineIndex {
                    discount = Self.departedDiscountHookKirtan
                } else {
                    discount = Self.departedDiscount
                }
                effectiveStrength *= discount
                diagnostics.append(
                    "departed-suppression line=\(lineIndex) ageSec=\(fmt(age)) discount=\(fmt(discount))"
                )
            }
        }
        if var existing = lineEvidence[lineIndex] {
            existing.weight += effectiveStrength
            existing.updatedAt = time
            lineEvidence[lineIndex] = existing
        } else {
            lineEvidence[lineIndex] = LineEvidence(weight: effectiveStrength, updatedAt: time)
        }
    }

    /// Brief #9.30 Fix 1: record the previously-current line as
    /// recently departed. If the line is already in the list its
    /// timestamp is refreshed (kirtan A→B→A→B keeps the freshest
    /// departure); otherwise it's appended, evicting the oldest entry
    /// when the list is at capacity.
    private mutating func recordDeparture(previous: Int, at time: TimeInterval) {
        if let existingIdx = recentlyDeparted.firstIndex(where: { $0.lineIndex == previous }) {
            recentlyDeparted[existingIdx].departedAt = time
            return
        }
        recentlyDeparted.append(DepartedLine(lineIndex: previous, departedAt: time))
        if recentlyDeparted.count > Self.departedRecentMaxEntries {
            recentlyDeparted.removeFirst(recentlyDeparted.count - Self.departedRecentMaxEntries)
        }
    }

    /// Exponentially decay every accumulator to `time`. Entries whose
    /// weight drops below a small epsilon are dropped so the dict
    /// doesn't grow unbounded across a long session.
    private mutating func decayEvidence(to time: TimeInterval) {
        if lineEvidence.isEmpty { return }
        let epsilon: Double = 1e-4
        var toDrop: [Int] = []
        for (idx, ev) in lineEvidence {
            let dt = time - ev.updatedAt
            if dt <= 0 { continue }
            let factor = pow(0.5, dt / Self.evidenceHalfLifeSeconds)
            let newWeight = ev.weight * factor
            if newWeight < epsilon {
                toDrop.append(idx)
            } else {
                lineEvidence[idx] = LineEvidence(weight: newWeight, updatedAt: time)
            }
        }
        for k in toDrop { lineEvidence.removeValue(forKey: k) }
    }

    /// A line is "prior-favored" if it maps to a stay/next/hook prior.
    /// Used to gate `.flAmbiguous` distribution — ambiguous FL signals
    /// never contribute evidence to non-favored candidates.
    private func isPriorFavored(lineIndex idx: Int) -> Bool {
        if idx == currentLineIndex { return true }
        if idx == currentLineIndex + 1 && idx < lineCount { return true }
        if idx == hookLineIndex { return true }
        return false
    }

    /// Return the maximum applicable prior for the candidate line.
    /// Multiple criteria may apply (e.g. hook == next); the highest
    /// wins so the tracker never under-weights a line.
    private func priorFor(lineIndex idx: Int) -> Double {
        var p = (mode == .kirtan) ? Self.priorOtherKirtan : Self.priorOtherPaath
        if idx == currentLineIndex {
            p = max(p, Self.priorStay)
        }
        if idx == currentLineIndex + 1 && idx < lineCount {
            p = max(p, Self.priorNext)
        }
        if idx == currentLineIndex - 1 && idx >= 0 {
            p = max(p, Self.priorPrev)
        }
        if idx == hookLineIndex {
            let hookP = (mode == .kirtan) ? Self.priorHookKirtan : Self.priorHookPaath
            p = max(p, hookP)
        }
        return p
    }

    private mutating func maybePromoteHook() {
        let hookCount = confirmationCounts[hookLineIndex] ?? 0
        var bestLine = hookLineIndex
        var bestCount = hookCount
        for (idx, count) in confirmationCounts {
            if idx == hookLineIndex { continue }
            if count >= hookCount + Self.hookPromotionMargin && count > bestCount {
                bestLine = idx
                bestCount = count
            }
        }
        if bestLine != hookLineIndex {
            hookLineIndex = bestLine
        }
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.3f", v)
    }
}
