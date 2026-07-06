import Foundation

/// Per-shabad decaying-evidence accumulator used by
/// `StreamingRaagiModeEngine`'s DISCOVERING state when Sung Kirtan Mode
/// (Brief #9.20-iOS) is enabled. Value type held inside a
/// `SungModeAccumulatorStore`.
public struct SungModeAccumulator: Equatable {
    /// Sum of (score × tierMultiplier) contributions, decayed by an
    /// exponential half-life at every subsequent event.
    public var totalWeight: Double
    /// Number of match events counted (post-min-score gate).
    public var hitCount: Int
    /// Lowest (best) tier ever observed for this shabad. Diagnostic
    /// only — not used by the lock condition.
    public var maxTierSeen: Int
    /// Highest single-match score ever observed. Handed to
    /// `lockTo(peakScore:)` so the LOCKED-state hysteresis primes
    /// consistently with speech mode.
    public var maxScoreSeen: Double
    /// Timestamp of the most recent match. Drives decay + eviction.
    public var lastSeenAt: Date
    /// Bounded ring of recently-observed tiers. Diagnostic only.
    public var lastTiers: [Int]

    public init(
        totalWeight: Double,
        hitCount: Int,
        maxTierSeen: Int,
        maxScoreSeen: Double,
        lastSeenAt: Date,
        lastTiers: [Int]
    ) {
        self.totalWeight = totalWeight
        self.hitCount = hitCount
        self.maxTierSeen = maxTierSeen
        self.maxScoreSeen = maxScoreSeen
        self.lastSeenAt = lastSeenAt
        self.lastTiers = lastTiers
    }
}

/// Decision returned from `SungModeAccumulatorStore.processMatch`.
/// Callers switch on the case to route the log line + optional lock
/// action.
public enum SungModeLockDecision: Equatable {
    /// Match consumed, no lock yet.
    /// - Parameters:
    ///   - top3Summary: pre-formatted `"<shabadId>:<weight>h<hitCount>"`
    ///     entries joined by spaces, up to top 3 by weight.
    ///   - slotCount: how many accumulator slots remain after this event.
    case noLock(top3Summary: String, slotCount: Int)
    /// A shabad's evidence cleared the lock threshold. Caller should
    /// route this to its `lockTo(...)` equivalent, passing
    /// `peakScore` through unchanged.
    /// - Parameters:
    ///   - shabadId: locked shabad.
    ///   - peakScore: highest single-match score ever seen for this
    ///     shabad. Semantically parallel to speech mode's
    ///     `peakOfEvidence`.
    ///   - weight: total decayed weight at lock time (diagnostic).
    ///   - hitCount: total hits counted for this shabad (diagnostic).
    ///   - runnerUpWeight: second-place weight (diagnostic).
    ///   - tiers: recent tier ring for the locked shabad (diagnostic).
    case lock(
        shabadId: String,
        peakScore: Double,
        weight: Double,
        hitCount: Int,
        runnerUpWeight: Double,
        tiers: [Int]
    )
}

/// Brief #9.21-iOS: decision returned from
/// `SungModeAccumulatorStore.processMatchInLocked`. Distinct from
/// `SungModeLockDecision` because LOCKED-state semantics differ:
/// same-shabad matches feed the accumulator to refresh the current
/// shabad's weight, but they can never *decide* to swap. Only a
/// non-current shabad emerging as the leader (and clearing the
/// threshold + ratio-vs-current + hits gates) yields `.reLock`.
public enum SungModeLockedDecision: Equatable {
    /// Either the current shabad is still the leader, or no
    /// challenger has met the re-lock thresholds. Caller emits the
    /// per-brief `sungMode locked-acc …` DIAG line and continues
    /// normal same-shabad / cross-shabad handling.
    case noSwap(top3Summary: String, slotCount: Int, currentWeight: Double)
    /// A non-current shabad's accumulator weight dominates the
    /// current shabad's decayed weight past all three thresholds.
    /// Caller should invoke its `lockTo(...)` equivalent with a
    /// via-tag of "sungReLock".
    /// - Parameters:
    ///   - currentWeight: current shabad's decayed weight at the
    ///     time of the check (diagnostic).
    case reLock(
        shabadId: String,
        peakScore: Double,
        weight: Double,
        hitCount: Int,
        currentWeight: Double,
        tiers: [Int]
    )
}

