import SwiftUI

struct HomeView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var settingsRuntime = SettingsRuntime.shared
    @ObservedObject var vm: BreweryViewModel
    let onNavigate: (BreweryDestination) -> Void
    @State private var showCleanup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Brewery").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text([vm.brewVersion, preferences.values.formatHomebrewSize(vm.brewSize)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = vm.inventoryError { InventoryErrorBanner(message: error) { Task { await vm.loadInstalled() } } }
                if let error = vm.outdatedError {
                    InventoryErrorBanner(message: vm.hasLoadedOutdated ? "Update check failed. Showing the last successful result.\n\(error)" : "Updates could not be checked.\n\(error)") {
                        Task { await vm.loadInstalled() }
                    }
                }
                HStack(spacing: 16) {
                    summary("Installed", count: vm.installedPackageIDs.count, hasValue: vm.hasLoadedInventory, destination: .installed(outdatedOnly: false))
                    summary("Updates", count: vm.outdatedCount, hasValue: vm.hasLoadedOutdated, destination: .installed(outdatedOnly: true))
                }
                Text(vm.hasLoadedInventory ? "\(vm.installedFormula.count) Formula · \(vm.installedCasks.count) Cask" : vm.isLoading ? "Loading installed packages…" : "Installed packages unavailable")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Package updates", systemImage: "shippingbox").font(.headline)
                        Text(LocalizedStringKey(updateSummary))
                            .foregroundStyle(.secondary)
                        Button("Review Package Updates") { onNavigate(.installed(outdatedOnly: true)) }
                            .accessibilityIdentifier("home.reviewUpdates")
                            .buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Homebrew maintenance").font(.headline)
                        Text("Refresh Homebrew updates its package definitions. Installed packages are updated separately from Package Updates.")
                            .font(.callout).foregroundStyle(.secondary)
                        if settingsRuntime.cleanupReminderAvailable {
                            Label("It may be time to review old Homebrew files. Preview cleanup to see what can be removed.", systemImage: "sparkles")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(LocalizedStringKey(vm.isRunningUpdate ? "Refreshing Homebrew…" : "Refresh Homebrew")) { Task { await vm.brewSelfUpdate() } }
                                .disabled(vm.hasPendingOperations || vm.isHomebrewAvailable != true)
                            Button(LocalizedStringKey(vm.isPreviewingCleanup ? "Checking Cleanup…" : "Preview Cleanup…")) {
                                vm.clearCleanupPreview()
                                showCleanup = true
                                Task { await vm.previewCleanup() }
                            }.disabled(vm.hasPendingOperations || vm.isPreviewingCleanup || vm.isHomebrewAvailable != true)
                        }
                        if vm.isLatestAfterUpdate == true { Label("Homebrew definitions refreshed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                        if let message = vm.cleanupMessage { Text(message).font(.caption).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let active = vm.activeOperation {
                    HStack { ProgressView().controlSize(.small); Text(active.kind.localizedTitle); Spacer(); Text(LocalizedStringKey(active.status.rawValue)).foregroundStyle(.secondary) }
                }
            }.padding(24)
        }
        .sheet(isPresented: $showCleanup, onDismiss: { vm.clearCleanupPreview() }) { CleanupPreviewView(vm: vm) }
    }

    private var updateSummary: String {
        if !vm.hasLoadedInventory { return "Load the installed package list to check for updates." }
        if !vm.hasLoadedOutdated {
            return vm.outdatedError != nil ? "Retry the update check to see available package updates." : "Checking for available package updates…"
        }
        if vm.outdatedError != nil { return BreweryLocalization.format("The last successful check found %lld package updates. Retry to check again.", Int64(vm.outdatedCount)) }
        return vm.outdatedCount == 0 ? "Your installed packages are up to date." : "Review available updates and choose the packages to update."
    }

    private func summary(_ title: String, count: Int, hasValue: Bool, destination: BreweryDestination) -> some View {
        Button { onNavigate(destination) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(LocalizedStringKey(title)).foregroundStyle(.secondary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                if vm.isLoading { ProgressView().frame(height: 32) }
                else { Text(hasValue ? count.formatted() : "—").font(.system(.largeTitle, design: .rounded, weight: .bold)) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct CleanupPreviewView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var settingsRuntime = SettingsRuntime.shared
    @ObservedObject var vm: BreweryViewModel
    @Environment(\.dismiss) private var dismiss
    private var canClean: Bool {
        guard let output = vm.cleanupPreview?.output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.hasPendingOperations && !vm.isPreviewingCleanup && vm.isHomebrewAvailable == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview Homebrew Cleanup").font(.title2.bold())
            Text("Homebrew's dry run lists old versions and cached files it will remove, with estimated savings when available.")
                .foregroundStyle(.secondary)
            if vm.isPreviewingCleanup { ProgressView("Checking cleanup targets…").frame(maxWidth: .infinity, minHeight: 150) }
            else if let preview = vm.cleanupPreview {
                if preview.output.isEmpty { Text("There are no files to clean up.").frame(maxWidth: .infinity, minHeight: 150) }
                else {
                    ScrollView { Text(preview.output).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minHeight: 150, maxHeight: 300)
                }
            } else { Text("Cleanup preview could not be loaded. Close this sheet and retry.").frame(maxWidth: .infinity, minHeight: 150) }
            Text("Cleanup permanently deletes these files and cannot be undone. Homebrew checks the targets again when it runs.")
                .font(.callout)
            if vm.hasPendingOperations { Text("Wait for the current operations to finish before cleaning up.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Permanently Clean Up", role: .destructive) {
                    guard canClean else { return }
                    dismiss()
                    Task { await vm.brewCleanUp() }
                }.disabled(!canClean)
            }
        }.padding(24).frame(width: 580)
    }
}
