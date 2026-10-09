//
//  brewData.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

struct BrewInfoResult: Decodable {
    let formulae: [BreweryFormula]
    let casks: [BreweryCask]
}

struct BreweryFormula: Decodable, Identifiable {
    // 기본 정보
    var id: String { packageID.id }
    var packageID: PackageID { .formula(full_name) }
    let name: String
    let full_name: String
    let tap: String
    let desc: String?
    let homepage: String
    let license: String?
    
    // 버전
    var cur_version: String { selectedInstallation?.version ?? "unknown" }
    var latest_version: String { versions.stable ?? "unknown" }
    var installed_date: Double? { selectedInstallation?.time }
    let outdated: Bool // 업데이트 가능 여부
    
    // 의존성
    let dependencies: [String]
        
    let installed: [FormulaInstalled]
    let versions: FormulaVersions
    var linked_keg: String? = nil

    private var selectedInstallation: FormulaInstalled? {
        if let linked_keg,
           let linked = installed.first(where: { $0.version == linked_keg }) {
            return linked
        }

        // Unlinked and keg-only formulas have no linked version. Prefer a known
        // recent install time; ties retain Homebrew's last (highest) keg order.
        return installed.enumerated().max { lhs, rhs in
            let lhsTime = lhs.element.time ?? -Double.infinity
            let rhsTime = rhs.element.time ?? -Double.infinity
            return lhsTime == rhsTime ? lhs.offset < rhs.offset : lhsTime < rhsTime
        }?.element
    }
}

struct FormulaInstalled: Decodable {
    var installed_on_request: Bool? = nil
    let version: String
    let time: Double?
}

struct FormulaVersions: Decodable {
    let stable: String?
    let head: String?
    let bottle: Bool?
}

struct BreweryCask: Decodable, Identifiable {
    var id: String { packageID.id }
    var packageID: PackageID { .cask(full_token ?? token) }
    let token: String
    let desc: String?
    let homepage: String
    let version: String      // 최신 버전
    let installed: String?   // 설치된 버전

    var name: String { token }
    var cur_version: String { installed ?? "unknown" }
    var latest_version: String { version }
    var outdated: Bool { installed != nil && installed != version }
    let installed_time: Double?
    let auto_updates: Bool?
    var full_token: String? = nil

}
