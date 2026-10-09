import XCTest
@testable import Brewery

#if DEBUG
@MainActor
final class BreweryUITestFixtureTests: XCTestCase {
    func testLaunchArgumentsRequireOneKnownScenarioAndRejectMalformedRequests() {
        XCTAssertNil(BreweryUITestScenario.configuration(arguments: ["Brewery"]))
        XCTAssertNil(BreweryUITestScenario.configuration(arguments: ["Brewery", "-NSDocumentRevisionsDebugMode", "YES"]))
        for scenario in BreweryUITestScenario.allCases {
            XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery", "--brewery-ui-testing", scenario.rawValue]), .scenario(scenario))
        }
        for suffix in [
            ["--brewery-ui-testing"],
            ["--brewery-ui-testing", "unknown"],
            ["--brewery-ui-testing=standard"],
            ["--brewery-ui-testing-typo", "standard"],
            ["--unknown", "--brewery-ui-testing", "standard"],
            ["--brewery-ui-testing", "standard", "extra"],
            ["--brewery-ui-testing", "standard", "--brewery-ui-testing", "offline"]
        ] {
            guard case .invalid = BreweryUITestScenario.configuration(arguments: ["Brewery"] + suffix) else {
                XCTFail("Malformed fixture request must stay isolated: \(suffix)")
                continue
            }
        }
    }

