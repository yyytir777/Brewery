//
//  brewCommand.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import Foundation

struct BreweryCommandResult: Equatable, Sendable {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var displayOutput: String { stdout.isEmpty ? stderr : stdout }
}

final class BreweryCommand {
    private nonisolated static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    nonisolated static func makeProcess(
        brewURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments
        process.environment = environment
        return process
    }

    nonisolated static func run(_ arguments: [String], logOutput: Bool = true) async -> BreweryCommandResult {
        await Task.detached(priority: .userInitiated) {
            let start = Date()
            guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                return await finish(
                    BreweryCommandResult(arguments: arguments, stdout: "", stderr: "Homebrew was not found in /opt/homebrew/bin or /usr/local/bin.", exitCode: 127),
                    startedAt: start,
                    logOutput: logOutput
                )
            }

            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "dumb"
            environment["HOME"] = NSHomeDirectory()
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

            let process = makeProcess(brewURL: URL(fileURLWithPath: path), arguments: arguments, environment: environment)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return await finish(
                    BreweryCommandResult(arguments: arguments, stdout: "", stderr: error.localizedDescription, exitCode: 126),
                    startedAt: start,
                    logOutput: logOutput
                )
            }

            async let stdoutData = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
            let (out, err) = await (stdoutData, stderrData)
            process.waitUntilExit()

            return await finish(
                BreweryCommandResult(
                    arguments: arguments,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    exitCode: process.terminationStatus
                ),
                startedAt: start,
                logOutput: logOutput
            )
        }.value
    }

    private nonisolated static func finish(
        _ result: BreweryCommandResult,
        startedAt: Date,
        logOutput: Bool
    ) async -> BreweryCommandResult {
        await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(startedAt))
        return result
    }
}
