import XCTest
@testable import GurbaniLensCore

/// Tests for the Brief #9.16 safely-unique-starter fast-path helpers on
/// ``FirstLetterSignature``.
final class FirstLetterSignatureTests: XCTestCase {

    // MARK: - safeUniqueStarters

    func testSafeUniqueStartersTrivial() {
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਸ", "ਪ", "ਭ"]),
        ]
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertEqual(result, ["ਸ": "P1"])
    }

    func testSafeUniqueStartersAllAmbiguous() {
        // Every pangti starts with the same letter → no letter is safely-unique.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਸ", "ਪ", "ਮ"]),
            ("P2", ["ਸ", "ਨ", "ਲ"]),
            ("P3", ["ਸ", "ਗ", "ਹ"]),
        ]
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertTrue(result.isEmpty)
    }

    func testSafeUniqueStartersMixed() {
        // Documented brief example:
        //   P1: [ਜ, ਪ, ਮ, ਨ]
        //   P2: [ਮ, ਮ, ਪ, ਸ]
        //   P3: [ਜ, ਨ, ਸ]
        //   P4: [ਉ, ਛ, ਅ, ਓ]
        //   P5: [ਸ, ਗ, ਨ, ਛ]
        // Only ਉ is safely-unique (P4's starter, appears nowhere else).
        //  - ਜ: P1[0] AND P3[0] → shared starter, disqualified.
        //  - ਮ: P2[0] AND appears in P1 → disqualified.
        //  - ਸ: P5[0] AND appears in P2 and P3 → disqualified.
        //  - ਛ: not a starter (P4 has ਉ first, P5 has ਸ first).
        //  - ਅ / ਓ / ਗ / ਨ / ਪ: not starters.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਜ", "ਪ", "ਮ", "ਨ"]),
            ("P2", ["ਮ", "ਮ", "ਪ", "ਸ"]),
            ("P3", ["ਜ", "ਨ", "ਸ"]),
            ("P4", ["ਉ", "ਛ", "ਅ", "ਓ"]),
            ("P5", ["ਸ", "ਗ", "ਨ", "ਛ"]),
        ]
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertEqual(result, ["ਉ": "P4"])
    }

    func testSafeUniqueStartersMidPositionFails() {
        // ਜ is P1's starter AND appears mid-position in P2 → disqualified.
        // ਹ is P2's starter and appears nowhere else → qualified.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਜ", "ਕ", "ਲ"]),
            ("P2", ["ਹ", "ਜ", "ਮ"]),
        ]
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertEqual(result, ["ਹ": "P2"])
    }

    func testSafeUniqueStartersEmptyCorpus() {
        let corpus: [(lineId: String, fl: [String])] = []
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertTrue(result.isEmpty)
    }

    func testSafeUniqueStartersRepeatedInSamePangtiDoesntPenalize() {
        // Defensive: if a pangti's starter also appears later in the SAME
        // pangti (e.g. ਮ starts P2 and P2 has another ਮ mid-word), the
        // dedup should keep ਮ safely-unique because no OTHER pangti has ਮ.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਸ", "ਪ", "ਲ"]),
            ("P2", ["ਮ", "ਮ", "ਨ"]),   // ਮ appears twice in P2
        ]
        let result = FirstLetterSignature.safeUniqueStarters(corpus: corpus)
        XCTAssertEqual(result, ["ਸ": "P1", "ਮ": "P2"])
    }

    // MARK: - findTrailingSafeUniqueStarter

    func testFindTrailingSafeUniqueStarterBasic() {
        let query = ["ਚ", "ਹ", "ਉ"]
        let starters = ["ਉ": "P4"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.letter, "ਉ")
        XCTAssertEqual(hit?.lineId, "P4")
    }

    func testFindTrailingSafeUniqueStarterRecentFirst() {
        // queryFL trailing 3 = [ਹ, ਉ, ਸ]. Both ਉ (P4) and ਸ (P1) are safe
        // starters. ਸ is more recent (rightmost) → wins.
        let query = ["ਖ", "ਪ", "ਹ", "ਉ", "ਸ"]
        let starters = ["ਉ": "P4", "ਸ": "P1"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.letter, "ਸ")
        XCTAssertEqual(hit?.lineId, "P1")
    }

    func testFindTrailingSafeUniqueStarterNoMatch() {
        let query = ["ਚ", "ਹ", "ਗ"]
        let starters = ["ਉ": "P4"]   // ਉ isn't in query at all
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueStarterRespectsWindow() {
        // ਉ is the SAFE-unique starter but sits OUTSIDE the trailing window.
        // queryFL = [ਉ, ਪ, ਖ, ਗ, ਹ], window=3 → scans [ਖ, ਗ, ਹ], no hit.
        let query = ["ਉ", "ਪ", "ਖ", "ਗ", "ਹ"]
        let starters = ["ਉ": "P4"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueStarterEmptyStarters() {
        let query = ["ਚ", "ਹ", "ਉ"]
        let starters: [String: String] = [:]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueStarterEmptyQuery() {
        // Defensive: empty query short-circuits regardless of starters.
        let starters = ["ਉ": "P4"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: [], safeStarters: starters, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueStarterWindowLargerThanQuery() {
        // Defensive: window larger than query.count clamps to query.count.
        let query = ["ਉ"]
        let starters = ["ਉ": "P4"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
            queryFL: query, safeStarters: starters, trailingWindow: 100
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.letter, "ਉ")
        XCTAssertEqual(hit?.lineId, "P4")
    }
}
