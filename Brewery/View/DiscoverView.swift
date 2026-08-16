import SwiftUI

struct DiscoverView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    @ObservedObject var breweryViewModel: BreweryViewModel
    @State private var previewPackage: CatalogPackage?
    @FocusState private var searchFocused: Bool
    let focusRequest: Int
    let onOpenInstalled: (PackageID) -> Void

    private var rows: [DiscoverRow] { viewModel.rows(installedIDs: breweryViewModel.installedPackageIDs) }

    var body: some View {
        VStack(spacing: 12) {
            TextField("Search packages by name or description", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            HStack {
                Picker("Type", selection: $viewModel.kindFilter) {
                    ForEach(PackageKindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Period", selection: Binding(get: { viewModel.window }, set: { value in Task { await viewModel.changeWindow(to: value) } })) {
                    ForEach(RankingWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if let error = viewModel.blockingError, rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Catalog unavailable").font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await viewModel.load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No packages match “\(viewModel.query)”").font(.headline)
                    Button("Clear Filters") { viewModel.query = ""; viewModel.kindFilter = .all }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    HStack(spacing: 12) {
                        Text(row.rank.map(String.init) ?? "—").monospacedDigit().frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(row.package.name).fontWeight(.semibold); Text(row.package.kind == .formula ? "Formula" : "Cask").font(.caption).foregroundStyle(.secondary) }
                            if let description = row.package.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(row.installs?.formatted() ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        if row.isInstalled {
                            Button("View") { onOpenInstalled(row.package.id) }
                        } else {
                            Button("Info") { previewPackage = row.package }
                            Button(breweryViewModel.installingPackageIDs.contains(row.package.id) ? "Installing…" : "Install") {
                                Task {
                                    if row.package.kind == .cask { await breweryViewModel.installCask(name: row.package.name) }
                                    else { await breweryViewModel.installFormula(name: row.package.name) }
                                }
                            }.disabled(breweryViewModel.installingPackageIDs.contains(row.package.id))
                        }
                    }
                }
            }
            HStack {
                if viewModel.isRefreshing { ProgressView().controlSize(.small); Text("Refreshing popularity…") }
                if let message = viewModel.refreshMessage { Text(message).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
                Button { Task { await viewModel.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(viewModel.isRefreshing)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .task { await viewModel.load() }
        .onChange(of: focusRequest) { _ in searchFocused = true }
        .popover(item: $previewPackage) { package in PackagePreviewView(vm: breweryViewModel, name: package.name, isCask: package.kind == .cask) }
    }
}