/// Pure-value store for sung-mode discovery accumulation. Owns the
/// `[shabadId: SungModeAccumulator]` dict and exposes a single
/// `processMatch(...)` API that:
///   1. Floor-checks the incoming score.
///   2. Decays every existing slot's weight to `now`.
///   3. Update-or-create the target shabad's slot.
///   4. Evicts stale slots older than `windowSeconds`.
///   5. Enforces the LRU cap `maxSlots`.
///   6. Evaluates the lock condition (weight × ratio × hits).
///   7. Returns a `SungModeLockDecision`.
///
/// Deliberately no dependencies on `StreamingRaagiModeEngine` or any
/// UIKit / SwiftUI type — extracted so the engine unit tests can
/// exercise the accumulator with synthetic dates and no @MainActor
/// state. Brief #9.20-iOS.
public struct SungModeAccumulatorStore: Equatable {

    // MARK: - Tunables (Brief #9.20)

    /// Minimum incoming score to be counted as evidence. Below this
    /// is treated as noise and does not update any slot.
    public static let minScore: Double = 40.0
    /// Stale-eviction horizon: slots whose `lastSeenAt` is older than
    /// this from the current `now` are dropped before the leader search.
    public static let windowSeconds: TimeInterval = 15.0
    /// Exponential-decay half-life for accumulated weight, in seconds.
    /// After this long since a slot's `lastSeenAt`, its weight is
    /// halved.
    public static let halfLife: Double = 6.0
    /// Leader must reach at least this much decayed weight to lock.
    public static let lockWeightThreshold: Double = 100.0
    /// Leader must exceed runner-up (or the zero-value floor) by this
    /// multiplicative ratio.
    public static let lockRatio: Double = 1.5
    /// Leader must have this many distinct match events. Prevents a
    /// single high-score outlier from locking.
    public static let minHits: Int = 3
    /// Max simultaneously-tracked shabads. Excess slots evicted LRU
    /// by `lastSeenAt`.
    public static let maxSlots: Int = 8
    /// Weight multipliers indexed by tier (0..3). Lower tiers get more
    /// weight per hit. Out-of-range tiers clamp to the last slot.
    public static let tierMultiplier: [Double] = [2.0, 1.5, 1.0, 0.5]
    /// Cap on the `lastTiers` diagnostic ring per slot.
    public static let lastTiersCap: Int = 8
    /// Brief #9.22: challenger must have this many distinct match events
    /// to trigger re-lock. Higher than `minHits` (3) — post-lock swap
    /// overrides a user-visible shabad and deserves more evidence.
    public static let reLockMinHits: Int = 4
    /// Brief #9.22: challenger's most recent match must be within this
    /// many seconds of `now`. Prevents a briefly-touched-then-abandoned
    /// shabad from later winning after decay + one coincidental hit.
    public static let reLockMinRecencySeconds: TimeInterval = 3.0
    /// Brief #9.23a Fix 1: floor applied to the currently-locked
    /// shabad's weight when it is used as the ratio denominator for
    /// re-lock evaluation. #9.22 kept the current-shabad slot alive
    /// through stale eviction, but its weight can still decay
    /// arbitrarily close to zero across a long pause — Deep's
    /// #9.22 iPhone log had `currentWeight=0.0` and
    /// `ratio=270735.62` on RE-LOCK from=HLD to=3CZ. Reading the
    /// weight with `max(stored, currentWeightFloor)` keeps ratios
    /// meaningful: a real strong challenger (weight ≥ 100) still
    /// clears 100/20 = 5.0 >> 1.5, but a weak tier-3-noise
    /// challenger (weight ~30) hits exactly the 1.5 ratio and is
    /// blocked by the other four gates. The underlying stored
    /// weight is NOT modified — the floor applies only at the read
    /// site in `processMatchInLocked`, so decay behavior for other
    /// callers is unchanged.
    public static let currentWeightFloor: Double = 20.0
    /// Brief #9.23a Fix 2: challenger's `lastTiers` ring must contain
    /// at least this many hits at tier ≤ 1 to satisfy the tier-
    /// quality gate. Raised from #9.22's "≥1 low-tier hit" because
    /// Deep's #9.22 iPhone log showed RE-LOCK from=3CZ to=TUY
    /// tiers=[3, 3, 1, 2] — one lonely tier-1 hit amid tier-3 noise
    /// is not enough evidence to swap. Requiring two low-tier hits
    /// filters that pattern out without blocking the real-world
    /// Aukhi Gharri scenario ([3,1,3,1] → 2 low-tier hits still
    /// passes).
    public static let reLockMinLowTierHits: Int = 2

