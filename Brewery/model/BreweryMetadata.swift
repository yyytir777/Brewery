import Foundation

enum BreweryMetadata {
    static func parseVersion(from output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "unknown"
    }

    static func parseSize(from output: String) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            let pieces = line
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let last = pieces.last, last.range(of: #"^\d+(\.\d+)?\s?(KB|MB|GB|TB)$"#, options: .regularExpression) != nil {
                return last
            }
        }

        return "unknown"
    }
}

struct BrewOutdatedResult: Decodable {
    let formulae: [OutdatedFormula]
    let casks: [OutdatedCask]
}

struct OutdatedFormula: Decodable {
    let name: String
}

struct OutdatedCask: Decodable {
    let name: String
}
