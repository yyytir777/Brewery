import Foundation

nonisolated struct BreweryCommandResult: Equatable, Sendable {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var displayOutput: String { stdout.isEmpty ? stderr : stdout }
    var failureOutput: String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedStdout.isEmpty { return trimmedStderr }
        if trimmedStderr.isEmpty { return trimmedStdout }
        return "\(trimmedStderr)\n\n\(trimmedStdout)"
    }
}

final class BreweryCommand {
    private nonisolated static let brewCandidatePaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]

    static func run(_ arguments: [String], logOutput: Bool = true, onOutput: (@Sendable (String) -> Void)? = nil) async -> BreweryCommandResult {
        let overridePath = AppPreferences.shared.values.brewPath
        return await Task.detached(priority: .userInitiated) {
            let start = Date()

            guard let brewURL = resolveBrewURL(overridePath: overridePath) else {
                let result = BreweryCommandResult(
                    arguments: arguments,
                    stdout: "",
                    stderr: "Homebrew executable not found. Check the executable path in Settings.",
                    exitCode: 127
                )
                await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
                return result
            }

            let result = await executeProcess(
                brewURL: brewURL,
                arguments: arguments,
                environment: makeEnvironment(brewURL: brewURL),
                onOutput: onOutput
            )
            await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
            return result
        }.value
    }

    nonisolated static func executeProcess(
        brewURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> BreweryCommandResult {
        let process = makeProcess(brewURL: brewURL, arguments: arguments, environment: environment)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        async let stdoutRead = drainOutput(stdoutPipe.fileHandleForReading, onOutput: onOutput)
        async let stderrRead = drainOutput(stderrPipe.fileHandleForReading, onOutput: onOutput)

        // waitUntilExit polls a thread's run loop. After an async pipe read the
        // task can resume on another thread and never observe an exited child.
        // Register before launch so even a child that exits immediately is observed.
        let termination: Result<Int32, Error> = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: .success(finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failure(error))
            }
            // Also release readers when launch fails and no child can close the pipes.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }
        let (stdoutData, stderrData) = await (stdoutRead, stderrRead)
        process.terminationHandler = nil
        switch termination {
        case .success(let exitCode):
            return BreweryCommandResult(
                arguments: arguments,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: exitCode
            )
        case .failure(let error):
            return BreweryCommandResult(arguments: arguments, stdout: "", stderr: error.localizedDescription, exitCode: 126)
        }
    }

    private nonisolated static func drainOutput(
        _ handle: FileHandle,
        onOutput: (@Sendable (String) -> Void)?
    ) async -> Data {
        await withCheckedContinuation { continuation in
            // Blocking pipe reads must not occupy Swift's cooperative executor.
            DispatchQueue.global(qos: .userInitiated).async {
                let output = readOutput(handle, onOutput: onOutput)
                try? handle.close()
                continuation.resume(returning: output)
            }
        }
    }

    nonisolated static func makeProcess(brewURL: URL, arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments
        process.environment = environment
        return process
    }

    private nonisolated static func readOutput(_ handle: FileHandle, onOutput: (@Sendable (String) -> Void)?) -> Data {
        var output = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            output.append(chunk)
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }
        return output
    }

    nonisolated static func resolveBrewURL(overridePath: String = "") -> URL? {
        if !overridePath.isEmpty {
            guard validateOverridePath(overridePath) == nil else { return nil }
            return URL(fileURLWithPath: overridePath)
        }
        for path in brewCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated static func validateOverridePath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return "Use an absolute path to the Homebrew executable." }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue, FileManager.default.isExecutableFile(atPath: path) else { return "The selected path is not an executable file." }
        return nil
    }

    nonisolated static func makeEnvironment(brewURL: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        environment["TERM"] = "dumb"
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = [
            brewURL?.deletingLastPathComponent().path ?? "",
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
