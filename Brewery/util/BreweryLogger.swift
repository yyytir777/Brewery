//
//  BreweryLogger.swift
//  brewery
//
//  Created by Wonjae Lim on 3/23/26.
//
import Foundation

final class BreweryLogger {
    static let shared = BreweryLogger()
    
    private let fileURL: URL
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
    
    func log(command: [String], stdout: String, stderr: String, duration: TimeInterval) async {
        let timestamp = dateFormatter.string(from: Date())
        var lines = ["[\(timestamp)] CMD: brew \(command.joined(separator: " "))"]

              if !stdout.isEmpty {
                  lines.append("[\(timestamp)] OUT: \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
              }
        
              if !stderr.isEmpty {
                  lines.append("[\(timestamp)] ERR: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
              }
        
              lines.append("[\(timestamp)] DONE (\(String(format: "%.2f", duration))s)\n")

              let entry = lines.joined(separator: "\n") + "\n"
              guard let data = entry.data(using: .utf8) else { return }

              if FileManager.default.fileExists(atPath: fileURL.path) {
                  if let handle = try? FileHandle(forWritingTo: fileURL) {
                      handle.seekToEndOfFile()
                      handle.write(data)
                      try? handle.close()
                  }
              } else {
                  try? data.write(to: fileURL, options: .atomic)
              }
    }
}
