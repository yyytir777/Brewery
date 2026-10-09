import Foundation

/// Keeps Sparkle's relaunch request pending until the entire Homebrew queue is idle.
@MainActor
final class AppUpdateInstallationGate {
    private var pendingInstall: (() -> Void)?

    func postponeIfNeeded(isBusy: Bool, install: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        pendingInstall = install
        return true
    }

    func operationsChanged(isBusy: Bool) {
        guard !isBusy, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    func cancel() { pendingInstall = nil }
}
