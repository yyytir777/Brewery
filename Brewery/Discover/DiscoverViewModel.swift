import Foundation
import Combine

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var query = ""
    @Published var kindFilter: PackageKindFilter = .all
    @Published private(set) var window: RankingWindow = .days30
    @Published private(set) var isRefreshing = false
    @Published private(set) var blockingError: String?
    @Published private(set) var refreshMessage: String?
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var catalogUpdatedAt: Date?
    @Published private(set) var formulaRankingUpdatedAt: Date?
    @Published private(set) var caskRankingUpdatedAt: Date?

    private let service: any CatalogServing
    private var subscriptions = Set<AnyCancellable>()
    private var catalog: [CatalogPackage] = []
    private var catalogRevision = 0
    private var rankings: [PackageID: PackageRanking] = [:]
    private var snapshots: [RankingWindow: RankingSnapshot] = [:]
    private var requestNumber = 0
    private var latestRequestByWindow: [RankingWindow: Int] = [:]
    private var isLoading = false
    private var searchFields: [PackageID: (name: String, description: String)] = [:]
    private var alphabeticalRanks: [PackageID: Int] = [:]
    private var combinedRanks: [PackageID: Int] = [:]
    private var cachedRows: (query: String, filter: PackageKindFilter, installed: Set<PackageID>, rows: [DiscoverRow])?
    private let beforePreparingCatalog: (@Sendable (CatalogSnapshot) async -> Void)?

    private nonisolated struct CatalogIndex: Sendable {
        let searchFields: [PackageID: (name: String, description: String)]
        let alphabeticalRanks: [PackageID: Int]
    }

    init(service: any CatalogServing, preferences: AppPreferences? = nil, beforePreparingCatalog: (@Sendable (CatalogSnapshot) async -> Void)? = nil) {
        self.service = service
        self.beforePreparingCatalog = beforePreparingCatalog
        if let preferences {
            window = RankingWindow(rawValue: preferences.values.rankingWindow) ?? .days30
            let saved = preferences.values.rememberFilters && preferences.values.hasSavedSearchFilters
            query = saved ? preferences.values.savedSearchQuery : ""
            let initialKind = saved ? preferences.values.savedSearchKind : preferences.values.defaultKind
            kindFilter = PackageKindFilter.allCases.first { $0.rawValue.lowercased() == initialKind } ?? .all
            $query.combineLatest($kindFilter).dropFirst().sink { [weak preferences] query, kind in
                guard let preferences, preferences.values.rememberFilters else { return }
                var values = preferences.values
                values.savedSearchQuery = query
                values.savedSearchKind = kind.rawValue.lowercased()
                values.hasSavedSearchFilters = true
                if values != preferences.values { preferences.values = values }
            }.store(in: &subscriptions)
            preferences.resetEvents.sink { [weak self] in
                self?.query = ""
                self?.kindFilter = .all
            }.store(in: &subscriptions)
            preferences.$values.map(\.rememberFilters).removeDuplicates().dropFirst().sink { [weak preferences] enabled in
                guard !enabled else { return }
                Task { @MainActor in
                    preferences?.values.hasSavedSearchFilters = false
                    preferences?.values.savedSearchQuery = ""
                    preferences?.values.savedSearchKind = "all"
                }
            }.store(in: &subscriptions)
            preferences.$values.map(\.defaultKind).removeDuplicates().dropFirst().sink { [weak self] value in
                Task { @MainActor in
                    self?.kindFilter = PackageKindFilter.allCases.first { $0.rawValue.lowercased() == value } ?? .all
                }
            }.store(in: &subscriptions)
            preferences.$values.map(\.rankingWindow).removeDuplicates().dropFirst().sink { [weak self] value in
                Task { await self?.changeWindow(to: RankingWindow(rawValue: value) ?? .days30) }
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: .catalogCacheCleared)
            .merge(with: NotificationCenter.default.publisher(for: .catalogCacheUpdated)).sink { [weak self] notification in
            guard let self, let cleared = notification.object as? CatalogService, let own = self.service as? CatalogService, cleared === own else { return }
            self.requestNumber += 1
            self.latestRequestByWindow = [:]
            self.catalogRevision += 1
            self.catalog = []
            self.snapshots = [:]
            self.cachedRows = nil
            self.apply(nil)
            self.catalogUpdatedAt = nil
            self.isRefreshing = false
            Task { await self.reloadLocalCache() }
        }.store(in: &subscriptions)
    }

    private func reloadLocalCache() async {
        let revision = catalogRevision
        let requestedWindow = window
        do {
            let local = try await service.loadLocalData(for: requestedWindow)
            let index = await prepareCatalog(local.catalog)
            guard revision == catalogRevision else { return }
            setCatalog(local.catalog, index: index)
            if let snapshot = local.rankings { snapshots[requestedWindow] = snapshot }
            apply(snapshots[window])
        } catch {
            guard revision == catalogRevision else { return }
            blockingError = error.localizedDescription
        }
    }

    func load() async {
        guard catalog.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let requestedWindow = window
        let initialRequest = requestNumber
        let initialCatalogRevision = catalogRevision
        do {
            let local = try await service.loadLocalData(for: requestedWindow)
            let index = await prepareCatalog(local.catalog)
            guard catalogRevision == initialCatalogRevision else { return }
            setCatalog(local.catalog, index: index)
            if let snapshot = local.rankings, snapshot.window == requestedWindow {
                let newer = snapshots[requestedWindow]
                snapshots[requestedWindow] = RankingSnapshot(schemaVersion: 1, window: requestedWindow,
                    formula: newer?.formula ?? snapshot.formula, cask: newer?.cask ?? snapshot.cask)
            }
            apply(snapshots[window])
            blockingError = nil
            if requestNumber == initialRequest { await refresh() }
        } catch {
            guard catalogRevision == initialCatalogRevision else { return }
            blockingError = error.localizedDescription
        }
    }

    func changeWindow(to newWindow: RankingWindow) async {
        guard window != newWindow else { return }
        window = newWindow
        apply(snapshots[newWindow])
        await refresh()
    }

    func refresh(force: Bool = false) async {
        let requestedWindow = window
        requestNumber += 1
        let request = requestNumber
        latestRequestByWindow[requestedWindow] = request
        isRefreshing = true
        async let rankingResult = service.refreshRankingsIfNeeded(for: requestedWindow, force: force)
        var catalogMessage: String?
        var preparedCatalog: (snapshot: CatalogSnapshot, index: CatalogIndex)?
        do {
            if let catalog = try await service.refreshCatalogIfNeeded(force: force), request == requestNumber {
                preparedCatalog = (catalog, await prepareCatalog(catalog))
            }
        } catch { catalogMessage = "Catalog: \(error.localizedDescription)" }
        let result = await rankingResult
        guard latestRequestByWindow[requestedWindow] == request else { return }
        if let snapshot = result.snapshot, snapshot.window == requestedWindow {
            let previous = snapshots[requestedWindow]
            snapshots[requestedWindow] = RankingSnapshot(schemaVersion: 1, window: requestedWindow, formula: snapshot.formula ?? previous?.formula, cask: snapshot.cask ?? previous?.cask)
        }
        guard requestedWindow == window, request == requestNumber else { return }
        // Publish catalog and rankings in one actor turn, avoiding an intermediate
        // list calculation against the previous popularity snapshot.
        if let preparedCatalog { setCatalog(preparedCatalog.snapshot, index: preparedCatalog.index) }
        apply(snapshots[window])
        isRefreshing = false
        let messages = result.messages + service.catalogRefreshMessages + [catalogMessage].compactMap { $0 }
        refreshMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func rows(installedIDs: Set<PackageID>) -> [DiscoverRow] {
        let interval = DiscoverPerformance.begin("DiscoverRows")
        defer { DiscoverPerformance.end("DiscoverRows", id: interval) }
        let needle = normalized(query)
        if let cachedRows, cachedRows.query == needle, cachedRows.filter == kindFilter, cachedRows.installed == installedIDs { return cachedRows.rows }
        var candidates: [(row: DiscoverRow, relevance: Int)] = []
        for package in catalog {
            let kindMatches = kindFilter == .all || (kindFilter == .formula && package.kind == .formula) || (kindFilter == .cask && package.kind == .cask)
            guard kindMatches else { continue }
            let relevance: Int
            if needle.isEmpty { relevance = 0 }
            else if let fields = searchFields[package.id] {
                if fields.name == needle { relevance = 0 }
                else if fields.name.hasPrefix(needle) { relevance = 1 }
                else if fields.name.contains(needle) { relevance = 2 }
                else if fields.description.contains(needle) { relevance = 3 }
                else { continue }
            } else { continue }
            let ranking = rankings[package.id]
            let row = DiscoverRow(package: package, rank: kindFilter == .all ? combinedRanks[package.id] : ranking?.rank, installs: ranking?.installs, isInstalled: installedIDs.contains(package.id))
            candidates.append((row, relevance))
        }
        let rows = candidates.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            if lhs.row.installs != rhs.row.installs { return (lhs.row.installs ?? -1) > (rhs.row.installs ?? -1) }
            return precedes(lhs.row.package, rhs.row.package)
        }.map(\.row)
        cachedRows = (needle, kindFilter, installedIDs, rows)
        return rows
    }

    private func apply(_ snapshot: RankingSnapshot?) {
        rankings = [:]
        for ranking in (snapshot?.formula?.entries ?? []) + (snapshot?.cask?.entries ?? []) { rankings[ranking.packageID] = ranking }
        formulaRankingUpdatedAt = snapshot?.formula?.fetchedAt
        caskRankingUpdatedAt = snapshot?.cask?.fetchedAt
        lastSuccessfulRefresh = [formulaRankingUpdatedAt, caskRankingUpdatedAt].compactMap { $0 }.max()
        recomputeRanks()
    }

    private func setCatalog(_ snapshot: CatalogSnapshot, index: CatalogIndex) {
        catalogRevision += 1
        catalog = snapshot.packages
        blockingError = nil
        catalogUpdatedAt = snapshot.generatedAt
        searchFields = index.searchFields
        alphabeticalRanks = index.alphabeticalRanks
    }

    private func prepareCatalog(_ snapshot: CatalogSnapshot) async -> CatalogIndex {
        await beforePreparingCatalog?(snapshot)
        return await Task.detached(priority: .userInitiated) {
            let interval = DiscoverPerformance.begin("CatalogSearchIndex")
            defer { DiscoverPerformance.end("CatalogSearchIndex", id: interval) }
            let locale = Locale.current
            var fields: [PackageID: (name: String, description: String)] = [:]
            for package in snapshot.packages {
                fields[package.id] = (
                    package.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale),
                    (package.description ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                )
            }
            let ordered = snapshot.packages.sorted { lhs, rhs in
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.id.id < rhs.id.id : comparison == .orderedAscending
            }
            var order: [PackageID: Int] = [:]
            for (index, package) in ordered.enumerated() { order[package.id] = index }
            return CatalogIndex(searchFields: fields, alphabeticalRanks: order)
        }.value
    }

    private func recomputeRanks() {
        let ranked = catalog.filter { rankings[$0.id] != nil }.sorted {
            let left = rankings[$0.id]?.installs ?? -1
            let right = rankings[$1.id]?.installs ?? -1
            return left == right ? precedes($0, $1) : left > right
        }
        combinedRanks = [:]
        for (index, package) in ranked.enumerated() { combinedRanks[package.id] = index + 1 }
        cachedRows = nil
    }

    private func precedes(_ lhs: CatalogPackage, _ rhs: CatalogPackage) -> Bool {
        let left = alphabeticalRanks[lhs.id] ?? .max
        let right = alphabeticalRanks[rhs.id] ?? .max
        return left == right ? lhs.id.id < rhs.id.id : left < right
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
