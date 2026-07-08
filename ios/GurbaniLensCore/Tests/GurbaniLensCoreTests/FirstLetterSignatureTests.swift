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

    // MARK: - safeUniqueBigramStarters (Brief #9.19)

    func testSafeUniqueBigrams_bsjExample() {
        // Documented BSJ shabad from Deep's data. ALL 6 pangtis should have
        // safely-unique starter bigrams. Constructed FL arrays such that each
        // pangti's starter bigram appears nowhere else as a consecutive pair.
        //   D7PD (ਤ, ਵ) — ਤਾਤੀ ਵਾਉ …
        //   XLVS (ਚ, ਹ) — ਚਉਗਿਰਦ ਹਮਾਰੈ …
        //   H0Y2 (ਸ, ਪ) — ਸੁਖਿ ਪਧਾਰੇ …
        //   90CQ (ਕ, ਨ) — ਕੋਟਿ ਨਾਰਾਇਣ …
        //   RENR (ਰ, ਨ) — ਰਾਖਨਹਾਰ …
        //   H942 (ਰ, ਲ) — ਰਖੁ ਲੇਹੁ …
        // Shared letters (ਰ in RENR and H942; ਲ in D7PD/XLVS/H942) are fine —
        // the algorithm only cares about consecutive pairs.
        let corpus: [(lineId: String, fl: [String])] = [
            ("D7PD", ["ਤ", "ਵ", "ਨ", "ਲ", "ਪ", "ਸ"]),
            ("XLVS", ["ਚ", "ਹ", "ਰ", "ਕ", "ਦ", "ਲ", "ਨ", "ਬ"]),
            ("H0Y2", ["ਸ", "ਪ", "ਭ", "ਜ", "ਬ", "ਬ"]),
            ("90CQ", ["ਕ", "ਨ", "ਪ", "ਹ"]),
            ("RENR", ["ਰ", "ਨ", "ਖ", "ਮ", "ਦ"]),
            ("H942", ["ਰ", "ਲ", "ਤ", "ਰ", "ਸ", "ਬ", "ਮ"]),
        ]
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result["ਤ|ਵ"], "D7PD")
        XCTAssertEqual(result["ਚ|ਹ"], "XLVS")
        XCTAssertEqual(result["ਸ|ਪ"], "H0Y2")
        XCTAssertEqual(result["ਕ|ਨ"], "90CQ")
        XCTAssertEqual(result["ਰ|ਨ"], "RENR")
        XCTAssertEqual(result["ਰ|ਲ"], "H942")
    }

    func testSafeUniqueBigrams_sharedStarterBigram() {
        // Two pangtis both start with (ਸ, ਤ) → neither in map. Third pangti's
        // starter (ਪ, ਨ) appears nowhere else → safely-unique.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਸ", "ਤ", "ਵ"]),
            ("P2", ["ਸ", "ਤ", "ਹ"]),
            ("P3", ["ਪ", "ਨ", "ਲ"]),
        ]
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertNil(result["ਸ|ਤ"])
        XCTAssertEqual(result["ਪ|ਨ"], "P3")
    }

    func testSafeUniqueBigrams_midPositionFails() {
        // P1 starter is (ਕ, ਤ). P2 has (ਕ, ਤ) as mid-position consecutive pair.
        // → (ਕ, ਤ) NOT safely-unique for P1. P2's own starter (ਹ, ਕ) is safe.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਕ", "ਤ", "ਸ"]),
            ("P2", ["ਹ", "ਕ", "ਤ", "ਵ"]),
        ]
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertNil(result["ਕ|ਤ"])
        XCTAssertEqual(result["ਹ|ਕ"], "P2")
    }

    func testSafeUniqueBigrams_repeatedInSamePangtiDoesntPenalize() {
        // X has (ਕ, ਤ) as starter AND repeats mid-pangti. Dedup-within-pangti
        // should keep (ਕ, ਤ)'s global count at 1 (only in X) → safely-unique.
        let corpus: [(lineId: String, fl: [String])] = [
            ("X", ["ਕ", "ਤ", "ਸ", "ਕ", "ਤ"]),
            ("Y", ["ਹ", "ਪ", "ਲ"]),
        ]
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertEqual(result["ਕ|ਤ"], "X")
        XCTAssertEqual(result["ਹ|ਪ"], "Y")
    }

    func testSafeUniqueBigrams_singleLetterPangti() {
        // Pangti with only 1 FL letter has no starter bigram — excluded.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਕ"]),
            ("P2", ["ਸ", "ਤ", "ਵ"]),
        ]
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["ਸ|ਤ"], "P2")
    }

    func testSafeUniqueBigrams_emptyCorpus() {
        let corpus: [(lineId: String, fl: [String])] = []
        let result = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpus)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - findTrailingSafeUniqueBigram (Brief #9.19)

    func testFindTrailingSafeUniqueBigram_basic() {
        // queryFL = [A, B, ਚ, ਹ]; safe bigram (ਚ, ਹ) → P4.
        let query = ["A", "B", "ਚ", "ਹ"]
        let bigrams = ["ਚ|ਹ": "P4"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 4
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.bigram.0, "ਚ")
        XCTAssertEqual(hit?.bigram.1, "ਹ")
        XCTAssertEqual(hit?.lineId, "P4")
    }

    func testFindTrailingSafeUniqueBigram_recentFirst() {
        // Two trailing bigram hits — rightmost (most recent) wins.
        // queryFL = [ਚ, ਹ, ਕ, ਖ, ਬ, ਵ]; safes {ਚ|ਹ: P1, ਬ|ਵ: P2}.
        // Bigrams checked right-to-left: (ਬ,ਵ) at pos 4 hits first → P2.
        let query = ["ਚ", "ਹ", "ਕ", "ਖ", "ਬ", "ਵ"]
        let bigrams = ["ਚ|ਹ": "P1", "ਬ|ਵ": "P2"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 6
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.bigram.0, "ਬ")
        XCTAssertEqual(hit?.bigram.1, "ਵ")
        XCTAssertEqual(hit?.lineId, "P2")
    }

    func testFindTrailingSafeUniqueBigram_respectsWindow() {
        // Brief example: queryFL=[X,Y,ਚ,ਹ,Z,W], trailingWindow=3 → trailing
        // slice is last 3 letters [ਹ, Z, W]. Bigrams within slice have start
        // positions in [3..4]: (ਹ,Z) and (Z,W). (ਚ,ਹ) starts at position 2 —
        // OUTSIDE window — even though ਹ itself is in-window. Not checked.
        let query = ["X", "Y", "ਚ", "ਹ", "Z", "W"]
        let bigrams = ["ਚ|ਹ": "P1"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueBigram_shortQuery() {
        // queryFL.count < 2 — no bigram possible.
        let query = ["ਚ"]
        let bigrams = ["ਚ|ਹ": "P1"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueBigram_emptyBigrams() {
        let query = ["ਚ", "ਹ", "ਪ"]
        let bigrams: [String: String] = [:]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    func testFindTrailingSafeUniqueBigram_noMatch() {
        // Trailing bigrams (ਖ,ਗ), (ਗ,ਘ) — neither in the map.
        let query = ["ਖ", "ਗ", "ਘ"]
        let bigrams = ["ਚ|ਹ": "P1"]
        let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
            queryFL: query, safeBigrams: bigrams, trailingWindow: 3
        )
        XCTAssertNil(hit)
    }

    // MARK: - First-2-word signatures (Brief #9.26 5)

    /// Cache-parity contract: `firstTwoWordSignatures` must return
    /// a map keyed by `"L1|L2"` for every pangti whose starter
    /// bigram is unique AMONG STARTERS. Distinct from
    /// safeUniqueBigramStarters, which also rules out any BODY
    /// occurrence of the bigram — this one is looser.
    func testFirstTwoWordSigs_includesUniqueStarters() {
        // Three pangtis, each with a distinct starter bigram. All
        // three qualify because no two share a starter pair.
        // Bodies contain repeats (e.g. ਸ appears in P1 body and
        // as P2's starter's second letter) but that's fine — first-
        // 2-word signatures ignore body positions.
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਤ", "ਵ", "ਨ", "ਲ"]),
            ("P2", ["ਪ", "ਸ", "ਚ", "ਹ"]),
            ("P3", ["ਸ", "ਭ", "ਗ", "ਤ"]),
        ]
        let sigs = FirstLetterSignature.firstTwoWordSignatures(corpus: corpus)
        XCTAssertEqual(sigs["ਤ|ਵ"], "P1")
        XCTAssertEqual(sigs["ਪ|ਸ"], "P2")
        XCTAssertEqual(sigs["ਸ|ਭ"], "P3")
    }

    /// When two pangtis SHARE a starter bigram, neither is included
    /// (the ambiguity floor). Third pangti with a distinct starter
    /// still qualifies.
    func testFirstTwoWordSigs_excludesAmbiguousStarters() {
        let corpus: [(lineId: String, fl: [String])] = [
            ("P1", ["ਤ", "ਵ", "ਨ", "ਲ"]),
            ("P2", ["ਤ", "ਵ", "ਪ", "ਸ"]),   // shares "ਤ|ਵ" with P1
            ("P3", ["ਸ", "ਭ", "ਗ"]),
        ]
        let sigs = FirstLetterSignature.firstTwoWordSignatures(corpus: corpus)
        XCTAssertNil(sigs["ਤ|ਵ"], "Ambiguous starter must NOT map to any single pangti")
        XCTAssertEqual(sigs["ਸ|ਭ"], "P3", "Unique starter must still map")
    }

    /// The trailing-window matcher must fire when the ASR partial's
    /// trailing bigram matches a first-2-word signature.
    func testFindTrailingFirstTwoWordSig_fires() {
        // Pangti "ਤ ਵ ਨ ਲ" has starter "ਤ|ਵ". ASR partial ends
        // with "ਪ ਸ ਤ ਵ" — trailing bigram matches.
        let query = ["ਪ", "ਸ", "ਤ", "ਵ"]
        let sigs = ["ਤ|ਵ": "P1"]
        let hit = FirstLetterSignature.findTrailingFirstTwoWordSig(
            queryFL: query, firstTwoWordSigs: sigs, trailingWindow: 4
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.lineId, "P1")
        XCTAssertEqual(hit?.bigram.0, "ਤ")
        XCTAssertEqual(hit?.bigram.1, "ਵ")
    }

    /// Single-letter partial cannot form a bigram — must return nil
    /// even when the letter appears in the map's keyspace.
    func testFindTrailingFirstTwoWordSig_doesNotFireOnPartialWordHit() {
        // Only one letter in the partial — no bigram possible.
        let query = ["ਤ"]
        let sigs = ["ਤ|ਵ": "P1"]
        let hit = FirstLetterSignature.findTrailingFirstTwoWordSig(
            queryFL: query, firstTwoWordSigs: sigs, trailingWindow: 3
        )
        XCTAssertNil(hit, "Single-letter partial cannot form a bigram — must return nil")
    }
}
