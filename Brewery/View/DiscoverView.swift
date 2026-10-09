import SwiftUI

struct DiscoverView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    @ObservedObject var breweryViewModel: BreweryViewModel
    @FocusState private var searchFocused: Bool
    @StateObject private var searchTrace = DiscoverSearchTrace()
    let focusRequest: Int
    let onOpenInstalled: (PackageID) -> Void

    private var rows: [DiscoverRow] { viewModel.rows(installedIDs: breweryViewModel.installedPackageIDs) }
    private struct ScrollRequest: Hashable {
        let query: String
        let kind: PackageKindFilter
        let window: RankingWindow
    }
    private var scrollRequest: ScrollRequest {
        ScrollRequest(query: viewModel.query, kind: viewModel.kindFilter, window: viewModel.window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search packages by name or description", text: Binding(get: { viewModel.query }, set: { value in
                if value != viewModel.query { searchTrace.beginEdit() }
                viewModel.query = value
            }))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("discover.search")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    kindPicker.frame(width: 235)
                    periodPicker.frame(width: 280)
                }
                VStack(alignment: .leading, spacing: 10) {
                    kindPicker
                    periodPicker
                }
            }
            HStack {
                Text("Rank").frame(width: 38, alignment: .trailing)
                    .help("Popularity rank across all packages in the selected type, including when searching.")
                Text("Package")
                Spacer()
                Text("Installs · \(BreweryLocalization.string(viewModel.window.title))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = viewModel.blockingError, rows.isEmpty {
                emptyState(title: "Catalog unavailable", message: error, symbol: "wifi.exclamationmark")
                Button("Try Again") { Task { await viewModel.refresh(force: true) } }
            } else if rows.isEmpty && viewModel.query.isEmpty && viewModel.isRefreshing {
                ProgressView("Loading packages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState(title: "No matching packages", message: "Try another name or clear the filters.", symbol: "magnifyingglass")
                Button("Clear Filters") { viewModel.query = ""; viewModel.kindFilter = .all }
            } else {
                List(rows) { row in
                    DiscoverPackageRow(row: row, vm: breweryViewModel, onOpenInstalled: onOpenInstalled)
                }
                .listStyle(.plain)
                .id(scrollRequest)
                .accessibilityIdentifier("discover.results")
            }
            if let message = viewModel.refreshMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("discover.refreshMessage")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…")
                } else if let date = viewModel.lastSuccessfulRefresh {
                    Text("Popularity updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .help(freshnessDescription)
                } else {
                    Text("Popularity unavailable · packages remain searchable")
                }
                Spacer()
                Button { Task { await viewModel.refresh(force: true) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)
                .help("Refresh catalog and popularity")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(DiscoverWindowUpdateProbe(generation: searchTrace.generation, trace: searchTrace).accessibilityHidden(true))
        .onDisappear { searchTrace.cancel() }
        .navigationTitle("Search")
        .task { await viewModel.load() }
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            await Task.yield()
            searchFocused = true
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $viewModel.kindFilter) {
            ForEach(PackageKindFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var periodPicker: some View {
        Picker("Period", selection: Binding(get: { viewModel.window }, set: { value in
            Task { await viewModel.changeWindow(to: value) }
        })) {
            ForEach(RankingWindow.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var freshnessDescription: String {
        [
            ("Catalog", viewModel.catalogUpdatedAt),
            ("Formula popularity", viewModel.formulaRankingUpdatedAt),
            ("Cask popularity", viewModel.caskRankingUpdatedAt)
        ].map { label, date in
            "\(label): \(date?.formatted(date: .abbreviated, time: .shortened) ?? "Not available")"
        }.joined(separator: "\n")
    }

    private func emptyState(title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(message)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiscoverPackageRow: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let row: DiscoverRow
    @ObservedObject var vm: BreweryViewModel
    let onOpenInstalled: (PackageID) -> Void
    @State private var showsInfo = false

    var body: some View {
        HStack(spacing: 12) {
            Text(row.rank.map(String.init) ?? "—")
                .monospacedDigit().frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.package.name).fontWeight(.semibold).lineLimit(1)
                    if preferences.values.showKind { Text(LocalizedStringKey(row.package.kind == .formula ? "Formula" : "Cask")).font(.caption).foregroundStyle(.secondary) }
                }
                if preferences.values.showDescription, let description = row.package.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if preferences.values.showVersion, let version = row.package.latestVersion { Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Text(row.installs?.formatted() ?? "—").monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("\(row.installs?.formatted() ?? "Unavailable") installs")
            if row.isInstalled {
                Button("View") { onOpenInstalled(row.package.id) }
                    .accessibilityIdentifier("discover.view.\(row.package.id.id)")
                    .accessibilityLabel("View \(row.package.name)")
            } else {
                Button("Info") { showsInfo = true }
                    .accessibilityIdentifier("discover.info.\(row.package.id.id)")
                    .accessibilityLabel("Information about \(row.package.name)")
                    .popover(isPresented: $showsInfo) {
                        PackagePreviewView(vm: vm, name: row.package.name, isCask: row.package.kind == .cask)
                    }
                Button(LocalizedStringKey(vm.isOperating(row.package.id) ? "Waiting…" : "Install")) {
                    Task {
                        if row.package.kind == .cask { await vm.installCask(name: row.package.name) }
                        else { await vm.installFormula(name: row.package.name) }
                    }
                }
                .disabled(vm.isOperating(row.package.id) || !vm.hasLoadedInventory || vm.isHomebrewAvailable != true)
                .accessibilityLabel("Install \(row.package.name)")
                .accessibilityIdentifier("discover.install.\(row.package.id.id)")
            }
        }
        .padding(.vertical, preferences.values.density == "comfortable" ? 8 : preferences.values.density == "compact" ? 0 : 3)
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
    }
}
