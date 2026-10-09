import XCTest
@testable import Brewery

@MainActor
final class InventoryOperationTests: XCTestCase {
    func testAppRelaunchReservationRejectsNewMutationsAndReopensAfterAbort() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            Self.result(args, #"{"formulae":[],"casks":[]}"#)
        }
        vm.isPreparingAppUpdate = true
        await vm.installFormula(name: "tool")
        await vm.brewSelfUpdate()
        await vm.brewCleanUp()
        XCTAssertTrue(vm.operations.isEmpty, "Once relaunch is reserved, no new mutations may enter the queue")
        vm.isPreparingAppUpdate = false
        await vm.installFormula(name: "tool")
        XCTAssertEqual(vm.operations.count, 1, "Aborting the app update must restore package operations")
    }

    func testExecutableChangeRejectsLateOutdatedResultFromOldInstallation() async {
        var oldResult: CheckedContinuation<Void, Never>?
        var outdatedCalls = 0
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if args.first == "outdated" {
                outdatedCalls += 1
                if outdatedCalls == 1 {
                    await withCheckedContinuation { oldResult = $0 }
                    return Self.result(args, #"{"formulae":[{"name":"old-install"}],"casks":[]}"#)
                }
                return Self.result(args, #"{"formulae":[],"casks":[]}"#)
            }
            return Self.result(args, Self.inventory())
        }
        let oldCheck = Task { await vm.loadOutdatedPackages() }
        while oldResult == nil { await Task.yield() }
        await vm.reloadForExecutableChange()
        XCTAssertEqual(vm.outdatedCount, 0)
        oldResult?.resume()
        await oldCheck.value
        XCTAssertEqual(vm.outdatedCount, 0, "A late result from the old executable must not mark new packages outdated")
        XCTAssertTrue(vm.hasLoadedOutdated)
    }

    func testTappedFormulaUsesQualifiedIdentityForLookupAndOutdatedState() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            let output = args.first == "outdated"
                ? #"{"formulae":[{"name":"acme/tools/tool"}],"casks":[]}"#
                : Self.inventory(name: "tool", fullName: "acme/tools/tool")
            return Self.result(args, output)
        }
        await vm.loadAllBrew()
        await vm.loadOutdatedPackages()
        XCTAssertNotNil(vm.formula(for: .formula("acme/tools/tool")))
        XCTAssertEqual(vm.installedPackageIDs, [.formula("acme/tools/tool")])
        XCTAssertTrue(vm.isOutdated(.formula("acme/tools/tool")))
    }

    func testMalformedInventoryKeepsLastSuccessAndReportsError() async {
        var output = Self.inventory()
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in Self.result(args, output) }
        await vm.loadAllBrew()
        output = "{ broken"
        await vm.loadAllBrew()
        XCTAssertEqual(vm.installedFormula.map(\.name), ["tool"])
        XCTAssertNotNil(vm.lastCommandError)
    }

    func testFailedInventoryCommandCannotReplaceLastSuccess() async {
        var shouldFail = false
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            Self.result(args, shouldFail ? #"{"formulae":[],"casks":[]}"# : Self.inventory(), exit: shouldFail ? 1 : 0)
        }
        await vm.loadAllBrew()
        shouldFail = true
        await vm.loadAllBrew()
        XCTAssertEqual(vm.installedFormula.map(\.name), ["tool"])
        XCTAssertNotNil(vm.lastCommandError)
    }

    func testMalformedPackageInfoReturnsNoValueWithoutPresentingGlobalAlert() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in Self.result(args, "bad json") }
        let value = await vm.fetchPackageInfo(name: "tool", isCask: false)
        XCTAssertNil(value.formula)
        XCTAssertNil(vm.lastCommandError)
    }

    func testDuplicateInstallOnlyRunsOneMutation() async {
        var installCalls = 0
        var finish: CheckedContinuation<Void, Never>?
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if args.first == "install" {
                installCalls += 1
                if installCalls == 1 { await withCheckedContinuation { finish = $0 } }
            }
            return Self.result(args, #"{"formulae":[],"casks":[]}"#)
        }
        let first = Task { await vm.installFormula(name: "tool") }
        while finish == nil { await Task.yield() }
        await vm.installFormula(name: "tool")
        XCTAssertEqual(installCalls, 1)
        finish?.resume()
        await first.value
        XCTAssertTrue(vm.installingPackageIDs.isEmpty)
    }

    func testFormulaUpgradeUsesExplicitKindAndQualifiedName() async {
        var upgradeArgs: [String] = []
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if args.first == "upgrade" { upgradeArgs = args }
            return Self.result(args, #"{"formulae":[],"casks":[]}"#)
        }
        await vm.updateBrew(name: "acme/tools/tool")
        XCTAssertEqual(upgradeArgs, ["upgrade", "--formula", "acme/tools/tool"])
    }

    func testCatalogNameDoesNotResolveDifferentTapPackage() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in Self.result(args, Self.inventory(name: "tool", fullName: "acme/tools/tool")) }
        await vm.loadAllBrew()
        XCTAssertNil(vm.formula(for: .formula("tool")))
        XCTAssertNotNil(vm.formula(for: .formula("acme/tools/tool")))
    }

    func testMissingHomebrewPreventsMutation() async {
        var mutations = 0
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if args.first == "install" { mutations += 1 }
            return Self.result(args, "", exit: 127)
        }
        await vm.loadAllBrew()
        await vm.installFormula(name: "tool")
        XCTAssertEqual(vm.isHomebrewAvailable, false)
        XCTAssertFalse(vm.hasLoadedInventory)
        XCTAssertEqual(mutations, 0)
    }

    func testDifferentPackageWaitsAndCanBeCancelledBeforeItRuns() async {
        var mutations: [[String]] = []
        var finish: CheckedContinuation<Void, Never>?
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if ["install", "upgrade"].contains(args.first ?? "") {
                mutations.append(args)
                if mutations.count == 1 { await withCheckedContinuation { finish = $0 } }
            }
            return Self.result(args, #"{"formulae":[],"casks":[]}"#)
        }
        let first = Task { await vm.installFormula(name: "one") }
        while finish == nil { await Task.yield() }
        let second = Task { await vm.updateBrew(name: "two") }
        for _ in 0..<100 { if vm.operations.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(mutations.count, 1)
        let queued = vm.operations.first { $0.status == .queued }
        XCTAssertNotNil(queued)
        if let queued { vm.cancelQueuedOperation(queued.id) }
        finish?.resume()
        await first.value
        await second.value
        XCTAssertEqual(mutations.count, 1)
        XCTAssertFalse(vm.hasPendingOperations)
        XCTAssertEqual(vm.operations.map(\.status), [.succeeded, .cancelled])
    }

    func testFailedMutationKeepsInventoryAndClearsProgress() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            Self.result(args, args.first == "uninstall" ? "" : Self.inventory(), exit: args.first == "uninstall" ? 1 : 0)
        }
        await vm.loadAllBrew()
        await vm.uninstallFormula(name: "tool")
        XCTAssertNotNil(vm.formula(for: .formula("tool")))
        XCTAssertFalse(vm.isOperating(.formula("tool")))
        XCTAssertEqual(vm.operations.last?.status, .failed)
        XCTAssertNotNil(vm.lastCommandError)
    }

    func testCleanupPreviewDoesNotRunDeletionAndSuccessRefreshesSize() async {
        var commands: [[String]] = []
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            commands.append(args)
            if args == ["cleanup", "--dry-run"] { return Self.result(args, "Would remove: old.tar.gz (1MB)\nWould free 1MB") }
            if args == ["info"] { return Self.result(args, "1 files, 2MB") }
            return Self.result(args, #"{"formulae":[],"casks":[]}"#)
        }
        await vm.previewCleanup()
        XCTAssertEqual(commands, [["cleanup", "--dry-run"]])
        XCTAssertTrue(vm.cleanupPreview?.output.contains("old.tar.gz") == true)
        await vm.brewCleanUp()
        XCTAssertEqual(vm.brewSize, "2MB")
        XCTAssertTrue(commands.contains(["cleanup"]))
    }

    static func result(_ args: [String], _ stdout: String, exit: Int32 = 0) -> BreweryCommandResult {
        BreweryCommandResult(arguments: args, stdout: stdout, stderr: exit == 0 ? "" : "Unavailable", exitCode: exit)
    }

    func testOutdatedFailureKeepsLastResultAndClearsOnRecovery() async {
        var fail = false
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            Self.result(args, fail ? "bad json" : #"{"formulae":[{"name":"tool"}],"casks":[]}"#, exit: fail ? 1 : 0)
        }
        await vm.loadOutdatedPackages()
        XCTAssertTrue(vm.hasLoadedOutdated)
        XCTAssertNil(vm.outdatedError)
        fail = true
        await vm.loadOutdatedPackages()
        XCTAssertEqual(vm.outdatedFormulaNames, ["tool"])
        XCTAssertNotNil(vm.outdatedError)
        fail = false
        await vm.loadOutdatedPackages()
        XCTAssertNil(vm.outdatedError)
    }

    func testInitialOutdatedFailureRemainsUnknown() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in Self.result(args, "", exit: 1) }
        await vm.loadOutdatedPackages()
        XCTAssertFalse(vm.hasLoadedOutdated)
        XCTAssertNotNil(vm.outdatedError)
    }

    func testTappedCaskOutdatedShortTokenResolvesOnlyAtIngestion() async {
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            let output = args.first == "outdated"
                ? #"{"formulae":[],"casks":[{"name":"tool"}]}"#
                : #"{"formulae":[],"casks":[{"token":"tool","full_token":"acme/apps/tool","name":["Tool"],"desc":"Fixture","homepage":"https://example.com","version":"2.0","installed":"1.0","outdated":true}]}"#
            return Self.result(args, output)
        }
        await vm.loadAllBrew()
        await vm.loadOutdatedPackages()
        XCTAssertTrue(vm.isOutdated(.cask("acme/apps/tool")))
        XCTAssertEqual(vm.outdatedCaskNames, ["acme/apps/tool"])
        XCTAssertNil(vm.cask(for: .cask("tool")))
    }

    func testSelectedUpgradesKeepKindsDistinctAndContinueAfterFailure() async {
        var commands: [[String]] = []
        let inventory = Self.inventory().replacingOccurrences(of: #""casks":[]"#, with: #""casks":[{"token":"tool","name":["Tool"],"homepage":"https://example.com","version":"2.0","installed":"1.0"}]"#)
        let vm = BreweryViewModel(loadOnInit: false) { args, _ in
            if args.first == "upgrade" {
                commands.append(args)
                return Self.result(args, "", exit: args.contains("--cask") ? 1 : 0)
            }
            if args.first == "outdated" { return Self.result(args, #"{"formulae":[{"name":"tool"}],"casks":[{"name":"tool"}]}"#) }
            return Self.result(args, inventory)
        }
        await vm.loadAllBrew()
        await vm.loadOutdatedPackages()
        await vm.upgradePackages([.formula("tool"), .cask("tool"), .formula("not-installed")])
        XCTAssertEqual(commands, [["upgrade", "--cask", "tool"], ["upgrade", "--formula", "tool"]])
        XCTAssertEqual(vm.operations.map(\.status), [.failed, .succeeded])
        XCTAssertFalse(vm.hasPendingOperations)
    }

    static func inventory(name: String = "tool", fullName: String = "tool") -> String {
        """
        {"formulae":[{"name":"\(name)","full_name":"\(fullName)","tap":"\(fullName == name ? "homebrew/core" : "acme/tools")","desc":"Fixture","homepage":"https://example.com","license":"MIT","outdated":false,"dependencies":[],"installed":[{"version":"1.0","time":1}],"versions":{"stable":"2.0"}}],"casks":[]}
        """
    }
}
