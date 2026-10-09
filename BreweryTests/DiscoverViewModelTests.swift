import XCTest
@testable import Brewery

final class DiscoverViewModelTests: XCTestCase {
    @MainActor
    func testSearchRemembersFiltersOnlyWhenEnabledAndUsesDefaultOtherwise() async {
        let suite = "Brewery.SearchPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.values.defaultKind = "formula"
        let model = DiscoverViewModel(service: ImmediateCatalogService(), preferences: preferences)
        XCTAssertEqual(model.kindFilter, .formula)
        model.query = "editor"
        model.kindFilter = .cask
        let restored = DiscoverViewModel(service: ImmediateCatalogService(), preferences: preferences)
        XCTAssertEqual(restored.query, "editor")
        XCTAssertEqual(restored.kindFilter, .cask)
        preferences.values.rememberFilters = false
        model.query = "not saved"
        let fresh = DiscoverViewModel(service: ImmediateCatalogService(), preferences: preferences)
        XCTAssertEqual(fresh.query, "")
        XCTAssertEqual(fresh.kindFilter, .formula)
        XCTAssertEqual(preferences.values.savedSearchQuery, "editor")
        preferences.values.defaultKind = "cask"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fresh.kindFilter, .cask)
    }

    @MainActor
    func testResetClearsSearchFieldsAndStoredFilters() async {
        let preferences = AppPreferences(persistChanges: false)
        let model = DiscoverViewModel(service: ImmediateCatalogService(), preferences: preferences)
        model.query = "old query"
        model.kindFilter = .cask
        preferences.reset()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.kindFilter, .all)
        XCTAssertEqual(preferences.values.savedSearchQuery, "")
        XCTAssertEqual(preferences.values.savedSearchKind, "all")
    }

    @MainActor
    func testLateInitialCatalogPreparationCannotReplaceNewerAppliedCatalogOrSearchIndex() async {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let service = ImmediateCatalogService()
        service.localGeneratedAt = oldDate
        service.packages = [testPackage("obsolete10", description: "retired metadata")]
        service.updatedCatalog = CatalogSnapshot(schemaVersion: 1, generatedAt: newDate,
                                                 packages: [testPackage("current2", description: "fresh metadata")])
        let started = expectation(description: "Initial catalog preparation started")
        let gate = DeferredIndexPreparation(started: started)
        let model = DiscoverViewModel(service: service, beforePreparingCatalog: { snapshot in
            if snapshot.generatedAt == oldDate { await gate.wait() }
        })
        let initialLoad = Task { await model.load() }
        await fulfillment(of: [started], timeout: 5)

        await model.refresh(force: true)
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("current2")])
        XCTAssertEqual(model.catalogUpdatedAt, newDate)
        // A redundant refresh after stale load completion must not hide an incorrect overwrite.
        service.updatedCatalog = nil
        gate.release()
        await initialLoad.value

        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("current2")])
        XCTAssertEqual(model.catalogUpdatedAt, newDate)
        model.query = "fresh"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("current2")])
        model.query = "retired"
        XCTAssertTrue(model.rows(installedIDs: []).isEmpty)
    }

    @MainActor
    func testInitialPreparedCatalogRemainsVisibleWhileNewerRankingRequestIsPending() async {
        let oldDate = Date(timeIntervalSince1970: 100)
        let service = DeferredCatalogService()
        service.localGeneratedAt = oldDate
        let started = expectation(description: "Initial catalog preparation started")
        let requested = expectation(description: "Newer ranking request started")
        let initialFinished = expectation(description: "Initial load publishes local data without another refresh")
        service.onRequest = { if $0 == .days90 { requested.fulfill() } }
        let gate = DeferredIndexPreparation(started: started)
        let model = DiscoverViewModel(service: service, beforePreparingCatalog: { snapshot in
            if snapshot.generatedAt == oldDate { await gate.wait() }
        })
        let initialLoad = Task { await model.load(); initialFinished.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let ninety = Task { await model.changeWindow(to: .days90) }
        await fulfillment(of: [requested], timeout: 5)

        gate.release()
        await fulfillment(of: [initialFinished], timeout: 5)
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.cask("firefox"), .formula("git")])
        XCTAssertEqual(model.catalogUpdatedAt, oldDate)
        XCTAssertEqual(service.requested, [.days90], "Publishing local data must not duplicate the newer refresh")
        XCTAssertTrue(model.isRefreshing)

        service.finish(.days90, installs: 90)
        await initialLoad.value
        await ninety.value
        XCTAssertEqual(model.window, .days90)
        XCTAssertEqual(model.rows(installedIDs: []).first(where: { $0.id == .formula("git") })?.installs, 90)
        XCTAssertFalse(model.isRefreshing)
    }

    @MainActor
    func testNaturalNameOrderingBreaksPopularityTiesAndKeepsGlobalRanksAfterSearch() async {
        let service = ImmediateCatalogService()
        service.packages = [testPackage("tool10"), testPackage("tool2"), testPackage("tool1")]
        let model = DiscoverViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("tool1"), .formula("tool2"), .formula("tool10")])

        service.result = RankingRefreshResult(snapshot: RankingSnapshot(schemaVersion: 1, window: .days30,
            formula: RankingSection(fetchedAt: Date(timeIntervalSince1970: 1_000), entries: [
                PackageRanking(packageID: .formula("tool10"), installs: 100, rank: 1),
                PackageRanking(packageID: .formula("tool2"), installs: 100, rank: 2),
                PackageRanking(packageID: .formula("tool1"), installs: 100, rank: 3)
            ]), cask: nil), messages: [])
        await model.refresh(force: true)
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("tool1"), .formula("tool2"), .formula("tool10")])
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [1, 2, 3])
        model.query = "tool2"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("tool2")])
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [2])
    }

    @MainActor
    func testSameNameFormulaAndCaskUseDeterministicIdentityTieBreak() async {
        let service = ImmediateCatalogService()
        service.packages = [testPackage("tool"), testPackage("tool", kind: .cask)]
        service.localRankings = RankingSnapshot(schemaVersion: 1, window: .days30,
            formula: RankingSection(fetchedAt: Date(timeIntervalSince1970: 1_000), entries: [PackageRanking(packageID: .formula("tool"), installs: 100, rank: 1)]),
            cask: RankingSection(fetchedAt: Date(timeIntervalSince1970: 1_000), entries: [PackageRanking(packageID: .cask("tool"), installs: 100, rank: 1)]))
        let model = DiscoverViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.rows(installedIDs: [.formula("tool")]).map(\.id), [.cask("tool"), .formula("tool")])
        XCTAssertEqual(model.rows(installedIDs: [.formula("tool")]).map(\.isInstalled), [false, true])
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [1, 2])
        model.query = "TOOL"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.cask("tool"), .formula("tool")])
        model.kindFilter = .formula
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("tool")])
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [1])
    }

    @MainActor
    func testNameAndDescriptionSearchFoldCaseAndDiacriticsAcrossQueryChanges() async {
        let service = ImmediateCatalogService()
        service.packages = [testPackage("café"), testPackage("report", description: "Résumé JSON utilities"), testPackage("cafeteria", kind: .cask)]
        let model = DiscoverViewModel(service: service)
        await model.load()
        let searches: [(query: String, expected: [PackageID])] = [
            ("CAFE", [.formula("café"), .cask("cafeteria")]),
            ("café", [.formula("café"), .cask("cafeteria")]),
            ("RESUME", [.formula("report")]),
            ("résumé", [.formula("report")]),
            ("json", [.formula("report")]),
            ("absent", [])
        ]
        for search in searches {
            model.query = search.query
            XCTAssertEqual(model.rows(installedIDs: []).map(\.id), search.expected, "Query: \(search.query)")
        }
    }

    @MainActor
    func testLatestPeriodWinsWhenResponsesFinishInReverseOrder() async {
        let service = DeferredCatalogService()
        let initialRequested = expectation(description: "Initial period requested")
        let ninetyRequested = expectation(description: "Ninety-day period requested")
        let yearRequested = expectation(description: "Year period requested")
        service.onRequest = {
            switch $0 {
            case .days30: initialRequested.fulfill()
            case .days90: ninetyRequested.fulfill()
            case .days365: yearRequested.fulfill()
            }
        }
        let model = DiscoverViewModel(service: service)
        let load = Task { await model.load() }
        await fulfillment(of: [initialRequested], timeout: 5)
        let ninety = Task { await model.changeWindow(to: .days90) }
        await fulfillment(of: [ninetyRequested], timeout: 5)
        let year = Task { await model.changeWindow(to: .days365) }
        await fulfillment(of: [yearRequested], timeout: 5)
        XCTAssertEqual(service.requested, [.days30, .days90, .days365])
        service.finish(.days365, installs: 365)
        await year.value
        service.finish(.days90, installs: 90)
        await ninety.value
        service.finish(.days30, installs: 30)
        await load.value
        XCTAssertEqual(model.window, .days365)
        XCTAssertEqual(model.rows(installedIDs: []).first?.installs, 365)
        XCTAssertFalse(model.isRefreshing)
    }

    @MainActor
    func testPartialRefreshKeepsLastSuccessfulSource() async {
        let service = ImmediateCatalogService()
        service.localRankings = snapshot(formula: 30, cask: 20)
        service.result = RankingRefreshResult(snapshot: snapshot(formula: 31, cask: nil), messages: ["Cask rankings unavailable"])
        let model = DiscoverViewModel(service: service)
        await model.load()
        let rows = model.rows(installedIDs: [])
        XCTAssertEqual(rows.first(where: { $0.id == .formula("git") })?.installs, 31)
        XCTAssertEqual(rows.first(where: { $0.id == .cask("firefox") })?.installs, 20)
        XCTAssertNotNil(model.refreshMessage)
    }

    @MainActor
    func testAllRanksAreGlobalAndSearchDoesNotRenumberThem() async {
        let service = ImmediateCatalogService()
        service.localRankings = snapshot(formula: 30, cask: 20)
        let model = DiscoverViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [1, 2])
        model.query = "firefox"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [2])
        model.kindFilter = .cask
        XCTAssertEqual(model.rows(installedIDs: []).map(\.rank), [1])
    }

    @MainActor
    func testSearchPreservesAccentCaseAndInstalledState() async {
        let service = ImmediateCatalogService()
        service.packages.append(CatalogPackage(id: .formula("café"), name: "café", kind: .formula, description: "한글 검색", homepage: nil, latestVersion: nil))
        let model = DiscoverViewModel(service: service)
        await model.load()
        model.query = "CAFE"
        XCTAssertEqual(model.rows(installedIDs: [.formula("café")]).map(\.id), [.formula("café")])
        XCTAssertEqual(model.rows(installedIDs: []).map(\.isInstalled), [false])
        model.query = "한글"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("café")])
    }

    @MainActor
    func testNameMatchPrecedesDescriptionOnlyMatchRegardlessOfPopularity() async {
        let service = ImmediateCatalogService()
        service.packages = [CatalogPackage(id: .formula("bigit"), name: "bigit", kind: .formula, description: nil, homepage: nil, latestVersion: nil), CatalogPackage(id: .formula("popular"), name: "popular", kind: .formula, description: "git integration", homepage: nil, latestVersion: nil)]
        service.localRankings = RankingSnapshot(schemaVersion: 1, window: .days30, formula: RankingSection(fetchedAt: Date(), entries: [PackageRanking(packageID: .formula("popular"), installs: 1_000, rank: 1), PackageRanking(packageID: .formula("bigit"), installs: 2, rank: 2)]), cask: nil)
        let model = DiscoverViewModel(service: service)
        await model.load()
        model.query = "git"
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.formula("bigit"), .formula("popular")])
    }

    @MainActor
    func testRefreshRecoversBlockingCatalogError() async {
        let service = ImmediateCatalogService()
        service.loadFails = true
        let model = DiscoverViewModel(service: service)
        await model.load()
        XCTAssertNotNil(model.blockingError)
        service.updatedCatalog = CatalogSnapshot(schemaVersion: 1, generatedAt: Date(), packages: service.packages)
        await model.refresh(force: true)
        XCTAssertNil(model.blockingError)
        XCTAssertEqual(model.rows(installedIDs: []).map(\.id), [.cask("firefox"), .formula("git")])
    }

}

