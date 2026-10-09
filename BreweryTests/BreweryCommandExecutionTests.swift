import Darwin
import Foundation
import XCTest
@testable import Brewery

@MainActor
final class BreweryCommandExecutionTests: XCTestCase {
    func testRepeatedShortChildrenFinishAfterBothPipesReachEOF() async throws {
        let child = try OwnedShellChild()
        defer { child.cleanup() }
        let results = LockedCommandValue<[BreweryCommandResult]>([])
        let completed = expectation(description: "128 short child processes complete")
        let task = Task.detached {
            for _ in 0..<128 {
                guard !Task.isCancelled else { break }
                let result = await child.execute("printf out; printf err >&2; /bin/sleep 0.01")
                results.update { $0.append(result) }
            }
            completed.fulfill()
        }
        // A structured task group would await a stuck waitUntilExit even after timeout.
        await fulfillment(of: [completed], timeout: 30)
        task.cancel()
        let finished = results.snapshot()
        XCTAssertEqual(finished.count, 128, "A child ended but the command pipeline did not return")
        for result in finished {
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "out")
            XCTAssertEqual(result.stderr, "err")
        }
    }

    func testLargeStdoutAndStderrAreDrainedCompletelyAndStreamedWithoutLoss() async throws {
        let child = try OwnedShellChild()
        defer { child.cleanup() }
        let streamed = LockedCommandValue("")
        let outChunk = String(repeating: "O", count: 128)
        let errChunk = String(repeating: "E", count: 128)
        let script = """
        i=0
        while [ "$i" -lt 2048 ]; do
            printf '%s' '\(outChunk)'
            printf '%s' '\(errChunk)' >&2
            i=$((i + 1))
        done
        """
        guard let result = await resultWithinTimeout({
            await child.execute(script) { chunk in streamed.update { $0 += chunk } }
        }) else { return }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, String(repeating: "O", count: 262_144))
        XCTAssertEqual(result.stderr, String(repeating: "E", count: 262_144))
        let callbackOutput = streamed.snapshot()
        // Stream ordering between stdout and stderr is intentionally unspecified.
        XCTAssertEqual(callbackOutput.utf8.count, 524_288)
        XCTAssertEqual(callbackOutput.utf8.filter { $0 == 79 }.count, 262_144)
        XCTAssertEqual(callbackOutput.utf8.filter { $0 == 69 }.count, 262_144)
    }

    func testOutputCallbackArrivesBeforeChildIsAllowedToExit() async throws {
        let child = try OwnedShellChild()
        defer { child.cleanup() }
        let outputReceived = expectation(description: "Stream callback precedes child exit")
        let completed = expectation(description: "Child completes after gate opens")
        let output = LockedCommandValue("")
        let result = LockedCommandValue<BreweryCommandResult?>(nil)
        let notified = LockedCommandValue(false)
        let task = Task.detached {
            let commandResult = await child.execute("""
            printf 'ready\\n'
            attempts=0
            while [ ! -f "$BREWERY_TEST_GATE_FILE" ] && [ "$attempts" -lt 500 ]; do
                /bin/sleep 0.01
                attempts=$((attempts + 1))
            done
            [ -f "$BREWERY_TEST_GATE_FILE" ] || exit 99
            printf 'done\\n'
            """) { chunk in
                let ready = output.update { value in
                    value += chunk
                    return value.contains("ready\n")
                }
                if ready, notified.update({ value in
                    guard !value else { return false }
                    value = true
                    return true
                }) {
                    outputReceived.fulfill()
                }
            }
            result.update { $0 = commandResult }
            completed.fulfill()
        }
        defer { task.cancel() }

        await fulfillment(of: [outputReceived], timeout: 3)
        XCTAssertNil(result.snapshot(), "Streaming must occur while the child is still waiting")
        // Release even when the callback assertion fails, so the test owns no hanging child.
        try Data().write(to: child.gateURL)
        await fulfillment(of: [completed], timeout: 10)
        guard let finished = result.snapshot() else { return }
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertEqual(finished.stdout, "ready\ndone\n")
        XCTAssertEqual(finished.stderr, "")
    }

    func testNonzeroChildExitPreservesBothOutputStreams() async throws {
        let child = try OwnedShellChild()
        defer { child.cleanup() }
        guard let result = await resultWithinTimeout({
            await child.execute("printf 'partial output'; printf 'failure detail' >&2; exit 23")
        }) else { return }

        XCTAssertEqual(result.exitCode, 23)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stdout, "partial output")
        XCTAssertEqual(result.stderr, "failure detail")
    }

    func testArgumentsAndExplicitEnvironmentReachOnlyTheOwnedChild() async throws {
        let child = try OwnedShellChild()
        defer { child.cleanup() }
        let argument = "literal spaces; $(not-a-command)"
        guard let result = await resultWithinTimeout({
            await child.execute(
                "printf '%s\\n' \"$BREWERY_EXECUTION_TEST_VALUE\"; printf '%s' \"$1\"",
                arguments: [argument],
                extraEnvironment: ["BREWERY_EXECUTION_TEST_VALUE": "isolated environment"]
            )
        }) else { return }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "isolated environment\n" + argument)
        XCTAssertEqual(result.stderr, "")
    }

    func testMissingExecutableReturns126WithoutWaitingForPipeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard let result = await resultWithinTimeout({
            await BreweryCommand.executeProcess(
                brewURL: directory.appendingPathComponent("missing-executable"),
                arguments: ["unused"],
                environment: [:]
            )
        }) else { return }

        XCTAssertEqual(result.exitCode, 126)
        XCTAssertEqual(result.arguments, ["unused"])
        XCTAssertEqual(result.stdout, "")
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertFalse(result.succeeded)
    }

    private func resultWithinTimeout(
        _ operation: @escaping @Sendable () async -> BreweryCommandResult
    ) async -> BreweryCommandResult? {
        let completed = expectation(description: "Owned child process returns")
        let result = LockedCommandValue<BreweryCommandResult?>(nil)
        let task = Task.detached {
            let output = await operation()
            result.update { $0 = output }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 15)
        task.cancel()
        // Never await task.value here: a regression must fail within this timeout.
        return result.snapshot()
    }
}

private final class LockedCommandValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func snapshot() -> Value { update { $0 } }
}

private struct OwnedShellChild: Sendable {
    let directory: URL
    let pidURL: URL
    let gateURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreweryCommandExecutionTests-" + UUID().uuidString)
        pidURL = directory.appendingPathComponent("child.pid")
        gateURL = directory.appendingPathComponent("continue")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func execute(
        _ script: String,
        arguments: [String] = [],
        extraEnvironment: [String: String] = [:],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> BreweryCommandResult {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "BREWERY_TEST_PID_FILE": pidURL.path,
            "BREWERY_TEST_GATE_FILE": gateURL.path
        ]
        environment.merge(extraEnvironment) { _, new in new }
        return await BreweryCommand.executeProcess(
            brewURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$$\" > \"$BREWERY_TEST_PID_FILE\"\n" + script,
                        "brewery-owned-test-child"] + arguments,
            environment: environment,
            onOutput: onOutput
        )
    }

    func cleanup() {
        // Only terminate the PID written by this unique fixture and still directly
        // parented by this XCTest host. Never use broad process-name matching.
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(text), pid > 1 {
            var processInfo = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            let status = query.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, u_int($0.count), &processInfo, &size, nil, 0)
            }
            if status == 0, size > 0, processInfo.kp_eproc.e_ppid == getpid() {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
