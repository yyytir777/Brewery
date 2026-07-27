import XCTest
@testable import Brewery

final class BreweryParsingTests: XCTestCase {
    func testFormulaInstalledDateIsNilWhenInstalledArrayIsEmpty() {
        let formula = BreweryFormula(
            name: "empty",
            full_name: "empty",
            tap: "homebrew/core",
            desc: nil,
            homepage: "https://example.com",
            license: nil,
            outdated: false,
            dependencies: [],
            installed: [],
            versions: FormulaVersions(stable: "1.0.0", head: nil, bottle: nil)
        )

        XCTAssertNil(formula.installed_date)
    }

    func testValidatedHTTPURLAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(validatedHTTPURL(from: "https://brew.sh")?.absoluteString, "https://brew.sh")
        XCTAssertEqual(validatedHTTPURL(from: "http://example.com")?.absoluteString, "http://example.com")
        XCTAssertNil(validatedHTTPURL(from: ""))
        XCTAssertNil(validatedHTTPURL(from: "not a url"))
        XCTAssertNil(validatedHTTPURL(from: "file:///etc/passwd"))
    }
}
