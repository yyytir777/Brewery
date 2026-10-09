import Foundation

nonisolated struct DiscoverLocalData: Sendable {
    let catalog: CatalogSnapshot
    let rankings: RankingSnapshot?
}

nonisolated struct RankingRefreshResult: Sendable {
    let snapshot: RankingSnapshot?
    let messages: [String]
}

nonisolated enum CatalogServiceError: LocalizedError {
    case missingBundledCatalog
    case http(Int)
    case invalidSnapshot
    var errorDescription: String? {
        switch self {
        case .missingBundledCatalog: "The bundled Homebrew catalog is missing."
        case .http(let status): "Homebrew returned HTTP \(status)."
        case .invalidSnapshot: "Homebrew data has an unsupported format or invalid package identifiers."
        }
    }
}

@MainActor
protocol CatalogServing: Sendable {
    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData
    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot?
    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult
    func refreshCatalogIfNeeded(force: Bool) async throws -> CatalogSnapshot?
    func refreshRankingsIfNeeded(for window: RankingWindow, force: Bool) async -> RankingRefreshResult
    var catalogRefreshMessages: [String] { get }
    func cacheSizeBytes() async throws -> Int64
    func clearCache() async throws
    func notifyCacheUpdated()
}

extension CatalogServing {
    func cacheSizeBytes() async throws -> Int64 { 0 }
    func clearCache() async throws {}
    func notifyCacheUpdated() {}
    func refreshCatalogIfNeeded(force: Bool) async throws -> CatalogSnapshot? { try await refreshCatalogIfNeeded() }
    func refreshRankingsIfNeeded(for window: RankingWindow, force: Bool) async -> RankingRefreshResult { await refreshRankingsIfNeeded(for: window) }
    var catalogRefreshMessages: [String] { [] }
}

@MainActor
final class CatalogService: CatalogServing {
    private let worker: CatalogWorker
    private let refreshPolicy: @MainActor () -> String
    private var catalogRequestNumber = 0
    private(set) var catalogRefreshMessages: [String] = []

    init(session: URLSession = .shared, bundleCatalogURL: URL?, cacheDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }, onBackgroundWork: (@Sendable () -> Void)? = nil, refreshPolicy: @escaping @MainActor () -> String = { "daily" }) {
        self.refreshPolicy = refreshPolicy
        worker = CatalogWorker(session: session, bundleCatalogURL: bundleCatalogURL, cacheDirectory: cacheDirectory, now: now, onBackgroundWork: onBackgroundWork)
    }

    static func production(bundle: Bundle = .main) -> CatalogService {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Brewery/Discover", isDirectory: true)
        return CatalogService(session: .shared, bundleCatalogURL: bundle.url(forResource: "catalog", withExtension: "json"), cacheDirectory: directory, refreshPolicy: { AppPreferences.shared.values.catalogRefresh })
    }

    func notifyCacheUpdated() { NotificationCenter.default.post(name: .catalogCacheUpdated, object: self) }
    func cacheSizeBytes() async throws -> Int64 { try await worker.cacheSizeBytes() }
    func clearCache() async throws {
        catalogRequestNumber += 1
        try await worker.clearCache()
        catalogRefreshMessages = []
        NotificationCenter.default.post(name: .catalogCacheCleared, object: self)
    }

    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData {
        try await worker.loadLocalData(for: window)
    }

    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? { try await refreshCatalogIfNeeded(force: false) }

    func refreshCatalogIfNeeded(force: Bool) async throws -> CatalogSnapshot? {
        catalogRequestNumber += 1
        let request = catalogRequestNumber
        let result = await worker.refreshCatalogWithMessages(force: force, policy: refreshPolicy())
        if request == catalogRequestNumber { catalogRefreshMessages = result.messages }
        return try result.snapshot.get()
    }

    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        await refreshRankingsIfNeeded(for: window, force: false)
    }

    func refreshRankingsIfNeeded(for window: RankingWindow, force: Bool) async -> RankingRefreshResult {
        await worker.refreshRankingsIfNeeded(for: window, force: force, manual: refreshPolicy() == "manual")
    }
}

