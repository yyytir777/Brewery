import XCTest
@testable import Brewery

final class BreweryCommandTests: XCTestCase {
    func testProcessUsesBrewExecutableAndPreservesArgumentBoundaries() {
        let suspiciousName = "git; touch /tmp/not-run"
        let process = BreweryCommand.makeProcess(
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["install", suspiciousName],
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )

        XCTAssertEqual(process.executableURL?.path, "/opt/homebrew/bin/brew")
        XCTAssertEqual(process.arguments, ["install", suspiciousName])
    }

    func testStructuredResultKeepsStreamsAndStatusSeparate() {
        let result = BreweryCommandResult(
            arguments: ["install", "missing"],
            stdout: "",
            stderr: "Error: missing\n",
            exitCode: 1
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.displayOutput, "Error: missing\n")
    }
}
