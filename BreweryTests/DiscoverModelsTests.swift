import XCTest
@testable import Brewery

final class DiscoverModelsTests: XCTestCase {
    func testDecodesFormulaCatalog() throws {
        let data = Data(#"[{"name":"git","desc":"Version control","homepage":"https://git-scm.com","versions":{"stable":"2.51.0"}}]"#.utf8)
        XCTAssertEqual(try HomebrewPayloadDecoder.decodeFormulaCatalog(data), [CatalogPackage(id: .formula("git"), name: "git", kind: .formula, description: "Version control", homepage: URL(string: "https://git-scm.com"), latestVersion: "2.51.0")])
    }

    func testDecodesCommaSeparatedFormulaAndCaskCounts() throws {
        let formulaData = Data(#"{"items":[{"number":1,"formula":"gh","count":"266,351","percent":"3.12"}]}"#.utf8)
        let caskData = Data(#"{"formulae":{"firefox":[{"cask":"firefox","count":"12,345"}],"orphan":[]}}"#.utf8)
        XCTAssertEqual(try HomebrewPayloadDecoder.decodeFormulaRankings(formulaData), [PackageRanking(packageID: .formula("gh"), installs: 266_351, rank: 1)])
        XCTAssertEqual(try HomebrewPayloadDecoder.decodeCaskRankings(caskData), [PackageRanking(packageID: .cask("firefox"), installs: 12_345, rank: 1)])
    }
}