    // Brief #9.23 Part 1: repeat detection for alaap handling.
    // Rationale in the brief: when the raagi holds on a tuk during a
    // sustained vowel or melisma, ASR still emits partials for the
    // vowel body but they all resolve to the same tuk. Meanwhile the
    // matcher — asked to disambiguate common phrases like
    // "gopal gobinde" — can float across many false shabads. The
    // repeat detector notices when the same shabad keeps landing and
    // reweights subsequent hits: the currently-repeated shabad gets
    // a boost, cross-shabad "coincidental common-phrase" hits get
    // downweighted. Clears when a genuinely-new shabad shows two
    // consecutive hits, or on a timeout.

    /// Post-increment count at which the repeat state activates
    /// (i.e. from this hit onwards, boost/downweight multipliers
    /// apply). Three consecutive same-shabad hits is roughly ~1.5 s
    /// of raagi holding on a tuk at the streaming server's
    /// ~500 ms partial cadence.
    public static let repeatBoostThreshold: Int = 3
    /// Multiplier applied to `addedWeight` for hits on the repeated
    /// shabad (same as `RepeatState.shabadId`) while the state is
    /// active.
    public static let repeatBoostMultiplier: Double = 1.5
    /// Multiplier applied to `addedWeight` for cross-shabad hits
    /// (shabadId ≠ `RepeatState.shabadId`) while the state is
    /// active. Suppresses the coincidental-common-phrase false
    /// matches described in the brief.
    public static let repeatDownweightMultiplier: Double = 0.5
    /// Repeat state clears if no hit for the repeated shabad
    /// arrives within this many seconds of `now`. Prevents a stale
    /// boost from persisting into a new song.
    public static let repeatTimeoutSeconds: TimeInterval = 8.0
    /// Repeat state clears when a shabad OTHER than the repeated one
    /// receives this many consecutive hits — signals the raagi has
    /// genuinely moved on. Distinguished from a single stray
    /// coincidental hit, which would trigger repeatedly and prevent
    /// the boost from ever helping.
    public static let repeatClearOtherShabadStreak: Int = 2

    /// Brief #9.23 Part 3: elevated re-lock ratio applied while the
    /// engine reports `alaapMode = true` (four consecutive empty
    /// ASR partials — the raagi is holding a vowel, and the matcher
    /// gets no phoneme progression to work with). Under alaap the
    /// re-lock gate demands 2.0× current-shabad weight instead of
    /// the usual 1.5×, so a coincidental cross-shabad hit stack has
    /// to be that much stronger before it can override a
    /// legitimately-locked shabad. Reverts to `lockRatio` the
    /// moment a non-empty partial arrives.
    public static let alaapReLockRatio: Double = 2.0

    /// Brief #9.23 Part 4: multiplier applied to `addedWeight` for a
    /// LOCKED-state cross-shabad hit whose shabad is in the
    /// `ambiguousSet`. Halves the evidence a coincidental common-
    /// phrase match contributes toward re-lock. Discovery hits and
    /// same-shabad hits are unaffected — only cross-shabad in
    /// LOCKED.
    public static let ambiguousMultiplier: Double = 0.5

    // MARK: - State

    public private(set) var slots: [String: SungModeAccumulator]

