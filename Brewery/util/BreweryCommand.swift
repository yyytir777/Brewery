//
//  brewCommand.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import Foundation

final class BreweryCommand {
    static func run(_ command: [String], logOutput: Bool = true) async -> String {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.launchPath = "/bin/zsh"
            process.environment = [
                "TERM": "homebrew",
                "HOME": NSHomeDirectory(),   // "/Users/yourname"
                "PATH": "/opt/homebrew/bin:/usr/local/bin"
            ]
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            process.arguments = ["-c", "brew \(command.joined(separator: " "))"]
            
            let start = Date()
            
            if #available(macOS 13.0, *) {
              try? process.run()
            } else {
              process.launch()
            }
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            
            async let stdoutRead = Task.detached(priority: .userInitiated) { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrRead = Task.detached(priority: .userInitiated) { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value

            let (stdoutData, stderrData) = await (stdoutRead, stderrRead)
            process.waitUntilExit()
            
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let duration = Date().timeIntervalSince(start)
            
            await BreweryLogger.shared.log(command: command, stdout: logOutput ? stdout : "(output skipped)", stderr: stderr, duration: duration)
            return stdout.isEmpty ? stderr : stdout
        }.value
    }
}
