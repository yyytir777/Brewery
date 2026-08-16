import Foundation

struct DiscoverLocalData: Sendable {
    let catalog: CatalogSnapshot
    let rankings: RankingSnapshot?
}

struct RankingRefreshResult: Sendable {
    let snapshot: RankingSnapshot?
    let messages: [String]
}

enum CatalogServiceError: LocalizedError {
    case missingBundledCatalog
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .missingBundledCatalog: "The bundled Homebrew catalog is missing."
        case .http(let status): "Homebrew returned HTTP \(status)."
        }
    }
}

@MainActor
protocol CatalogServing: Sendable {
    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData
    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot?
    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult
}

@MainActor
final class CatalogService: CatalogServing {
    private let session: URLSession
    private let bundleCatalogURL: URL?
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, bundleCatalogURL: URL?) {
        self.session = session
        self.bundleCatalogURL = bundleCatalogURL
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func production(bundle: Bundle = .main) -> CatalogService {
        CatalogService(session: .shared, bundleCatalogURL: bundle.url(forResource: "catalog", withExtension: "json"))
    }

    func loadLocalData(for window: RankingWindow) throws -> DiscoverLocalData {
        guard let bundleCatalogURL else { throw CatalogServiceError.missingBundledCatalog }
        let catalog = try decoder.decode(CatalogSnapshot.self, from: Data(contentsOf: bundleCatalogURL))
        return DiscoverLocalData(catalog: catalog, rankings: nil)
    }

    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? { nil }

    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        async let formula = fetchFormula(window)
        async let cask = fetchCask(window)
        let formulaResult = await formula
        let caskResult = await cask
        var messages: [String] = []
        let now = Date()
        let formulaSection: RankingSection?
        let caskSection: RankingSection?
        switch formulaResult {
        case .success(let entries): formulaSection = RankingSection(fetchedAt: now, entries: entries)
        case .failure(let error): formulaSection = nil; messages.append("Formula rankings: \(error.localizedDescription)")
        }
        switch caskResult {
        case .success(let entries): caskSection = RankingSection(fetchedAt: now, entries: entries)
        case .failure(let error): caskSection = nil; messages.append("Cask rankings: \(error.localizedDescription)")
        }
        guard formulaSection != nil || caskSection != nil else { return RankingRefreshResult(snapshot: nil, messages: messages) }
        return RankingRefreshResult(snapshot: RankingSnapshot(schemaVersion: 1, window: window, formula: formulaSection, cask: caskSection), messages: messages)
    }

    private func fetchFormula(_ window: RankingWindow) async -> Result<[PackageRanking], Error> {
        await fetch(URL(string: "https://formulae.brew.sh/api/analytics/install-on-request/\(window.rawValue).json")!, decode: HomebrewPayloadDecoder.decodeFormulaRankings)
    }

    private func fetchCask(_ window: RankingWindow) async -> Result<[PackageRanking], Error> {
        await fetch(URL(string: "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/\(window.rawValue).json")!, decode: HomebrewPayloadDecoder.decodeCaskRankings)
    }

    private func fetch<T: Sendable>(_ url: URL, decode: (Data) throws -> T) async -> Result<T, Error> {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            return .success(try decode(data))
        } catch { return .failure(error) }
    }
}
