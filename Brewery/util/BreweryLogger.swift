//
//  BreweryLogger.swift
//  brewery
//
//  Created by Wonjae Lim on 3/23/26.
//
import Foundation

@MainActor
final class BreweryLogger {
    static let shared = BreweryLogger()
    
    let fileURL: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    
    private init() {
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Brewery", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        fileURL = logsDir.appendingPathComponent("Brewery.log")
    }
    
    func logFileSize() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attrs[.size] as? Int64 else { return "0 KB" }
        return AppPreferences.shared.values.formatBytes(bytes)
    }

    func clearLog() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    func contents() throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func prune(days: Int, now: Date = Date()) throws {
        let text = try contents()
        let retained = Self.retainedLog(text, cutoff: now.addingTimeInterval(-Double(days) * 86400))
        if retained != text { try retained.write(to: fileURL, atomically: true, encoding: .utf8) }
    }

    nonisolated static func retainedLog(_ text: String, cutoff: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var keep = true
        return text.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("["), line.count >= 21 {
                let stamp = String(line.dropFirst().prefix(19))
                if let date = formatter.date(from: stamp) { keep = date >= cutoff }
            }
            return keep
        }.joined(separator: "\n")
    }

    func log(result: BreweryCommandResult, logOutput: Bool, duration: TimeInterval) async {
        let timestamp = dateFormatter.string(from: Date())
        var lines = ["[\(timestamp)] CMD: brew \(result.arguments.joined(separator: " "))"]
        if logOutput, !result.stdout.isEmpty {
            lines.append("[\(timestamp)] OUT: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else if !logOutput {
            lines.append("[\(timestamp)] OUT: (output skipped)")
        }
        if !result.stderr.isEmpty {
            lines.append("[\(timestamp)] ERR: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("[\(timestamp)] EXIT: \(result.exitCode)")
        lines.append("[\(timestamp)] DONE (\(String(format: "%.2f", duration))s)\n")
        append(lines.joined(separator: "\n") + "\n")
    }

    func logDiagnostic(_ message: String) async {
        let timestamp = dateFormatter.string(from: Date())
        append("[\(timestamp)] INFO: \(message)\n")
    }

    private func append(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
