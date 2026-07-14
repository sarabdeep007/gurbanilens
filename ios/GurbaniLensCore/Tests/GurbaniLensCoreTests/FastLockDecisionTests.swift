import XCTest
@testable import GurbaniLensCore

/// Brief #9.30 Fix 2 tests for the pure ``FastLockDecision`` gate that
/// arbitrates the sung-mode DISCOVERING fast-lock path.
///
/// Three cases pin down the ambiguity guard:
///   1. non-ambiguous + all gates satisfied → fire (unchanged from #9.26)
///   2. ambiguous + sung mode → defer (defers to accumulator/cloud)
///   3. ambiguous + speech mode → fire (speech path is unaffected)
///
/// The three individual gate rejections (partialIndex > 3, score < 90,
/// tier > 1) are covered by the shared `shouldFastLock` implementation
/// but not asserted here — they existed identically pre-#9.30 and any
/// regression would be caught by Deep's on-device sung/speech A/B
/// alongside the engine's DIAG stream.
final class FastLockDecisionTests: XCTestCase {

    func test_fastLock_firesOnNonAmbiguous() {
        let should = FastLockDecision.shouldFastLock(
            score: 92, tier: 1, partialIndex: 2,
            isAmbiguous: false, mode: .sung
        )
        XCTAssertTrue(
            should,
            "Non-ambiguous shabad within all fast-lock gates must fire (unchanged Brief #9.26 behavior)"
        )
    }

    func test_fastLock_deferredOnAmbiguous_sungMode() {
        let should = FastLockDecision.shouldFastLock(
            score: 92, tier: 1, partialIndex: 2,
            isAmbiguous: true, mode: .sung
        )
        XCTAssertFalse(
            should,
            "Ambiguous shabad in sung mode must DEFER fast-lock so the candidate cloud can engage"
        )
    }

    func test_fastLock_firesOnAmbiguous_speechMode() {
        let should = FastLockDecision.shouldFastLock(
            score: 92, tier: 1, partialIndex: 2,
            isAmbiguous: true, mode: .speech
        )
        XCTAssertTrue(
            should,
            "Speech-mode fast-lock is unchanged — ambiguity flag must be ignored here (Deep values speed)"
        )
    }
}