    /// Brief #9.23 Part 1: repeat-detection sidecar state. Nil when
    /// no shabad has been seen recently; populated on the first hit
    /// and updated on every subsequent ingest. See the
    /// `repeatBoost…` tunables for semantics.
    public private(set) var repeatState: RepeatState?

    /// Brief #9.23 Part 3: engine-driven alaap flag. Set true when
    /// the engine observes N consecutive empty ASR partials (raagi
    /// is on a sustained vowel / melisma); cleared on the first non-
    /// empty partial. While true, `processMatchInLocked` uses the
    /// tightened `alaapReLockRatio` (2.0) instead of `lockRatio`
    /// (1.5) as the re-lock ratio-vs-current gate. Read-write so
    /// the engine can toggle it in step with its own alaap state.
    public var alaapMode: Bool = false

    /// Brief #9.23 Part 4: optional precomputed ambiguous-shabad
    /// set. Populated at engine.init from the JSON bundled by
    /// scripts/fetch_ios_deps.sh + scripts/build_ambiguous_shabad_set.py.
    /// Nil in tests + speech mode where the ambiguity multiplier
    /// should be inert.
    public var ambiguousSet: AmbiguousShabadSet? = nil

    /// Sidecar state for the alaap repeat detector (Brief #9.23
    /// Part 1). Distinct from `SungModeAccumulator` (per-shabad
    /// evidence) — there is only one `RepeatState` at a time, and it
    /// tracks the shabad the raagi is currently dwelling on.
    public struct RepeatState: Equatable {
        /// The shabad receiving the recent streak of hits. Multiplier
        /// application compares this against the incoming `shabadId`.
        public var shabadId: String
        /// Most recent lineId for diagnostic logging; not used by
        /// the multiplier logic (raagi may hold on a Rahao and drift
        /// across sub-lines of the same tuk, all of which should
        /// count toward the same repeat).
        public var lineId: String
        /// Consecutive-same-shabad hit count. Multipliers activate at
        /// `repeatBoostThreshold`.
        public var count: Int
        /// Wall-clock timestamp of the most recent same-shabad hit;
        /// drives the `repeatTimeoutSeconds` decay.
        public var lastSeenAt: Date
        /// Shabad-in-flight that could clear the repeat state if it
        /// posts `repeatClearOtherShabadStreak` consecutive hits.
        /// Nil when the last hit matched the repeat.
        public var otherShabadStreakId: String?
        /// Consecutive-different-shabad hit count for the streak
        /// tracker above. Resets to 0 on any same-shabad hit.
        public var otherShabadStreakCount: Int

        public init(
            shabadId: String,
            lineId: String,
            count: Int,
            lastSeenAt: Date,
            otherShabadStreakId: String? = nil,
            otherShabadStreakCount: Int = 0
        ) {
            self.shabadId = shabadId
            self.lineId = lineId
            self.count = count
            self.lastSeenAt = lastSeenAt
            self.otherShabadStreakId = otherShabadStreakId
            self.otherShabadStreakCount = otherShabadStreakCount
        }
    }

    public init(slots: [String: SungModeAccumulator] = [:]) {
        self.slots = slots
        self.repeatState = nil
    }

    // MARK: - Public API

