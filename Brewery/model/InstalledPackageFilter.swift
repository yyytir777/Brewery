import Foundation

struct InstalledPackageItem: Identifiable {
    let id: PackageID
    let name: String
    let version: String
    let latestVersion: String
    let isOutdated: Bool
    var isDirectInstall = false
    var description: String? = nil
}

struct InstalledPackageFilter {
    var query = ""
    var kind: PackageKind?
    var outdatedOnly = false
    var updatesFirst = false
    var directFirst = false

    func apply(to items: [InstalledPackageItem]) -> [InstalledPackageItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            (kind == nil || $0.id.kind == kind)
            && (!outdatedOnly || $0.isOutdated)
            && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.id.name.localizedCaseInsensitiveContains(term))
        }.sorted {
            if updatesFirst && $0.isOutdated != $1.isOutdated { return $0.isOutdated }
            if directFirst && $0.isDirectInstall != $1.isDirectInstall { return $0.isDirectInstall }
            return $0.id.name == $1.id.name ? $0.id.kind.rawValue < $1.id.kind.rawValue : $0.id.name.localizedStandardCompare($1.id.name) == .orderedAscending
        }
    }

    static func upgradeCandidates(selection: Set<PackageID>, items: [InstalledPackageItem], busy: Set<PackageID>, excluded: Set<String> = []) -> Set<PackageID> {
        Set(items.filter { selection.contains($0.id) && $0.isOutdated && !busy.contains($0.id) && !excluded.contains($0.id.id) }.map(\.id))
    }
}
