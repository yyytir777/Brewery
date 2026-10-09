import XCTest
@testable import Brewery

@MainActor
final class AppPreferencesTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "Brewery.SettingsTests.\(UUID().uuidString)")!
    }

    func testDefaultsPreserveAppearanceAndDisableExternalActions() {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        XCTAssertEqual(preferences.values.theme, "system")
        XCTAssertEqual(preferences.values.startupPage, "home")
        XCTAssertFalse(preferences.values.notifyOperations)
        XCTAssertFalse(preferences.values.notifyUpdates)
        XCTAssertFalse(preferences.values.checkAppUpdates)
    }

    func testNestedChangesPersistAndResetPreservesUnrelatedDefaults() {
        let defaults = isolatedDefaults()
        defaults.set("preserve", forKey: "unrelated")
        let preferences = AppPreferences(defaults: defaults)
        preferences.values.theme = "dark"
        preferences.values.excludedUpdates = ["formula:owner/tap/tool", "cask:tool"]
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.values.theme, "dark")
        XCTAssertEqual(restored.values.excludedUpdates.count, 2)
        restored.reset()
        XCTAssertEqual(AppPreferences(defaults: defaults).values, PreferencesValues())
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserve")
    }

    func testCorruptDataAndUnknownOptionsFallBackSafely() throws {
        let defaults = isolatedDefaults()
        defaults.set(Data("invalid".utf8), forKey: AppPreferences.storageKey)
        XCTAssertEqual(AppPreferences(defaults: defaults).values, PreferencesValues())
        var bad = PreferencesValues()
        bad.theme = "invalid"
        bad.logRetentionDays = -4
        defaults.set(try JSONEncoder().encode(bad), forKey: AppPreferences.storageKey)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.values.theme, "system")
        XCTAssertEqual(restored.values.logRetentionDays, 30)
    }

    func testOldPreferencesMergeNewDefaults() throws {
        let defaults = isolatedDefaults()
        defaults.set(try JSONSerialization.data(withJSONObject: ["theme": "dark"]), forKey: AppPreferences.storageKey)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.values.theme, "dark")
        XCTAssertTrue(restored.values.showVersion)
        XCTAssertEqual(restored.values.rankingWindow, "30d")
    }

    func testTransientFixturePreferencesNeverReadOrWritePersonalPreferences() {
        let defaults = isolatedDefaults()
        let live = AppPreferences(defaults: defaults)
        live.values.theme = "dark"
        let fixture = AppPreferences(defaults: defaults, persistChanges: false)
        XCTAssertEqual(fixture.values.theme, "system")
        fixture.values.theme = "light"
        fixture.reset()
        XCTAssertEqual(AppPreferences(defaults: defaults).values.theme, "dark")
    }

    func testSizeFormattingRespectsSelectedUnitAndKeepsUnknownValues() {
        var values = PreferencesValues()
        XCTAssertEqual(values.formatHomebrewSize("unknown"), "unknown")
        values.sizeUnit = "mb"
        XCTAssertTrue(values.formatHomebrewSize("1.5 GB").contains("MB"))
        values.sizeUnit = "gb"
        XCTAssertTrue(values.formatBytes(1_500_000_000).contains("GB"))
        XCTAssertEqual(values.formatHomebrewSize("unknown"), "unknown")
    }

    func testStartupAndFilterPolicies() {
        var values = PreferencesValues()
        values.startupPage = "last"
        values.lastPage = "updates"
        XCTAssertEqual(values.initialDestination, .installed(outdatedOnly: true))
        values.rememberFilters = false
        values.defaultKind = "cask"
        values.hasSavedFilters = true
        values.savedKind = "formula"
        values.savedQuery = "old search"
        XCTAssertEqual(values.initialKind, .cask)
        XCTAssertEqual(values.initialQuery, "")
        values.rememberFilters = true
        XCTAssertEqual(values.initialKind, .formula)
        XCTAssertEqual(values.initialQuery, "old search")
    }
}
