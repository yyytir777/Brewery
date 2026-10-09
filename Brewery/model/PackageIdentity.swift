import Foundation

nonisolated enum PackageKind: String, Codable, CaseIterable, Sendable {
    case formula
    case cask
}

nonisolated struct PackageID: Hashable, Identifiable, Codable, Sendable {
    let kind: PackageKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }

    init(kind: PackageKind, name: String) {
        self.kind = kind
        let officialPrefix = kind == .formula ? "homebrew/core/" : "homebrew/cask/"
        self.name = name.hasPrefix(officialPrefix) ? String(name.dropFirst(officialPrefix.count)) : name
    }

    static func formula(_ name: String) -> Self {
        Self(kind: .formula, name: name)
    }

    static func cask(_ name: String) -> Self {
        Self(kind: .cask, name: name)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)

        guard parts.count == 2,
              let kind = PackageKind(rawValue: String(parts[0])),
              !parts[1].isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a package identifier in the form formula:name or cask:name."
            )
        }

        self.init(kind: kind, name: String(parts[1]))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
