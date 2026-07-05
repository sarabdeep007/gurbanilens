import XCTest
@testable import GurbaniLensCore

/// Brief #9.24 Part 6: unit tests for the nearest-section-header
/// helper. FullShabad + its display-side sectionHeader() method live
/// in the iOS app target (no test coverage there); the underlying
/// helper is in Core so the pure lookup is testable in isolation.
final class LineSectionHeaderTests: XCTestCase {

    private func line(_ id: String, orderId: Int, type: String? = "Pankti", gurmukhi: String = "") -> Line {
        Line(
            id: id, shabadId: "S1", ang: 1, pangti: nil,
            lineType: type, gurmukhi: gurmukhi,
            gurmukhiUnicode: nil, transliterationEn: nil,
            firstLetters: nil, orderId: orderId
        )
    }

    func test_findsNearestSectionHeader() {
        // Mixed shabad with two sirlekh markers at orderIds 10 and
        // 20. Reference orderIds 12, 21, 100 should all land on the
        // most recently-preceding sirlekh.
        let sloku = line("SL", orderId: 10, type: "Sirlekh", gurmukhi: "ਸਲੋਕੁ ॥")
        let paurhi = line("PA", orderId: 20, type: "Sirlekh", gurmukhi: "ਪਉੜੀ ॥")
        let sirlekh = [sloku, paurhi]

        let refBetween = Line.nearestSectionHeader(from: sirlekh, atOrderId: 12)
        XCTAssertEqual(refBetween?.id, "SL")

        let refAtPaurhi = Line.nearestSectionHeader(from: sirlekh, atOrderId: 21)
        XCTAssertEqual(refAtPaurhi?.id, "PA")

        let refFarAfter = Line.nearestSectionHeader(from: sirlekh, atOrderId: 100)
        XCTAssertEqual(refFarAfter?.id, "PA")
    }

    func test_returnsNilWhenSirlekhListIsEmpty() {
        XCTAssertNil(Line.nearestSectionHeader(from: [], atOrderId: 5))
    }

    func test_returnsNilWhenReferencePrecedesEverySirlekh() {
        // Reference orderId of 5 precedes both sirlekh at 10 and 20.
        let sirlekh = [
            line("SL", orderId: 10, type: "Sirlekh"),
            line("PA", orderId: 20, type: "Sirlekh"),
        ]
        XCTAssertNil(Line.nearestSectionHeader(from: sirlekh, atOrderId: 5))
    }

    /// Brief #9.23d: Japji-mirror case. BaniDB stores Japji Sahib as:
    ///   - orderId 1, Manglacharan "<> siq nwmu..." (Mool Mantar)
    ///   - orderId 2, Sirlekh "] jpu ]" ("|| ਜਪੁ ||")
    ///   - orderId 3, Pankti "Awid scu..." ("ਆਦਿ ਸਚੁ")
    /// The sirlekh sits BETWEEN Mool Mantar and Aad Sach, not before
    /// Mool Mantar. `nearestSectionHeader` walking backward from Mool
    /// Mantar (orderId 1) must return nil — otherwise the display
    /// renders "|| ਜਪੁ ||" above Mool Mantar, which is visually and
    /// convention-wise wrong (Japji Sahib traditionally opens with
    /// Mool Mantar; the ਜਪੁ sirlekh is a mid-shabad marker). Walking
    /// backward from Aad Sach (orderId 3) correctly returns the
    /// sirlekh.
    func test_japjiSahibSectionHeaderPositioning() {
        let sirlekh = line("JAP", orderId: 2, type: "Sirlekh", gurmukhi: "] jpu ]")

        // Mool Mantar (orderId 1) → nothing legitimately precedes it,
        // even though the sirlekh has a higher orderId in the corpus.
        let atMoolMantar = Line.nearestSectionHeader(from: [sirlekh], atOrderId: 1)
        XCTAssertNil(atMoolMantar, "No sirlekh should render above Mool Mantar (Japji orderId 1)")

        // Aad Sach (orderId 3) → the "|| ਜਪੁ ||" sirlekh is genuinely
        // behind us in the shabad and should render as the section
        // header.
        let atAadSach = Line.nearestSectionHeader(from: [sirlekh], atOrderId: 3)
        XCTAssertEqual(atAadSach?.id, "JAP", "|| ਜਪੁ || should render as section header from Aad Sach onward")
    }

    /// Brief #9.23d: `<` strictness — a candidate at the same orderId
    /// as the reference is NOT considered "behind us". Unique orderIds
    /// in the real corpus make this edge case rare, but the change
    /// from `<=` to `<` needs an explicit regression guard.
    func test_strictLessThanExcludesEqualOrderId() {
        let sirlekh = [
            line("SL", orderId: 10, type: "Sirlekh"),
        ]
        // refOrderId equal to candidate → excluded.
        XCTAssertNil(Line.nearestSectionHeader(from: sirlekh, atOrderId: 10))
        // refOrderId one past → included.
        XCTAssertEqual(Line.nearestSectionHeader(from: sirlekh, atOrderId: 11)?.id, "SL")
    }
}