    /// Process a single match event and return a lock decision.
    /// Mutates the receiver's slots in place.
    ///
    /// - Parameters:
    ///   - shabadId: incoming match's shabad.
    ///   - score: server score (used for min-score gate + weight).
    ///   - tier: server tier (0=best..3=noisiest). Out-of-range clamps.
    ///   - now: current wall-clock time. Explicit so tests can pass
    ///          synthetic dates without touching real `Date()`.
    ///   - lineId: incoming match's lineId. Threaded through to the
    ///     Brief #9.23 Part 1 repeat detector purely for its
    ///     diagnostic `RepeatState.lineId` field. Defaults to "" so
    ///     existing tests keep compiling.
    public mutating func processMatch(
        shabadId: String,
        score: Double,
        tier: Int,
        now: Date = Date(),
        lineId: String = ""
    ) -> SungModeLockDecision {
        guard ingestMatch(shabadId: shabadId, score: score, tier: tier, now: now, lineId: lineId) else {
            return .noLock(top3Summary: topSummary(top: 3), slotCount: slots.count)
        }

        // Find leader + runner-up (by weight).
        let sorted = slots.sorted { $0.value.totalWeight > $1.value.totalWeight }
        guard let (topId, topAcc) = sorted.first else {
            return .noLock(top3Summary: "", slotCount: 0)
        }
        let runnerWeight: Double = sorted.dropFirst().first?.value.totalWeight ?? 0.001

        let hasWeight = topAcc.totalWeight >= Self.lockWeightThreshold
        let hasRatio = topAcc.totalWeight >= runnerWeight * Self.lockRatio
        let hasHits = topAcc.hitCount >= Self.minHits
        if hasWeight && hasRatio && hasHits {
            return .lock(
                shabadId: topId,
                peakScore: topAcc.maxScoreSeen,
                weight: topAcc.totalWeight,
                hitCount: topAcc.hitCount,
                runnerUpWeight: runnerWeight,
                tiers: topAcc.lastTiers
            )
        }

        return .noLock(top3Summary: topSummary(top: 3), slotCount: slots.count)
    }

    /// Brief #9.21-iOS: process a match event while the engine is
    /// already LOCKED on `currentShabadId`. Same ingest pipeline as
    /// ``processMatch`` (floor-check → decay → update-or-create →
    /// stale-evict → LRU-cap). Then routes to either:
    ///   - `.reLock(...)` when a NON-current shabad is the leader
    ///     AND clears weight + ratio-vs-current + hits thresholds
    ///   - `.noSwap(...)` otherwise (including when current is
    ///     leader, which is the common same-shabad refresh path)
    ///
    /// Callers should feed BOTH same-shabad and cross-shabad matches
    /// into this method while singingModeEnabled == true and state
    /// == .locked. Same-shabad calls refresh current's weight so it
    /// doesn't decay unfairly; cross-shabad calls build challenger
    /// weight that can eventually trigger a re-lock.
    public mutating func processMatchInLocked(
        shabadId: String,
        score: Double,
        tier: Int,
        currentShabadId: String,
        now: Date = Date(),
        lineId: String = ""
    ) -> SungModeLockedDecision {
        guard ingestMatch(
            shabadId: shabadId,
            score: score,
            tier: tier,
            now: now,
            protectedShabadId: currentShabadId,
            lineId: lineId
        ) else {
            // Brief #9.23a Fix 1: floor the read.
            let currentWeight = max(
                slots[currentShabadId]?.totalWeight ?? 0.001,
                Self.currentWeightFloor
            )
            return .noSwap(top3Summary: topSummary(top: 3), slotCount: slots.count, currentWeight: currentWeight)
        }

        // Refresh currentWeight AFTER the ingest — if the incoming
        // match was for the current shabad, ingest just added to its
        // weight and we want the post-add value in the decision.
        // Brief #9.23a Fix 1: floor at read site so the ratio
        // denominator can never collapse to near-zero and produce a
        // bogus infinite ratio. Stored weight is untouched — decay
        // continues normally for future ingests.
        let currentWeight = max(
            slots[currentShabadId]?.totalWeight ?? 0.001,
            Self.currentWeightFloor
        )

        let sorted = slots.sorted { $0.value.totalWeight > $1.value.totalWeight }
        guard let (topId, topAcc) = sorted.first else {
            return .noSwap(top3Summary: "", slotCount: 0, currentWeight: currentWeight)
        }

        // Current shabad is (still) the leader → common same-shabad
        // path. No swap; the log entry is the diagnostic value.
        if topId == currentShabadId {
            return .noSwap(top3Summary: topSummary(top: 3), slotCount: slots.count, currentWeight: currentWeight)
        }

        // Some other shabad is now the leader. Brief #9.22: re-lock
        // requires FIVE gates (up from three), because a post-lock
        // swap overrides a user-visible shabad and deserves stronger
        // evidence than initial discovery:
        //   1. hasWeight   — challenger weight ≥ 100 (unchanged)
        //   2. hasRatio    — challenger ≥ 1.5 × currentShabad weight
        //   3. hasHits     — challenger has ≥ reLockMinHits (4) hits
        //   4. isRecent    — challenger's latest match within
        //                    reLockMinRecencySeconds (3s) of now,
        //                    blocking briefly-touched-then-abandoned
        //                    shabads from later winning via decay
        //   5. hasGoodTier — Brief #9.23a raised this gate: challenger
        //                    has at least `reLockMinLowTierHits` (2,
        //                    up from #9.22's 1) tier-0/1 hits in its
        //                    lastTiers ring. Blocks a single tier-1
        //                    hit amid tier-3 noise (Deep's #9.22
        //                    tiers=[3,3,1,2] false swap).
        // Brief #9.23 Part 3: when alaapMode is set, the ratio gate
        // tightens from lockRatio (1.5) to alaapReLockRatio (2.0).
        // Other gates are unchanged.
        let effectiveRatio = alaapMode ? Self.alaapReLockRatio : Self.lockRatio
        let hasWeight = topAcc.totalWeight >= Self.lockWeightThreshold
        let hasRatio = topAcc.totalWeight >= currentWeight * effectiveRatio
        let hasHits = topAcc.hitCount >= Self.reLockMinHits
        let isRecent = now.timeIntervalSince(topAcc.lastSeenAt) <= Self.reLockMinRecencySeconds
        let hasGoodTier = topAcc.lastTiers.filter { $0 <= 1 }.count >= Self.reLockMinLowTierHits
        if hasWeight && hasRatio && hasHits && isRecent && hasGoodTier {
            return .reLock(
                shabadId: topId,
                peakScore: topAcc.maxScoreSeen,
                weight: topAcc.totalWeight,
                hitCount: topAcc.hitCount,
                currentWeight: currentWeight,
                tiers: topAcc.lastTiers
            )
        }
        return .noSwap(top3Summary: topSummary(top: 3), slotCount: slots.count, currentWeight: currentWeight)
    }

