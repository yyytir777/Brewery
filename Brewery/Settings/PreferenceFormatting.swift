import Foundation

extension PreferencesValues {
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = sizeUnit == "mb" ? .useMB : sizeUnit == "gb" ? .useGB : .useAll
        formatter.isAdaptive = sizeUnit == "auto"
        return formatter.string(fromByteCount: max(0, bytes))
    }

    func formatHomebrewSize(_ original: String) -> String {
        guard sizeUnit != "auto" else { return original }
        let pieces = original.uppercased().split(whereSeparator: { $0.isWhitespace })
        // Homebrew prints either "123.4MB" or "123.4 MB".
        let compact = pieces.joined()
        let suffixes: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in suffixes where compact.hasSuffix(suffix) {
            guard let number = Double(compact.dropLast(suffix.count)), number.isFinite, number >= 0,
                  number * multiplier < Double(Int64.max) else { return original }
            return formatBytes(Int64(number * multiplier))
        }
        return original
    }
}
