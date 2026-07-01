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

    // MARK: - State

    public private(set) var slots: [String: SungModeAccumulator]

    public init(slots: [String: SungModeAccumulator] = [:]) {
        self.slots = slots
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
    public mutating func processMatch(
        shabadId: String,
        score: Double,
        tier: Int,
        now: Date = Date()
    ) -> SungModeLockDecision {
        guard ingestMatch(shabadId: shabadId, score: score, tier: tier, now: now) else {
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
        now: Date = Date()
    ) -> SungModeLockedDecision {
        guard ingestMatch(
            shabadId: shabadId,
            score: score,
            tier: tier,
            now: now,
            protectedShabadId: currentShabadId
        ) else {
            let currentWeight = slots[currentShabadId]?.totalWeight ?? 0.001
            return .noSwap(top3Summary: topSummary(top: 3), slotCount: slots.count, currentWeight: currentWeight)
        }

        // Refresh currentWeight AFTER the ingest — if the incoming
        // match was for the current shabad, ingest just added to its
        // weight and we want the post-add value in the decision.
        let currentWeight = slots[currentShabadId]?.totalWeight ?? 0.001

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
        //   5. hasGoodTier — challenger has at least one tier-0/1
        //                    hit in its lastTiers ring, blocking
        //                    pure tier-2 accumulation
        let hasWeight = topAcc.totalWeight >= Self.lockWeightThreshold
        let hasRatio = topAcc.totalWeight >= currentWeight * Self.lockRatio
        let hasHits = topAcc.hitCount >= Self.reLockMinHits
        let isRecent = now.timeIntervalSince(topAcc.lastSeenAt) <= Self.reLockMinRecencySeconds
        let hasGoodTier = topAcc.lastTiers.contains(where: { $0 <= 1 })
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
        protectedShabadId: String? = nil
    ) -> Bool {
        // 1. Floor-check the incoming hit.
        guard score >= Self.minScore else { return false }
        let tierClamped = max(0, min(tier, Self.tierMultiplier.count - 1))
        let addedWeight = score * Self.tierMultiplier[tierClamped]

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
