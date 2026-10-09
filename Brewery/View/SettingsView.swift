import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var vm: BreweryViewModel
    let catalogService: any CatalogServing
    var allowsSystemActions = true
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var runtime = SettingsRuntime.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @State private var category: SettingsCategory = .general
    @State private var query = ""
    @State private var message: String?
    @State private var confirmation: SettingsConfirmation?
    @State private var loginEnabled = false
    @State private var loginNeedsApproval = false
    @State private var cacheSize = "—"
    @State private var logSize = "—"
    @State private var busy = false
    @State private var brewPathDraft = ""

    private var categories: [SettingsCategory] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return SettingsCategory.allCases.filter { term.isEmpty || $0.searchText.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2.bold()).padding(.horizontal, 12)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings", text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("settings.search")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(categories) { item in
                            Button { category = item } label: {
                                Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                                    .font(.system(size: 13, weight: category == item ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                                    .background(category == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("settings.category.\(item.rawValue)")
                        }
                        if categories.isEmpty { Text("No matching settings").foregroundStyle(.secondary).padding(.top, 12) }
                    }
                }
                Spacer(minLength: 0)
                Text("Brewery").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12)
            }.padding(16).frame(width: 200).background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(category.rawValue)).font(.system(size: 28, weight: .bold))
                        Text(LocalizedStringKey(category.subtitle)).foregroundStyle(.secondary)
                    }
                    if categories.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("No matching settings", systemImage: "magnifyingglass").font(.headline)
                            Text("Try a different setting name or clear your search.").foregroundStyle(.secondary)
                            Button("Clear Search") { query = "" }
                        }.padding(.vertical, 30)
                    } else { content }
                    if busy { ProgressView().controlSize(.small) }
                    if !runtime.status.isEmpty && [.advanced, .diagnostics, .notifications].contains(category) {
                        Text(runtime.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: 760, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 550, idealHeight: 670)
        .onAppear {
            brewPathDraft = preferences.values.brewPath
            refreshLogin()
            if allowsSystemActions { logSize = BreweryLogger.shared.logFileSize() }
            refreshCacheSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLogin() }
        .onChange(of: preferences.values.sizeUnit) { _ in
            refreshCacheSize()
            if allowsSystemActions { logSize = BreweryLogger.shared.logFileSize() }
        }
        .onChange(of: preferences.values.notifyOperations) { enabled in requestNotificationsIfNeeded(enabled) }
        .onChange(of: preferences.values.notifyUpdates) { enabled in requestNotificationsIfNeeded(enabled) }
        .onChange(of: query) { _ in if !categories.contains(category), let first = categories.first { category = first } }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(confirmation?.action ?? "Confirm", role: .destructive) { performConfirmation() }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmation?.detail ?? "") }
        .alert("Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch category {
        case .general: general
        case .appearance: appearance
        case .packages: packages
        case .updates: updates
        case .notifications: notifications
        case .search: search
        case .storage: storage
        case .advanced: advanced
        case .diagnostics: diagnostics
        case .about: about
        }
    }

    private var general: some View {
        card("Startup") {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin)).disabled(!allowsSystemActions)
            if loginNeedsApproval { Button("Approve in Login Items") { SMAppService.openSystemSettingsLoginItems() } }
            choice("Startup page", value: $preferences.values.startupPage, options: [("home", "Home"), ("installed", "Installed"), ("updates", "Updates"), ("search", "Search"), ("last", "Last opened page")], identifier: "settings.startup")
            Toggle("Remember window size and sidebar width", isOn: $preferences.values.rememberWindow).accessibilityIdentifier("settings.rememberWindow")
            choice("Language", value: $preferences.values.language, options: [("system", "System"), ("en", "English"), ("ko", "한국어")], identifier: "settings.language")
        }
    }
    private var appearance: some View {
        VStack(spacing: 20) {
            card("Interface") {
                choice("Theme", value: $preferences.values.theme, options: [("system", "System"), ("light", "Light"), ("dark", "Dark")], identifier: "settings.theme")
                choice("Accent color", value: $preferences.values.accent, options: [("system", "System"), ("blue", "Blue"), ("purple", "Purple"), ("pink", "Pink"), ("orange", "Orange"), ("green", "Green")], identifier: "settings.accent")
                choice("List density", value: $preferences.values.density, options: [("comfortable", "Comfortable"), ("standard", "Standard"), ("compact", "Compact")], identifier: "settings.density")
                Toggle("Reduce motion", isOn: $preferences.values.reduceMotion).accessibilityIdentifier("settings.reduceMotion")
            }
            card("Package information") {
                Toggle("Show version", isOn: $preferences.values.showVersion).accessibilityIdentifier("settings.showVersion")
                Toggle("Show description", isOn: $preferences.values.showDescription).accessibilityIdentifier("settings.showDescription")
                Toggle("Show package type", isOn: $preferences.values.showKind).accessibilityIdentifier("settings.showKind")
                Toggle("Show status badges", isOn: $preferences.values.showBadges).accessibilityIdentifier("settings.showBadges")
            }
        }
    }
    private var packages: some View {
        card("Package lists") {
            choice("Default package type", value: $preferences.values.defaultKind, options: [("all", "All packages"), ("formula", "Formulae"), ("cask", "Casks")], identifier: "settings.defaultKind")
            choice("Sort order", value: $preferences.values.sortOrder, options: [("name", "Name"), ("updates", "Updates first")], identifier: "settings.sortOrder")
            Toggle("Remember search and filters", isOn: $preferences.values.rememberFilters).accessibilityIdentifier("settings.rememberFilters")
            Toggle("Show directly installed packages first", isOn: $preferences.values.directFirst).accessibilityIdentifier("settings.directFirst")
            choice("Operation details", value: $preferences.values.operationDetails, options: [("always", "Always show"), ("failure", "Show on failure")], identifier: "settings.operationDetails")
        }
    }
    private var updates: some View {
        VStack(spacing: 20) {
            card("Package updates") {
                choice("Check package updates", value: $preferences.values.updateCheck, options: [("manual", "Manually"), ("launch", "At launch"), ("daily", "Daily")], identifier: "settings.updateCheck")
                Text("Automatic checks run while Brewery is open. Package upgrades always require your action.").font(.caption).foregroundStyle(.secondary)
                Button("Check Package Updates Now") { run { await vm.loadOutdatedPackages(); message = vm.outdatedError ?? BreweryLocalization.string("Package update check complete.") } }.disabled(busy)
            }
            card("Brewery app updates") {
                Toggle("Check for Brewery releases", isOn: $preferences.values.checkAppUpdates).accessibilityIdentifier("settings.checkAppUpdates")
                Button("Check for Brewery Updates…") { appUpdater.checkForUpdates() }
                    .disabled(busy || !allowsSystemActions || !appUpdater.canCheckForUpdates || vm.hasPendingOperations)
                    .accessibilityIdentifier("settings.checkBreweryUpdates")
                Text("Download and install Brewery updates from the update window. Brewery restarts after installation.").font(.caption).foregroundStyle(.secondary)
                if vm.hasPendingOperations { Text("Finish package operations before updating Brewery.").font(.caption).foregroundStyle(.secondary) }
                if !appUpdater.status.isEmpty { Text(appUpdater.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            card("Exclude from bulk updates") {
                Text("Excluded packages remain visible and can still be updated individually.").font(.caption).foregroundStyle(.secondary)
                if vm.installedPackageIDs.isEmpty { Text("No installed packages").foregroundStyle(.secondary) }
                ForEach(vm.installedPackageIDs.sorted { $0.id < $1.id }, id: \.id) { id in
                    Toggle(id.id, isOn: Binding(get: { preferences.values.excludedUpdates.contains(id.id) }, set: { excluded in
                        if excluded { if !preferences.values.excludedUpdates.contains(id.id) { preferences.values.excludedUpdates.append(id.id) } }
                        else { preferences.values.excludedUpdates.removeAll { $0 == id.id } }
                    }))
                }
                ForEach(preferences.values.excludedUpdates.filter { saved in !vm.installedPackageIDs.contains { $0.id == saved } }, id: \.self) { saved in
                    HStack { Text(saved).foregroundStyle(.secondary); Spacer(); Button("Remove") { preferences.values.excludedUpdates.removeAll { $0 == saved } } }
                }
            }
        }
    }
    private var notifications: some View {
        card("Notifications") {
            Toggle("Notify when operations finish", isOn: $preferences.values.notifyOperations).accessibilityIdentifier("settings.notifyOperations")
            Toggle("Notify when updates are available", isOn: $preferences.values.notifyUpdates).accessibilityIdentifier("settings.notifyUpdates")
            Toggle("Play notification sound", isOn: $preferences.values.notificationSound).accessibilityIdentifier("settings.notificationSound")
            Button("Allow Notifications") { run { await runtime.requestNotificationPermission() } }.disabled(!allowsSystemActions || busy)
            if !runtime.notificationStatus.isEmpty { Text(runtime.notificationStatus).font(.callout).foregroundStyle(.secondary) }
            Text("Notification delivery follows your macOS notification settings.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var search: some View {
        card("Catalog and rankings") {
            choice("Ranking period", value: $preferences.values.rankingWindow, options: [("30d", "30 days"), ("90d", "90 days"), ("365d", "365 days")], identifier: "settings.rankingWindow")
            choice("Refresh catalog", value: $preferences.values.catalogRefresh, options: [("hourly", "Hourly"), ("daily", "Daily"), ("weekly", "Weekly"), ("manual", "Manually")], identifier: "settings.catalogRefresh")
            Button("Refresh Catalog and Rankings Now") { run {
                _ = try await catalogService.refreshCatalogIfNeeded(force: true)
                let result = await catalogService.refreshRankingsIfNeeded(for: RankingWindow(rawValue: preferences.values.rankingWindow) ?? .days30, force: true)
                catalogService.notifyCacheUpdated()
                let warnings = catalogService.catalogRefreshMessages + result.messages
                message = warnings.isEmpty ? BreweryLocalization.string("Catalog and rankings refreshed.") : warnings.joined(separator: "\n")
                refreshCacheSize()
            } }.disabled(busy)
        }
    }
    private var storage: some View {
        card("Storage") {
            Toggle("Weekly cleanup reminder", isOn: $preferences.values.cleanupReminder).accessibilityIdentifier("settings.cleanupReminder")
            choice("Size units", value: $preferences.values.sizeUnit, options: [("auto", "Automatic"), ("mb", "MB"), ("gb", "GB")], identifier: "settings.sizeUnit")
            LabeledContent("Catalog cache", value: cacheSize)
            Button("Clear Catalog Cache", role: .destructive) { confirmation = .cache }.disabled(busy)
            Text("Only downloaded search data is removed. Installed packages are kept.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var advanced: some View {
        VStack(spacing: 20) {
            card("Homebrew executable") {
                TextField("Automatic (/opt/homebrew/bin/brew or /usr/local/bin/brew)", text: $brewPathDraft).textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.brewPath")
                Text("Leave empty to detect Homebrew automatically. Changes apply to the next command.").font(.caption).foregroundStyle(.secondary)
                Button("Validate and Save Path") {
                    let path = brewPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let error = runtime.validateBrewPath(path) { message = error }
                    else { preferences.values.brewPath = path; message = BreweryLocalization.string("Homebrew path saved.") }
                }.disabled(!allowsSystemActions || vm.hasPendingOperations)
            }
            card("Environment") {
                Text(runtime.environmentInfo).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            card("Reset") {
                Button("Reset All Settings…", role: .destructive) { confirmation = .reset }.accessibilityIdentifier("settings.reset").disabled(vm.hasPendingOperations)
                Text("Restores Brewery defaults and turns off launch at login. Installed packages and Homebrew configuration are kept.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var diagnostics: some View {
        VStack(spacing: 20) {
            card("Command logs") {
                Picker("Keep logs", selection: $preferences.values.logRetentionDays) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.pickerStyle(.menu).accessibilityIdentifier("settings.logRetentionDays")
                LabeledContent("Log file size", value: logSize)
                HStack {
                    Button("Open Log") { if !NSWorkspace.shared.open(logURL) { message = BreweryLocalization.string("The log file could not be opened.") } }
                    Button("Export Log…") { runtime.exportLog() }
                    Spacer()
                    Button("Clear Log…", role: .destructive) { confirmation = .log }
                }.disabled(!allowsSystemActions)
            }
            card("Troubleshooting") {
                Text("Diagnostics include app, macOS and Homebrew environment information. Review exported files before sharing.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Copy Diagnostics") { runtime.copyDiagnostics() }; Button("Export Diagnostics…") { runtime.exportDiagnostics() } }.disabled(!allowsSystemActions)
            }
        }
    }
    private var about: some View {
        card("Brewery") {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Brewery").font(.title2.bold())
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))").foregroundStyle(.secondary)
                    Text("A native Homebrew companion for macOS.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Link("GitHub Repository", destination: URL(string: "https://github.com/yyytir777/Brewery")!)
            Link("Report an Issue", destination: URL(string: "https://github.com/yyytir777/Brewery/issues")!)
            Link("Release Notes", destination: URL(string: "https://github.com/yyytir777/Brewery/releases")!)
            Link("MIT License · © 2026 Lim Wonjae", destination: URL(string: "https://github.com/yyytir777/Brewery/blob/main/LICENSE")!)
        }
    }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content()
        }.toggleStyle(SettingsToggleStyle()).controlSize(.regular).frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06), lineWidth: 1))
    }
    private func choice(_ title: LocalizedStringKey, value: Binding<String>, options: [(String, String)], identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 20)
            Picker(title, selection: value) { ForEach(options, id: \.0) { Text(LocalizedStringKey($0.1)).tag($0.0) } }
                .labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier(identifier)
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    private func requestNotificationsIfNeeded(_ enabled: Bool) {
        guard enabled, allowsSystemActions else { return }
        Task { await runtime.requestNotificationPermission() }
    }
    private func refreshCacheSize() {
        Task { do { cacheSize = preferences.values.formatBytes(try await catalogService.cacheSizeBytes()) } catch { cacheSize = BreweryLocalization.string("Unavailable") } }
    }
    private var logURL: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Brewery/Brewery.log") }
    private func refreshLogin() {
        guard allowsSystemActions else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    private func setLogin(_ enabled: Bool) {
        guard allowsSystemActions else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { message = error.localizedDescription }
        refreshLogin()
    }
    private func performConfirmation() {
        let action = confirmation
        confirmation = nil
        switch action {
        case .cache: run { try await catalogService.clearCache(); refreshCacheSize() }
        case .log:
            do { if FileManager.default.fileExists(atPath: logURL.path) { try BreweryLogger.shared.clearLog() }; logSize = BreweryLogger.shared.logFileSize() }
            catch { message = error.localizedDescription }
        case .reset:
            guard !vm.hasPendingOperations else { message = BreweryLocalization.string("Wait for current operations to finish before resetting settings."); return }
            if allowsSystemActions && loginEnabled {
                do { try SMAppService.mainApp.unregister() } catch { message = error.localizedDescription; return }
            }
            preferences.reset(); brewPathDraft = ""; refreshLogin()
        case nil: break
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", packages = "Packages", updates = "Updates", notifications = "Notifications", search = "Search", storage = "Storage", advanced = "Advanced", diagnostics = "Diagnostics", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"; case .appearance: "paintpalette"; case .packages: "shippingbox"; case .updates: "arrow.triangle.2.circlepath"; case .notifications: "bell"; case .search: "magnifyingglass"; case .storage: "internaldrive"; case .advanced: "slider.horizontal.3"; case .diagnostics: "waveform.path.ecg"; case .about: "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Make Brewery feel at home on your Mac."
        case .appearance: "Choose how your workspace looks and feels."
        case .packages: "Set the defaults for browsing installed packages."
        case .updates: "Keep track of package and Brewery updates."
        case .notifications: "Choose which events deserve your attention."
        case .search: "Keep package discovery useful and up to date."
        case .storage: "Manage cached data and storage information."
        case .advanced: "Configure Homebrew and restore preferences."
        case .diagnostics: "Inspect and export information for troubleshooting."
        case .about: "Your Homebrew companion."
        }
    }
    var searchText: String {
        let keywords: String
        switch self {
        case .general: keywords = "Startup Launch at login Startup page Remember window size sidebar width Language System English 한국어 일반 시작 로그인 언어 창"
        case .appearance: keywords = "Theme Accent color List density Reduce motion Show version description package type status badges 테마 색상 모양 밀도 동작 버전 설명 배지"
        case .packages: keywords = "Default package type Sort order Remember search filters directly installed first Operation details 패키지 정렬 필터 작업 상세"
        case .updates: keywords = "Check package updates Manually launch Daily Brewery releases Exclude bulk updates 업데이트 제외"
        case .notifications: keywords = "Notify operations finish updates available Play notification sound Allow 알림 소리"
        case .search: keywords = "Catalog rankings Refresh period days 검색 카탈로그 순위 새로고침"
        case .storage: keywords = "Homebrew cleanup reminder Size units cache clear 저장 공간 캐시 정리 단위"
        case .advanced: keywords = "Homebrew executable automatic path Validate Save Reset All Settings 고급 경로 초기화"
        case .diagnostics: keywords = "Command logs Keep retention days file size Open Export Clear Copy troubleshooting 진단 로그 내보내기 복사"
        case .about: keywords = "Version GitHub Repository Report Issue Release Notes MIT License 정보 버전 라이선스"
        }
        return rawValue + " " + keywords
    }
}
private enum SettingsConfirmation {
    case cache, log, reset
    var title: String { switch self { case .cache: BreweryLocalization.string("Clear catalog cache?"); case .log: BreweryLocalization.string("Clear command log?"); case .reset: BreweryLocalization.string("Reset all settings?") } }
    var action: String { switch self { case .cache: BreweryLocalization.string("Clear Cache"); case .log: BreweryLocalization.string("Clear Log"); case .reset: BreweryLocalization.string("Reset Settings") } }
    var detail: String { switch self { case .cache: BreweryLocalization.string("Downloaded catalog and ranking data will be removed. Installed packages are kept."); case .log: BreweryLocalization.string("This permanently deletes the diagnostic log."); case .reset: BreweryLocalization.string("Brewery preferences will return to their defaults and launch at login will turn off. Installed packages and Homebrew configuration are kept.") } }
}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 20)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch)
        }
    }
}
