import Foundation

struct CatalogPackage: Codable, Identifiable, Hashable, Sendable {
    let id: PackageID
    let name: String
    let kind: PackageKind
    let description: String?
    let homepage: URL?
    let latestVersion: String?
}

struct CatalogSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let packages: [CatalogPackage]
}

enum RankingWindow: String, Codable, CaseIterable, Sendable {
    case days30 = "30d", days90 = "90d", days365 = "365d"
    var title: String {
        switch self { case .days30: "30 days"; case .days90: "90 days"; case .days365: "365 days" }
    }
}

struct PackageRanking: Codable, Equatable, Sendable { let packageID: PackageID; let installs: Int; let rank: Int }
struct RankingSection: Codable, Equatable, Sendable { let fetchedAt: Date; let entries: [PackageRanking] }
struct RankingSnapshot: Codable, Equatable, Sendable { let schemaVersion: Int; let window: RankingWindow; let formula: RankingSection?; let cask: RankingSection? }

enum PackageKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", formula = "Formula", cask = "Cask"
    var id: Self { self }
}

struct DiscoverRow: Identifiable, Equatable, Sendable {
    let package: CatalogPackage
    let rank: Int?
    let installs: Int?
    let isInstalled: Bool
    var id: PackageID { package.id }
}

enum HomebrewPayloadDecoder {
    private struct Formula: Decodable { struct Versions: Decodable { let stable: String? }; let name: String; let desc: String?; let homepage: String?; let versions: Versions }
    private struct Cask: Decodable { let token: String; let desc: String?; let homepage: String?; let version: String? }
    private struct FormulaAnalytics: Decodable { struct Item: Decodable { let number: Int; let formula: String; let count: String }; let items: [Item] }
    private struct CaskAnalytics: Decodable { struct Item: Decodable { let cask: String; let count: String }; let formulae: [String: [Item]] }

    static func decodeFormulaCatalog(_ data: Data) throws -> [CatalogPackage] {
        try unique(JSONDecoder().decode([Formula].self, from: data).map { CatalogPackage(id: .formula($0.name), name: $0.name, kind: .formula, description: $0.desc, homepage: validatedURL($0.homepage), latestVersion: $0.versions.stable) })
    }
    static func decodeCaskCatalog(_ data: Data) throws -> [CatalogPackage] {
        try unique(JSONDecoder().decode([Cask].self, from: data).map { CatalogPackage(id: .cask($0.token), name: $0.token, kind: .cask, description: $0.desc, homepage: validatedURL($0.homepage), latestVersion: $0.version) })
    }
    static func decodeFormulaRankings(_ data: Data) throws -> [PackageRanking] {
        try JSONDecoder().decode(FormulaAnalytics.self, from: data).items.map { PackageRanking(packageID: .formula($0.formula), installs: try parseCount($0.count), rank: $0.number) }
    }
    static func decodeCaskRankings(_ data: Data) throws -> [PackageRanking] {
        let items = try JSONDecoder().decode(CaskAnalytics.self, from: data).formulae.values.flatMap { $0 }
        let sorted = try items.map { ($0.cask, try parseCount($0.count)) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return sorted.enumerated().map { PackageRanking(packageID: .cask($0.element.0), installs: $0.element.1, rank: $0.offset + 1) }
    }
    private static func parseCount(_ value: String) throws -> Int {
        guard let count = Int(value.replacingOccurrences(of: ",", with: "")) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid analytics count: \(value)")) }
        return count
    }
    private static func validatedURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }
    private static func unique(_ packages: [CatalogPackage]) throws -> [CatalogPackage] {
        var seen = Set<PackageID>()
        for package in packages where !seen.insert(package.id).inserted { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate package ID: \(package.id.id)")) }
        return packages
    }
}
