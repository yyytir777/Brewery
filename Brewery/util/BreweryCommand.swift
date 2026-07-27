import Foundation

struct BreweryCommandResult: Equatable {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var displayOutput: String { stdout.isEmpty ? stderr : stdout }
}

final class BreweryCommand {
    private nonisolated static let brewCandidatePaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]

    static func run(_ arguments: [String], logOutput: Bool = true) async -> BreweryCommandResult {
        await Task.detached(priority: .userInitiated) {
            let start = Date()

            guard let brewURL = resolveBrewURL() else {
                let result = BreweryCommandResult(
                    arguments: arguments,
                    stdout: "",
                    stderr: "Homebrew executable not found at /opt/homebrew/bin/brew or /usr/local/bin/brew.",
                    exitCode: 127
                )
                await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
                return result
            }

            let process = makeProcess(
                brewURL: brewURL,
                arguments: arguments,
                environment: makeEnvironment()
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                let result = BreweryCommandResult(
                    arguments: arguments,
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: 126
                )
                await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
                return result
            }

            async let stdoutRead = Task.detached(priority: .userInitiated) {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let stderrRead = Task.detached(priority: .userInitiated) {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }.value

            let (stdoutData, stderrData) = await (stdoutRead, stderrRead)
            process.waitUntilExit()

            let result = BreweryCommandResult(
                arguments: arguments,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )

            await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
            return result
        }.value
    }

    nonisolated static func makeProcess(brewURL: URL, arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments
        process.environment = environment
        return process
    }

    private nonisolated static func resolveBrewURL() -> URL? {
        for path in brewCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private nonisolated static func makeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        environment["TERM"] = "dumb"
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            currentPath
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ":")
        return environment
    }
}
