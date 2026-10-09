import Foundation
@testable import Brewery

func makeFormula(_ name: String, dependencies: [String] = [], fullName: String? = nil) -> BreweryFormula {
    BreweryFormula(
        name: name,
        full_name: fullName ?? name,
        tap: "homebrew/core",
        desc: nil,
        homepage: "https://example.com/\(name)",
        license: nil,
        outdated: false,
        dependencies: dependencies,
        installed: [FormulaInstalled(version: "1.0", time: 0)],
        versions: FormulaVersions(stable: "1.0", head: nil, bottle: true)
    )
}
