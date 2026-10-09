import SwiftUI

struct PackagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: BreweryViewModel
    let name: String
    let isCask: Bool
    @State private var formula: BreweryFormula?
    @State private var cask: BreweryCask?
    @State private var isLoading = true
    @State private var error: String?

    private var packageID: PackageID { isCask ? .cask(name) : .formula(name) }
    private var installed: Bool { vm.installedPackageIDs.contains(packageID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(name).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close package information")
                    .accessibilityIdentifier("preview.close")
            }
            if isLoading {
                ProgressView("Loading package information…").frame(maxWidth: .infinity, minHeight: 100)
            } else if let error {
                Label("Information unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preview.error")
                Button("Try Again") { Task { await loadInfo() } }
                    .accessibilityIdentifier("preview.retry")
            } else {
                if let description = formula?.desc ?? cask?.desc {
                    Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                GroupBox("Package information") {
                    VStack(spacing: 0) {
                        infoRow(key: "Version", value: formula?.latest_version ?? cask?.latest_version ?? "Unknown")
                        Divider()
                        infoLinkRow(key: "Homepage", url: formula?.homepage ?? cask?.homepage ?? "")
                    }
                }
                .accessibilityIdentifier("preview.content")
                HStack {
                    if !vm.hasLoadedInventory {
                        Text("Connect to Homebrew to install packages.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(LocalizedStringKey(installed ? "Installed" : vm.isOperating(packageID) ? "Waiting / Installing…" : "Install")) {
                        Task {
                            if isCask { await vm.installCask(name: name) }
                            else { await vm.installFormula(name: name) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installed || vm.isOperating(packageID) || !vm.hasLoadedInventory || vm.isHomebrewAvailable != true)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: packageID.id) { await loadInfo() }
    }

    private func loadInfo() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let info = try await vm.packageInfo(for: packageID)
            guard !Task.isCancelled else { return }
            formula = info.formula
            cask = info.cask
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
