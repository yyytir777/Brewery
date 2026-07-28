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

final class BreweryMetadataTests: XCTestCase {
    func testParseVersionUsesFirstNonEmptyLine() {
        let output = "\nHomebrew 4.5.0\nHomebrew/homebrew-core abc123\n"

        XCTAssertEqual(BreweryMetadata.parseVersion(from: output), "Homebrew 4.5.0")
    }

    func testParseSizeUsesLastCommaSeparatedComponentWhenPresent() {
        let output = "Homebrew 4.5.0 (/opt/homebrew)\n24 files, 74.3MB\n"

        XCTAssertEqual(BreweryMetadata.parseSize(from: output), "74.3MB")
    }

    func testParseSizeReturnsUnknownForEmptyOutput() {
        XCTAssertEqual(BreweryMetadata.parseSize(from: ""), "unknown")
    }

    func testOutdatedResultDecodesFormulaeAndCasks() throws {
        let json = """
        {
          "formulae": [
            { "name": "git", "installed_versions": ["2.1.0"], "current_version": "2.2.0", "pinned": false, "pinned_version": null }
          ],
          "casks": [
            { "name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0" }
          ]
        }
        """

        let result = try JSONDecoder().decode(BrewOutdatedResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.formulae.map(\.name), ["git"])
        XCTAssertEqual(result.casks.map(\.name), ["firefox"])
    }
}

@MainActor
final class BreweryViewModelOutdatedTests: XCTestCase {
    func testLoadOutdatedPackagesAcceptsValidJsonFromNonZeroExitCode() async {
        let json = """
        {
          "formulae": [
            { "name": "git", "installed_versions": ["2.1.0"], "current_version": "2.2.0", "pinned": false, "pinned_version": null }
          ],
          "casks": [
            { "name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0" }
          ]
        }
        """
        let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
            BreweryCommandResult(arguments: arguments, stdout: json, stderr: "", exitCode: 1)
        }

        await vm.loadOutdatedPackages()

        XCTAssertTrue(vm.isOutdated(.formula("git")))
        XCTAssertTrue(vm.isOutdated(.cask("firefox")))
        XCTAssertNil(vm.lastCommandError)
    }

    func testLoadOutdatedPackagesRetainsPreviousStateWhenJsonParseFails() async {
        var responses = [
            BreweryCommandResult(
                arguments: ["outdated", "--json=v2"],
                stdout: """
                {
                  "formulae": [
                    { "name": "git", "installed_versions": ["2.1.0"], "current_version": "2.2.0", "pinned": false, "pinned_version": null }
                  ],
                  "casks": []
                }
                """,
                stderr: "",
                exitCode: 0
            ),
            BreweryCommandResult(
                arguments: ["outdated", "--json=v2"],
                stdout: "{ malformed json",
                stderr: "",
                exitCode: 0
            )
        ]
        let vm = BreweryViewModel(loadOnInit: false) { _, _ in
            responses.removeFirst()
        }

        await vm.loadOutdatedPackages()
        await vm.loadOutdatedPackages()

        XCTAssertTrue(vm.isOutdated(.formula("git")))
        XCTAssertFalse(vm.isOutdated(.cask("firefox")))
        XCTAssertTrue(vm.commandErrorMessage.contains("Failed to parse Homebrew outdated package data"))
    }

    func testLoadOutdatedPackagesRecordsCommandFailureWhenNoJsonIsReturned() async {
        let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
            BreweryCommandResult(
                arguments: arguments,
                stdout: "",
                stderr: "Error: Homebrew is temporarily unavailable.",
                exitCode: 1
            )
        }

        await vm.loadOutdatedPackages()

        XCTAssertEqual(
            vm.commandErrorMessage,
            "brew outdated --json=v2 failed with exit code 1.\n\nError: Homebrew is temporarily unavailable."
        )
    }
}
