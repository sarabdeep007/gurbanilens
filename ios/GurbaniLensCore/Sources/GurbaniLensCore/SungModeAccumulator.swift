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
        // 1. Floor-check the incoming hit.
        guard score >= Self.minScore else {
            let summary = topSummary(top: 3)
            return .noLock(top3Summary: summary, slotCount: slots.count)
        }
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

        // 4. Evict stale slots older than the window horizon.
        let staleCutoff = now.addingTimeInterval(-Self.windowSeconds)
        slots = slots.filter { $0.value.lastSeenAt >= staleCutoff }

        // 5. Enforce LRU cap.
        if slots.count > Self.maxSlots {
            let sortedByAge = slots.sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
            let toEvict = sortedByAge.prefix(slots.count - Self.maxSlots)
            for (id, _) in toEvict {
                slots.removeValue(forKey: id)
            }
        }

        // 6. Find leader + runner-up (by weight).
        let sorted = slots.sorted { $0.value.totalWeight > $1.value.totalWeight }
        guard let (topId, topAcc) = sorted.first else {
            return .noLock(top3Summary: "", slotCount: 0)
        }
        let runnerWeight: Double = sorted.dropFirst().first?.value.totalWeight ?? 0.001

        // 7. Lock condition.
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

        // 8. No lock yet — return top-3 summary for logging.
        let summary = topSummary(top: 3)
        return .noLock(top3Summary: summary, slotCount: slots.count)
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
