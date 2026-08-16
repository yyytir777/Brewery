import XCTest
@testable import Brewery

final class PackageIdentityTests: XCTestCase {
    func testFormulaAndCaskWithSameNameDoNotCollide() {
        XCTAssertNotEqual(PackageID.formula("foo"), PackageID.cask("foo"))
        XCTAssertEqual(PackageID.formula("foo").id, "formula:foo")
        XCTAssertEqual(PackageID.cask("foo").id, "cask:foo")
    }

    func testSingleValueCodableUsesStableKindNameKey() throws {
        let encoded = try JSONEncoder().encode(PackageID.cask("firefox"))

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"cask:firefox\"")
        XCTAssertEqual(
            try JSONDecoder().decode(PackageID.self, from: encoded),
            .cask("firefox")
        )
    }
}
