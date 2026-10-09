import XCTest
@testable import Brewery

@MainActor
final class InstalledPackageFilterTests: XCTestCase {
    private let rows = [
        InstalledPackageItem(id: .formula("owner/tap/tool"), name: "tool", version: "1", latestVersion: "2", isOutdated: true),
        InstalledPackageItem(id: .cask("tool"), name: "tool", version: "2", latestVersion: "2", isOutdated: false),
        InstalledPackageItem(id: .formula("git"), name: "git", version: "1", latestVersion: "2", isOutdated: true)
    ]
    func testSearchUsesCanonicalTapNameAndIgnoresCase() {
        XCTAssertEqual(InstalledPackageFilter(query: " OWNER/TAP ").apply(to: rows).map(\.id), [.formula("owner/tap/tool")])
    }
    func testTypeAndOutdatedFiltersCombine() {
        XCTAssertEqual(InstalledPackageFilter(kind: .cask, outdatedOnly: true).apply(to: rows).count, 0)
        XCTAssertEqual(InstalledPackageFilter(kind: .formula, outdatedOnly: true).apply(to: rows).count, 2)
    }
    func testUpgradeSelectionExcludesLatestMissingAndBusyPackages() {
        let selection: Set<PackageID> = [.formula("owner/tap/tool"), .cask("tool"), .formula("git"), .formula("missing")]
        XCTAssertEqual(InstalledPackageFilter.upgradeCandidates(selection: selection, items: rows, busy: [.formula("git")]), [.formula("owner/tap/tool")])
    }
    func testExclusionsUseQualifiedIdentityAndOnlyAffectBulkCandidates() {
        let sameNames = [
            InstalledPackageItem(id: .formula("tool"), name: "tool", version: "1", latestVersion: "2", isOutdated: true),
            InstalledPackageItem(id: .cask("tool"), name: "tool", version: "1", latestVersion: "2", isOutdated: true)
        ]
        XCTAssertEqual(InstalledPackageFilter.upgradeCandidates(selection: Set(sameNames.map(\.id)), items: sameNames, busy: [], excluded: ["formula:tool"]), [.cask("tool")])
        XCTAssertEqual(InstalledPackageFilter(outdatedOnly: true).apply(to: sameNames).count, 2)
    }

    func testUpdatesAndDirectInstallsSortBeforeAlphabeticalFallback() {
        let items = [
            InstalledPackageItem(id: .formula("a"), name: "a", version: "1", latestVersion: "1", isOutdated: false),
            InstalledPackageItem(id: .formula("z"), name: "z", version: "1", latestVersion: "1", isOutdated: false, isDirectInstall: true),
            InstalledPackageItem(id: .formula("b"), name: "b", version: "1", latestVersion: "2", isOutdated: true)
        ]
        XCTAssertEqual(InstalledPackageFilter(directFirst: true).apply(to: items).map(\.name), ["z", "a", "b"])
        XCTAssertEqual(InstalledPackageFilter(updatesFirst: true, directFirst: true).apply(to: items).map(\.name), ["b", "z", "a"])
        XCTAssertEqual(InstalledPackageFilter().apply(to: items).map(\.name), ["a", "b", "z"])
    }
}