    /// Brief #9.21-iOS: cap the given shabad's weight at `cap` (default
    /// `lockWeightThreshold` = 100). Called by the engine right after
    /// a fresh LOCK or RE-LOCK so pre-lock overkill weight (e.g. BSJ
    /// hitting 146) doesn't make subsequent re-locks require an
    /// impossibly large challenger (146 * 1.5 = 219 vs the natural
    /// 100 * 1.5 = 150). No-op if the shabad has no slot or its
    /// current weight is already ≤ cap.
    public mutating func capWeight(
        shabadId: String,
        cap: Double = SungModeAccumulatorStore.lockWeightThreshold
    ) {
        guard var acc = slots[shabadId] else { return }
        if acc.totalWeight > cap {
            acc.totalWeight = cap
            slots[shabadId] = acc
        }
    }

    // MARK: - Internal ingest pipeline

    /// Common ingest pipeline shared by ``processMatch`` and
    /// ``processMatchInLocked``: floor-check the incoming score,
    /// decay every existing slot to `now`, update-or-create the
    /// target slot, evict stale slots, enforce the LRU cap. Returns
    /// `true` when the hit was counted (score ≥ minScore), `false`
    /// when it was rejected as noise — callers use this to short-
    /// circuit their decision logic.
    ///
    /// - Parameter protectedShabadId: Brief #9.22 — when non-nil,
    ///   this shabad's slot is exempt from stale-window eviction.
    ///   Its weight still decays through step 2 (so it can still
    ///   lose weight-comparisons), but the slot itself stays in
    ///   `slots` so `currentWeight` lookups in the LOCKED path
    ///   never fall through to the 0.001 floor and give a bogus
    ///   infinite ratio. Discovery path passes nil → speech-mode-
    ///   compatible byte-for-byte behavior.
    private mutating func ingestMatch(
        shabadId: String,
        score: Double,
        tier: Int,
        now: Date,
        protectedShabadId: String? = nil,
        lineId: String = ""
    ) -> Bool {
        // 1. Floor-check the incoming hit.
        guard score >= Self.minScore else { return false }
        let tierClamped = max(0, min(tier, Self.tierMultiplier.count - 1))

        // Brief #9.23 Part 1: repeat-detector state update happens
        // BEFORE weight computation so the multiplier below reflects
        // the post-update state (i.e. the 3rd consecutive same-shabad
        // hit sees `count == 3` and is itself boosted). Below-floor
        // hits are skipped by the `guard` above — noise doesn't
        // churn the repeat state.
        updateRepeatState(shabadId: shabadId, lineId: lineId, now: now)
        let repeatMult = repeatMultiplierFor(shabadId: shabadId)
        // Brief #9.23 Part 4: ambiguous-shabad downweight. Applies
        // ONLY to LOCKED-state cross-shabad hits (protectedShabadId
        // is set + differs from incoming) whose shabadId is in the
        // ambiguousSet. Discovery hits are untouched so a real lock
        // can still form on an ambiguous shabad; same-shabad hits
        // are untouched so the current shabad refreshes at full
        // weight.
        let ambigMult = ambiguousMultiplierFor(shabadId: shabadId, protectedShabadId: protectedShabadId)
        let addedWeight = score * Self.tierMultiplier[tierClamped] * repeatMult * ambigMult

        // 2. Decay all existing slots to `now`.
        for (id, var acc) in slots {
            let elapsed = now.timeIntervalSince(acc.lastSeenAt)
            if elapsed > 0 {
                let decayFactor = pow(0.5, elapsed / Self.halfLife)
                acc.totalWeight *= decayFactor
                slots[id] = acc
            }
        }

        // 3. Update-or-create the target shabad's slot.
        if var existing = slots[shabadId] {
            existing.totalWeight += addedWeight
            existing.hitCount += 1
            existing.maxTierSeen = min(existing.maxTierSeen, tierClamped)
            existing.maxScoreSeen = max(existing.maxScoreSeen, score)
            existing.lastSeenAt = now
            existing.lastTiers.append(tierClamped)
            if existing.lastTiers.count > Self.lastTiersCap {
                existing.lastTiers.removeFirst(existing.lastTiers.count - Self.lastTiersCap)
            }
            slots[shabadId] = existing
        } else {
            slots[shabadId] = SungModeAccumulator(
                totalWeight: addedWeight,
                hitCount: 1,
                maxTierSeen: tierClamped,
                maxScoreSeen: score,
                lastSeenAt: now,
                lastTiers: [tierClamped]
            )
        }

        // 4. Evict stale slots older than the window horizon. Brief
        // #9.22: exempt the protected shabad (currentShabadId when
        // called from LOCKED). Its weight still decayed in step 2 —
        // we just don't let its slot disappear, so `currentWeight`
        // stays a meaningful (small but nonzero) ratio denominator.
        let staleCutoff = now.addingTimeInterval(-Self.windowSeconds)
        slots = slots.filter { key, value in
            if key == protectedShabadId { return true }
            return value.lastSeenAt >= staleCutoff
        }

        // 5. Enforce LRU cap.
        if slots.count > Self.maxSlots {
            let sortedByAge = slots.sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
            let toEvict = sortedByAge.prefix(slots.count - Self.maxSlots)
            for (id, _) in toEvict {
                slots.removeValue(forKey: id)
            }
        }
        return true
    }

