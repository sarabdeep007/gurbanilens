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
}
