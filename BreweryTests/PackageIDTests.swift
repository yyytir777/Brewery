import XCTest
@testable import Brewery

final class PackageIDTests: XCTestCase {
    func testFormulaAndCaskWithSameNameHaveDifferentIdentity() {
        let formula = PackageID.formula("foo")
        let cask = PackageID.cask("foo")

        XCTAssertNotEqual(formula, cask)
        XCTAssertEqual(formula.id, "formula:foo")
        XCTAssertEqual(cask.id, "cask:foo")
    }

    func testSearchResultExposesTypedPackageID() {
        let formulaResult = SearchResult(name: "git", isCask: false)
        let caskResult = SearchResult(name: "firefox", isCask: true)

        XCTAssertEqual(formulaResult.packageID, .formula("git"))
        XCTAssertEqual(caskResult.packageID, .cask("firefox"))
    }
}