    /// Drop all slots.
    public mutating func reset() {
        slots.removeAll()
        repeatState = nil
        alaapMode = false
    }

    // MARK: - Repeat detection (Brief #9.23 Part 1)

    /// Update the sidecar `repeatState` for the current ingest.
    /// Called from `ingestMatch` after the score-floor gate. Handles
    /// timeout expiry, same-shabad increment, and different-shabad
    /// streak tracking.
    private mutating func updateRepeatState(
        shabadId: String,
        lineId: String,
        now: Date
    ) {
        // Timeout: if the tracked shabad has gone quiet longer than
        // `repeatTimeoutSeconds`, discard the state before deciding
        // what this hit does. Prevents a stale boost from carrying
        // into a new song.
        if let state = repeatState,
           now.timeIntervalSince(state.lastSeenAt) > Self.repeatTimeoutSeconds {
            repeatState = nil
        }

        guard var state = repeatState else {
            // Nothing tracked yet — this hit seeds a fresh state at
            // count=1 (below the boost threshold, so no multiplier
            // will apply yet).
            repeatState = RepeatState(
                shabadId: shabadId, lineId: lineId, count: 1, lastSeenAt: now
            )
            return
        }

        if state.shabadId == shabadId {
            // Same shabad — extend the streak. Different lineId is
            // fine; raagi holding a rahao may drift across sub-lines
            // of the same tuk and it all counts as "dwelling here".
            state.count += 1
            state.lineId = lineId
            state.lastSeenAt = now
            state.otherShabadStreakId = nil
            state.otherShabadStreakCount = 0
            repeatState = state
            return
        }

        // Different shabad — grow the other-shabad streak.
        if state.otherShabadStreakId == shabadId {
            state.otherShabadStreakCount += 1
        } else {
            state.otherShabadStreakId = shabadId
            state.otherShabadStreakCount = 1
        }
        if state.otherShabadStreakCount >= Self.repeatClearOtherShabadStreak {
            // Raagi has genuinely moved on — burn the state so the
            // next hit seeds a fresh repeat.
            repeatState = nil
        } else {
            repeatState = state
        }
    }

