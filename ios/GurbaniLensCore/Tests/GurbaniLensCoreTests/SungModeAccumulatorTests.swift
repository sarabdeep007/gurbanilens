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
}
