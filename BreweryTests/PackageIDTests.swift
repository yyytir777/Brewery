import XCTest
@testable import Brewery

@MainActor
final class PackageIDTests: XCTestCase {
    func testFormulaAndCaskWithSameNameHaveDifferentIdentity() {
        let formula = PackageID.formula("foo")
        let cask = PackageID.cask("foo")

        XCTAssertNotEqual(formula, cask)
        XCTAssertEqual(formula.id, "formula:foo")
        XCTAssertEqual(cask.id, "cask:foo")
    }

}
