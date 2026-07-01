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
        // Brief #9.22 Fix 2 gate 3 (tier quality): challenger's
        // lastTiers ring must contain at least one tier ≤ 1. Pure
        // tier-2 accumulation should not swap. Then a single tier-1
        // hit unlocks the swap.
        var store = SungModeAccumulatorStore()
        _ = store.processMatch(shabadId: "BSJ", score: 50, tier: 0, now: at(0))
        store.capWeight(shabadId: "BSJ")

        // 4 tier-2 hits at score=80 (weight=80 per hit).
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

        // One tier-1 hit is the missing ingredient.
        lastDecision = store.processMatchInLocked(
            shabadId: "1HU", score: 80, tier: 1,
            currentShabadId: "BSJ", now: at(2.5)
        )
        guard case .reLock(let toId, _, _, _, _, _) = lastDecision else {
            XCTFail("Expected .reLock after tier-1 hit lands, got \(lastDecision)"); return
        }
        XCTAssertEqual(toId, "1HU")
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
}

