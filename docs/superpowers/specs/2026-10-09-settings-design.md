# Brewery Settings

User authorized implementing all 32 proposed settings and prefers Search over Discover. Preserve existing uncommitted work and macOS 13 support.

Settings uses a searchable category sidebar and grouped forms. All exposed controls must persist and affect behavior; actions report errors and destructive data removal requires the existing-style confirmation. Settings reset removes only Brewery preferences, not installed packages or Homebrew configuration. Defaults preserve existing behavior. Automatic checks run only while Brewery is open; package upgrades remain user-triggered.

Shared interface: AppPreferences.shared is a MainActor ObservableObject with @Published var values: PreferencesValues (Codable, Equatable, Sendable). Mutating nested fields persists the whole value. Tests use isolated UserDefaults suites. String options are fixed below.

Fields/defaults:
- startupPage: "home" (home/installed/updates/search/last); lastPage: "home"
- rememberWindow: true; language: "system" (system/en/ko)
- theme: "system" (system/light/dark); accent: "system" (system/blue/purple/pink/orange/green)
- density: "standard" (comfortable/standard/compact)
- showVersion/showDescription/showKind/showBadges: true; reduceMotion: false
- defaultKind: "all" (all/formula/cask); sortOrder: "name" (name/updates)
- rememberFilters: true; savedQuery: ""; savedKind: "all"; directFirst: false
- operationDetails: "always" (always/failure)
- updateCheck: "launch" (manual/launch/daily); excludedUpdates: [String] = [] (PackageID.id qualified identities)
- checkAppUpdates: false; notifyOperations/notifyUpdates/notificationSound: false
- rankingWindow: "30d" (30d/90d/365d); catalogRefresh: "daily" (hourly/daily/weekly/manual)
- cleanupReminder: false; sizeUnit: "auto" (auto/mb/gb)
- brewPath: "" (empty = automatic); logRetentionDays: 30

Launch-at-login uses SMAppService actual status, not a pretend preference. Window frame autosave and sidebar width restoration respect rememberWindow. Runtime owns scheduled checks, notification permission and deduplication, app release checks, cleanup hints, command executable override, log retention/export. Package/Search integration owns defaults, sorting, direct-installed priority, metadata toggles, density, bulk exclusions, details disclosure, ranking window, cache maintenance. Root owns store, appearance/localization/window/startup/navigation integration and final verification.
