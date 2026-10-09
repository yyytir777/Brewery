import XCTest
@testable import Brewery

final class SettingsRuntimeTests: XCTestCase {
    func testCadenceRequiresFullDayAndManualNeverSchedules() {
        let now = Date(timeIntervalSince1970: 100000)
        XCTAssertFalse(SettingsPolicy.shouldCheck(cadence: "manual", lastCheck: nil, now: now, launching: true))
        XCTAssertTrue(SettingsPolicy.shouldCheck(cadence: "launch", lastCheck: now, now: now, launching: true))
        XCTAssertFalse(SettingsPolicy.shouldCheck(cadence: "launch", lastCheck: nil, now: now, launching: false))
        XCTAssertFalse(SettingsPolicy.shouldCheck(cadence: "daily", lastCheck: now.addingTimeInterval(-86399), now: now, launching: true))
        XCTAssertTrue(SettingsPolicy.shouldCheck(cadence: "daily", lastCheck: now.addingTimeInterval(-86400), now: now, launching: false))
    }

    func testNewUpdateDedupUsesQualifiedIdentityAndOnlyAddedPackages() {
        let original: Set<String> = ["formula:git", "cask:example"]
        XCTAssertTrue(SettingsPolicy.newlyAvailableUpdates(current: original, previouslySeen: original).isEmpty)
        XCTAssertEqual(SettingsPolicy.newlyAvailableUpdates(current: ["formula:git", "cask:git"], previouslySeen: original), ["cask:git"])
        XCTAssertTrue(SettingsPolicy.newlyAvailableUpdates(current: [], previouslySeen: original).isEmpty)
    }

    func testDailyRestartLoadsSnapshotWithoutForcingMetadataRefresh() {
        XCTAssertTrue(SettingsPolicy.needsInitialSnapshot(hasLoaded: false, cadence: "daily"))
        XCTAssertFalse(SettingsPolicy.needsInitialSnapshot(hasLoaded: true, cadence: "daily"))
        XCTAssertFalse(SettingsPolicy.needsInitialSnapshot(hasLoaded: false, cadence: "manual"))
    }

    func testCleanupReminderIsWeeklyAndVersionValidationRejectsUnknownTags() {
        let now = Date()
        XCTAssertFalse(SettingsPolicy.shouldRemindCleanup(lastCleanup: now.addingTimeInterval(-6 * 86400), now: now))
        XCTAssertTrue(SettingsPolicy.shouldRemindCleanup(lastCleanup: now.addingTimeInterval(-7 * 86400), now: now))
        XCTAssertFalse(SettingsPolicy.isValidVersion("latest"))
        XCTAssertFalse(SettingsPolicy.isValidVersion("1..2"))
        XCTAssertFalse(SettingsPolicy.isValidVersion("1.2-beta"))
        XCTAssertTrue(SettingsPolicy.isValidVersion("v1.2.3"))
    }

    func testReleaseComparisonUsesNumbersAndRejectsPrerelease() {
        XCTAssertTrue(SettingsPolicy.isNewerVersion("v1.10.0", than: "1.9.9"))
        XCTAssertFalse(SettingsPolicy.isNewerVersion("1.2", than: "1.2.0"))
        XCTAssertFalse(SettingsPolicy.isNewerVersion("2.0-beta", than: "1.0"))
    }

    func testRetentionKeepsMultilineOutputWithItsTimestamp() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let cutoff = formatter.date(from: "2026-10-01 00:00:00")!
        let input = "[2026-09-30 12:00:00] OUT: old\nold continuation\n[2026-10-02 12:00:00] OUT: recent\nrecent continuation\n"
        XCTAssertEqual(BreweryLogger.retainedLog(input, cutoff: cutoff), "[2026-10-02 12:00:00] OUT: recent\nrecent continuation\n")
    }

    func testInvalidOverrideNeverFallsBackAndEnvironmentUsesSelectedBin() {
        XCTAssertNotNil(BreweryCommand.validateOverridePath("relative/brew"))
        XCTAssertNotNil(BreweryCommand.validateOverridePath("/usr/bin"))
        XCTAssertNil(BreweryCommand.resolveBrewURL(overridePath: "/nonexistent-brewery-test/brew"))
        XCTAssertTrue(BreweryCommand.makeEnvironment(brewURL: URL(fileURLWithPath: "/custom/bin/brew"))["PATH"]!.hasPrefix("/custom/bin:"))
    }
}
