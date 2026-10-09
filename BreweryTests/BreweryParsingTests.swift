import XCTest
@testable import Brewery

@MainActor
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

    func testDecodedMultiKegSnapshotSelectsLinkedVersionAndItsInstallDate() throws {
        // Reduced from native-snapshot-03.json (2026-10-03 real disposable-prefix QA).
        // Homebrew retains the old keg first after a successful 1.0 -> 2.0 upgrade.
        for row in [
            (name: "qa-batch", oldTime: 1_791_012_386.0, linkedTime: 1_791_012_655.0),
            (name: "qa-formula", oldTime: 1_791_012_381.0, linkedTime: 1_791_012_658.0)
        ] {
            let formula = try decodeFormula(
                name: row.name,
                installed: [("1.0", row.oldTime), ("2.0", row.linkedTime)],
                linkedKeg: "2.0"
            )

            XCTAssertEqual(formula.cur_version, "2.0", row.name)
            XCTAssertEqual(formula.installed_date, row.linkedTime, row.name)
        }
    }

    func testDecodedLinkedKegTakesPrecedenceOverMoreRecentlyInstalledVersion() throws {
        let formula = try decodeFormula(
            installed: [("2.0", 300), ("1.0", 100)],
            linkedKeg: "1.0"
        )

        XCTAssertEqual(formula.cur_version, "1.0")
        XCTAssertEqual(formula.installed_date, 100)
    }

    func testDecodedUnlinkedKegOnlyFormulaUsesNewestInstallInsteadOfStableOrArrayOrder() throws {
        // A null linked_keg and an omitted linked_keg both occur without an active link.
        for includeLinkedKeg in [true, false] {
            let formula = try decodeFormula(
                installed: [("1.0", 100), ("2.0", 300), ("3.0", 200)],
                linkedKeg: nil,
                includeLinkedKeg: includeLinkedKeg,
                stableVersion: "3.0",
                kegOnly: true
            )

            XCTAssertEqual(formula.cur_version, "2.0", "linked_keg present: \(includeLinkedKeg)")
            XCTAssertEqual(formula.installed_date, 300, "linked_keg present: \(includeLinkedKeg)")
            XCTAssertEqual(formula.latest_version, "3.0")
        }
    }

    func testDecodedDanglingLinkedKegFallsBackToNewestInstalledTime() throws {
        let formula = try decodeFormula(
            installed: [("1.0", 100), ("2.0", 300), ("3.0", 200)],
            linkedKeg: "missing-keg",
            stableVersion: "3.0"
        )

        XCTAssertEqual(formula.cur_version, "2.0")
        XCTAssertEqual(formula.installed_date, 300)
    }

    func testDecodedLinkedKegWithUnknownInstallTimeKeepsItsVersionAndNilDate() throws {
        let formula = try decodeFormula(
            installed: [("2.0", 300), ("1.0", nil)],
            linkedKeg: "1.0"
        )

        XCTAssertEqual(formula.cur_version, "1.0")
        XCTAssertNil(formula.installed_date)
    }

    func testDecodedUnlinkedKegPrefersNewestKnownTimeOverUnknownTimes() throws {
        let formula = try decodeFormula(
            installed: [("1.0", nil), ("2.0", 300), ("3.0", nil), ("4.0", 100)],
            linkedKeg: nil,
            stableVersion: "4.0"
        )

        XCTAssertEqual(formula.cur_version, "2.0")
        XCTAssertEqual(formula.installed_date, 300)
    }

    func testDecodedTimestampTiesUseLastKegInHomebrewOrderIncludingAllUnknownTimes() throws {
        let cases: [(installed: [(version: String, time: Double?)], version: String, time: Double?)] = [
            ([("1.0", 300), ("2.0", 300), ("3.0", 100)], "2.0", 300),
            ([("1.0", nil), ("2.0", nil), ("3.0", nil)], "3.0", nil)
        ]
        for row in cases {
            let formula = try decodeFormula(installed: row.installed, linkedKeg: nil)

            XCTAssertEqual(formula.cur_version, row.version)
            XCTAssertEqual(formula.installed_date, row.time)
        }
    }

    func testDecodedEmptyInstalledArrayKeepsUnknownVersionAndNilDate() throws {
        let formula = try decodeFormula(installed: [], linkedKeg: nil)

        XCTAssertEqual(formula.cur_version, "unknown")
        XCTAssertNil(formula.installed_date)
    }

    private func decodeFormula(
        name: String = "qa-formula",
        installed: [(version: String, time: Double?)],
        linkedKeg: String?,
        includeLinkedKeg: Bool = true,
        stableVersion: String = "2.0",
        kegOnly: Bool = false
    ) throws -> BreweryFormula {
        var json: [String: Any] = [
            "name": name,
            "full_name": "brewery/qa/" + name,
            "tap": "brewery/qa",
            "desc": "Disposable Brewery integration fixture",
            "homepage": "https://example.invalid/brewery-qa",
            "license": "MIT",
            "outdated": false,
            "dependencies": [],
            "installed": installed.map { ["version": $0.version, "time": $0.time.map { $0 as Any } ?? NSNull()] },
            "versions": ["stable": stableVersion, "head": NSNull(), "bottle": false],
            "keg_only": kegOnly
        ]
        if includeLinkedKeg {
            json["linked_keg"] = linkedKeg.map { $0 as Any } ?? NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(BreweryFormula.self, from: data)
    }

    func testValidatedHTTPURLAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(validatedHTTPURL(from: "https://brew.sh")?.absoluteString, "https://brew.sh")
        XCTAssertEqual(validatedHTTPURL(from: "http://example.com")?.absoluteString, "http://example.com")
        XCTAssertNil(validatedHTTPURL(from: ""))
        XCTAssertNil(validatedHTTPURL(from: "not a url"))
        XCTAssertNil(validatedHTTPURL(from: "file:///etc/passwd"))
    }
}

@MainActor
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
