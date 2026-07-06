import XCTest
@testable import GurbaniLensCore

/// Unit tests for the Brief #9.20-iOS sung-mode decaying accumulator.
/// Verifies the pure-value `SungModeAccumulatorStore` in isolation
/// from the engine.
final class SungModeAccumulatorTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed epoch to anchor all synthetic dates on. Using a specific
    /// past date so `Date().timeIntervalSince(...)` differences are
    /// exactly what the test intends (no drift from real time).
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    /// Offset from t0 by `seconds`.
    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - Basic single-hit paths

    func testAccumulator_singleHitBelowFloor_noLock() {
        // score 39 < minScore (40) → no slot created, no lock.
        var store = SungModeAccumulatorStore()
        let decision = store.processMatch(shabadId: "BSJ", score: 39, tier: 1, now: at(0))
        guard case .noLock(_, let slotCount) = decision else {
            XCTFail("Expected .noLock for below-floor score"); return
        }
        XCTAssertEqual(slotCount, 0)
        XCTAssertTrue(store.slots.isEmpty)
    }

    func testAccumulator_singleHitAtThreshold_noLockYet() {
        // score 40 tier 0 → weight = 40 * 2.0 = 80. Below lockWeight (100).
        var store = SungModeAccumulatorStore()
        let decision = store.processMatch(shabadId: "BSJ", score: 40, tier: 0, now: at(0))
        guard case .noLock(_, let slotCount) = decision else {
            XCTFail("Expected .noLock at 80 weight"); return
        }
        XCTAssertEqual(slotCount, 1)
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight, 80.0, accuracy: 0.001)
        XCTAssertEqual(store.slots["BSJ"]?.hitCount, 1)
        XCTAssertEqual(store.slots["BSJ"]?.maxScoreSeen, 40.0)
    }

    // MARK: - Lock condition

    func testAccumulator_multipleHitsBuildToLock_bsj() {
        // Five hits at score 50 tier 1 (multiplier 1.5), tightly spaced
        // so decay barely bites. Each hit adds 50*1.5 = 75 weight.
        // hitCount reaches 5 (≥ minHits 3); no runner-up so ratio is
        // ∞ vs the 0.001 floor → passes. Weight after ~5 hits: even
        // with modest decay this comfortably crosses 100.
        var store = SungModeAccumulatorStore()
        var lastDecision: SungModeLockDecision = .noLock(top3Summary: "", slotCount: 0)
        for i in 0..<5 {
            lastDecision = store.processMatch(
                shabadId: "BSJ", score: 50, tier: 1, now: at(Double(i) * 0.5)
            )
            if case .lock = lastDecision { break }
        }
        guard case .lock(let shabadId, let peakScore, let weight, let hits, _, _) = lastDecision else {
            XCTFail("Expected .lock after 5 hits, got \(lastDecision)"); return
        }
        XCTAssertEqual(shabadId, "BSJ")
        XCTAssertGreaterThanOrEqual(weight, SungModeAccumulatorStore.lockWeightThreshold)
        XCTAssertGreaterThanOrEqual(hits, SungModeAccumulatorStore.minHits)
        XCTAssertEqual(peakScore, 50.0, accuracy: 0.001)
    }

    func testAccumulator_evenSplitTwoShabads_noLock() {
        // Alternating hits between BSJ and DGF at 0.2s intervals. With
        // an EVEN number of iterations (2 each), the two weights stay
        // tightly balanced; ratio ~1.02 < 1.5 → no lock. Odd counts
        // would eventually give BSJ 3 hits vs DGF 2 and the ratio
        // could drift above 1.5, so we keep the loop at 4 iterations.
        var store = SungModeAccumulatorStore()
        var lastDecision: SungModeLockDecision = .noLock(top3Summary: "", slotCount: 0)
        for i in 0..<4 {
            let id = (i % 2 == 0) ? "BSJ" : "DGF"
            lastDecision = store.processMatch(
                shabadId: id, score: 50, tier: 0, now: at(Double(i) * 0.2)
            )
            if case .lock = lastDecision { break }
        }
        if case .lock = lastDecision {
            XCTFail("Should NOT lock on even split — ratio < 1.5")
        }
        XCTAssertEqual(store.slots.count, 2)
        let bsjW = store.slots["BSJ"]?.totalWeight ?? 0
        let dgfW = store.slots["DGF"]?.totalWeight ?? 0
        XCTAssertLessThan(
            max(bsjW, dgfW) / max(min(bsjW, dgfW), 0.001),
            SungModeAccumulatorStore.lockRatio
        )
    }

    // MARK: - Stale eviction

    func testAccumulator_staleEviction() {
        // DGF gets one hit at t=0, then a BSJ hit at t=17 (past
        // windowSeconds=15). At t=17: DGF's lastSeenAt (t=0) is below
        // the stale cutoff (t=17 - 15 = t=2) → DGF evicted. BSJ is
        // fresh (just updated), stays. slotCount ends at 1.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "DGF", score: 50, tier: 0, now: at(0))
        XCTAssertEqual(store.slots.count, 1)
        let elapsedPastWindow = SungModeAccumulatorStore.windowSeconds + 2.0
        let decision = store.processMatch(
            shabadId: "BSJ", score: 50, tier: 0, now: at(elapsedPastWindow)
        )
        guard case .noLock(_, let slotCount) = decision else {
            XCTFail("Expected .noLock after stale eviction"); return
        }
        XCTAssertEqual(slotCount, 1)
        XCTAssertNil(store.slots["DGF"], "DGF should have been stale-evicted")
        XCTAssertNotNil(store.slots["BSJ"])
        XCTAssertEqual(store.slots["BSJ"]?.hitCount, 1)
    }

    // MARK: - LRU eviction

    func testAccumulator_lruEviction() {
        // 9 distinct shabads at 1s intervals: after the 9th, LRU cap
        // (maxSlots=8) evicts the OLDEST. Verify exactly 8 slots
        // remain and the oldest shabad ("S0") is gone.
        var store = SungModeAccumulatorStore()
        for i in 0..<9 {
            _ = store.processMatch(
                shabadId: "S\(i)", score: 50, tier: 0, now: at(Double(i))
            )
        }
        XCTAssertEqual(store.slots.count, SungModeAccumulatorStore.maxSlots)  // 8
        XCTAssertNil(store.slots["S0"], "Oldest slot S0 should have been LRU-evicted")
        XCTAssertNotNil(store.slots["S8"])
    }

    // MARK: - Decay

    func testAccumulator_decayOverTime() {
        // Hit at t=0 (weight 100 from score 50 tier 1 → 50*1.5=75...
        // let's use tier 0 for weight=100 exactly: score 50 tier 0
        // → 50*2.0=100). Second hit at t=halfLife=6s should first
        // halve the existing weight (100 → 50), then add another 100
        // → total ~150.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        // First hit sets weight = 100.
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.01)
        // Second hit at exactly one half-life later.
        _ = store.processMatch(
            shabadId: "BSJ", score: 50, tier: 0, now: at(SungModeAccumulatorStore.halfLife)
        )
        // Before-add weight was 100 * 0.5 = 50. After-add: 50 + 100 = 150.
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 150.0, accuracy: 0.01)
        XCTAssertEqual(store.slots["BSJ"]?.hitCount, 2)
    }

    // MARK: - Reset

    func testAccumulator_reset() {
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        _ = store.processMatch(shabadId: "DGF", score: 50, tier: 0, now: at(0.5))
        XCTAssertEqual(store.slots.count, 2)
        store.reset()
        XCTAssertTrue(store.slots.isEmpty)
    }

    // MARK: - Tier clamp

    func testAccumulator_tierClampsOutOfRange() {
        // tier 99 clamps to last tierMultiplier slot (tier 3, multiplier 0.5).
        // score 50 * 0.5 = 25 weight.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 99, now: at(0))
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 25.0, accuracy: 0.001)
        // tier -5 clamps to 0 (multiplier 2.0). 50 * 2.0 = 100.
        _ = store.processMatch(shabadId: "DGF", score: 50, tier: -5, now: at(0.1))
        XCTAssertEqual(store.slots["DGF"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)
    }

    // MARK: - processMatchInLocked (Brief #9.21)

    func test_processMatchInLocked_currentShabadDominant_returnsNoSwap() {
        // Same-shabad match (BSJ) while currentShabadId=BSJ. Leader
        // IS current → .noSwap regardless of weight.
        var store = SungModeAccumulatorStore()
        // Seed BSJ with a high weight (pre-existing lock context).
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))  // +100
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0.1)) // +100 (decayed)
        let decision = store.processMatchInLocked(
            shabadId: "BSJ", score: 50, tier: 0, currentShabadId: "BSJ", now: at(0.2)
        )
        guard case .noSwap(_, _, let currentWeight) = decision else {
            XCTFail("Expected .noSwap when current is leader, got \(decision)"); return
        }
        XCTAssertGreaterThan(currentWeight, 100.0, "BSJ weight should reflect the fresh add")
    }

    func test_processMatchInLocked_challengerAboveThresholdAndRatio_returnsReLock() {
        // BSJ was locked, capped at 100. Challenger 1HU accumulates
        // enough weight + hits + ratio to swap. Brief #9.22 raised
        // reLockMinHits to 4 (from 3), so feed 4 hits.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))  // 100
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)

        // Feed 4 fresh 1HU hits at tier 0 (mult 2.0). 50*2.0=100 per
        // hit, spaced 0.5s apart (small decay).
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 50, tier: 0, currentShabadId: "BSJ",
                now: at(1.0 + Double(i) * 0.5)
            )
            if case .reLock = lastDecision { break }
        }
        guard case .reLock(let toId, _, let weight, let hits, let currentWeight, _) = lastDecision else {
            XCTFail("Expected .reLock after 4 challenger hits, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(weight, SungModeAccumulatorStore.lockWeightThreshold)
        XCTAssertGreaterThanOrEqual(hits, SungModeAccumulatorStore.reLockMinHits)
        XCTAssertGreaterThanOrEqual(weight, currentWeight * SungModeAccumulatorStore.lockRatio)
    }

    func test_processMatchInLocked_challengerAboveThresholdButBelowRatio_returnsNoSwap() {
        // Both BSJ (current) and 1HU accumulate high weight, but 1HU
        // stays below 1.5x BSJ → no swap even though 1HU weight ≥ 100.
        var store = SungModeAccumulatorStore()
        // BSJ: 3 hits tier 0 rapid → ~280 weight, hits=3
        for i in 0..<3 {
            _ = store.processMatchInLocked(
                shabadId: "BSJ", score: 50, tier: 0, currentShabadId: "BSJ",
                now: at(Double(i) * 0.1)
            )
        }
        // 1HU: 3 hits tier 0 rapid → ~280 weight, hits=3
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<3 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 50, tier: 0, currentShabadId: "BSJ",
                now: at(1.0 + Double(i) * 0.1)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock — 1HU weight ~= BSJ weight, ratio well below 1.5")
        }
    }

    func test_processMatchInLocked_challengerAboveRatioButBelowMinHits_returnsNoSwap() {
        // BSJ has been capped LOW (10) so a single high-score 1HU
        // hit clears both weight (needs ≥ 100 — arrange via tier 0
        // + score 60 = 120 weight) and ratio (120/10 = 12 >> 1.5)
        // yet hitCount stays at 1 < minHits (3) → no swap.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ", cap: 10)
        let decision = store.processMatchInLocked(
            shabadId: "1HU", score: 60, tier: 0, currentShabadId: "BSJ", now: at(1.0)
        )
        if case .reLock = decision {
            XCTFail("Should NOT reLock — 1HU has only 1 hit")
        }
        XCTAssertEqual(store.slots["1HU"]?.hitCount, 1)
    }

    func test_processMatchInLocked_challengerAboveMinHitsButBelowWeightThreshold_returnsNoSwap() {
        // 4 hits at low score/tier so per-hit weight is small
        // (score 40 * tier 3 mult 0.5 = 20). 4 hits = 80 raw, minus
        // decay = ~60. hitCount ≥ 3 ✓ but weight < 100 → no swap.
        var store = SungModeAccumulatorStore()
        // Ensure BSJ has some weight so it's the "current".
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 40, tier: 3, currentShabadId: "BSJ",
                now: at(1.0 + Double(i) * 0.5)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock — 1HU weight below threshold 100")
        }
        XCTAssertGreaterThanOrEqual(store.slots["1HU"]?.hitCount ?? 0, 3)
        XCTAssertLessThan(
            store.slots["1HU"]?.totalWeight ?? 0,
            SungModeAccumulatorStore.lockWeightThreshold
        )
    }

    // MARK: - capWeight (Brief #9.21)

    func test_capWeight_reducesOverkillWeightToCap() {
        // 5 rapid hits build BSJ weight far above cap; capWeight
        // clamps to 100 without touching other fields.
        var store = SungModeAccumulatorStore()
        for i in 0..<5 {
            _ = store.processMatch(shabadId: "BSJ", score: 60, tier: 0, now: at(Double(i) * 0.1))
        }
        XCTAssertGreaterThan(store.slots["BSJ"]?.totalWeight ?? 0, SungModeAccumulatorStore.lockWeightThreshold)
        let hitCountBefore = store.slots["BSJ"]?.hitCount
        let maxScoreBefore = store.slots["BSJ"]?.maxScoreSeen
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, SungModeAccumulatorStore.lockWeightThreshold, accuracy: 0.001)
        XCTAssertEqual(store.slots["BSJ"]?.hitCount, hitCountBefore)
        XCTAssertEqual(store.slots["BSJ"]?.maxScoreSeen, maxScoreBefore)
    }

    func test_capWeight_leavesUnderCap_untouched() {
        // BSJ has a modest single hit (60 weight); cap is a no-op.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 40, tier: 1, now: at(0))  // 40 * 1.5 = 60
        let weightBefore = store.slots["BSJ"]?.totalWeight ?? 0
        XCTAssertLessThan(weightBefore, SungModeAccumulatorStore.lockWeightThreshold)
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, weightBefore, accuracy: 0.001)
    }

    func test_capWeight_missingShabad_noOp() {
        // Defensive: cap on a shabad that isn't in slots should do
        // nothing (no crash, no phantom slot).
        var store = SungModeAccumulatorStore()
        store.capWeight(shabadId: "NOPE")
        XCTAssertTrue(store.slots.isEmpty)
    }

    // MARK: - Real-world Deep-log replay

    func test_realWorldAukhiGharriScenario() {
        // Replay Deep's #9.20 iPhone log around Aukhi Gharri swap:
        //   - BSJ locked earlier (weight capped at 100 by engine)
        //   - Deep switches to Aukhi Gharri (1HU on ang 682)
        //   - Server emits four 1HU matches at scores/tiers:
        //       seq=112 tier=3 score=63.6
        //       seq=113 tier=1 score=62.2
        //       seq=114 tier=3 score=46.9
        //       seq=115 tier=1 score=47.4
        //   - 500ms spacing
        //   - Expect .reLock returned within these four hits
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)

        let events: [(score: Double, tier: Int)] = [
            (63.6, 3),
            (62.2, 1),
            (46.9, 3),
            (47.4, 1),
        ]
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for (i, ev) in events.enumerated() {
            let t = 1.0 + Double(i) * 0.5
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU",
                score: ev.score,
                tier: ev.tier,
                currentShabadId: "BSJ",
                now: at(t)
            )
            if case .reLock = lastDecision { break }
        }
        guard case .reLock(let toId, _, _, let hits, _, _) = lastDecision else {
            XCTFail("Expected .reLock to 1HU within the 4-event window; got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(hits, 3)
    }

    // MARK: - Brief #9.22 stability fixes

    func test_processMatchInLocked_currentShabadSlot_survivesStaleWindow() {
        // Brief #9.22 Fix 1: currentShabadId slot must NOT be evicted
        // by stale-window filter even after > windowSeconds elapsed.
        // Its weight decays normally; only the slot's existence is
        // protected so currentWeight lookups don't collapse to 0.001
        // and give bogus infinite ratios.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)

        // Advance well past stale window. Different-shabad hit
        // triggers ingest + stale eviction pass.
        let farFuture = SungModeAccumulatorStore.windowSeconds + 5.0
        _ = store.processMatchInLocked(
            shabadId: "OTHER", score: 50, tier: 0,
            currentShabadId: "BSJ", now: at(farFuture)
        )

        // BSJ still in slots, weight decayed but non-zero.
        XCTAssertNotNil(store.slots["BSJ"], "BSJ slot must survive stale eviction as protected currentShabadId")
        let bsjWeight = store.slots["BSJ"]?.totalWeight ?? 0
        XCTAssertGreaterThan(bsjWeight, 0.0)
        XCTAssertLessThan(bsjWeight, 100.0, "BSJ weight should be decayed from its seeded value")
    }

    func test_processMatchInLocked_reLock_requiresMinFourHits() {
        // Brief #9.22 Fix 2 gate 1 (hits): challenger must have
        // reLockMinHits=4 hits. 3 tier-1 hits at score=80 build
        // weight fast but stay 1 hit short → noSwap. 4th hit fires
        // reLock (all other gates already met at that point).
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        // 3 challenger hits at tier=1 score=80 (weight=120 per hit,
        // spaced 0.3s apart).
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<3 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 80, tier: 1,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock after only 3 challenger hits; got \(lastDecision)")
        }

        // 4th hit lands right on the threshold.
        lastDecision = store.processMatchInLocked(
            shabadId: "1HU", score: 80, tier: 1,
            currentShabadId: "BSJ", now: at(1.9)
        )
        guard case .reLock(let toId, _, _, let hits, _, _) = lastDecision else {
            XCTFail("Expected .reLock on 4th hit, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertEqual(hits, 4)
    }

    func test_processMatchInLocked_reLock_requiresRecentHit() {
        // Brief #9.22 Fix 2 gate 2 (recency): challenger's lastSeenAt
        // must be within reLockMinRecencySeconds (3s) of `now`.
        //
        // Setup: 4 challenger hits packed between t=0.5 and t=1.4
        // (the last one triggers .reLock mid-loop as all gates are
        // met right then; we discard that intermediate decision —
        // the engine's real caller would act on it, but this test
        // isolates the STORE's state and recomputes later). Then
        // fast-forward past the recency window and issue a BSJ
        // (current) hit — at that point 1HU is still the top slot
        // by weight, but its recency gate fails and .reLock is
        // suppressed.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        for i in 0..<4 {
            _ = store.processMatchInLocked(
                shabadId: "1HU", score: 80, tier: 1,
                currentShabadId: "BSJ", now: at(0.5 + Double(i) * 0.3)
            )
        }
        // Fast-forward past the recency window. BSJ same-shabad
        // refresh — this is what "user pauses 1HU and stays on BSJ"
        // looks like from the store's perspective.
        let lateT = 1.4 + SungModeAccumulatorStore.reLockMinRecencySeconds + 0.5
        let decision = store.processMatchInLocked(
            shabadId: "BSJ", score: 50, tier: 0,
            currentShabadId: "BSJ", now: at(lateT)
        )
        if case .reLock = decision {
            XCTFail("Should NOT reLock — challenger's lastSeenAt is stale; got \(decision)")
        }
    }

    func test_processMatchInLocked_reLock_requiresGoodTier() {
        // Brief #9.22 Fix 2 gate 3 (tier quality), tightened by
        // #9.23a Fix 2: challenger's lastTiers ring must contain at
        // least `reLockMinLowTierHits` (2) hits at tier ≤ 1. Pure
        // tier-2 accumulation still doesn't swap; a SINGLE tier-1 hit
        // amid noise is also insufficient (this is the Deep #9.22
        // false-swap pattern). Only a SECOND tier-1 hit unlocks the
        // swap.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        // 4 tier-2 hits at score=80 (weight=80 per hit) — no low-tier.
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 80, tier: 2,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock on pure tier-2 evidence, got \(lastDecision)")
        }

        // First tier-1 hit: 1 low-tier < reLockMinLowTierHits (2) →
        // still noSwap under #9.23a.
        lastDecision = store.processMatchInLocked(
            shabadId: "1HU", score: 80, tier: 1,
            currentShabadId: "BSJ", now: at(2.5)
        )
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock on a single tier-1 hit amid tier-2 noise, got \(lastDecision)")
        }

        // Second tier-1 hit: 2 low-tier ≥ 2 → tier gate passes; all
        // other gates already met (weight/ratio/hits/recent) → reLock.
        lastDecision = store.processMatchInLocked(
            shabadId: "1HU", score: 80, tier: 1,
            currentShabadId: "BSJ", now: at(2.8)
        )
        guard case .reLock(let toId, _, _, _, _, let tiers) = lastDecision else {
            XCTFail("Expected .reLock after 2nd tier-1 hit lands, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(tiers.filter { $0 <= 1 }.count, 2)
    }

    func test_processMatchInLocked_reLock_allGatesMet_swaps() {
        // Happy path — all 5 re-lock gates cleared. BSJ capped, then
        // 4 recent tier-0 challenger hits with weight far exceeding
        // BSJ's decayed weight.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 60, tier: 0,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        guard case .reLock(let toId, _, let weight, let hits, let currentWeight, let tiers) = lastDecision else {
            XCTFail("Expected .reLock happy path, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(hits, SungModeAccumulatorStore.reLockMinHits)
        XCTAssertGreaterThanOrEqual(weight, SungModeAccumulatorStore.lockWeightThreshold)
        XCTAssertGreaterThanOrEqual(weight, currentWeight * SungModeAccumulatorStore.lockRatio)
        XCTAssertTrue(tiers.contains(where: { $0 <= 1 }))
    }

    func test_realWorld921Scenario_pauseThenNewShabad_noFalseSwap() {
        // Replay the #9.21 iPhone bug directly: BSJ locked, capped
        // at 100. Deep pauses ~30s (heavy decay, BSJ ~3). Then he
        // starts a new shabad (3 tier-1 hits at score=60). Because
        // the currentShabad slot is protected (Fix 1), BSJ still
        // shows a decayed-but-nonzero weight — ratio comparisons
        // remain meaningful, and the hits=4 gate (Fix 2) still
        // blocks the premature swap. Adding a 4th hit puts all
        // gates over the line.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)

        // 30s pause.
        let pauseEnd = 30.0
        // 3 challenger hits after the pause (tier=1 score=60 →
        // 90 weight/hit). Spaced 0.4s.
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<3 {
            lastDecision = store.processMatchInLocked(
                shabadId: "NEW", score: 60, tier: 1,
                currentShabadId: "BSJ", now: at(pauseEnd + Double(i) * 0.4)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock on 3 hits after pause — Fix 2 hits gate should block")
        }
        // BSJ slot still present with decayed weight (Fix 1).
        XCTAssertNotNil(store.slots["BSJ"], "BSJ slot must survive stale eviction")
        XCTAssertGreaterThan(store.slots["BSJ"]?.totalWeight ?? 0, 0.0)

        // 4th hit puts hits gate over, all others (weight/ratio/
        // recency/tier) already satisfied.
        lastDecision = store.processMatchInLocked(
            shabadId: "NEW", score: 60, tier: 1,
            currentShabadId: "BSJ", now: at(pauseEnd + 1.2)
        )
        guard case .reLock(let toId, _, _, let hits, _, _) = lastDecision else {
            XCTFail("Expected .reLock on 4th hit, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "NEW")
        XCTAssertEqual(hits, 4)
    }

    // MARK: - Brief #9.23a stability fixes

    func test_currentWeightFloor_preventsInfiniteRatio_afterDecayToZero() {
        // Brief #9.23a Fix 1: after the current shabad's stored
        // weight decays to near-zero (Deep's #9.22 iPhone log:
        // currentWeight=0.0 → ratio=270735.62 on RE-LOCK from=HLD
        // to=3CZ), the ratio-denominator read at
        // processMatchInLocked must apply the currentWeightFloor
        // (20) so ratios stay meaningful and no bogus infinity is
        // produced. The underlying stored slot weight is NOT
        // modified — the floor applies at the read site only.
        //
        // Assertions:
        //   1. Decision returns .noSwap on a single-hit challenger
        //      (reLockMinHits=4 gate blocks it).
        //   2. The `currentWeight` field in the .noSwap decision
        //      equals currentWeightFloor.
        //   3. The stored BSJ weight remains its decayed value
        //      (below the floor), proving the floor is read-time
        //      only.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")
        XCTAssertEqual(store.slots["BSJ"]?.totalWeight ?? 0, 100.0, accuracy: 0.001)

        // Advance 30s — 5 half-lives → BSJ decays to ~3.125.
        let farFuture = 30.0
        let decision = store.processMatchInLocked(
            shabadId: "1HU", score: 50, tier: 0,
            currentShabadId: "BSJ", now: at(farFuture)
        )

        guard case .noSwap(_, _, let currentWeight) = decision else {
            XCTFail("Expected .noSwap on single-hit challenger, got \(decision)"); return
        }
        // Floor applied at read site.
        XCTAssertEqual(
            currentWeight, SungModeAccumulatorStore.currentWeightFloor,
            accuracy: 0.001,
            "currentWeight in decision must be floored to currentWeightFloor"
        )
        // Underlying stored BSJ weight is BELOW the floor — proves
        // the floor didn't leak into storage.
        let bsjStored = store.slots["BSJ"]?.totalWeight ?? 0
        XCTAssertLessThan(
            bsjStored, SungModeAccumulatorStore.currentWeightFloor,
            "Stored BSJ weight must remain decayed (below floor)"
        )
        XCTAssertGreaterThan(bsjStored, 0.0)
    }

    func test_currentWeightFloor_stillPermitsGenuineStrongChallenger() {
        // Brief #9.23a Fix 1 sanity: the currentWeightFloor does NOT
        // suppress genuine strong challengers. Same 30s pause setup
        // as the previous test, but the challenger now runs 4 tier-1
        // hits at score=100 (weight=150 per hit), so tiers=[1,1,1,1]
        // clears #9.23a Fix 2's ≥2 low-tier gate too. Challenger
        // weight exceeds 200; ratio against the floor is 10.0+ which
        // trivially exceeds lockRatio=1.5 → reLock as expected.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        let pauseEnd = 30.0
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 100, tier: 1,
                currentShabadId: "BSJ", now: at(pauseEnd + Double(i) * 0.3)
            )
        }
        guard case .reLock(let toId, _, let weight, let hits, let currentWeight, _) = lastDecision else {
            XCTFail("Expected .reLock on strong 4-hit tier-1 challenger, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(hits, SungModeAccumulatorStore.reLockMinHits)
        XCTAssertGreaterThanOrEqual(weight, 200.0)
        // BSJ is decayed far below floor → currentWeight reflects
        // the floor, not the raw stored value.
        XCTAssertEqual(
            currentWeight, SungModeAccumulatorStore.currentWeightFloor,
            accuracy: 0.001,
            "currentWeight must equal the floor when stored BSJ weight decayed below it"
        )
        // Ratio against the floor still comfortably clears lockRatio.
        XCTAssertGreaterThanOrEqual(
            weight, currentWeight * SungModeAccumulatorStore.lockRatio
        )
    }

    func test_reLockRequiresTwoLowTierHits_blocksSingleTier1AmidNoise() {
        // Brief #9.23a Fix 2: replay Deep's #9.22 iPhone Bug 2
        // exactly — challenger tiers=[3,3,1,2], currentWeight~97,
        // challenger weight ~171, ratio ~1.75. Under #9.22 this
        // false-swapped because ≥1 low-tier hit satisfied the gate.
        // Under #9.23a the tier-quality gate requires ≥2 low-tier
        // hits → noSwap. Rerun with the second tier-3 replaced by a
        // tier-1 (tiers=[3,1,1,2]) → 2 low-tier → reLock fires.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        // Deep's exact tier composition. Scored to land the
        // challenger weight north of 100 (satisfying hasWeight) so
        // the ONLY blocker is the tier-quality gate.
        let noisyEvents: [(score: Double, tier: Int)] = [
            (60, 3),
            (60, 3),
            (80, 1),
            (70, 2),
        ]
        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for (i, ev) in noisyEvents.enumerated() {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: ev.score, tier: ev.tier,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        if case .reLock = lastDecision {
            XCTFail("Should NOT reLock on tiers=[3,3,1,2] (1 low-tier hit); got \(lastDecision)")
        }
        // Confirm the assertion isolation: challenger DID reach
        // weight ≥ 100 and hits = 4.
        XCTAssertGreaterThanOrEqual(store.slots["1HU"]?.totalWeight ?? 0, 100.0)
        XCTAssertEqual(store.slots["1HU"]?.hitCount, 4)
        XCTAssertEqual(store.slots["1HU"]?.lastTiers.filter { $0 <= 1 }.count, 1)

        // Fresh store. One tier-3 flipped to tier-1 → tiers=[3,1,1,2]
        // → 2 low-tier hits → all gates pass → reLock.
        var cleanerStore = SungModeAccumulatorStore()
        _ = cleanerStore.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        cleanerStore.capWeight(shabadId: "BSJ")
        let cleanerEvents: [(score: Double, tier: Int)] = [
            (60, 3),
            (80, 1),  // was (60, 3)
            (80, 1),
            (70, 2),
        ]
        lastDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for (i, ev) in cleanerEvents.enumerated() {
            lastDecision = cleanerStore.processMatchInLocked(
                shabadId: "1HU", score: ev.score, tier: ev.tier,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        guard case .reLock(let toId, _, _, _, _, let tiers) = lastDecision else {
            XCTFail("Expected .reLock on tiers=[3,1,1,2] (2 low-tier hits); got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertGreaterThanOrEqual(tiers.filter { $0 <= 1 }.count, 2)
    }

    // MARK: - Brief #9.23 Part 4: ambiguous-shabad downweight

    func test_ambiguousShabadSet_appliesHalfWeightMultiplier() {
        // Cross-shabad LOCKED-state hit on a shabad flagged as
        // ambiguous should have its addedWeight halved. Baseline
        // (no ambiguous set) established side-by-side.
        let ambig = AmbiguousShabadSet(shabadIds: ["AMB1"])

        // Baseline: fresh store, no ambiguousSet. Seed BSJ as
        // "current" via a discovery hit, then feed AMB1 as cross-
        // shabad LOCKED hit — record its slot weight.
        var baseline = SungModeAccumulatorStore()
        _ = baseline.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        _ = baseline.processMatchInLocked(
            shabadId: "AMB1", score: 90, tier: 0,
            currentShabadId: "BSJ", now: at(0.1)
        )
        let baseWeight = baseline.slots["AMB1"]?.totalWeight ?? 0
        XCTAssertGreaterThan(baseWeight, 0)

        // With ambiguousSet: same setup but AMB1 gets the 0.5×.
        var withAmb = SungModeAccumulatorStore()
        withAmb.ambiguousSet = ambig
        _ = withAmb.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        _ = withAmb.processMatchInLocked(
            shabadId: "AMB1", score: 90, tier: 0,
            currentShabadId: "BSJ", now: at(0.1)
        )
        let dampedWeight = withAmb.slots["AMB1"]?.totalWeight ?? 0
        XCTAssertEqual(
            dampedWeight, baseWeight * SungModeAccumulatorStore.ambiguousMultiplier,
            accuracy: 0.001,
            "Cross-shabad hit on ambiguous shabad should be 0.5× baseline"
        )
    }

    func test_ambiguousShabadSet_doesNotAffectCurrentShabad() {
        // Same-shabad refresh in LOCKED — even if the current shabad
        // is in the ambiguous set, its own hits should NOT be
        // damped; the multiplier only affects cross-shabad hits.
        let ambig = AmbiguousShabadSet(shabadIds: ["CUR1"])

        // Baseline: no ambig, seed CUR1 + one same-shabad refresh.
        var baseline = SungModeAccumulatorStore()
        _ = baseline.processMatch(shabadId: "CUR1", score: 50, tier: 0, now: at(0))
        _ = baseline.processMatchInLocked(
            shabadId: "CUR1", score: 90, tier: 0,
            currentShabadId: "CUR1", now: at(0.1)
        )
        let baseWeight = baseline.slots["CUR1"]?.totalWeight ?? 0

        // With ambig: identical calls; CUR1 should end at same weight.
        var withAmb = SungModeAccumulatorStore()
        withAmb.ambiguousSet = ambig
        _ = withAmb.processMatch(shabadId: "CUR1", score: 50, tier: 0, now: at(0))
        _ = withAmb.processMatchInLocked(
            shabadId: "CUR1", score: 90, tier: 0,
            currentShabadId: "CUR1", now: at(0.1)
        )
        let sameShabadWeight = withAmb.slots["CUR1"]?.totalWeight ?? 0
        XCTAssertEqual(sameShabadWeight, baseWeight, accuracy: 0.001,
                       "Same-shabad hits must be unaffected by ambiguous multiplier")
    }

    // MARK: - Brief #9.23 Part 3: alaap-mode re-lock ratio gate

    func test_alaapMode_requiresDoubleRatioForReLock() {
        // Verifies the alaapReLockRatio (2.0) supplants the normal
        // lockRatio (1.5) in the LOCKED-state ratio-vs-current gate
        // when `alaapMode` is set. Two identical event streams into
        // two identical stores — only alaapMode differs. The event
        // set is tuned so the challenger:current ratio lands between
        // 1.5 and 2.0: the non-alaap store re-locks, the alaap store
        // does not. One extra strong challenger hit then pushes the
        // alaap store past 2.0 → reLock fires under alaap too.

        // Build a store primed with BSJ at weight 130 (2 seed hits
        // then cap to a precise value). Two hits keeps repeatState
        // below the boost threshold, so it doesn't perturb weights.
        func primed(alaap: Bool) -> SungModeAccumulatorStore {
            var s = SungModeAccumulatorStore()
            s.alaapMode = alaap
            _ = s.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
            _ = s.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0.05))
            s.capWeight(shabadId: "BSJ", cap: 130)
            return s
        }

        // Challenger events tuned for ratio ~1.7 vs decayed BSJ ~115.
        // 2 tier-1 hits at score 40 (weight 60 each) + 2 tier-2 hits
        // at score 40 (weight 40 each). Total raw ≈ 200, low-tier
        // count = 2 (satisfies reLockMinLowTierHits).
        let events: [(score: Double, tier: Int)] = [
            (40, 1), (40, 1), (40, 2), (40, 2),
        ]

        // Non-alaap: ratio ~1.7 > 1.5 → reLock fires.
        var normal = primed(alaap: false)
        var lastNormal: SungModeLockedDecision =
            .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for (i, ev) in events.enumerated() {
            lastNormal = normal.processMatchInLocked(
                shabadId: "1HU", score: ev.score, tier: ev.tier,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.05)
            )
        }
        guard case .reLock(let normalId, _, _, _, _, _) = lastNormal else {
            XCTFail("Non-alaap should reLock at ratio >1.5; got \(lastNormal)"); return
        }
        XCTAssertEqual(normalId, "1HU")

        // Alaap: identical stream, ratio ~1.7 < 2.0 → noSwap.
        var alaap = primed(alaap: true)
        var lastAlaap: SungModeLockedDecision =
            .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for (i, ev) in events.enumerated() {
            lastAlaap = alaap.processMatchInLocked(
                shabadId: "1HU", score: ev.score, tier: ev.tier,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.05)
            )
        }
        if case .reLock = lastAlaap {
            XCTFail("Alaap should NOT reLock at ratio <2.0; got \(lastAlaap)")
        }

        // One more strong challenger hit pushes ratio comfortably
        // past 2.0 — reLock should now fire under alaap too.
        let bump = alaap.processMatchInLocked(
            shabadId: "1HU", score: 100, tier: 1,
            currentShabadId: "BSJ", now: at(1.25)
        )
        guard case .reLock(let bumpId, _, _, _, _, _) = bump else {
            XCTFail("Alaap should reLock once ratio clears 2.0; got \(bump)"); return
        }
        XCTAssertEqual(bumpId, "1HU")
    }

    // MARK: - Brief #9.23 Part 1: repeat detection for alaap

    func test_repeatDetection_boostsCurrentShabadOn3ConsecutiveSameLineHits() {
        // Feed 3 same-shabad same-line hits. The 3rd hit lands with
        // count post-incremented to 3 — the boost threshold — so its
        // weight is multiplied by repeatBoostMultiplier (1.5).
        //
        // Assertion: compare the 3rd-hit delta against a baseline
        // store that saw 2 identical hits (post-decay reference).
        // The 3rd hit's added weight should be 1.5× the baseline
        // single-hit contribution.
        var store = SungModeAccumulatorStore()
        // Two hits — count goes 1 → 2, both unboosted.
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0), lineId: "L1")
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0.1), lineId: "L1")
        XCTAssertEqual(store.repeatState?.count, 2)
        // Snapshot weight just before the boosted hit lands. Third
        // hit at t=0.2 — decay from the last update (t=0.1) is
        // 0.1 s so weight barely moves.
        let preBoostWeight = store.slots["BSJ"]?.totalWeight ?? 0
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0.2), lineId: "L1")
        let postBoostWeight = store.slots["BSJ"]?.totalWeight ?? 0
        XCTAssertEqual(store.repeatState?.count, 3)

        // Compute the decayed pre-boost weight the way the ingest
        // pipeline does, then subtract to isolate the 3rd hit's
        // contribution.
        let decayFactor = pow(0.5, 0.1 / SungModeAccumulatorStore.halfLife)
        let decayedPre = preBoostWeight * decayFactor
        let addedByBoostedHit = postBoostWeight - decayedPre
        // Baseline single-hit contribution for score 50 tier 0 is
        // 50 * 2.0 = 100. Boosted: 100 * 1.5 = 150.
        let baselineContribution = 50.0 * SungModeAccumulatorStore.tierMultiplier[0]
        let expectedBoosted = baselineContribution * SungModeAccumulatorStore.repeatBoostMultiplier
        XCTAssertEqual(addedByBoostedHit, expectedBoosted, accuracy: 0.5,
                       "3rd hit should be boosted to \(expectedBoosted) (1.5× baseline \(baselineContribution))")
    }

    func test_repeatDetection_downweightsCrossShabadDuringRepeat() {
        // Build repeat state on BSJ (3 same-shabad hits → count=3),
        // then feed a cross-shabad hit. Multiplier for the cross-
        // shabad update should be repeatDownweightMultiplier (0.5),
        // producing HALF the baseline addedWeight.
        var store = SungModeAccumulatorStore()
        for i in 0..<3 {
            _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(Double(i) * 0.1), lineId: "L1")
        }
        XCTAssertEqual(store.repeatState?.shabadId, "BSJ")
        XCTAssertEqual(store.repeatState?.count, 3)

        // Cross-shabad hit — 1HU has no prior slot, so the added
        // weight is exactly the slot's totalWeight after ingest.
        _ = store.processMatch(shabadId: "1HU", score: 50, tier: 0, now: at(0.4), lineId: "LX")
        let hitWeight = store.slots["1HU"]?.totalWeight ?? 0
        let baselineContribution = 50.0 * SungModeAccumulatorStore.tierMultiplier[0]
        let expected = baselineContribution * SungModeAccumulatorStore.repeatDownweightMultiplier
        XCTAssertEqual(hitWeight, expected, accuracy: 0.001,
                       "Cross-shabad hit during repeat should be 0.5× baseline (\(expected))")
        // Repeat state should still exist (only 1 other-shabad hit,
        // needs 2 to clear).
        XCTAssertNotNil(store.repeatState)
        XCTAssertEqual(store.repeatState?.otherShabadStreakId, "1HU")
        XCTAssertEqual(store.repeatState?.otherShabadStreakCount, 1)
    }

    func test_repeatDetection_clearsOnNewShabadWith2ConsecutiveHits() {
        // Build BSJ repeat state, then feed shabad B twice. On the
        // 2nd B hit the other-shabad streak reaches
        // repeatClearOtherShabadStreak (2) and the state clears.
        // A subsequent hit for any shabad should NOT see any
        // multiplier (both slots score normally).
        var store = SungModeAccumulatorStore()
        for i in 0..<3 {
            _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(Double(i) * 0.1), lineId: "L1")
        }
        XCTAssertEqual(store.repeatState?.count, 3)

        // Two consecutive cross-shabad hits.
        _ = store.processMatch(shabadId: "OTH", score: 50, tier: 0, now: at(0.4), lineId: "LX")
        _ = store.processMatch(shabadId: "OTH", score: 50, tier: 0, now: at(0.5), lineId: "LY")
        XCTAssertNil(store.repeatState, "Repeat state must clear after 2 consecutive different-shabad hits")

        // Feed a 3rd OTH hit — because the state was just cleared,
        // this seeds a fresh repeat starting at count=1 → no boost
        // yet. Weight added should be the plain baseline.
        let preWeight = store.slots["OTH"]?.totalWeight ?? 0
        _ = store.processMatch(shabadId: "OTH", score: 50, tier: 0, now: at(0.6), lineId: "LZ")
        let postWeight = store.slots["OTH"]?.totalWeight ?? 0
        let decayFactor = pow(0.5, 0.1 / SungModeAccumulatorStore.halfLife)
        let addedByNormalHit = postWeight - preWeight * decayFactor
        let baselineContribution = 50.0 * SungModeAccumulatorStore.tierMultiplier[0]
        XCTAssertEqual(addedByNormalHit, baselineContribution, accuracy: 0.5,
                       "After state cleared, next hit should score at baseline (\(baselineContribution))")
        // A brand-new state should now be tracking OTH at count=1.
        XCTAssertEqual(store.repeatState?.shabadId, "OTH")
        XCTAssertEqual(store.repeatState?.count, 1)
    }

    func test_repeatDetection_clearsOn8SecondTimeout() {
        // Build BSJ repeat state, then advance past repeatTimeoutSeconds
        // (8.0). Any subsequent hit should see the state torn down
        // BEFORE the multiplier check, so a cross-shabad hit gets
        // no downweight.
        var store = SungModeAccumulatorStore()
        for i in 0..<3 {
            _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(Double(i) * 0.1), lineId: "L1")
        }
        XCTAssertEqual(store.repeatState?.count, 3)

        // Just past the timeout — repeat state should be cleared on
        // the next ingest.
        let past = 0.2 + SungModeAccumulatorStore.repeatTimeoutSeconds + 0.1
        _ = store.processMatch(shabadId: "OTH", score: 50, tier: 0, now: at(past), lineId: "LX")

        // OTH weight added at baseline — no downweight because state
        // was torn down before multiplier evaluation.
        let othWeight = store.slots["OTH"]?.totalWeight ?? 0
        let baselineContribution = 50.0 * SungModeAccumulatorStore.tierMultiplier[0]
        XCTAssertEqual(othWeight, baselineContribution, accuracy: 0.001,
                       "Post-timeout cross-shabad hit should score at baseline (\(baselineContribution))")
        // A fresh repeat state should be seeded on OTH at count=1.
        XCTAssertEqual(store.repeatState?.shabadId, "OTH")
        XCTAssertEqual(store.repeatState?.count, 1)
    }

    func test_reLockRequiresTwoLowTierHits_stillFiresOnCleanChallenger() {
        // Brief #9.23a Fix 2 sanity: 4 clean tier-1 hits still reLock
        // normally. tier=1 is counted as low-tier (≤ 1), so
        // lastTiers=[1,1,1,1] trivially clears the ≥2 gate. Mirrors
        // the #9.22 allGatesMet test at a different tier level.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        var lastDecision: SungModeLockedDecision = .noSwap(top3Summary: "", slotCount: 0, currentWeight: 0)
        for i in 0..<4 {
            lastDecision = store.processMatchInLocked(
                shabadId: "1HU", score: 80, tier: 1,
                currentShabadId: "BSJ", now: at(1.0 + Double(i) * 0.3)
            )
        }
        guard case .reLock(let toId, _, let weight, let hits, _, let tiers) = lastDecision else {
            XCTFail("Expected .reLock on 4 clean tier-1 hits, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
        XCTAssertEqual(hits, 4)
        XCTAssertGreaterThanOrEqual(weight, SungModeAccumulatorStore.lockWeightThreshold)
        XCTAssertEqual(tiers.filter { $0 <= 1 }.count, 4)
    }

    // MARK: - Brief #9.23e: ping-pong detection between same pair

    func test_pingPongDetection_blocksThirdSwapBetweenSamePair() {
        // Deep's post-#9.25 iPhone log had three RE-LOCK swaps
        // HLD↔NB5 in ~62 s, each individually passing all five
        // #9.23a gates. The ping-pong tracker records the pair; the
        // 3rd swap in the 60-second window is denied and a lockout
        // is armed. Mirrors that exact scenario at the accumulator
        // API level.
        var store = SungModeAccumulatorStore()

        // First swap HLD → NB5 within the window. Allowed; state
        // seeded with a single timestamp.
        let block1 = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(0))
        XCTAssertFalse(block1, "First swap between a fresh pair must be allowed")
        XCTAssertEqual(
            store.pingPongState.map { Set([$0.shabadA, $0.shabadB]) },
            Set(["HLD", "NB5"])
        )
        XCTAssertEqual(store.pingPongState?.swapTimestamps.count, 1)
        XCTAssertNil(store.pingPongLockoutUntil)

        // Second swap back NB5 → HLD, still inside the window.
        // Allowed; count reaches 2.
        let block2 = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(30))
        XCTAssertFalse(block2, "Second swap between the same pair must be allowed")
        XCTAssertEqual(store.pingPongState?.swapTimestamps.count, 2)
        XCTAssertNil(store.pingPongLockoutUntil)

        // Third swap HLD → NB5 within the same 60 s window. This is
        // the ping-pong signal — DENIED, and a lockout is armed.
        let block3 = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(45))
        XCTAssertTrue(block3, "Third swap between the same pair within 60 s must be BLOCKED")
        XCTAssertEqual(store.pingPongState?.swapTimestamps.count, 3)
        XCTAssertNotNil(store.pingPongLockoutUntil, "Lockout must be armed on ping-pong detection")
        let expectedUntil = at(45).addingTimeInterval(SungModeAccumulatorStore.pingPongLockoutSeconds)
        XCTAssertEqual(
            store.pingPongLockoutUntil?.timeIntervalSince1970 ?? 0,
            expectedUntil.timeIntervalSince1970,
            accuracy: 0.001,
            "Lockout must expire pingPongLockoutSeconds after the blocking swap"
        )

        // Sanity: another attempt inside the lockout window is still
        // denied, without appending yet-another timestamp (the swap
        // did not actually happen).
        let block4 = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(50))
        XCTAssertTrue(block4, "Further same-pair attempts during lockout must remain BLOCKED")
        XCTAssertEqual(
            store.pingPongState?.swapTimestamps.count, 3,
            "Lockout denials must not grow the timestamp list"
        )
    }

    func test_pingPongDetection_allowsSwapToThirdShabad() {
        // Establish an active lockout on HLD↔NB5 via the same 3-swap
        // sequence. Then request a swap to a THIRD shabad ANC — the
        // lockout is pair-specific, so this must proceed. State
        // resets to the new pair.
        var store = SungModeAccumulatorStore()
        _ = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(0))
        _ = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(20))
        _ = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(40))
        XCTAssertNotNil(store.pingPongLockoutUntil, "Precondition: lockout is active")

        // Swap NB5 → ANC while HLD↔NB5 lockout is still live. ANC is
        // outside the tracked pair, so this must be allowed.
        let block = store.recordAndCheckPingPong(from: "NB5", to: "ANC", now: at(50))
        XCTAssertFalse(block, "Swap involving a third shabad must proceed during pair lockout")
        XCTAssertEqual(
            store.pingPongState.map { Set([$0.shabadA, $0.shabadB]) },
            Set(["NB5", "ANC"]),
            "State must reset to track the new pair"
        )
        XCTAssertEqual(
            store.pingPongState?.swapTimestamps.count, 1,
            "State must reset to a fresh single timestamp"
        )
        XCTAssertNil(
            store.pingPongLockoutUntil,
            "Lockout was tied to the old pair; a new-pair reset clears it"
        )
    }

    func test_pingPongDetection_clearsAfterLockoutWindow() {
        // Establish a lockout at t=45 s (expires at t=105 s). At
        // t=106 s the SAME pair swap is allowed again — the tracker
        // clears expired state on the next call, then seeds a fresh
        // single-timestamp state.
        var store = SungModeAccumulatorStore()
        _ = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(0))
        _ = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(20))
        _ = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(45))
        XCTAssertNotNil(store.pingPongLockoutUntil, "Precondition: lockout is active")

        // Advance one second past the lockoutUntil timestamp.
        let past = 45.0 + SungModeAccumulatorStore.pingPongLockoutSeconds + 1.0
        let block = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(past))
        XCTAssertFalse(block, "Same-pair swap must be allowed after the lockout window expires")
        XCTAssertNil(store.pingPongLockoutUntil, "Expired lockout must be cleared")
        XCTAssertEqual(
            store.pingPongState.map { Set([$0.shabadA, $0.shabadB]) },
            Set(["HLD", "NB5"]),
            "Fresh state must seed on the same pair after lockout expiry"
        )
        XCTAssertEqual(
            store.pingPongState?.swapTimestamps.count, 1,
            "Fresh state must contain only the just-recorded swap"
        )
    }

    func test_pingPongDetection_resetsOnNewPair() {
        // Establish HLD↔NB5 as the tracked pair with two swaps, then
        // pivot to HLD↔TUY. The tracker must switch to the new pair
        // and NOT accumulate HLD↔NB5 evidence alongside HLD↔TUY.
        var store = SungModeAccumulatorStore()
        _ = store.recordAndCheckPingPong(from: "HLD", to: "NB5", now: at(0))
        _ = store.recordAndCheckPingPong(from: "NB5", to: "HLD", now: at(10))
        XCTAssertEqual(
            store.pingPongState.map { Set([$0.shabadA, $0.shabadB]) },
            Set(["HLD", "NB5"])
        )
        XCTAssertEqual(store.pingPongState?.swapTimestamps.count, 2)

        // HLD → TUY: a new pair emerges. State pivots.
        let block = store.recordAndCheckPingPong(from: "HLD", to: "TUY", now: at(15))
        XCTAssertFalse(block, "New-pair swap must be allowed")
        XCTAssertEqual(
            store.pingPongState.map { Set([$0.shabadA, $0.shabadB]) },
            Set(["HLD", "TUY"]),
            "State must now track the new pair"
        )
        XCTAssertEqual(
            store.pingPongState?.swapTimestamps.count, 1,
            "State must seed at a fresh single timestamp on pair reset"
        )
        XCTAssertNil(store.pingPongLockoutUntil, "Pair reset must not carry stale lockout")
    }
}

