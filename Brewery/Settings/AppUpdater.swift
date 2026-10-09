import Combine
import Sparkle
import SwiftUI

/// Sparkle owns download, signature verification, replacement, and relaunch UI.
/// SettingsRuntime owns the existing opt-in daily check schedule.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = ""
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var vm: BreweryViewModel?
    private let installationGate = AppUpdateInstallationGate()

    func start(vm: BreweryViewModel) {
        guard controller == nil, !AppPreferences.isTesting else { return }
        self.vm = vm
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        vm.$operations.sink { [weak self] _ in
            // @Published emits before storage changes. Read the live queue next turn,
            // so queued work added in the same turn cannot be missed.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installationGate.operationsChanged(isBusy: self.vm?.hasPendingOperations == true)
            }
        }.store(in: &subscriptions)
        do {
            try controller.updater.start()
            // Brewery's preference and scheduler remain the single source of truth.
            controller.updater.automaticallyChecksForUpdates = false
        } catch {
            status = error.localizedDescription
        }
    }

    @discardableResult
    func checkForUpdates(inBackground: Bool = false) -> Bool {
        guard !AppPreferences.isTesting, let controller, canCheckForUpdates else { return false }
        guard vm?.hasPendingOperations != true else {
            if !inBackground { status = BreweryLocalization.string("Finish package operations before updating Brewery.") }
            return false
        }
        status = BreweryLocalization.string("Checking for Brewery updates…")
        if inBackground { controller.updater.checkForUpdatesInBackground() }
        else { controller.checkForUpdates(nil) }
        return true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if vm?.hasPendingOperations == true {
            throw NSError(domain: "Brewery.AppUpdater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: BreweryLocalization.string("Finish package operations before updating Brewery.")])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = BreweryLocalization.string("A Brewery update is available. Follow the update window to install it.")
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Reserve admission before handing control to Sparkle's asynchronous
        // installer, including the already-idle case. Existing queued work drains.
        vm?.isPreparingAppUpdate = true
        let postponed = installationGate.postponeIfNeeded(isBusy: vm?.hasPendingOperations == true, install: installHandler)
        if postponed { status = BreweryLocalization.string("Brewery will restart after package operations finish.") }
        return postponed
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationGate.cancel()
        vm?.isPreparingAppUpdate = false
        let error = error as NSError
        status = error.code == SUError.noUpdateError.rawValue && error.domain == SUSparkleErrorDomain
            ? BreweryLocalization.string("Brewery is up to date.")
            : error.localizedDescription
    }
}

struct CheckForBreweryUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject var vm: BreweryViewModel

    var body: some View {
        Button("Check for Brewery Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates || vm.hasPendingOperations)
    }
}
