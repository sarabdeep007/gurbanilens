import XCTest
@testable import GurbaniLensCore

/// Standalone unit tests for ``Matcher/matchByFirstLetters(_:topN:)`` and
/// ``PhoneticEquivalence``. Does NOT need a real SGGS corpus — uses small
/// hand-built `Matcher(prebuilt:)` instances so it runs in every CI pass
/// regardless of `GURBANILENS_CORPUS_PATH`.
final class MatchByFirstLettersTests: XCTestCase {

    // MARK: - PhoneticEquivalence char-level

    func testPhoneticEquivalence_groupsCollapseSymmetrically() {
        // b/p
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("b", "p"))
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("p", "b"))
        // g/k
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("g", "k"))
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("k", "g"))
        // d/t
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("d", "t"))
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("t", "d"))
        // j/c
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("j", "c"))
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("c", "j"))
        // identity
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("a", "a"))
        XCTAssertTrue(PhoneticEquivalence.charEquivalent("m", "m"))
        // cross-group should NOT collapse
        XCTAssertFalse(PhoneticEquivalence.charEquivalent("b", "g"))
        XCTAssertFalse(PhoneticEquivalence.charEquivalent("d", "j"))
        XCTAssertFalse(PhoneticEquivalence.charEquivalent("m", "n"))
    }

    func testPhoneticEquivalence_stringCanonicalisation() {
        XCTAssertEqual(PhoneticEquivalence.canonicalize("babba mn"), "pappa mn")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("papa mn"),  "papa mn")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("gana"),     "kana")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("kana"),     "kana")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("dada"),     "tata")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("tata"),     "tata")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("jajja"),    "cacca")
        XCTAssertEqual(PhoneticEquivalence.canonicalize("cacca"),    "cacca")
        // non-group chars unchanged
        XCTAssertEqual(PhoneticEquivalence.canonicalize("meena"), "meena")
        XCTAssertEqual(PhoneticEquivalence.canonicalize(""),      "")
    }

    // MARK: - matchByFirstLetters via prebuilt Matcher

    /// Build a minimal `Matcher(prebuilt:)` from a list of `(id, translit)`.
    /// `normalised` uses the package's `normalize(_:)` for parity with the
    /// production index pipeline. Tokens are split on whitespace.
    private func makeMatcher(_ pairs: [(id: String, translit: String)]) -> Matcher {
        let prebuilt: [(line: Line, normalised: String, tokens: [String])] = pairs.enumerated().map { (idx, p) in
            let line = Line(
                id: p.id,
                shabadId: "S\(p.id)",
                ang: idx + 1,
                pangti: 1,
                lineType: nil,
                gurmukhi: p.translit,
                gurmukhiUnicode: nil,
                transliterationEn: p.translit,
                firstLetters: nil,
                orderId: idx
            )
            let norm = normalize(p.translit)
            let toks = norm.split(separator: " ").map(String.init)
            return (line: line, normalised: norm, tokens: toks)
        }
        return Matcher(prebuilt: prebuilt)
    }

    /// Phonetic groups: "babba mn" and "papa mn" must rank-tie at the top
    /// regardless of which letter the query uses. This is the core v2
    /// requirement — Whisper's b↔p flip cannot break live matching.
    func testMatchByFirstLetters_babbaPapaRankEquivalently() {
        let matcher = makeMatcher([
            ("p", "papa mn"),    // FL "pm", phonetic "pm"
            ("b", "babba mn"),   // FL "bm", phonetic "pm"
            ("z", "zebra mn"),   // FL "zm", phonetic "zm" — distractor
            ("m", "meena nm"),   // FL "mn", phonetic "mn" — distractor
        ])

        let bQuery = matcher.matchByFirstLetters("babba mn", topN: 4)
        let pQuery = matcher.matchByFirstLetters("papa mn",  topN: 4)

        // Both queries must return the same number of results.
        XCTAssertEqual(bQuery.count, 4)
        XCTAssertEqual(pQuery.count, 4)

        // The top two slots (babba + papa) must score identically
        // between the two queries — the phonetic canonicalisation makes
        // them indistinguishable.
        XCTAssertEqual(bQuery[0].score, pQuery[0].score, accuracy: 0.01,
                       "top-1 scores diverge between b-query and p-query")
        XCTAssertEqual(bQuery[1].score, pQuery[1].score, accuracy: 0.01,
                       "top-2 scores diverge between b-query and p-query")

        // The top-1 score should be 100 (or very near) — an exact match
        // under phonetic equivalence.
        XCTAssertGreaterThanOrEqual(bQuery[0].score, 99.0)
        XCTAssertGreaterThanOrEqual(pQuery[0].score, 99.0)
    }

    /// "gana" / "kana" — g/k group. Mirrors the b/p case.
    func testMatchByFirstLetters_ganaKanaRankEquivalently() {
        let matcher = makeMatcher([
            ("k", "kana"),
            ("g", "gana"),
            ("h", "hana"),
        ])
        let gQuery = matcher.matchByFirstLetters("gana", topN: 3)
        let kQuery = matcher.matchByFirstLetters("kana", topN: 3)

        XCTAssertEqual(gQuery.count, 3)
        XCTAssertEqual(kQuery.count, 3)
        XCTAssertEqual(gQuery[0].score, kQuery[0].score, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(gQuery[0].score, 99.0)

        // The h-distractor must rank STRICTLY below the g/k pair in
        // either query — phonetic equivalence shouldn't pull in unrelated
        // letters.
        XCTAssertGreaterThan(gQuery[0].score, gQuery[2].score)
        XCTAssertGreaterThan(kQuery[0].score, kQuery[2].score)
    }

    /// Two-token first-letters with one group letter inside.
    /// "har naam" (FL "hn") and "har taam" (FL "ht") should NOT collapse —
    /// h is not in any group and n is not in any group. The d/t group only
    /// fires when an actual d or t is in the first-letters.
    func testMatchByFirstLetters_unrelatedLettersDoNotCollapse() {
        let matcher = makeMatcher([
            ("hn", "har naam"),
            ("ht", "har taam"),
        ])
        let hnQuery = matcher.matchByFirstLetters("har naam", topN: 2)
        let htQuery = matcher.matchByFirstLetters("har taam", topN: 2)

        // hn query: top must be the "hn" line, not the "ht" line.
        XCTAssertEqual(hnQuery[0].line.id, "hn")
        XCTAssertEqual(htQuery[0].line.id, "ht")
        // Top scores both ~100; second-place ratios are real but lower.
        XCTAssertGreaterThan(hnQuery[0].score, hnQuery[1].score)
        XCTAssertGreaterThan(htQuery[0].score, htQuery[1].score)
    }

    /// Sirlekh (section-header) lines must not appear in matcher results
    /// even when their tiny first-letters trivially substring-match a
    /// longer query. Deep's "ਹਮ ਰੁਲਤੇ ਫਿਰਤੇ" test returned 4× "Pauri ॥"
    /// + 1× "Bhagat" — all Sirlekh, all scored 100.0, none useful. The
    /// fix filters Sirlekh at Matcher init time. This test verifies via
    /// `Matcher(prebuilt:)` which applies the same filter.
    func testMatchByFirstLetters_sirlekhExcludedFromIndex() {
        let sirlekh = Line(
            id: "TEST_SIRLEKH",
            shabadId: "TEST",
            ang: 1, pangti: 1,
            lineType: "Sirlekh",
            gurmukhi: "pauri ||",
            gurmukhiUnicode: nil,
            transliterationEn: "Pauri |",
            firstLetters: "p|",
            orderId: 1
        )
        let content = Line(
            id: "TEST_CONTENT",
            shabadId: "TEST",
            ang: 1, pangti: 2,
            lineType: "Pankti",
            gurmukhi: "test line",
            gurmukhiUnicode: nil,
            transliterationEn: "ham rulate phirate koee baat na puchata",
            firstLetters: "hrpkbnp",
            orderId: 2
        )
        let matcher = Matcher(prebuilt: [
            (line: sirlekh, normalised: "pauri", tokens: ["pauri"]),
            (line: content,
             normalised: "ham rulate phirate koee baat na puchata",
             tokens: ["ham","rulate","phirate","koee","baat","na","puchata"]),
        ])

        XCTAssertEqual(matcher.count, 1, "Sirlekh must be filtered out of the index")

        // Long-query test — partial_ratio would have rated "p" 100.0
        // against "hrpkbnp" pre-fix, putting Sirlekh on top.
        let results = matcher.matchByFirstLetters(
            "ham rulate phirate koee baat na puchata", topN: 5
        )
        XCTAssertEqual(results.count, 1, "only the content line remains after Sirlekh filter")
        XCTAssertEqual(results.first?.line.id, "TEST_CONTENT")
        XCTAssertNotEqual(results.first?.line.id, "TEST_SIRLEKH")
    }

    /// Empty / whitespace-only / single-char queries must not crash and
    /// should return empty (or up to topN at zero score).
    func testMatchByFirstLetters_emptyOrTrivialQueries() {
        let matcher = makeMatcher([
            ("p", "papa mn"),
            ("k", "kana"),
        ])

        XCTAssertEqual(matcher.matchByFirstLetters("",       topN: 5).count, 0)
        XCTAssertEqual(matcher.matchByFirstLetters("   ",    topN: 5).count, 0)
        // Single-char query is allowed (qFL = "p") — should return all
        // corpus lines ranked.
        let single = matcher.matchByFirstLetters("p", topN: 5)
        XCTAssertEqual(single.count, 2)
    }
}