/// All windows share this executor so disk merge and atomic save remain one transaction.
/// JSON decoding and file access never occupy the UI actor.
@globalActor
private actor CatalogExecutor {
    static let shared = CatalogExecutor()
}

@CatalogExecutor
private final class CatalogWorker {
    private let session: URLSession
    private let bundleCatalogURL: URL?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let onBackgroundWork: (@Sendable () -> Void)?
    private var catalogCache: CatalogCache?
    private var rankingCaches: [RankingWindow: RankingSnapshot] = [:]
    private var catalogRequestNumber = 0
    private var rankingRequestNumbers: [RankingWindow: Int] = [:]
    private(set) var catalogRefreshMessages: [String] = []

    private nonisolated struct CatalogSection: Codable, Sendable {
        let fetchedAt: Date
        let packages: [CatalogPackage]
    }
    private nonisolated struct CatalogCache: Codable, Sendable {
        let schemaVersion: Int
        let formula: CatalogSection?
        let cask: CatalogSection?
    }

    nonisolated init(session: URLSession, bundleCatalogURL: URL?, cacheDirectory: URL?, now: @escaping @Sendable () -> Date, onBackgroundWork: (@Sendable () -> Void)?) {
        self.session = session
        self.bundleCatalogURL = bundleCatalogURL
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.onBackgroundWork = onBackgroundWork
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { valueDecoder in
            let value = try valueDecoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid cache date")
        }
        self.decoder = decoder
        let encoder = JSONEncoder()
        // Preserve subsecond ordering between windows; legacy ISO-8601 caches remain readable.
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    func refreshCatalogWithMessages(force: Bool, policy: String) async -> (snapshot: Result<CatalogSnapshot?, Error>, messages: [String]) {
        do {
            let snapshot = try await refreshCatalogIfNeeded(force: force, policy: policy)
            return (.success(snapshot), catalogRefreshMessages)
        } catch {
            return (.failure(error), catalogRefreshMessages)
        }
    }

    func loadLocalData(for window: RankingWindow) throws -> DiscoverLocalData {
        let catalog = try currentCatalog()
        return DiscoverLocalData(catalog: catalog, rankings: currentRankings(window))
    }

    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? { try await refreshCatalogIfNeeded(force: false) }

    func refreshCatalogIfNeeded(force: Bool, policy: String = "daily") async throws -> CatalogSnapshot? {
        do { _ = try currentCatalog() }
        catch { if !force { throw error } }
        if !force && policy == "manual" { return catalogCache.map(catalogSnapshot) }
        let ttl: TimeInterval = policy == "hourly" ? 3600 : policy == "weekly" ? 604800 : 86400
        let previous = catalogCache ?? CatalogCache(schemaVersion: 1, formula: nil, cask: nil)
        let instant = now()
        let needsFormula = force || !isFresh(previous.formula?.fetchedAt, ttl: ttl)
        let needsCask = force || !isFresh(previous.cask?.fetchedAt, ttl: ttl)
        catalogRefreshMessages = []
        guard needsFormula || needsCask else { return catalogSnapshot(previous) }
        catalogRequestNumber += 1
        let request = catalogRequestNumber
        async let formula = fetchCatalog(.formula, needed: needsFormula)
        async let cask = fetchCatalog(.cask, needed: needsCask)
        let formulaResult = await formula
        let caskResult = await cask
        guard request == catalogRequestNumber else { return catalogCache.map(catalogSnapshot) }
        let latest = mergingCatalogCache(previous)
        var formulaSection = latest.formula
        var caskSection = latest.cask
        if let formulaResult {
            switch formulaResult {
            case .success(let packages): formulaSection = CatalogSection(fetchedAt: instant, packages: packages)
            case .failure(let error): catalogRefreshMessages.append(failureMessage("Formula catalog", error: error, date: latest.formula?.fetchedAt))
            }
        }
        if let caskResult {
            switch caskResult {
            case .success(let packages): caskSection = CatalogSection(fetchedAt: instant, packages: packages)
            case .failure(let error): catalogRefreshMessages.append(failureMessage("Cask catalog", error: error, date: latest.cask?.fetchedAt))
            }
        }
        let updated = mergingCatalogCache(CatalogCache(schemaVersion: 1, formula: formulaSection, cask: caskSection))
        guard formulaSection != nil || caskSection != nil else { throw CatalogServiceError.invalidSnapshot }
        catalogCache = updated
        do { try save(updated, filename: "catalog.json") }
        catch { catalogRefreshMessages.append("Catalog cache could not be saved: \(error.localizedDescription)") }
        return catalogSnapshot(updated)
    }

    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        await refreshRankingsIfNeeded(for: window, force: false)
    }

