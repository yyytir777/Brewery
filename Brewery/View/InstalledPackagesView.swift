import SwiftUI

struct InstalledPackagesView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject var vm: BreweryViewModel
    let outdatedOnly: Bool
    let focusRequest: Int
    let onOpenPackage: (PackageID) -> Void
    let onChangeOutdatedFilter: (Bool) -> Void
    @Binding var query: String
    @Binding var kind: PackageKind?
    @Binding var selection: Set<PackageID>
    @FocusState private var searchFocused: Bool

    private var items: [InstalledPackageItem] {
        vm.installedFormula.map { InstalledPackageItem(id: $0.packageID, name: $0.name, version: $0.cur_version, latestVersion: $0.latest_version, isOutdated: vm.isOutdated($0.packageID), isDirectInstall: $0.installed.contains { $0.installed_on_request == true }, description: $0.desc) }
        + vm.installedCasks.map { InstalledPackageItem(id: $0.packageID, name: $0.name, version: $0.cur_version, latestVersion: $0.latest_version, isOutdated: vm.isOutdated($0.packageID), isDirectInstall: true, description: $0.desc) }
    }
    private var rows: [InstalledPackageItem] {
        InstalledPackageFilter(query: query, kind: kind, outdatedOnly: outdatedOnly, updatesFirst: preferences.values.sortOrder == "updates", directFirst: preferences.values.directFirst).apply(to: items)
    }
    private var upgrades: Set<PackageID> {
        InstalledPackageFilter.upgradeCandidates(selection: selection, items: items, busy: Set(items.filter { vm.isOperating($0.id) }.map(\.id)), excluded: Set(preferences.values.excludedUpdates))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey(outdatedOnly ? "Package Updates" : "Installed Packages")).font(.title2.bold())
                Spacer()
                if vm.isLoading { ProgressView().controlSize(.small) }
            }
            TextField("Search installed packages", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityIdentifier("installed.search")
            HStack {
                Picker("Type", selection: $kind) {
                    Text("All (\(items.count))").tag(Optional<PackageKind>.none)
                    Text("Formula (\(vm.installedFormula.count))").tag(Optional(PackageKind.formula))
                    Text("Cask (\(vm.installedCasks.count))").tag(Optional(PackageKind.cask))
                }.pickerStyle(.menu)
                    .accessibilityIdentifier("installed.typeFilter")
                Toggle("Updates only", isOn: Binding(get: { outdatedOnly }, set: { onChangeOutdatedFilter($0) }))
                    .accessibilityIdentifier("installed.updatesOnly")
                Spacer()
            }
            if let error = vm.inventoryError {
                InventoryErrorBanner(message: error) { Task { await vm.loadInstalled() } }
            }
            if let error = vm.outdatedError {
                InventoryErrorBanner(message: vm.hasLoadedOutdated ? "Update check failed. Showing the last successful result.\n\(error)" : "Updates could not be checked.\n\(error)") {
                    Task { await vm.loadInstalled() }
                }
            }
            if !vm.hasLoadedInventory && vm.isLoading {
                emptyState("Loading installed packages…", systemImage: "shippingbox")
            } else if rows.isEmpty {
                emptyState(emptyTitle, systemImage: outdatedOnly ? (vm.hasLoadedOutdated && vm.outdatedError == nil ? "checkmark.circle" : "clock.badge.exclamationmark") : "shippingbox")
                if !query.isEmpty || kind != nil {
                    Button("Clear Search and Type Filter") { query = ""; kind = nil }
                }
            } else {
                List(rows, selection: $selection) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).fontWeight(.semibold)
                            Text(row.id.name).font(.caption).foregroundStyle(.secondary)
                            if preferences.values.showDescription, let description = row.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        if preferences.values.showKind { Text(LocalizedStringKey(row.id.kind == .formula ? "Formula" : "Cask")).font(.caption).foregroundStyle(.secondary) }
                        if preferences.values.showVersion { VStack(alignment: .trailing, spacing: 3) {
                            Text(row.version).lineLimit(1)
                            if row.isOutdated { Text("Update available: \(row.latestVersion)").font(.caption).foregroundStyle(.orange).lineLimit(1) }
                        }
                        }
                        if vm.isOperating(row.id) { ProgressView().controlSize(.small) }
                        Button("View") { onOpenPackage(row.id) }.accessibilityLabel("View \(row.id.name)")
                            .accessibilityIdentifier("installed.view.\(row.id.id)")
                    }
                    .padding(.vertical, preferences.values.density == "comfortable" ? 8 : preferences.values.density == "compact" ? 0 : 3)
                    .tag(row.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("installed.row.\(row.id.id)")
                    .contextMenu { Button("View Details") { onOpenPackage(row.id) } }
                }
                .listStyle(.inset).accessibilityIdentifier("installed.results")
            }
            HStack {
                Text("\(rows.count) shown · \(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("installed.summary")
                Spacer()
                Button("Select Available Updates") { selection = Set(rows.filter { $0.isOutdated && !vm.isOperating($0.id) && !preferences.values.excludedUpdates.contains($0.id.id) }.map(\.id)) }
                    .accessibilityIdentifier("installed.selectUpdates")
                    .disabled(rows.allSatisfy { !$0.isOutdated || vm.isOperating($0.id) || preferences.values.excludedUpdates.contains($0.id.id) })
                Button("Update Selected (\(upgrades.count))") {
                    let requested = upgrades
                    Task { await vm.upgradePackages(requested) }
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("installed.upgradeSelection")
                .disabled(upgrades.isEmpty || vm.isHomebrewAvailable != true)
            }
        }
        .padding()
        .onAppear { if focusRequest > 0 { searchFocused = true } }
        .onChange(of: focusRequest) { _ in searchFocused = true }
        .onChange(of: vm.installedPackageIDs) { selection.formIntersection($0) }
        .onChange(of: query) { _ in selection.formIntersection(Set(rows.map(\.id))) }
        .onChange(of: kind) { _ in selection.formIntersection(Set(rows.map(\.id))) }
        .onChange(of: outdatedOnly) { _ in selection.formIntersection(Set(rows.map(\.id))) }
    }

    private var emptyTitle: String {
        if !vm.hasLoadedInventory && vm.inventoryError != nil { return "Installed packages could not be loaded." }
        if outdatedOnly && !vm.hasLoadedOutdated {
            if vm.outdatedError != nil { return "Updates could not be checked. Retry to see available updates." }
            return vm.isLoading ? "Checking for package updates…" : "Updates have not been checked yet. Refresh to check."
        }
        if !query.isEmpty || kind != nil { return "No installed packages match these filters." }
        if outdatedOnly && vm.outdatedError != nil { return "No updates in the last successful check. Retry to check again." }
        return outdatedOnly ? "All installed packages are up to date." : "No packages installed yet. Explore Search to get started."
    }
    private func emptyState(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InventoryErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Retry", action: retry)
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
