#if DEBUG
import Foundation

enum BreweryUITestScenario: String, CaseIterable {
    case standard, missingHomebrew = "missing-homebrew", infoFailure = "info-failure", offline, queue

    /// Explicit fixture requests are strict so typos cannot silently launch live services.
    static func configuration(arguments: [String], environment: [String: String] = [:], bundleInfo: [String: Any] = [:]) -> BreweryUITestLaunchConfiguration? {
        let options = Array(arguments.dropFirst())
        if options.contains(where: { $0.hasPrefix("--brewery-ui-testing") }) {
            guard options.count == 2, options[0] == "--brewery-ui-testing",
                  let scenario = Self(rawValue: options[1]) else {
                return .invalid("Use --brewery-ui-testing followed by standard, missing-homebrew, info-failure, offline, or queue.")
            }
            return .scenario(scenario)
        }
        // A dedicated Debug QA app can opt in through its generated Info.plist.
        // Preserve the value's type so malformed keys cannot fall back to live services.
        if let value = bundleInfo["BreweryUITestScenario"] {
            guard let name = value as? String, let scenario = Self(rawValue: name) else {
                return .invalid("The bundled BreweryUITestScenario must name a supported UI test scenario.")
            }
            return .scenario(scenario)
        }
        // XCTest's unit-test host runs App.init too; never let it start live inventory reads.
        if environment["XCTestConfigurationFilePath"] != nil { return .scenario(.standard) }
        return nil
    }
}

enum BreweryUITestLaunchConfiguration: Equatable {
    case scenario(BreweryUITestScenario)
    case invalid(String)
}

@MainActor
final class BreweryUITestFixture: CatalogServing {
    let configurationError: String?
    var requiresManualOperationCompletion: Bool { scenario == .queue }
    var isWaitingForFirstMutation: Bool { firstMutationContinuation != nil }

    func completeFirstMutation() {
        let continuation = firstMutationContinuation
        firstMutationContinuation = nil
        continuation?.resume()
    }

    private let scenario: BreweryUITestScenario?
    private let waitForFirstMutation: (() async -> Void)?
    private var firstMutationContinuation: CheckedContinuation<Void, Never>?
    private var installed: [PackageID: String] = [.formula("git"): "1.0", .formula("gettext"): "1.0", .cask("qa-app"): "1.0"]
    private var inventoryReadCount = 0
    private var jqInfoReadCount = 0
    private var hasStartedMutation = false
    private var rankingRefreshCount = 0

    private struct FixturePackage {
        let id: PackageID
        let latest: String
        let description: String
        let dependencies: [String]
    }
    private let packages = [
        FixturePackage(id: .formula("git"), latest: "2.0", description: "Distributed revision control system", dependencies: ["gettext"]),
        FixturePackage(id: .formula("gettext"), latest: "1.0", description: "GNU internationalization utilities", dependencies: []),
        FixturePackage(id: .formula("jq"), latest: "1.0", description: "Lightweight JSON processor", dependencies: []),
        FixturePackage(id: .cask("qa-app"), latest: "2.0", description: "Brewery QA application", dependencies: [])
    ]
    private let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

    init(configuration: BreweryUITestLaunchConfiguration, waitForFirstMutation: (() async -> Void)? = nil) {
        switch configuration {
        case .scenario(let scenario): self.scenario = scenario; configurationError = nil
        case .invalid(let message): scenario = nil; configurationError = message
        }
        self.waitForFirstMutation = waitForFirstMutation
    }