    func refreshRankingsIfNeeded(for window: RankingWindow, force: Bool, manual: Bool = false) async -> RankingRefreshResult {
        let previous = currentRankings(window)
        if manual && !force { return RankingRefreshResult(snapshot: previous, messages: []) }
        let needsFormula = force || !isFresh(previous?.formula?.fetchedAt, ttl: 60 * 60)
        let needsCask = force || !isFresh(previous?.cask?.fetchedAt, ttl: 60 * 60)
        guard needsFormula || needsCask else { return RankingRefreshResult(snapshot: previous, messages: []) }
        let request = (rankingRequestNumbers[window] ?? 0) + 1
        rankingRequestNumbers[window] = request
        let instant = now()
        async let formula = fetchRankings(.formula, window: window, needed: needsFormula)
        async let cask = fetchRankings(.cask, window: window, needed: needsCask)
        let formulaResult = await formula
        let caskResult = await cask
        guard rankingRequestNumbers[window] == request else { return RankingRefreshResult(snapshot: rankingCaches[window], messages: []) }
        var messages: [String] = []
        let latest = mergingRankingCache(previous ?? RankingSnapshot(schemaVersion: 1, window: window, formula: nil, cask: nil))
        var formulaSection = latest.formula
        var caskSection = latest.cask
        if let formulaResult { switch formulaResult {
        case .success(let entries): formulaSection = RankingSection(fetchedAt: instant, entries: entries)
        case .failure(let error): messages.append(failureMessage("Formula rankings", error: error, date: formulaSection?.fetchedAt))
        } }
        if let caskResult { switch caskResult {
        case .success(let entries): caskSection = RankingSection(fetchedAt: instant, entries: entries)
        case .failure(let error): messages.append(failureMessage("Cask rankings", error: error, date: caskSection?.fetchedAt))
        } }
        guard formulaSection != nil || caskSection != nil else { return RankingRefreshResult(snapshot: nil, messages: messages) }
        let updated = mergingRankingCache(RankingSnapshot(schemaVersion: 1, window: window, formula: formulaSection, cask: caskSection))
        rankingCaches[window] = updated
        do { try save(updated, filename: "rankings-\(window.rawValue).json") }
        catch { messages.append("Ranking cache could not be saved: \(error.localizedDescription)") }
        return RankingRefreshResult(snapshot: updated, messages: messages)
    }

