//
//  brewData.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

struct SearchResult: Decodable, Identifiable {
    var id: String { "\(isCask ? "cask" : "formula")_\(name)" }
    let name: String
    let isCask: Bool
}

struct BrewInfoResult: Decodable {
    let formulae: [BreweryFormula]
    let casks: [BreweryCask]
}

struct BreweryFormula: Decodable, Identifiable {
    // 기본 정보
    var id: String { name }
    let name: String
    let full_name: String
    let tap: String
    let desc: String?
    let homepage: String
    let license: String?
    
    // 버전
    var cur_version: String { installed.first?.version ?? "unknown" }
    var latest_version: String { versions.stable ?? "unknown" }
    var installed_date: Double? { installed.first!.time }
    let outdated: Bool // 업데이트 가능 여부
    
    // 의존성
    let dependencies: [String]
        
    let installed: [FormulaInstalled]
    let versions: FormulaVersions
}

struct FormulaInstalled: Decodable {
    let version: String
    let time: Double
}

struct FormulaVersions: Decodable {
    let stable: String?
    let head: String?
    let bottle: Bool?
}

struct BreweryCask: Decodable, Identifiable {
    var id: String { token }
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

}
