import XCTest
@testable import Brewery

@MainActor
final class NavigationHistoryTests: XCTestCase {
    func testStartsAtHomeWithNoAvailableHistory() {
        var history = NavigationHistory()

        XCTAssertEqual(history.current, .home)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.goBack()
        history.goForward()

        XCTAssertEqual(history.current, .home)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackAndForwardRestoreEveryVisitedDestinationInOrder() {
        var history = NavigationHistory()
        history.navigate(to: .discover)
        history.navigate(to: .package(.formula("wget")))
        history.navigate(to: .package(.formula("openssl@3")))
        history.navigate(to: .package(.cask("firefox")))

        XCTAssertEqual(history.current, .package(.cask("firefox")))
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.goBack()
        XCTAssertEqual(history.current, .package(.formula("openssl@3")))
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        history.goBack()
        XCTAssertEqual(history.current, .package(.formula("wget")))

        history.goBack()
        XCTAssertEqual(history.current, .discover)

        history.goBack()
        XCTAssertEqual(history.current, .home)
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        history.goBack()
        XCTAssertEqual(history.current, .home)

        history.goForward()
        XCTAssertEqual(history.current, .discover)
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        history.goForward()
        XCTAssertEqual(history.current, .package(.formula("wget")))

        history.goForward()
        XCTAssertEqual(history.current, .package(.formula("openssl@3")))

        history.goForward()
        XCTAssertEqual(history.current, .package(.cask("firefox")))
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.goForward()
        XCTAssertEqual(history.current, .package(.cask("firefox")))
    }

    func testNavigatingAfterGoingBackReplacesTheForwardHistory() {
        var history = NavigationHistory()
        history.navigate(to: .discover)
        history.navigate(to: .package(.formula("wget")))
        history.navigate(to: .package(.formula("openssl@3")))
        history.goBack()
        history.goBack()

        history.navigate(to: .package(.cask("firefox")))

        XCTAssertEqual(history.current, .package(.cask("firefox")))
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.goForward()
        XCTAssertEqual(history.current, .package(.cask("firefox")))

        history.goBack()
        XCTAssertEqual(history.current, .discover)

        history.goForward()
        XCTAssertEqual(history.current, .package(.cask("firefox")))
        XCTAssertFalse(history.canGoForward)
    }

    func testNavigatingToCurrentDestinationPreservesForwardHistoryWithoutAddingAnEntry() {
        var history = NavigationHistory()
        history.navigate(to: .discover)
        history.navigate(to: .package(.formula("wget")))
        history.goBack()

        history.navigate(to: .discover)
        history.navigate(to: .discover)

        XCTAssertEqual(history.current, .discover)
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        history.goForward()
        XCTAssertEqual(history.current, .package(.formula("wget")))
        XCTAssertFalse(history.canGoForward)

        history.goBack()
        XCTAssertEqual(history.current, .discover)

        history.goBack()
        XCTAssertEqual(history.current, .home)
        XCTAssertFalse(history.canGoBack)
    }

    func testFormulaAndCaskWithTheSameNameRemainSeparateHistoryEntries() {
        var history = NavigationHistory()
        history.navigate(to: .package(.formula("foo")))
        history.navigate(to: .package(.cask("foo")))

        XCTAssertEqual(history.current, .package(.cask("foo")))

        history.goBack()
        XCTAssertEqual(history.current, .package(.formula("foo")))
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        history.goBack()
        XCTAssertEqual(history.current, .home)

        history.goForward()
        XCTAssertEqual(history.current, .package(.formula("foo")))

        history.goForward()
        XCTAssertEqual(history.current, .package(.cask("foo")))
        XCTAssertFalse(history.canGoForward)
    }
    func testRemovedPackagesLeaveUsableHistoryAndReturnToInstalled() {
        var history = NavigationHistory()
        history.navigate(to: .installed(outdatedOnly: true))
        history.navigate(to: .package(.formula("wget")))
        history.navigate(to: .package(.cask("firefox")))
        history.removePackages([.formula("wget"), .cask("firefox")])
        XCTAssertEqual(history.current, .installed(outdatedOnly: false))
        history.goBack()
        XCTAssertEqual(history.current, .installed(outdatedOnly: true))
        history.goBack()
        XCTAssertEqual(history.current, .home)
        history.goForward()
        XCTAssertEqual(history.current, .installed(outdatedOnly: true))
    }

    func testRemovingUnrelatedPackagePreservesForwardHistory() {
        var history = NavigationHistory()
        history.navigate(to: .discover)
        history.navigate(to: .package(.formula("wget")))
        history.goBack()
        history.removePackages([.formula("other")])
        history.goForward()
        XCTAssertEqual(history.current, .package(.formula("wget")))
    }
    func testRemovingCurrentPackageDoesNotCreateDuplicateBackDestination() {
        var history = NavigationHistory()
        history.navigate(to: .installed(outdatedOnly: false))
        history.navigate(to: .package(.formula("wget")))
        history.removePackages([.formula("wget")])
        history.goBack()
        XCTAssertEqual(history.current, .home)
    }

    func testRemovingPackageDoesNotLeaveDuplicateForwardDestination() {
        var history = NavigationHistory()
        history.navigate(to: .installed(outdatedOnly: false))
        history.navigate(to: .package(.formula("wget")))
        history.navigate(to: .installed(outdatedOnly: false))
        history.goBack()
        history.removePackages([.formula("wget")])
        XCTAssertEqual(history.current, .installed(outdatedOnly: false))
        XCTAssertFalse(history.canGoForward)
    }
}
