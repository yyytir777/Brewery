import Foundation
import Combine

nonisolated struct PreferencesValues: Codable, Equatable, Sendable {
    var startupPage = "home"
    var lastPage = "home"
    var rememberWindow = true
    var sidebarWidth = 190.0
    var language = "system"
    var theme = "system"
    var accent = "system"
    var density = "standard"
    var showVersion = true
    var showDescription = true
    var showKind = true
    var showBadges = true
    var reduceMotion = false
    var defaultKind = "all"
    var sortOrder = "name"
    var rememberFilters = true
    var hasSavedFilters = false
    var savedQuery = ""
    var savedKind = "all"
    var hasSavedSearchFilters = false
    var savedSearchQuery = ""
    var savedSearchKind = "all"
    var directFirst = false
    var operationDetails = "always"
    var updateCheck = "launch"
    var excludedUpdates: [String] = []
    var checkAppUpdates = false
    var notifyOperations = false
    var notifyUpdates = false
    var notificationSound = false
    var rankingWindow = "30d"
    var catalogRefresh = "daily"
    var cleanupReminder = false
    var sizeUnit = "auto"
    var brewPath = ""
    var logRetentionDays = 30

    mutating func normalize() {
        func valid(_ value: String, _ options: [String], _ fallback: String) -> String {
            options.contains(value) ? value : fallback
        }
        startupPage = valid(startupPage, ["home", "installed", "updates", "search", "last"], "home")
        lastPage = valid(lastPage, ["home", "installed", "updates", "search"], "home")
        language = valid(language, ["system", "en", "ko"], "system")
        theme = valid(theme, ["system", "light", "dark"], "system")
        accent = valid(accent, ["system", "blue", "purple", "pink", "orange", "green"], "system")
        density = valid(density, ["comfortable", "standard", "compact"], "standard")
        defaultKind = valid(defaultKind, ["all", "formula", "cask"], "all")
        savedSearchKind = valid(savedSearchKind, ["all", "formula", "cask"], "all")
        savedKind = valid(savedKind, ["all", "formula", "cask"], "all")
        sortOrder = valid(sortOrder, ["name", "updates"], "name")
        operationDetails = valid(operationDetails, ["always", "failure"], "always")
        updateCheck = valid(updateCheck, ["manual", "launch", "daily"], "launch")
        rankingWindow = valid(rankingWindow, ["30d", "90d", "365d"], "30d")
        catalogRefresh = valid(catalogRefresh, ["hourly", "daily", "weekly", "manual"], "daily")
        sizeUnit = valid(sizeUnit, ["auto", "mb", "gb"], "auto")
        if ![7, 30, 90].contains(logRetentionDays) { logRetentionDays = 30 }
        sidebarWidth = sidebarWidth.isFinite ? min(240, max(170, sidebarWidth)) : 190
        excludedUpdates = Array(Set(excludedUpdates)).sorted()
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let storageKey = "Brewery.preferences.v1"
    #if DEBUG
    static let isTesting = ProcessInfo.processInfo.arguments.contains("--brewery-ui-testing")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #else
    static let isTesting = false
    #endif
    static let shared = AppPreferences(persistChanges: !isTesting)

    @Published var values: PreferencesValues {
        didSet {
            guard persistChanges, let data = try? JSONEncoder().encode(values) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }
    let resetEvents = PassthroughSubject<Void, Never>()
    private let defaults: UserDefaults
    private let persistChanges: Bool

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        values = persistChanges ? Self.load(from: defaults) : PreferencesValues()
    }

    func reset() {
        values = PreferencesValues()
        if persistChanges {
            defaults.removeObject(forKey: Self.storageKey)
            defaults.removeObject(forKey: "Brewery.sidebarWidth")
            defaults.removeObject(forKey: "NSWindow Frame BreweryMainWindow")
        }
        resetEvents.send(())
    }

    private static func load(from defaults: UserDefaults) -> PreferencesValues {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseline = try? JSONEncoder().encode(PreferencesValues()),
              var merged = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any] else { return PreferencesValues() }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var result = try? JSONDecoder().decode(PreferencesValues.self, from: mergedData) else { return PreferencesValues() }
        result.normalize()
        return result
    }
}

extension PreferencesValues {
    @MainActor var initialDestination: BreweryDestination {
        switch startupPage == "last" ? lastPage : startupPage {
        case "installed": .installed(outdatedOnly: false)
        case "updates": .installed(outdatedOnly: true)
        case "search": .discover
        default: .home
        }
    }

    var initialKind: PackageKind? {
        PackageKind(rawValue: rememberFilters && hasSavedFilters ? savedKind : defaultKind)
    }
    var initialQuery: String { rememberFilters && hasSavedFilters ? savedQuery : "" }
}
