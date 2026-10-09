import XCTest

/// Every launch resets a Debug-only, in-memory fixture. No real Homebrew is used.
@MainActor
final class BreweryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() async throws {
        await MainActor.run {
            if let app {
                if let run = testRun, run.failureCount > 0 {
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name = name
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                    let hierarchy = XCTAttachment(string: app.debugDescription)
                    hierarchy.name = "Accessibility hierarchy"
                    hierarchy.lifetime = .keepAlways
                    add(hierarchy)
                }
                app.terminate()
            }
            app = nil
        }
        try await super.tearDown()
    }

    func testHomeDiscoverDetailAndBack() {
        launch()
        click("sidebar.discover")
        clickButton("discover.view.formula:git")
        assertExists("detail.formula:git")
        clickButton("toolbar.back")
        assertExists("discover.search")
        clickButton("toolbar.back")
        assertExists("home.reviewUpdates")
    }

    func testFirstCommandFFocusesDiscoverSearchWithoutClickingField() {
        launch()
        app.typeKey("f", modifierFlags: .command)
        assertExists("discover.search")
        // Clicking the field here would hide a first-shortcut focus regression.
        app.typeText("jq")
        assertValue("jq", of: app.textFields["discover.search"])
        assertExists("discover.info.formula:jq")
        assertAbsent("discover.view.formula:git")
    }

    func testInstalledQueryTypeAndUpdateFilterSurviveDetailRoundTrip() {
        launch()
        click("sidebar.installed")
        let search = app.textFields["installed.search"]
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.click()
        search.typeText("qa")
        click("installed.typeFilter")
        app.menuItems["Cask (1)"].click()
        click("installed.updatesOnly")
        assertLabel("1 shown · 0 selected", of: element("installed.summary"))
        clickButton("installed.view.cask:qa-app")
        assertExists("detail.cask:qa-app")
        clickButton("toolbar.back")
        assertValue("qa", of: app.textFields["installed.search"])
        assertValue("1", of: app.checkBoxes["installed.updatesOnly"])
        XCTAssertTrue(element("installed.typeFilter").label.contains("Cask")
                      || String(describing: element("installed.typeFilter").value ?? "").contains("Cask"))
        assertExists("installed.view.cask:qa-app")
        assertAbsent("installed.view.formula:git")
        assertLabel("1 shown · 0 selected", of: element("installed.summary"))
    }

    func testSelectingAvailableUpdatesUpgradesOnlyOutdatedPackages() {
        launch()
        click("sidebar.installed")
        assertLabel("3 shown · 0 selected", of: element("installed.summary"))
        clickButton("installed.selectUpdates")
        assertLabel("3 shown · 2 selected", of: element("installed.summary"))
        assertLabel("Update Selected (2)", of: app.buttons["installed.upgradeSelection"])
        clickButton("installed.upgradeSelection")
        assertInstalledVersion("2.0", package: "formula:git")
        assertInstalledVersion("2.0", package: "cask:qa-app")
        assertInstalledVersion("1.0", package: "formula:gettext")
        assertLabel("Update Selected (0)", of: app.buttons["installed.upgradeSelection"])
        XCTAssertFalse(app.buttons["installed.upgradeSelection"].isEnabled)
        clickButton("toolbar.activity")
        assertLabel("Completed", of: element("operation.status.Update git"))
        assertLabel("Completed", of: element("operation.status.Update qa-app"))
        assertAbsent("operation.status.Update gettext")
    }

    func testCancellingWaitingUpgradeLeavesThatPackageUnchanged() {
        launch("queue")
        click("sidebar.installed")
        clickButton("installed.view.formula:git")
        clickButton("detail.update")
        clickButton("toolbar.back")
        clickButton("installed.view.cask:qa-app")
        clickButton("detail.update")
        clickButton("toolbar.activity")
        assertLabel("Running", of: element("operation.status.Update git"))
        assertLabel("Waiting", of: element("operation.status.Update qa-app"))
        clickButton("operation.cancel.Update qa-app")
        assertLabel("Cancelled", of: element("operation.status.Update qa-app"))
        assertLabel("Running", of: element("operation.status.Update git"))
        clickButton("fixture.completeOperation")
        assertLabel("Completed", of: element("operation.status.Update git"))
        // Re-check after the running operation completes: cancellation must keep
        // the queued mutation from executing, not merely show a transient label.
        assertLabel("Cancelled", of: element("operation.status.Update qa-app"))
        clickButton("operations.done")
        click("sidebar.installed")
        assertInstalledVersion("2.0", package: "formula:git")
        assertInstalledVersion("1.0", package: "cask:qa-app")
        XCTAssertTrue(element("installed.row.cask:qa-app").staticTexts["Update available: 2.0"].exists)
    }

    func testCancellingFormulaUninstallKeepsPackageAndStartsNoOperation() {
        launch()
        click("sidebar.installed")
        clickButton("installed.view.formula:git")
        revealUninstall(in: "detail.formula:git")
        clickButton("detail.uninstall")
        cancelConfirmation(containing: "Uninstall git?")
        assertExists("detail.formula:git")
        click("sidebar.installed")
        assertInstalledVersion("1.0", package: "formula:git")
        assertNoOperations()
    }

    func testCancellingCaskDataDeletionKeepsPackageAndStartsNoOperation() {
        launch()
        click("sidebar.installed")
        clickButton("installed.view.cask:qa-app")
        revealUninstall(in: "detail.cask:qa-app")
        click("detail.uninstall")
        let deleteData = app.menuItems["Uninstall and Delete Data"]
        XCTAssertTrue(deleteData.waitForExistence(timeout: timeout))
        deleteData.click()
        cancelConfirmation(containing: "Uninstall qa-app and delete data?")
        assertExists("detail.cask:qa-app")
        click("sidebar.installed")
        assertInstalledVersion("1.0", package: "cask:qa-app")
        assertNoOperations()
    }

    func testMissingHomebrewCanRetryConnection() {
        launch("missing-homebrew", expectsInventory: false)
        assertExists("homebrew.retry")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Connect Homebrew", "Connect Homebrew")).firstMatch.exists)
        clickButton("homebrew.retry")
        waitForInventory()
        assertAbsent("homebrew.retry")
        click("sidebar.installed")
        assertLabel("3 shown · 0 selected", of: element("installed.summary"))
        XCTAssertTrue(app.buttons["installed.selectUpdates"].isEnabled)
    }

    func testInformationFailureCanRetryInsidePopover() {
        launch("info-failure")
        click("sidebar.discover")
        clickButton("discover.info.formula:jq")
        assertExists("preview.error")
        let globalFailure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Homebrew Command Failed", "Homebrew Command Failed")).firstMatch
        XCTAssertFalse(globalFailure.exists, "Package information errors must remain in the popover")
        clickButton("preview.retry")
        assertExists("preview.content")
        assertAbsent("preview.error")
        XCTAssertTrue(element("preview.content").staticTexts["1.0"].exists)
        clickButton("preview.close")
        assertAbsent("preview.content")
        assertExists("discover.info.formula:jq")
        XCTAssertFalse(globalFailure.exists)
    }

    func testOfflineRefreshPreservesSearchableCatalog() {
        launch("offline")
        click("sidebar.discover")
        assertExists("discover.info.formula:jq")
        assertExists("discover.refreshMessage")
        wait(until: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Offline UI fixture attempt 1", "Offline UI fixture attempt 1"), on: element("discover.refreshMessage"))
        clickButton("toolbar.refresh")
        wait(until: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Offline UI fixture attempt 2", "Offline UI fixture attempt 2"), on: element("discover.refreshMessage"))
        let search = app.textFields["discover.search"]
        search.click()
        search.typeText("jq")
        assertValue("jq", of: search)
        assertExists("discover.info.formula:jq")
        assertAbsent("discover.view.formula:git")
        XCTAssertFalse(app.staticTexts["Catalog unavailable"].exists)
    }

    func testSidebarTabNavigation() {
        launch()
        click("sidebar.home")
        app.typeKey(.tab, modifierFlags: [])
        assertExists("installed.search")
        app.typeKey(.tab, modifierFlags: [])
        assertValue("1", of: app.checkBoxes["installed.updatesOnly"])
        app.typeKey(.tab, modifierFlags: [])
        assertExists("discover.search")
        app.typeKey(.tab, modifierFlags: .shift)
        assertExists("installed.search")
        assertValue("1", of: app.checkBoxes["installed.updatesOnly"])
    }

    func testSettingsAppearanceAndSearch() {
        launch()
        app.typeKey(",", modifierFlags: .command)
        assertExists("settings.search")
        clickButton("settings.category.Appearance")
        click("settings.theme")
        app.menuItems["Dark"].click()
        XCTAssertTrue(String(describing: element("settings.theme").value ?? "").contains("Dark"))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Settings Appearance"
        shot.lifetime = .keepAlways
        add(shot)
        let search = app.textFields["settings.search"]
        search.click()
        search.typeText(" retention ")
        assertExists("settings.logRetentionDays")
        assertAbsent("settings.category.Appearance")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("nothing-matches-123")
        XCTAssertTrue(app.staticTexts["No matching settings"].firstMatch.waitForExistence(timeout: timeout))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        clickButton("settings.category.General")
        click("settings.language")
        app.menuItems["한국어"].click()
        XCTAssertTrue(app.staticTexts["언어"].firstMatch.waitForExistence(timeout: timeout))
        let koreanShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        koreanShot.name = "Settings Korean"
        koreanShot.lifetime = .keepAlways
        add(koreanShot)
    }

    private func launch(_ scenario: String = "standard", expectsInventory: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["--brewery-ui-testing", scenario]
        app.launch()
        app.activate()
        if scenario == "missing-homebrew" { dismissExpectedCommandFailureIfPresented() }
        assertExists("sidebar.home")
        // Native window restoration can retain the prior list selection between UI launches.
        // Each scenario starts its interaction from Home; preferences themselves use isolated unit tests.
        if expectsInventory { click("sidebar.home"); waitForInventory() }
    }

    private func waitForInventory() {
        XCTAssertTrue(app.staticTexts["2 Formula · 1 Cask"].waitForExistence(timeout: timeout))
        // Inventory and outdated load independently; both must be ready.
        let updateSummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review available updates and choose the packages to update.", "Review available updates and choose the packages to update.")).firstMatch
        XCTAssertTrue(updateSummary.waitForExistence(timeout: timeout))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func click(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), identifier, file: file, line: line)
        target.click()
    }

    private func clickButton(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        let target = app.buttons[identifier]
        XCTAssertTrue(target.waitForExistence(timeout: timeout), identifier, file: file, line: line)
        wait(until: NSPredicate(format: "isEnabled == true AND isHittable == true"), on: target, file: file, line: line)
        target.click()
    }

    private func assertExists(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: timeout), identifier, file: file, line: line)
    }

    private func assertAbsent(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        wait(until: NSPredicate(format: "exists == false"), on: element(identifier), file: file, line: line)
    }

    private func assertLabel(_ label: String, of target: XCUIElement, timeout: TimeInterval? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        wait(until: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", label, label), on: target, timeout: timeout, file: file, line: line)
    }

    private func assertValue(_ value: String, of target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(until: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.exists && String(describing: element.value ?? "") == value
        }, on: target, file: file, line: line)
    }

    private func assertInstalledVersion(_ version: String, package: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element("installed.row.\(package)")
        XCTAssertTrue(row.staticTexts[version].waitForExistence(timeout: timeout), "\(package) should be version \(version)", file: file, line: line)
    }

    private func cancelConfirmation(containing title: String, file: StaticString = #filePath, line: UInt = #line) {
        // macOS may expose the confirmation title and body as one static text.
        let confirmation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: timeout), file: file, line: line)
        // Invoke the native cancel action without selecting a duplicate Touch Bar button.
        app.typeKey(.escape, modifierFlags: [])
        wait(until: NSPredicate(format: "exists == false"), on: confirmation, file: file, line: line)
    }

    private func revealUninstall(in detailIdentifier: String) {
        let button = element("detail.uninstall")
        let scrollView = element(detailIdentifier)
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        for _ in 0..<2 where !button.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -400)
        }
        if !button.isHittable {
            // Dragging the native thumb also works when the host's wheel direction differs.
            let scrollbar = scrollView.descendants(matching: .scrollBar).firstMatch
            let thumb = scrollbar.descendants(matching: .valueIndicator).firstMatch
            if scrollbar.exists && thumb.exists {
                thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: scrollbar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            }
        }
        XCTAssertTrue(button.isHittable, "Uninstall must be reachable by scrolling the detail view")
    }

    private func dismissExpectedCommandFailureIfPresented() {
        // Read failures currently also publish the shared command-error alert.
        // Some SwiftUI presentations keep the error in the popover instead.
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Homebrew Command Failed", "Homebrew Command Failed")).firstMatch
        if title.waitForExistence(timeout: 3) {
            app.typeKey(.return, modifierFlags: [])
            wait(until: NSPredicate(format: "exists == false"), on: title)
        }
    }

    private func assertNoOperations(file: StaticString = #filePath, line: UInt = #line) {
        clickButton("toolbar.activity", file: file, line: line)
        XCTAssertTrue(app.staticTexts["No operations yet."].waitForExistence(timeout: timeout), file: file, line: line)
    }

    private func wait(until predicate: NSPredicate, on target: XCUIElement, timeout: TimeInterval? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout ?? self.timeout), .completed,
                       "Expected \(predicate) for \(target)", file: file, line: line)
    }
}
