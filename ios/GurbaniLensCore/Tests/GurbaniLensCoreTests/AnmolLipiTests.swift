import XCTest
@testable import GurbaniLensCore

/// Tests for `Gurmukhi.fromAnmolLipi` — the Swift port of anvaad-js's
/// `unicode()` function. Each expected string was computed by hand
/// against the JS reference (`scripts/anvaad-investigation/anvaad-unicode.js`),
/// not against a live conversion oracle — if you adjust the port, run
/// the JS reference (`node -e "console.log(require(\"./anvaad-unicode\")(\"...\"))"`)
/// before retuning these expectations.
final class AnmolLipiTests: XCTestCase {

    // MARK: - Canonical Gurbani conversions

    /// `] jpu ]` — "॥ ਜਪੁ ॥" (Jap heading: double-danda + word + double-danda).
    /// Note: `]` is double-danda (॥), NOT Ek Onkar (ੴ — that's `<>`).
    func testJapHeading() {
        XCTAssertEqual(Gurmukhi.fromAnmolLipi("] jpu ]"), "॥ ਜਪੁ ॥")
    }

    /// `sloku ]` — "ਸਲੋਕੁ ॥" (common Bani heading).
    func testSlokuHeading() {
        XCTAssertEqual(Gurmukhi.fromAnmolLipi("sloku ]"), "ਸਲੋਕੁ ॥")
    }

    /// `Awid scu jugwid scu ]` — the opening of the Mool Mantar
    /// proper-statement: "ਆਦਿ ਸਚੁ ਜੁਗਾਦਿ ਸਚੁ ॥".
    func testAadSachJugaadSach() {
        XCTAssertEqual(
            Gurmukhi.fromAnmolLipi("Awid scu jugwid scu ]"),
            "ਆਦਿ ਸਚੁ ਜੁਗਾਦਿ ਸਚੁ ॥"
        )
    }

    /// `hir hir hir hir nwmu` — the repeated Naam invocation:
    /// "ਹਰਿ ਹਰਿ ਹਰਿ ਹਰਿ ਨਾਮੁ". Exercises sihari prefix swap (`hir` → `ਹਰਿ`).
    func testHariHariNaam() {
        XCTAssertEqual(
            Gurmukhi.fromAnmolLipi("hir hir hir hir nwmu"),
            "ਹਰਿ ਹਰਿ ਹਰਿ ਹਰਿ ਨਾਮੁ"
        )
    }

    /// `<> siq nwmu krqw purKu ]` — the start of the Mool Mantar with
    /// the Ek Onkar symbol. `<>` is the canonical Anmol Lipi spelling
    /// for ੴ (the `>` is pre-cleaned, the `<` maps to ੴ).
    func testMoolMantarOpening() {
        XCTAssertEqual(
            Gurmukhi.fromAnmolLipi("<> siq nwmu krqw purKu ]"),
            "ੴ ਸਤਿ ਨਾਮੁ ਕਰਤਾ ਪੁਰਖੁ ॥"
        )
    }

    // MARK: - Edge cases

    func testEmptyString() {
        XCTAssertEqual(Gurmukhi.fromAnmolLipi(""), "")
    }

    /// Characters not in the mapping pass through unchanged.
    func testPassthroughUnknown() {
        XCTAssertEqual(Gurmukhi.fromAnmolLipi("?!"), "?!")
    }

    /// `iek` exercises the special `i` + `e` lookahead → `ਇ`.
    func testIekIndependentI() {
        XCTAssertEqual(Gurmukhi.fromAnmolLipi("iek"), "ਇਕ")
    }

    // MARK: - Padcheid punctuation strip (added 2026-06-23)

    /// `.` and `;` are BaniDB Padcheid (word-break) markers, not
    /// canonical Gurmukhi punctuation. They must be stripped during
    /// pre-clean so they never surface in the UI. Deep's 2026-06-23
    /// screenshot showed pollution like "ਅਉਖੀ ਘੜੀ. ਨ ਦੇਖਣ ਦੇਈ;" —
    /// this test guards against regression.
    func testPadcheidPunctuationStrip_periodsAndSemicolonsRemoved() {
        let pollutedAukhi = "AuKI GVI . n dyKx dyeI ] Apnw ibrdu smwly ]"
        let out = Gurmukhi.fromAnmolLipi(pollutedAukhi)
        XCTAssertFalse(out.contains("."), "period must not survive Padcheid strip — got '\(out)'")
        XCTAssertFalse(out.contains(";"), "semicolon must not survive Padcheid strip — got '\(out)'")
        // Sanity: the actual Gurmukhi content is still there.
        XCTAssertTrue(out.contains("ਦੇਖਣ"), "main content survives — got '\(out)'")
        XCTAssertTrue(out.contains("॥"), "double-danda from `]` survives — got '\(out)'")
    }

    /// Tight stress test — input is nothing but Padcheid markers
    /// interleaved with one valid token. Output must contain only the
    /// converted token + spaces.
    func testPadcheidPunctuationStrip_pureMarkerInterleave() {
        let input = "hir ; hir ] hir."
        let out = Gurmukhi.fromAnmolLipi(input)
        XCTAssertFalse(out.contains("."))
        XCTAssertFalse(out.contains(";"))
        // Three "hir" → three "ਹਰਿ" + the danda from `]`.
        XCTAssertEqual(
            out.components(separatedBy: "ਹਰਿ").count - 1, 3,
            "expected three 'ਹਰਿ' tokens, got '\(out)'"
        )
    }
}