    func cacheSizeBytes() throws -> Int64 {
        guard let cacheDirectory, FileManager.default.fileExists(atPath: cacheDirectory.path) else { return 0 }
        return try cacheFiles().reduce(0) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    func clearCache() throws {
        catalogRequestNumber += 1
        for window in RankingWindow.allCases { rankingRequestNumbers[window, default: 0] += 1 }
        catalogCache = nil
        rankingCaches = [:]
        for url in try cacheFiles() { try FileManager.default.removeItem(at: url) }
    }

    private func cacheFiles() throws -> [URL] {
        guard let cacheDirectory, FileManager.default.fileExists(atPath: cacheDirectory.path) else { return [] }
        let names = Set(["catalog.json"] + RankingWindow.allCases.map { "rankings-\($0.rawValue).json" })
        return try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]).filter { names.contains($0.lastPathComponent) }
    }

    private func currentCatalog() throws -> CatalogSnapshot {
        if let catalogCache { return catalogSnapshot(catalogCache) }
        let cached: CatalogCache? = read("catalog.json")
        let validCache = cached?.schemaVersion == 1 ? cached : nil
        let formula = validCache?.formula.flatMap { validCatalogSection($0, kind: .formula) ? $0 : nil }
        let cask = validCache?.cask.flatMap { validCatalogSection($0, kind: .cask) ? $0 : nil }
        if let formula, let cask {
            let cache = CatalogCache(schemaVersion: 1, formula: formula, cask: cask)
            catalogCache = cache
            return catalogSnapshot(cache)
        }
        let bundled: CatalogSnapshot
        do {
            guard let bundleCatalogURL else { throw CatalogServiceError.missingBundledCatalog }
            onBackgroundWork?()
            bundled = try decoder.decode(CatalogSnapshot.self, from: Data(contentsOf: bundleCatalogURL))
            guard bundled.schemaVersion == 1, validPackages(bundled.packages), !bundled.packages.isEmpty else { throw CatalogServiceError.invalidSnapshot }
        } catch {
            guard formula != nil || cask != nil else { throw error }
            let partial = CatalogCache(schemaVersion: 1, formula: formula, cask: cask)
            catalogCache = partial
            return catalogSnapshot(partial)
        }
        let cache = CatalogCache(schemaVersion: 1,
                                 formula: formula ?? CatalogSection(fetchedAt: bundled.generatedAt, packages: bundled.packages.filter { $0.kind == .formula }),
                                 cask: cask ?? CatalogSection(fetchedAt: bundled.generatedAt, packages: bundled.packages.filter { $0.kind == .cask }))
        catalogCache = cache
        return catalogSnapshot(cache)
    }

    private func catalogSnapshot(_ cache: CatalogCache) -> CatalogSnapshot {
        CatalogSnapshot(schemaVersion: 1, generatedAt: [cache.formula?.fetchedAt, cache.cask?.fetchedAt].compactMap { $0 }.min() ?? .distantPast, packages: (cache.formula?.packages ?? []) + (cache.cask?.packages ?? []))
    }

    private func currentRankings(_ window: RankingWindow) -> RankingSnapshot? {
        if let cached = rankingCaches[window] { return cached }
        guard let cached: RankingSnapshot = read("rankings-\(window.rawValue).json"), cached.schemaVersion == 1, cached.window == window else { return nil }
        let formula = cached.formula.flatMap { validRankingSection($0, kind: .formula) ? $0 : nil }
        let cask = cached.cask.flatMap { validRankingSection($0, kind: .cask) ? $0 : nil }
        guard formula != nil || cask != nil else { return nil }
        let sanitized = RankingSnapshot(schemaVersion: 1, window: window, formula: formula, cask: cask)
        rankingCaches[window] = sanitized
        return sanitized
    }

    // No suspension between merging and saving on the shared background executor.
    private func mergingCatalogCache(_ candidate: CatalogCache) -> CatalogCache {
        guard let stored: CatalogCache = read("catalog.json"), stored.schemaVersion == 1 else { return candidate }
        let formula = stored.formula.flatMap { validCatalogSection($0, kind: .formula) ? $0 : nil }
        let cask = stored.cask.flatMap { validCatalogSection($0, kind: .cask) ? $0 : nil }
        return CatalogCache(schemaVersion: 1,
                            formula: newest(candidate.formula, formula, date: \.fetchedAt),
                            cask: newest(candidate.cask, cask, date: \.fetchedAt))
    }

    private func mergingRankingCache(_ candidate: RankingSnapshot) -> RankingSnapshot {
        guard let stored: RankingSnapshot = read("rankings-\(candidate.window.rawValue).json"), stored.schemaVersion == 1, stored.window == candidate.window else { return candidate }
        let formula = stored.formula.flatMap { validRankingSection($0, kind: .formula) ? $0 : nil }
        let cask = stored.cask.flatMap { validRankingSection($0, kind: .cask) ? $0 : nil }
        return RankingSnapshot(schemaVersion: 1, window: candidate.window,
                               formula: newest(candidate.formula, formula, date: \.fetchedAt),
                               cask: newest(candidate.cask, cask, date: \.fetchedAt))
    }

    private func newest<T>(_ candidate: T?, _ stored: T?, date: KeyPath<T, Date>) -> T? {
        guard let candidate else { return stored }
        guard let stored else { return candidate }
        return stored[keyPath: date] > candidate[keyPath: date] ? stored : candidate
    }

    private func fetchCatalog(_ kind: PackageKind, needed: Bool) async -> Result<[CatalogPackage], Error>? {
        guard needed else { return nil }
        let url = URL(string: "https://formulae.brew.sh/api/\(kind.rawValue).json")!
        let result = await fetch(url, decode: kind == .formula ? HomebrewPayloadDecoder.decodeFormulaCatalog : HomebrewPayloadDecoder.decodeCaskCatalog)
        return result.flatMap { packages in
            guard !packages.isEmpty, self.validPackages(packages), packages.allSatisfy({ $0.kind == kind }) else { return .failure(CatalogServiceError.invalidSnapshot) }
            return .success(packages)
        }
    }

    private func fetchRankings(_ kind: PackageKind, window: RankingWindow, needed: Bool) async -> Result<[PackageRanking], Error>? {
        guard needed else { return nil }
        let path = kind == .formula ? "install-on-request" : "cask-install/homebrew-cask"
        let result = await fetch(URL(string: "https://formulae.brew.sh/api/analytics/\(path)/\(window.rawValue).json")!, decode: kind == .formula ? HomebrewPayloadDecoder.decodeFormulaRankings : HomebrewPayloadDecoder.decodeCaskRankings)
        return result.flatMap { entries in
            guard !entries.isEmpty, self.validRankingSection(RankingSection(fetchedAt: self.now(), entries: entries), kind: kind) else { return .failure(CatalogServiceError.invalidSnapshot) }
            return .success(entries)
        }
    }

    private func isFresh(_ date: Date?, ttl: TimeInterval) -> Bool {
        guard let date else { return false }
        let age = now().timeIntervalSince(date)
        return age >= -0.001 && age < ttl
    }

    private func validPackages(_ packages: [CatalogPackage]) -> Bool {
        var seen = Set<PackageID>()
        return packages.allSatisfy { $0.id.kind == $0.kind && $0.id.name == $0.name && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }
    }

    private func validCatalogSection(_ section: CatalogSection, kind: PackageKind) -> Bool {
        validCacheDate(section.fetchedAt) && !section.packages.isEmpty && validPackages(section.packages) && section.packages.allSatisfy { $0.kind == kind }
    }

    private func validRankingSection(_ section: RankingSection, kind: PackageKind) -> Bool {
        var seen = Set<PackageID>()
        return validCacheDate(section.fetchedAt) && !section.entries.isEmpty && section.entries.allSatisfy {
            $0.packageID.kind == kind && !$0.packageID.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.installs >= 0 && $0.rank > 0 && seen.insert($0.packageID).inserted
        }
    }

    private func validCacheDate(_ date: Date) -> Bool {
        // Date's epoch conversion can round a JSON round trip forward by one floating-point step.
        date.timeIntervalSince(now()) <= 0.001
    }

    private func failureMessage(_ source: String, error: Error, date: Date?) -> String {
        let retained = date.map { " Last successful data: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        return "\(source): \(error.localizedDescription)\(retained)"
    }

    private func read<T: Decodable>(_ filename: String) -> T? {
        let interval = DiscoverPerformance.begin("CatalogCacheRead")
        defer { DiscoverPerformance.end("CatalogCacheRead", id: interval) }
        guard let cacheDirectory else { return nil }
        onBackgroundWork?()
        return try? decoder.decode(T.self, from: Data(contentsOf: cacheDirectory.appendingPathComponent(filename)))
    }

    private func save<T: Encodable>(_ value: T, filename: String) throws {
        let interval = DiscoverPerformance.begin("CatalogCacheWrite")
        defer { DiscoverPerformance.end("CatalogCacheWrite", id: interval) }
        guard let cacheDirectory else { return }
        onBackgroundWork?()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: cacheDirectory.appendingPathComponent(filename), options: .atomic)
    }

    private func fetch<T: Sendable>(_ url: URL, decode: (Data) throws -> T) async -> Result<T, Error> {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            onBackgroundWork?()
            return .success(try decode(data))
        } catch { return .failure(error) }
    }
}

extension Notification.Name {
    static let catalogCacheUpdated = Notification.Name("Brewery.catalogCacheUpdated")
    static let catalogCacheCleared = Notification.Name("Brewery.catalogCacheCleared")
}
