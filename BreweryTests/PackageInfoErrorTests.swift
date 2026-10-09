import XCTest
@testable import Brewery

@MainActor
final class PackageInfoErrorTests: XCTestCase {
    func testCommandFailureThrowsItsDiagnosticWithoutPresentingGlobalAlert() async {
        let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
            BreweryCommandResult(arguments: arguments, stdout: "", stderr: "Information temporarily unavailable", exitCode: 1)
        }
        do {
            _ = try await vm.packageInfo(for: .formula("jq"))
            XCTFail("A failed command must not produce package information")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Information temporarily unavailable")
        }
        XCTAssertNil(vm.lastCommandError)
    }

    func testCommandFailureWithoutDiagnosticSuppliesNonemptyInlineFallback() async {
        let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
            BreweryCommandResult(arguments: arguments, stdout: " \n", stderr: "\t", exitCode: 1)
        }
        do {
            _ = try await vm.packageInfo(for: .cask("qa-app"))
            XCTFail("A failed command must not produce package information")
        } catch {
            XCTAssertFalse(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertNil(vm.lastCommandError)
    }

    func testMalformedAndBlankJSONThrowInlineErrorsWithoutGlobalAlert() async {
        for output in ["not JSON", ""] {
            let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
                BreweryCommandResult(arguments: arguments, stdout: output, stderr: "", exitCode: 0)
            }
            do {
                _ = try await vm.packageInfo(for: .formula("jq"))
                XCTFail("Malformed JSON must not produce package information")
            } catch {
                XCTAssertFalse(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            XCTAssertNil(vm.lastCommandError)
        }
    }

    func testEmptyPackageResponseThrowsInlineErrorForBothKinds() async {
        for id in [PackageID.formula("jq"), .cask("qa-app")] {
            let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
                BreweryCommandResult(arguments: arguments, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", exitCode: 0)
            }
            do {
                _ = try await vm.packageInfo(for: id)
                XCTFail("An empty response must not produce package information")
            } catch {
                XCTAssertFalse(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            XCTAssertNil(vm.lastCommandError)
        }
    }

    func testPackageInfoNeverClearsOrReplacesUnrelatedGlobalError() async {
        let previous = BreweryCommandResult(arguments: ["update"], stdout: "", stderr: "An earlier operation failed", exitCode: 4)
        let responses: [(output: String, exit: Int32, shouldSucceed: Bool)] = [
            ("", 1, false),
            ("not JSON", 0, false),
            (#"{"formulae":[],"casks":[]}"#, 0, false),
            (InventoryOperationTests.inventory(name: "jq", fullName: "jq"), 0, true)
        ]
        for response in responses {
            let vm = BreweryViewModel(loadOnInit: false) { arguments, _ in
                BreweryCommandResult(arguments: arguments, stdout: response.output, stderr: response.exit == 0 ? "" : "New info failure", exitCode: response.exit)
            }
            vm.recordFailure(previous)
            do {
                let info = try await vm.packageInfo(for: .formula("jq"))
                XCTAssertTrue(response.shouldSucceed)
                XCTAssertEqual(info.formula?.name, "jq")
            } catch {
                XCTAssertFalse(response.shouldSucceed)
            }
            XCTAssertEqual(vm.lastCommandError, previous)
        }
    }
}
