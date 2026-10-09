import AppKit
import Combine
import UserNotifications

nonisolated enum SettingsPolicy {
    static func shouldCheck(cadence: String, lastCheck: Date?, now: Date, launching: Bool) -> Bool {
        switch cadence {
        case "launch": return launching
        case "daily": return lastCheck.map { now.timeIntervalSince($0) >= 86400 } ?? true
        default: return false
        }
    }

    static func newlyAvailableUpdates(current: Set<String>, previouslySeen: Set<String>) -> Set<String> {
        current.subtracting(previouslySeen)
    }

    static func needsInitialSnapshot(hasLoaded: Bool, cadence: String) -> Bool {
        !hasLoaded && cadence != "manual"
    }

    static func shouldRemindCleanup(lastCleanup: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCleanup) >= 7 * 86400
    }

    static func isValidVersion(_ value: String) -> Bool {
        let cleaned = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }
    }

    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let cleaned = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let values = cleaned.split(separator: ".", omittingEmptySubsequences: false)
            guard !values.isEmpty, values.allSatisfy({ Int($0) != nil }) else { return nil }
            return values.compactMap { Int($0) }
        }
        guard let lhs = parts(candidate), let rhs = parts(current) else { return false }
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

@MainActor
final class SettingsRuntime: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SettingsRuntime()
    @Published private(set) var status = ""
    @Published private(set) var notificationStatus = ""
    @Published private(set) var cleanupReminderAvailable = false
    private weak var vm: BreweryViewModel?
    private var timer: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var completedOperations: Set<UUID> = []
    private var knownUpdates: Set<String> = []
    private var lastCheck: Date?
    private var lastAppCheck: Date?
    private var lastLogPrune: Date?
    private var lastLogRetentionDays: Int?
    private var lastCleanup = Date()
    private var observedBrewPath = ""
    private var checking = false
    private var enabled = false
    private let preferences = AppPreferences.shared

    func start(vm: BreweryViewModel) {
        guard !enabled, !AppPreferences.isTesting else { return }
        enabled = true
        let defaults = UserDefaults.standard
        lastCheck = defaults.object(forKey: "Brewery.settings.lastPackageCheck") as? Date
        lastAppCheck = defaults.object(forKey: "Brewery.settings.lastAppCheck") as? Date
        lastCleanup = defaults.object(forKey: "Brewery.settings.lastCleanup") as? Date ?? Date()
        defaults.set(lastCleanup, forKey: "Brewery.settings.lastCleanup")
        UNUserNotificationCenter.current().delegate = self
        self.vm = vm
        AppUpdater.shared.start(vm: vm)
        observedBrewPath = preferences.values.brewPath
        completedOperations = Set(vm.operations.filter { !$0.isPending }.map(\.id))
        vm.$operations.sink { [weak self] operations in
            guard let self else { return }
            for operation in operations where operation.status == .succeeded || operation.status == .failed {
                guard self.completedOperations.insert(operation.id).inserted else { continue }
                if operation.kind == .cleanup, operation.status == .succeeded {
                    self.cleanupReminderAvailable = false
                    self.lastCleanup = Date()
                    UserDefaults.standard.set(self.lastCleanup, forKey: "Brewery.settings.lastCleanup")
                }
                guard self.preferences.values.notifyOperations else { continue }
                Task { await self.notify(title: operation.kind.title, body: operation.status.rawValue) }
            }
        }.store(in: &subscriptions)
        vm.$outdatedFormulaNames.combineLatest(vm.$outdatedCaskNames).sink { [weak self] _, _ in
            Task { @MainActor [weak self] in await self?.reportNewUpdates() }
        }.store(in: &subscriptions)
        preferences.$values.dropFirst().sink { [weak self] values in
            guard let self else { return }
            if !values.cleanupReminder {
                self.cleanupReminderAvailable = false
            }
            if values.brewPath != self.observedBrewPath {
                self.observedBrewPath = values.brewPath
                self.lastCheck = nil
                UserDefaults.standard.removeObject(forKey: "Brewery.settings.lastPackageCheck")
                self.knownUpdates = []
                Task {
                    await self.vm?.reloadForExecutableChange()
                    await self.tick(launching: false)
                }
            } else {
                Task { await self.tick(launching: false) }
            }
        }.store(in: &subscriptions)
        timer = Task { [weak self] in
            guard let self else { return }
            await vm.loadInstalled(checkOutdated: false)
            await self.tick(launching: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await self.tick(launching: false)
            }
        }
    }

    func stop() {
        enabled = false
        timer?.cancel()
        timer = nil
        subscriptions.removeAll()
        vm = nil
    }

    private func tick(launching: Bool) async {
        guard enabled, !checking, let vm else { return }
        checking = true
        defer { checking = false }
        let now = Date()
        if lastLogRetentionDays != preferences.values.logRetentionDays || lastLogPrune.map({ now.timeIntervalSince($0) >= 86400 }) != false {
            do {
                try BreweryLogger.shared.prune(days: preferences.values.logRetentionDays, now: now)
                lastLogPrune = now
                lastLogRetentionDays = preferences.values.logRetentionDays
            } catch { status = "Could not trim logs: \(error.localizedDescription)" }
        }
        cleanupReminderAvailable = preferences.values.cleanupReminder
            && SettingsPolicy.shouldRemindCleanup(lastCleanup: lastCleanup, now: now)
        if vm.isHomebrewAvailable == true, !vm.hasPendingOperations, SettingsPolicy.shouldCheck(cadence: preferences.values.updateCheck, lastCheck: lastCheck, now: now, launching: launching) {
            lastCheck = now
            UserDefaults.standard.set(now, forKey: "Brewery.settings.lastPackageCheck")
            // Refresh definitions through the existing serial operation queue.
            // Homebrew update changes metadata; package upgrades remain manual.
            await vm.brewSelfUpdate()
            if !vm.hasLoadedOutdated { await vm.loadOutdatedPackages() }
            await reportNewUpdates()
        } else if vm.isHomebrewAvailable == true, launching, SettingsPolicy.needsInitialSnapshot(hasLoaded: vm.hasLoadedOutdated, cadence: preferences.values.updateCheck) {
            // The daily metadata cadence must not leave a new process with an empty Updates page.
            await vm.loadOutdatedPackages()
            await reportNewUpdates()
        }
        if preferences.values.checkAppUpdates, SettingsPolicy.shouldCheck(cadence: "daily", lastCheck: lastAppCheck, now: now, launching: launching) {
            if AppUpdater.shared.checkForUpdates(inBackground: true) {
                lastAppCheck = now
                UserDefaults.standard.set(now, forKey: "Brewery.settings.lastAppCheck")
            }
        }
    }

    private func reportNewUpdates() async {
        guard enabled, let vm, vm.hasLoadedOutdated, vm.outdatedError == nil else { return }
        let updates = Set(vm.outdatedFormulaNames.map { "formula:\($0)" } + vm.outdatedCaskNames.map { "cask:\($0)" })
        let added = SettingsPolicy.newlyAvailableUpdates(current: updates, previouslySeen: knownUpdates)
        knownUpdates = updates
        if preferences.values.notifyUpdates, !added.isEmpty {
            await notify(title: "Package updates available", body: "\(updates.count) installed packages have updates.")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func requestNotificationPermission() async {
        guard !AppPreferences.isTesting else { notificationStatus = "Notifications are disabled in test mode."; return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = granted ? "Notifications allowed." : "Notifications denied. Enable Brewery notifications in System Settings."
        } catch { notificationStatus = error.localizedDescription }
    }

    private func notify(title: String, body: String) async {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            notificationStatus = "Notifications are not allowed. Enable them in System Settings."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if preferences.values.notificationSound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = error.localizedDescription }
    }

    func validateBrewPath(_ path: String) -> String? { BreweryCommand.validateOverridePath(path) }

    var environmentInfo: String { diagnostics() }

    private func diagnostics() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let path = BreweryCommand.resolveBrewURL(overridePath: preferences.values.brewPath)?.path ?? "Not found"
        #if arch(arm64)
        let architecture = "Apple silicon (arm64)"
        #elseif arch(x86_64)
        let architecture = "Intel (x86_64)"
        #else
        let architecture = "Unknown"
        #endif
        return "Architecture: \(architecture)\nBrewery: \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nHomebrew executable: \(path)\nHomebrew: \(vm?.brewVersion ?? "Not loaded")\n"
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
        status = "Environment information copied."
    }

    func exportDiagnostics() {
        do { export(text: diagnostics() + "\nLogs\n" + (try BreweryLogger.shared.contents()), name: "Brewery-diagnostics.txt") }
        catch { status = error.localizedDescription }
    }

    func exportLog() {
        do { export(text: try BreweryLogger.shared.contents(), name: "Brewery.log") }
        catch { status = error.localizedDescription }
    }

    private func export(text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "Exported \(url.lastPathComponent)." }
        catch { status = "Export failed: \(error.localizedDescription)" }
    }
}
