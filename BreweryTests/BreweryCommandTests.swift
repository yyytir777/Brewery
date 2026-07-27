import XCTest
@testable import Brewery

final class BreweryCommandTests: XCTestCase {
    func testMakeProcessUsesBrewExecutableDirectly() {
        let process = BreweryCommand.makeProcess(
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["search", "git"],
            environment: ["PATH": "/opt/homebrew/bin"]
        )

        XCTAssertEqual(process.executableURL?.path, "/opt/homebrew/bin/brew")
        XCTAssertEqual(process.arguments, ["search", "git"])
    }

    func testMakeProcessDoesNotShellJoinArguments() {
        let suspiciousQuery = "git; echo injected"
        let process = BreweryCommand.makeProcess(
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["search", suspiciousQuery],
            environment: ["PATH": "/opt/homebrew/bin"]
        )

        XCTAssertEqual(process.arguments, ["search", suspiciousQuery])
        XCTAssertFalse(process.arguments?.joined(separator: " ").contains("brew search") ?? true)
    }

    func testCommandResultSuccessFlagAndDisplayOutput() {
        let success = BreweryCommandResult(
            arguments: ["search", "git"],
            stdout: "git\n",
            stderr: "",
            exitCode: 0
        )
        let failure = BreweryCommandResult(
            arguments: ["install", "missing-package"],
            stdout: "",
            stderr: "Error: No formulae found.\n",
            exitCode: 1
        )

        XCTAssertTrue(success.succeeded)
        XCTAssertEqual(success.displayOutput, "git\n")
        XCTAssertFalse(failure.succeeded)
        XCTAssertEqual(failure.displayOutput, "Error: No formulae found.\n")
    }
}
