import XCTest
@testable import GurbaniLensCore

/// Unit tests for ``Gurmukhi/fromDevanagari(_:)``. Pure transliteration —
/// no corpus dependency.
final class GurmukhiTests: XCTestCase {

    func testFromDevanagari_consonants() {
        XCTAssertEqual(Gurmukhi.fromDevanagari("क"),  "ਕ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ख"),  "ਖ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ग"),  "ਗ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("त"),  "ਤ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("न"),  "ਨ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("स"),  "ਸ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ह"),  "ਹ")
    }

    func testFromDevanagari_independentVowels() {
        XCTAssertEqual(Gurmukhi.fromDevanagari("अ"),  "ਅ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("आ"),  "ਆ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("इ"),  "ਇ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ई"),  "ਈ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("उ"),  "ਉ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ऊ"),  "ਊ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ए"),  "ਏ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ओ"),  "ਓ")
    }

    func testFromDevanagari_vowelSignsCompose() {
        // क + ा = का (Devanagari) → ਕ + ਾ = ਕਾ (Gurmukhi)
        XCTAssertEqual(Gurmukhi.fromDevanagari("का"), "ਕਾ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("कि"), "ਕਿ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("की"), "ਕੀ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("कु"), "ਕੁ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("कू"), "ਕੂ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("के"), "ਕੇ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("को"), "ਕੋ")
    }

    func testFromDevanagari_halantConjunct() {
        // क + ् + त = क्त (Devanagari conjunct) → ਕ + ੍ + ਤ = ਕ੍ਤ
        XCTAssertEqual(Gurmukhi.fromDevanagari("क्त"), "ਕ੍ਤ")
    }

    func testFromDevanagari_digits() {
        XCTAssertEqual(Gurmukhi.fromDevanagari("०"), "੦")
        XCTAssertEqual(Gurmukhi.fromDevanagari("१"), "੧")
        XCTAssertEqual(Gurmukhi.fromDevanagari("९"), "੯")
        XCTAssertEqual(Gurmukhi.fromDevanagari("०१२३४५६७८९"), "੦੧੨੩੪੫੬੭੮੯")
    }

    func testFromDevanagari_anusvaraToBindi() {
        // ं (anusvara) → ਂ (bindi)
        XCTAssertEqual(Gurmukhi.fromDevanagari("नं"), "ਨਂ")
    }

    func testFromDevanagari_sanskritShashaFallback() {
        // श / ष → ਸ਼ (closest Gurmukhi equivalent)
        XCTAssertEqual(Gurmukhi.fromDevanagari("श"), "ਸ਼")
        XCTAssertEqual(Gurmukhi.fromDevanagari("ष"), "ਸ਼")
    }

    func testFromDevanagari_passesThroughNonDevanagari() {
        XCTAssertEqual(Gurmukhi.fromDevanagari(""),         "")
        XCTAssertEqual(Gurmukhi.fromDevanagari("hello"),    "hello")
        XCTAssertEqual(Gurmukhi.fromDevanagari(" "),        " ")
        XCTAssertEqual(Gurmukhi.fromDevanagari("क hello"),  "ਕ hello")
        // Already-Gurmukhi passes through unchanged (idempotent)
        XCTAssertEqual(Gurmukhi.fromDevanagari("ਗੁਰਮੁਖੀ"),   "ਗੁਰਮੁਖੀ")
    }

    func testFromDevanagari_realWorldPangti() {
        // "तत् ट्वम् असि" — a Devanagari Sanskrit-ish fragment of the kind
        // Whisper-small produces. Should map cleanly to Gurmukhi.
        let dev = "तत् ट्वम् असि"
        let gur = Gurmukhi.fromDevanagari(dev)
        // We don't assert exact grapheme equality — Swift's grapheme
        // clustering can differ slightly between the two scripts for the
        // same logical syllables, so `.count` (which returns Characters,
        // not scalars) may differ by ±1 across the mapping. Assert
        // instead that:
        //   (a) no U+FFFD bleeds through,
        //   (b) scalar count is preserved (every Devanagari scalar maps
        //       to exactly one Gurmukhi scalar; ASCII pass-through),
        //   (c) every Devanagari scalar is gone,
        //   (d) some Gurmukhi scalars appear.
        XCTAssertFalse(gur.contains("\u{FFFD}"))
        XCTAssertEqual(gur.unicodeScalars.count, dev.unicodeScalars.count)
        for scalar in gur.unicodeScalars {
            if scalar.value >= 0x0900 && scalar.value <= 0x097F {
                XCTFail("Devanagari scalar leaked into Gurmukhi output: U+\(String(scalar.value, radix: 16))")
            }
        }
        let hasGurmukhi = gur.unicodeScalars.contains { $0.value >= 0x0A00 && $0.value <= 0x0A7F }
        XCTAssertTrue(hasGurmukhi, "no Gurmukhi scalars in output of \(dev) → \(gur)")
    }
}