    /// This is a closed interpreter: no Process, live runner, network, cache, or logger fallback.
    func run(_ arguments: [String], _ logOutput: Bool) async -> BreweryCommandResult {
        if let configurationError { return failure(arguments, configurationError) }
        if arguments == ["info", "--json=v2", "--installed"] {
            inventoryReadCount += 1
            if scenario == .missingHomebrew && inventoryReadCount == 1 {
                return failure(arguments, "UI fixture: Homebrew executable was not found. Retry Connection to recover.", exitCode: 127)
            }
            return infoResult(arguments, packages: packages.filter { installed[$0.id] != nil })
        }
        if arguments == ["outdated", "--json=v2"] {
            let outdated = packages.filter { package in installed[package.id].map { $0 != package.latest } ?? false }
            return jsonResult(arguments, object: [
                "formulae": outdated.filter { $0.id.kind == .formula }.map { ["name": $0.id.name] },
                "casks": outdated.filter { $0.id.kind == .cask }.map { ["name": $0.id.name] }
            ])
        }
        if arguments == ["--version"] { return success(arguments, "Homebrew 4.0.0 (Brewery UI fixture)") }
        if arguments == ["info"] { return success(arguments, "\(installed.count) packages, 3 files, 12MB") }
        if arguments == ["cleanup", "--dry-run"] {
            return success(arguments, "Would remove: fixture-download.tar.gz (1MB)\nWould free 1MB")
        }
        if arguments == ["cleanup"] || arguments == ["update"] {
            await pauseFirstMutationIfNeeded()
            return success(arguments, arguments == ["cleanup"] ? "Removed fixture files (1MB)." : "Already up-to-date.")
        }
        if arguments.count == 4, arguments[0] == "info", arguments[1] == "--json=v2",
           let package = package(kindOption: arguments[2], name: arguments[3]) {
            if package.id == .formula("jq") {
                jqInfoReadCount += 1
                if scenario == .infoFailure && jqInfoReadCount == 1 {
                    return failure(arguments, "UI fixture: jq information is temporarily unavailable. Please retry.", exitCode: 1)
                }
            }
            return infoResult(arguments, packages: [package])
        }
        if arguments.count == 3, arguments[0] == "info",
           let package = package(kindOption: arguments[1], name: arguments[2]) {
            return success(arguments, "\(package.id.name): stable \(package.latest)\n\(package.description)\nInstalled: \(installed[package.id] ?? "Not installed")")
        }
        let isZap = arguments.count == 4 && Array(arguments.prefix(3)) == ["uninstall", "--cask", "--zap"]
        if arguments.count == 3 || isZap,
           let operation = arguments.first, ["install", "upgrade", "uninstall"].contains(operation),
           let package = package(kindOption: arguments[1], name: arguments.last!) {
            if operation != "install" && installed[package.id] == nil {
                return failure(arguments, "UI fixture: \(package.id.name) is not installed.", exitCode: 1)
            }
            await pauseFirstMutationIfNeeded()
            if operation == "uninstall" { installed[package.id] = nil }
            else { installed[package.id] = package.latest }
            return success(arguments, "Simulated \(operation) of \(package.id.name) completed.")
        }
        return failure(arguments, "Unsupported UI fixture command: brew \(arguments.joined(separator: " "))")
    }

    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData {
        if let configurationError { throw PackageInfoError.unavailable(configurationError) }
        return DiscoverLocalData(catalog: catalog, rankings: rankings(for: window))
    }
    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? {
        if let configurationError { throw PackageInfoError.unavailable(configurationError) }
        if scenario == .offline { throw PackageInfoError.unavailable("Offline UI fixture: showing the locally stored catalog.") }
        return catalog
    }
    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        rankingRefreshCount += 1
        if let configurationError { return RankingRefreshResult(snapshot: nil, messages: [configurationError]) }
        if scenario == .offline { return RankingRefreshResult(snapshot: nil, messages: ["Offline UI fixture attempt \(rankingRefreshCount): showing the locally stored rankings."]) }
        return RankingRefreshResult(snapshot: rankings(for: window), messages: [])
    }

    private func pauseFirstMutationIfNeeded() async {
        guard !hasStartedMutation else { return }
        hasStartedMutation = true
        guard scenario == .queue else { return }
        if let waitForFirstMutation { await waitForFirstMutation() }
        else { await withCheckedContinuation { firstMutationContinuation = $0 } }
    }

    private func package(kindOption: String, name: String) -> FixturePackage? {
        guard kindOption == "--formula" || kindOption == "--cask" else { return nil }
        return packages.first { $0.id.name == name && $0.id.kind == (kindOption == "--cask" ? .cask : .formula) }
    }

    private var catalog: CatalogSnapshot {
        CatalogSnapshot(schemaVersion: 1, generatedAt: fixtureDate, packages: packages.map {
            CatalogPackage(id: $0.id, name: $0.id.name, kind: $0.id.kind, description: $0.description,
                           homepage: URL(string: "https://example.invalid/\($0.id.name)"), latestVersion: $0.latest)
        })
    }

    private func rankings(for window: RankingWindow) -> RankingSnapshot {
        RankingSnapshot(schemaVersion: 1, window: window,
                        formula: RankingSection(fetchedAt: fixtureDate, entries: [
                            PackageRanking(packageID: .formula("git"), installs: 400, rank: 1),
                            PackageRanking(packageID: .formula("jq"), installs: 300, rank: 2),
                            PackageRanking(packageID: .formula("gettext"), installs: 100, rank: 3)
                        ]), cask: RankingSection(fetchedAt: fixtureDate, entries: [
                            PackageRanking(packageID: .cask("qa-app"), installs: 200, rank: 1)
                        ]))
    }

    private func infoResult(_ arguments: [String], packages selected: [FixturePackage]) -> BreweryCommandResult {
        let formulae: [[String: Any]] = selected.filter { $0.id.kind == .formula }.map { package in
            let version = installed[package.id]
            let installations: [[String: Any]] = version.map { [["version": $0, "time": fixtureDate.timeIntervalSince1970]] } ?? []
            return ["name": package.id.name, "full_name": package.id.name, "tap": "homebrew/core",
                    "desc": package.description, "homepage": "https://example.invalid/\(package.id.name)", "license": "MIT",
                    "outdated": version.map { $0 != package.latest } ?? false, "dependencies": package.dependencies,
                    "installed": installations, "versions": ["stable": package.latest]]
        }
        let casks: [[String: Any]] = selected.filter { $0.id.kind == .cask }.map { package in
            ["token": package.id.name, "full_token": package.id.name, "name": ["QA App"], "desc": package.description,
             "homepage": "https://example.invalid/\(package.id.name)", "version": package.latest,
             "installed": installed[package.id] as Any? ?? NSNull(), "installed_time": fixtureDate.timeIntervalSince1970,
             "auto_updates": false]
        }
        return jsonResult(arguments, object: ["formulae": formulae, "casks": casks])
    }

    private func jsonResult(_ arguments: [String], object: [String: Any]) -> BreweryCommandResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return success(arguments, String(decoding: data, as: UTF8.self))
        } catch { return failure(arguments, "Fixture encoding failed: \(error.localizedDescription)") }
    }

    private func success(_ arguments: [String], _ output: String) -> BreweryCommandResult {
        BreweryCommandResult(arguments: arguments, stdout: output, stderr: "", exitCode: 0)
    }
    private func failure(_ arguments: [String], _ message: String, exitCode: Int32 = 64) -> BreweryCommandResult {
        BreweryCommandResult(arguments: arguments, stdout: "", stderr: message, exitCode: exitCode)
    }
}
#endif
