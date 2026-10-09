import XCTest
@testable import Brewery

final class AppUpdateInstallationGateTests: XCTestCase {
    @MainActor func testIdleInstallationDoesNotPostponeOrInvokeHandler() {
        let gate = AppUpdateInstallationGate()
        var calls = 0
        XCTAssertFalse(gate.postponeIfNeeded(isBusy: false) { calls += 1 })
        gate.operationsChanged(isBusy: false)
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testQueuedOperationsDelayRelaunchUntilAllCompleteExactlyOnce() {
        let gate = AppUpdateInstallationGate()
        var calls = 0
        XCTAssertTrue(gate.postponeIfNeeded(isBusy: true) { calls += 1 })
        gate.operationsChanged(isBusy: true)
        XCTAssertEqual(calls, 0)
        gate.operationsChanged(isBusy: false)
        XCTAssertEqual(calls, 1)
        gate.operationsChanged(isBusy: false)
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testCanceledUpdateCannotRelaunchWhenOperationsFinish() {
        let gate = AppUpdateInstallationGate()
        var calls = 0
        XCTAssertTrue(gate.postponeIfNeeded(isBusy: true) { calls += 1 })
        gate.cancel()
        gate.operationsChanged(isBusy: false)
        XCTAssertEqual(calls, 0)
    }
}
