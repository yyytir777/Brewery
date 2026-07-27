import Foundation

enum PackageKind: String, Codable, Hashable {
    case formula
    case cask
}

struct PackageID: Hashable, Identifiable, Codable {
    let kind: PackageKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }

    static func formula(_ name: String) -> PackageID {
        PackageID(kind: .formula, name: name)
    }

    static func cask(_ name: String) -> PackageID {
        PackageID(kind: .cask, name: name)
    }
}
