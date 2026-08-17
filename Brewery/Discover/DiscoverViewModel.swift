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

    private let service: any CatalogServing
    private var catalog: [CatalogPackage] = []
    private var rankings: [PackageID: PackageRanking] = [:]

    init(service: any CatalogServing) { self.service = service }

    func load() async {
        guard catalog.isEmpty else { return }
        do {
            let local = try await service.loadLocalData(for: window)
            catalog = local.catalog.packages
            apply(local.rankings)
            blockingError = nil
            await refresh()
        } catch { blockingError = error.localizedDescription }
    }

    func changeWindow(to newWindow: RankingWindow) async {
        window = newWindow
        rankings = [:]
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await service.refreshRankingsIfNeeded(for: window)
        if let snapshot = result.snapshot {
            apply(snapshot)
            lastSuccessfulRefresh = Date()
        }
        refreshMessage = result.messages.isEmpty ? nil : result.messages.joined(separator: "\n")
    }

    func rows(installedIDs: Set<PackageID>) -> [DiscoverRow] {
        let needle = normalized(query)
        let filtered = catalog.filter { package in
            let kindMatches = kindFilter == .all || (kindFilter == .formula && package.kind == .formula) || (kindFilter == .cask && package.kind == .cask)
            guard kindMatches else { return false }
            guard !needle.isEmpty else { return true }
            return normalized(package.name).contains(needle) || normalized(package.description ?? "").contains(needle)
        }
        return filtered.map { package in
            let ranking = rankings[package.id]
            return DiscoverRow(package: package, rank: ranking?.rank, installs: ranking?.installs, isInstalled: installedIDs.contains(package.id))
        }.sorted { lhs, rhs in
            if !needle.isEmpty {
                let leftExact = normalized(lhs.package.name) == needle
                let rightExact = normalized(rhs.package.name) == needle
                if leftExact != rightExact { return leftExact }
                let leftPrefix = normalized(lhs.package.name).hasPrefix(needle)
                let rightPrefix = normalized(rhs.package.name).hasPrefix(needle)
                if leftPrefix != rightPrefix { return leftPrefix }
            }
            if lhs.installs != rhs.installs { return (lhs.installs ?? -1) > (rhs.installs ?? -1) }
            return lhs.package.name.localizedStandardCompare(rhs.package.name) == .orderedAscending
        }
    }

    private func apply(_ snapshot: RankingSnapshot?) {
        guard let snapshot else { return }
        rankings = Dictionary(uniqueKeysWithValues: ((snapshot.formula?.entries ?? []) + (snapshot.cask?.entries ?? [])).map { ($0.packageID, $0) })
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