    func testUnitTestHostUsesFixtureButCannotHideInvalidExplicitScenario() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/fixture-tests.xctestconfiguration"]
        XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery"], environment: environment), .scenario(.standard))
        XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery", "--brewery-ui-testing", "offline"], environment: environment), .scenario(.offline))
        guard case .invalid = BreweryUITestScenario.configuration(arguments: ["Brewery", "--brewery-ui-testing", "typo"], environment: environment) else {
            return XCTFail("An invalid explicit request must not be hidden by the unit-test host fallback")
        }
    }

    func testBundledScenarioSelectsFixtureBeforeUnitHostFallback() {
        for scenario in BreweryUITestScenario.allCases {
            let bundleInfo: [String: Any] = ["BreweryUITestScenario": scenario.rawValue]
            XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery"], bundleInfo: bundleInfo), .scenario(scenario))
            XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery"], environment: ["XCTestConfigurationFilePath": "/tmp/tests"], bundleInfo: bundleInfo), .scenario(scenario))
        }
        XCTAssertNil(BreweryUITestScenario.configuration(arguments: ["Brewery"], bundleInfo: ["CFBundleIdentifier": "example.brewery"]))
    }

    func testInvalidBundledScenarioFailsClosedIncludingNonStringValues() {
        for value: Any in ["unknown", "", 1, true, NSNull(), ["standard"], ["scenario": "standard"]] {
            for environment in [[:], ["XCTestConfigurationFilePath": "/tmp/tests"]] {
                guard case .invalid = BreweryUITestScenario.configuration(arguments: ["Brewery"], environment: environment, bundleInfo: ["BreweryUITestScenario": value]) else {
                    XCTFail("An invalid bundled scenario must stay isolated: \(value)")
                    continue
                }
            }
        }
    }

    func testExplicitScenarioOverridesBundleButInvalidExplicitRequestStillFailsClosed() {
        for value: Any in ["offline", "unknown", 1] {
            XCTAssertEqual(BreweryUITestScenario.configuration(arguments: ["Brewery", "--brewery-ui-testing", "standard"], bundleInfo: ["BreweryUITestScenario": value]), .scenario(.standard))
        }
        guard case .invalid = BreweryUITestScenario.configuration(arguments: ["Brewery", "--brewery-ui-testing", "unknown"], bundleInfo: ["BreweryUITestScenario": "standard"]) else {
            return XCTFail("A valid bundled fixture must not hide an invalid explicit request")
        }
    }

    func testStandardFixtureFeedsInventoryOutdatedMetadataAndDependencyGraph() async throws {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        XCTAssertEqual(vm.installedPackageIDs, [.formula("git"), .formula("gettext"), .cask("qa-app")])
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "1.0")
        XCTAssertEqual(vm.formula(for: .formula("git"))?.latest_version, "2.0")
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.cur_version, "1.0")
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.latest_version, "2.0")
        XCTAssertEqual(vm.outdatedFormulaNames, ["git"])
        XCTAssertEqual(vm.outdatedCaskNames, ["qa-app"])
        XCTAssertTrue(vm.hasLoadedInventory)
        XCTAssertTrue(vm.hasLoadedOutdated)
        XCTAssertEqual(vm.isHomebrewAvailable, true)
        XCTAssertFalse(vm.brewVersion.isEmpty)
        XCTAssertFalse(vm.brewSize.isEmpty)
        let root = try await vm.resolveFormulaForDependencyGraph(name: "git")
        XCTAssertEqual(root.dependencies, ["gettext"])
        let child = try await vm.resolveFormulaForDependencyGraph(name: "gettext")
        XCTAssertTrue(child.dependencies.isEmpty)
        XCTAssertNil(vm.lastCommandError)
    }

    func testCatalogRanksKnownPackagesAndSearchFindsUninstalledFormula() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        let discover = DiscoverViewModel(service: fixture)
        await discover.load()
        let rows = discover.rows(installedIDs: [.formula("git"), .formula("gettext"), .cask("qa-app")])
        XCTAssertEqual(rows.map(\.id), [.formula("git"), .formula("jq"), .cask("qa-app"), .formula("gettext")])
        XCTAssertEqual(rows.map(\.rank), [1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.isInstalled), [true, false, true, true])
        discover.query = "jq"
        XCTAssertEqual(discover.rows(installedIDs: []).map(\.id), [.formula("jq")])
        await discover.changeWindow(to: .days365)
        XCTAssertNil(discover.refreshMessage)
        XCTAssertEqual(discover.rows(installedIDs: []).first?.rank, 2)
    }

    func testSuccessfulFormulaMutationsChangeInventoryAndOutdatedState() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        await vm.installFormula(name: "jq")
        XCTAssertEqual(vm.formula(for: .formula("jq"))?.cur_version, "1.0")
        await vm.updateBrew(name: "git")
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "2.0")
        XCTAssertFalse(vm.isOutdated(.formula("git")))
        await vm.uninstallFormula(name: "jq")
        XCTAssertNil(vm.formula(for: .formula("jq")))
        XCTAssertEqual(vm.operations.map(\.status), [.succeeded, .succeeded, .succeeded])
    }

    func testSuccessfulCaskMutationsChangeInventoryAndOutdatedState() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        await vm.updateBrew(name: "qa-app", isCask: true)
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.cur_version, "2.0")
        XCTAssertFalse(vm.isOutdated(.cask("qa-app")))
        await vm.uninstallCaskWithZap(name: "qa-app")
        XCTAssertNil(vm.cask(for: .cask("qa-app")))
        await vm.installCask(name: "qa-app")
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.cur_version, "2.0")
        await vm.uninstallCask(name: "qa-app")
        XCTAssertNil(vm.cask(for: .cask("qa-app")))
        XCTAssertTrue(vm.operations.allSatisfy { $0.status == .succeeded })
    }

    func testMaintenanceAndTextInfoStayInsideFixture() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        let info = await vm.fetchInfo(name: "git")
        XCTAssertTrue(info.contains("git"))
        await vm.previewCleanup()
        XCTAssertTrue(vm.cleanupPreview?.output.contains("Would remove") == true)
        XCTAssertTrue(vm.operations.isEmpty)
        await vm.brewCleanUp()
        XCTAssertNotNil(vm.cleanupMessage)
        await vm.brewSelfUpdate()
        XCTAssertEqual(vm.isLatestAfterUpdate, true)
        XCTAssertEqual(vm.operations.map(\.status), [.succeeded, .succeeded])
    }

    func testMissingHomebrewFailsFirstLoadThenRetryRecovers() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.missingHomebrew))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        XCTAssertEqual(vm.isHomebrewAvailable, false)
        XCTAssertEqual(vm.lastCommandError?.exitCode, 127)
        XCTAssertTrue(vm.installedPackageIDs.isEmpty)
        vm.clearCommandError()
        await vm.loadInstalled()
        XCTAssertEqual(vm.isHomebrewAvailable, true)
        XCTAssertEqual(vm.installedPackageIDs.count, 3)
        XCTAssertNil(vm.inventoryError)
        XCTAssertNil(vm.lastCommandError)
    }

    func testInfoFailureCanRetryWithoutInstallingPackage() async throws {
        let fixture = BreweryUITestFixture(configuration: .scenario(.infoFailure))
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        do {
            _ = try await vm.packageInfo(for: .formula("jq"))
            XCTFail("First jq detail load should fail")
        } catch {
            XCTAssertNil(vm.lastCommandError)
        }
        let info = try await vm.packageInfo(for: .formula("jq"))
        XCTAssertEqual(info.formula?.name, "jq")
        XCTAssertTrue(info.formula?.installed.isEmpty == true)
        XCTAssertFalse(vm.installedPackageIDs.contains(.formula("jq")))
        XCTAssertNil(vm.lastCommandError)
    }

    func testOfflineCatalogRetainsLocalRowsAcrossRefreshFailure() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.offline))
        let discover = DiscoverViewModel(service: fixture)
        await discover.load()
        XCTAssertEqual(discover.rows(installedIDs: []).count, 4)
        XCTAssertNil(discover.blockingError)
        XCTAssertTrue(discover.refreshMessage?.contains("Offline UI fixture attempt 1") == true)
        await discover.refresh(force: true)
        XCTAssertEqual(discover.rows(installedIDs: []).map(\.id), [.formula("git"), .formula("jq"), .cask("qa-app"), .formula("gettext")])
        XCTAssertTrue(discover.refreshMessage?.contains("Offline UI fixture attempt 2") == true)
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        XCTAssertEqual(vm.installedPackageIDs.count, 3)
    }

    func testUnknownAndMalformedCommandsFailWithoutChangingInventory() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.standard))
        for args in [
            [], ["shell"], ["install", "git"], ["install", "--formula", "unknown"],
            ["install", "--cask", "git"], ["uninstall", "--formula", "--zap", "git"],
            ["upgrade", "--formula", "git", "--force"], ["cleanup", "--prune=all"],
            ["info", "--json=v2", "--formula", "unknown"], ["info", "--json=v2", "--installed", "extra"]
        ] {
            let result = await fixture.run(args, false)
            XCTAssertFalse(result.succeeded, "Unsupported fixture command must fail: \(args)")
            XCTAssertFalse(result.stderr.isEmpty)
        }
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        XCTAssertEqual(vm.installedPackageIDs, [.formula("git"), .formula("gettext"), .cask("qa-app")])
        XCTAssertEqual(vm.outdatedCount, 2)
    }

    func testInvalidConfigurationCannotReadCatalogOrRunCommands() async {
        let fixture = BreweryUITestFixture(configuration: .invalid("Unknown UI test scenario"))
        XCTAssertNotNil(fixture.configurationError)
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        XCTAssertFalse(vm.hasLoadedInventory)
        XCTAssertNotNil(vm.lastCommandError)
        let discover = DiscoverViewModel(service: fixture)
        await discover.load()
        XCTAssertNotNil(discover.blockingError)
        XCTAssertTrue(discover.rows(installedIDs: []).isEmpty)
        let mutation = await fixture.run(["install", "--formula", "jq"], true)
        XCTAssertFalse(mutation.succeeded)
    }

    func testQueueScenarioAllowsCancellationBeforeSecondMutation() async {
        var release: CheckedContinuation<Void, Never>?
        let fixture = BreweryUITestFixture(configuration: .scenario(.queue), waitForFirstMutation: {
            await withCheckedContinuation { release = $0 }
        })
        let vm = viewModel(fixture)
        await vm.loadInstalled()
        let first = Task { await vm.updateBrew(name: "git") }
        for _ in 0..<1_000 { if release != nil { break }; await Task.yield() }
        guard let release else { XCTFail("First fixture mutation never started"); first.cancel(); return }
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "1.0")
        let second = Task { await vm.updateBrew(name: "qa-app", isCask: true) }
        for _ in 0..<1_000 { if vm.operations.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(vm.operations.map(\.status), [.running, .queued])
        if let queued = vm.operations.first(where: { $0.status == .queued }) { vm.cancelQueuedOperation(queued.id) }
        release.resume()
        await first.value
        await second.value
        XCTAssertEqual(vm.operations.map(\.status), [.succeeded, .cancelled])
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "2.0")
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.cur_version, "1.0")
        XCTAssertTrue(vm.isOutdated(.cask("qa-app")))
    }

    func testDefaultQueueGateRequiresExplicitCompletionAndGatesOnlyFirstMutation() async {
        let fixture = BreweryUITestFixture(configuration: .scenario(.queue))
        let vm = viewModel(fixture)
        // Clicking before an operation starts must not give a future operation permission to finish.
        fixture.completeFirstMutation()
        let finished = expectation(description: "First mutation completed after explicit release")
        var didComplete = false
        let operation = Task {
            let result = await fixture.run(["upgrade", "--formula", "git"], true)
            didComplete = true
            finished.fulfill()
            return result
        }
        for _ in 0..<1_000 { if fixture.isWaitingForFirstMutation { break }; await Task.yield() }
        XCTAssertTrue(fixture.isWaitingForFirstMutation)
        XCTAssertFalse(didComplete)
        await vm.loadInstalled()
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "1.0")
        fixture.completeFirstMutation()
        await fulfillment(of: [finished], timeout: 1)
        if !didComplete { fixture.completeFirstMutation(); operation.cancel() }
        let result = await operation.value
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(fixture.isWaitingForFirstMutation)
        fixture.completeFirstMutation() // A second click must not resume an already consumed continuation.
        await vm.loadInstalled()
        XCTAssertEqual(vm.formula(for: .formula("git"))?.cur_version, "2.0")
        let nextResult = await fixture.run(["upgrade", "--cask", "qa-app"], true)
        XCTAssertTrue(nextResult.succeeded)
        XCTAssertFalse(fixture.isWaitingForFirstMutation)
        await vm.loadInstalled()
        XCTAssertEqual(vm.cask(for: .cask("qa-app"))?.cur_version, "2.0")
    }

    private func viewModel(_ fixture: BreweryUITestFixture) -> BreweryViewModel {
        BreweryViewModel(loadOnInit: false, commandRunner: { await fixture.run($0, $1) })
    }
}
#endif
