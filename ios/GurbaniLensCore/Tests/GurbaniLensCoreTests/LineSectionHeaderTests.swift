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
}