private func testPackage(_ name: String, kind: PackageKind = .formula, description: String? = nil) -> CatalogPackage {
    CatalogPackage(id: kind == .formula ? .formula(name) : .cask(name), name: name, kind: kind,
                   description: description, homepage: nil, latestVersion: nil)
}

private func snapshot(formula: Int?, cask: Int?, window: RankingWindow = .days30) -> RankingSnapshot {
    RankingSnapshot(schemaVersion: 1, window: window,
                    formula: formula.map { RankingSection(fetchedAt: Date(timeIntervalSince1970: 1_000), entries: [PackageRanking(packageID: .formula("git"), installs: $0, rank: 1)]) },
                    cask: cask.map { RankingSection(fetchedAt: Date(timeIntervalSince1970: 1_000), entries: [PackageRanking(packageID: .cask("firefox"), installs: $0, rank: 1)]) })
}

@MainActor private class ImmediateCatalogService: CatalogServing {
    var packages = [CatalogPackage(id: .formula("git"), name: "git", kind: .formula, description: "Version control", homepage: nil, latestVersion: nil), CatalogPackage(id: .cask("firefox"), name: "firefox", kind: .cask, description: "Browser", homepage: nil, latestVersion: nil)]
    var localRankings: RankingSnapshot?
    var result = RankingRefreshResult(snapshot: nil, messages: [])
    var loadFails = false
    var updatedCatalog: CatalogSnapshot?
    var localGeneratedAt = Date()
    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData {
        if loadFails { throw CatalogServiceError.missingBundledCatalog }
        return DiscoverLocalData(catalog: CatalogSnapshot(schemaVersion: 1, generatedAt: localGeneratedAt, packages: packages), rankings: localRankings)
    }
    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? { updatedCatalog }
    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult { result }
}

@MainActor private final class DeferredCatalogService: ImmediateCatalogService {
    var requested: [RankingWindow] = []
    var onRequest: ((RankingWindow) -> Void)?
    private var pending: [RankingWindow: [CheckedContinuation<RankingRefreshResult, Never>]] = [:]
    override func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        requested.append(window)
        return await withCheckedContinuation {
            pending[window, default: []].append($0)
            onRequest?(window)
        }
    }
    func finish(_ window: RankingWindow, installs: Int) {
        for continuation in pending.removeValue(forKey: window) ?? [] {
            continuation.resume(returning: RankingRefreshResult(snapshot: snapshot(formula: installs, cask: nil, window: window), messages: []))
        }
    }
}

@MainActor private final class DeferredIndexPreparation {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