    /// Repeat-detector multiplier for the current ingest. Reads the
    /// state left by ``updateRepeatState`` on THIS same call. Returns
    /// 1.0 when no active repeat, `repeatBoostMultiplier` for the
    /// repeated shabad, `repeatDownweightMultiplier` for cross-shabad
    /// hits during an active repeat.
    private func repeatMultiplierFor(shabadId: String) -> Double {
        guard let state = repeatState,
              state.count >= Self.repeatBoostThreshold else {
            return 1.0
        }
        return state.shabadId == shabadId
            ? Self.repeatBoostMultiplier
            : Self.repeatDownweightMultiplier
    }

    /// Brief #9.23 Part 4: return the ambiguous-shabad multiplier.
    /// Applies only when we are ingesting a LOCKED-state cross-
    /// shabad hit (i.e. `protectedShabadId` is non-nil and differs
    /// from the incoming shabad) whose shabadId is in the
    /// `ambiguousSet`. Otherwise returns 1.0.
    ///
    /// Brief #9.25 Part 4: the pre-#9.25 implementation returned
    /// silently, which meant the entire ambiguous-set feature was
    /// invisible in Deep's iPhone logs — no way to tell whether the
    /// multiplier was firing or whether Deep's observed wrong-shabad
    /// cascade was even eligible for downweight. The two DIAG lines
    /// added below fire ONLY on the LOCKED cross-shabad path (the
    /// only path where the multiplier has semantic effect) so
    /// discovery + same-shabad ingests stay quiet. `applied` = we
    /// halved the hit's weight; `no-apply` = the shabad wasn't in
    /// the ambiguous set so it went through at full weight.
    private func ambiguousMultiplierFor(shabadId: String, protectedShabadId: String?) -> Double {
        guard let amb = ambiguousSet else { return 1.0 }
        guard let current = protectedShabadId, current != shabadId else { return 1.0 }
        if amb.contains(shabadId) {
            NSLog("[DIAG] SungModeAccumulator ambiguousSet applied shabadId=\(shabadId) currentShabad=\(current) multiplier=\(Self.ambiguousMultiplier) setCount=\(amb.count)")
            return Self.ambiguousMultiplier
        } else {
            NSLog("[DIAG] SungModeAccumulator ambiguousSet no-apply shabadId=\(shabadId) currentShabad=\(current) multiplier=1.0 (not in set, setCount=\(amb.count))")
            return 1.0
        }
    }

    /// Format the top-N slots by weight as
    /// `"<shabadId>:<weight>h<hitCount>"` entries, space-joined.
    /// Weight is formatted with one decimal place.
    public func topSummary(top n: Int) -> String {
        let sorted = slots.sorted { $0.value.totalWeight > $1.value.totalWeight }
        return sorted.prefix(n).map { id, acc in
            "\(id):\(String(format: "%.1f", acc.totalWeight))h\(acc.hitCount)"
        }.joined(separator: " ")
    }
}
