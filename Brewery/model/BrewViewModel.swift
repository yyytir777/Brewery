import SwiftUI
import Combine

typealias BreweryCommandRunner = (_ arguments: [String], _ logOutput: Bool) async -> BreweryCommandResult

@MainActor
final class BreweryViewModel: ObservableObject {
    @Published private var formulaMap: [String: BreweryFormula] = [:]
    @Published private var caskMap: [String: BreweryCask] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedInventory = false
    @Published private(set) var inventoryError: String?
    @Published private(set) var outdatedError: String?
    @Published private(set) var hasLoadedOutdated = false
    @Published private(set) var isHomebrewAvailable: Bool?
    @Published private(set) var brewVersion = ""
    @Published private(set) var brewSize = ""
    @Published private(set) var outdatedFormulaNames: Set<String> = []
    @Published private(set) var outdatedCaskNames: Set<String> = []
    @Published private(set) var operations: [PackageOperation] = []
    @Published private(set) var isPreviewingCleanup = false
    @Published private(set) var cleanupPreview: CleanupPreview?
    @Published private(set) var cleanupMessage: String?
    @Published private(set) var isLatestAfterUpdate: Bool?
    @Published var lastCommandError: BreweryCommandResult?

    private let commandRunner: BreweryCommandRunner
    private let usesLiveCommands: Bool
    private var reloadTask: Task<Void, Never>?
    private var isChangingExecutable = false
    private var executableGeneration = 0
    private var operationWorker: Task<Void, Never>?
    private struct PendingOperation {
        let id: UUID
        let kind: PackageOperationKind
        let completion: () -> Void
    }
    private var pendingOperations: [PendingOperation] = []

    init(loadOnInit: Bool = true, checkOutdatedOnLaunch: Bool = true, commandRunner: BreweryCommandRunner? = nil) {
        usesLiveCommands = commandRunner == nil
        self.commandRunner = commandRunner ?? { await BreweryCommand.run($0, logOutput: $1) }
        if loadOnInit { Task { await loadInstalled(checkOutdated: checkOutdatedOnLaunch) } }
    }

    var installedFormula: [BreweryFormula] { formulaMap.values.sorted { $0.full_name < $1.full_name } }
    var installedCasks: [BreweryCask] { caskMap.values.sorted { $0.packageID.name < $1.packageID.name } }
    var installedPackageIDs: Set<PackageID> { Set(formulaMap.keys.map(PackageID.formula) + caskMap.keys.map(PackageID.cask)) }
    var outdatedCount: Int { outdatedFormulaNames.count + outdatedCaskNames.count }
    var activeOperation: PackageOperation? { operations.first { $0.status == .running } }
    @Published var isPreparingAppUpdate = false
    var hasPendingOperations: Bool { operations.contains { $0.isPending } }
    var installingPackageIDs: Set<PackageID> {
        Set(operations.compactMap { operation in
            guard operation.isPending, case .install(let id) = operation.kind else { return nil }
            return id
        })
    }
    var updatingPackageNames: Set<String> { Set(operations.compactMap { if $0.isPending, case .upgrade(let id) = $0.kind { return id.name }; return nil }) }
    var uninstallingPackages: Set<String> { Set(operations.compactMap { if $0.isPending, case .uninstall(let id, _) = $0.kind { return id.name }; return nil }) }
    var isRunningUpdate: Bool { operations.contains { $0.isPending && $0.kind == .updateHomebrew } }
    var isRunningCleanup: Bool { operations.contains { $0.isPending && $0.kind == .cleanup } }

    func isOperating(_ id: PackageID) -> Bool { operations.contains { $0.isPending && $0.kind.packageID == canonicalID(id) } }
    func canonicalID(_ id: PackageID) -> PackageID {
        switch id.kind {
        case .formula: return getFormula(for: id.name)?.packageID ?? id
        case .cask: return getCask(for: id.name)?.packageID ?? id
        }
    }
    func isOutdated(_ id: PackageID) -> Bool {
        let id = canonicalID(id)
        return id.kind == .formula ? outdatedFormulaNames.contains(id.name) : outdatedCaskNames.contains(id.name)
    }
    func getFormula(for name: String) -> BreweryFormula? {
        formulaMap[PackageID.formula(name).name]
    }
    func getCask(for name: String) -> BreweryCask? {
        caskMap[PackageID.cask(name).name]
    }
    func formula(for id: PackageID) -> BreweryFormula? { id.kind == .formula ? getFormula(for: id.name) : nil }
    func cask(for id: PackageID) -> BreweryCask? { id.kind == .cask ? getCask(for: id.name) : nil }

    var commandErrorMessage: String {
        guard let result = lastCommandError else { return "" }
        let message = "brew " + result.arguments.joined(separator: " ") + " failed with exit code \(result.exitCode)."
        return result.failureOutput.isEmpty ? message : message + "\n\n" + result.failureOutput
    }

    func loadInstalled(checkOutdated: Bool = true) async {
        if let reloadTask { await reloadTask.value; return }
        let generation = executableGeneration
        let task = Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            guard await loadAllBrew(), generation == executableGeneration else { return }
            if checkOutdated { await loadOutdatedPackages() }
            await loadBrewMeta()
        }
        reloadTask = task
        await task.value
        if generation == executableGeneration { reloadTask = nil }
    }

    func reloadForExecutableChange() async {
        guard !hasPendingOperations else { return }
        isChangingExecutable = true
        executableGeneration += 1
        defer { isChangingExecutable = false }
        if let reloadTask { await reloadTask.value }
        reloadTask = nil
        formulaMap = [:]
        caskMap = [:]
        outdatedFormulaNames = []
        outdatedCaskNames = []
        hasLoadedInventory = false
        hasLoadedOutdated = false
        isHomebrewAvailable = false
        inventoryError = nil
        outdatedError = nil
        lastCommandError = nil
        brewVersion = ""
        brewSize = ""
        await loadInstalled()
    }

    @discardableResult
    func loadAllBrew() async -> Bool {
        let generation = executableGeneration
        let args = ["info", "--json=v2", "--installed"]
        let result = await commandRunner(args, false)
        guard generation == executableGeneration else { return false }
        guard result.succeeded else {
            inventoryError = result.failureOutput.isEmpty ? "Unable to read installed packages." : result.failureOutput
            isHomebrewAvailable = result.exitCode == 127 ? false : isHomebrewAvailable
            recordFailure(result)
            return false
        }
        isHomebrewAvailable = true
        do {
            let info = try JSONDecoder().decode(BrewInfoResult.self, from: Data(result.stdout.utf8))
            var formulas: [String: BreweryFormula] = [:]
            var casks: [String: BreweryCask] = [:]
            for formula in info.formulae {
                guard formulas.updateValue(formula, forKey: formula.packageID.name) == nil else { throw PackageInfoError.unavailable("Duplicate formula identity: \(formula.full_name)") }
            }
            for cask in info.casks {
                guard casks.updateValue(cask, forKey: cask.packageID.name) == nil else { throw PackageInfoError.unavailable("Duplicate cask identity: \(cask.packageID.name)") }
            }
            formulaMap = formulas
            caskMap = casks
            hasLoadedInventory = true
            inventoryError = nil
            return true
        } catch {
            inventoryError = "Could not read Homebrew's package data. Your last loaded list has been kept."
            recordParseFailure(result, message: "Failed to parse installed package data: \(error.localizedDescription)")
            return false
        }
    }

    func loadOutdatedPackages() async {
        let generation = executableGeneration
        let args = ["outdated", "--json=v2"]
        let result = await commandRunner(args, false)
        guard generation == executableGeneration else { return }
        if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if result.succeeded {
                outdatedFormulaNames = []; outdatedCaskNames = []
                outdatedError = nil
                hasLoadedOutdated = true
            } else {
                outdatedError = "Could not check for package updates. Try refreshing."
                recordFailure(result)
            }
            return
        }
        do {
            // Homebrew can return usable JSON with a nonzero outdated status.
            let data = try JSONDecoder().decode(BrewOutdatedResult.self, from: Data(result.stdout.utf8))
            outdatedFormulaNames = Set(data.formulae.map { PackageID.formula($0.name).name })
            outdatedCaskNames = Set(data.casks.map { item in
                let name = PackageID.cask(item.name).name
                if caskMap[name] != nil { return name }
                // Homebrew outdated emits a short Cask token even for tapped Casks.
                // This alias belongs only to that response, never general catalog lookup.
                let matches = caskMap.values.filter { $0.token == name }
                return matches.count == 1 ? matches[0].packageID.name : name
            })
            outdatedError = nil
            hasLoadedOutdated = true
        } catch {
            outdatedError = "Could not check for package updates. Try refreshing."
            recordParseFailure(result, message: "Failed to parse Homebrew outdated package data: \(error.localizedDescription)")
        }
    }

    func loadBrewMeta() async {
        let generation = executableGeneration
        let version = await commandRunner(["--version"], true)
        guard generation == executableGeneration else { return }
        recordFailure(version)
        if version.succeeded { brewVersion = BreweryMetadata.parseVersion(from: version.stdout) }
        let info = await commandRunner(["info"], true)
        guard generation == executableGeneration else { return }
        recordFailure(info)
        if info.succeeded { brewSize = BreweryMetadata.parseSize(from: info.stdout) }
    }

    func installFormula(name: String) async { await enqueue([.install(.formula(name))]) }
    func installCask(name: String) async { await enqueue([.install(.cask(name))]) }
    func uninstallFormula(name: String) async { await enqueue([.uninstall(canonicalID(.formula(name)), deleteData: false)]) }
    func uninstallCask(name: String) async { await enqueue([.uninstall(canonicalID(.cask(name)), deleteData: false)]) }
    func uninstallCaskWithZap(name: String) async { await enqueue([.uninstall(canonicalID(.cask(name)), deleteData: true)]) }
    func updateBrew(name: String, isCask: Bool = false) async { await enqueue([.upgrade(canonicalID(isCask ? .cask(name) : .formula(name)))]) }
    func upgradePackages(_ ids: Set<PackageID>) async {
        await enqueue(ids.filter { installedPackageIDs.contains($0) && isOutdated($0) }.sorted { $0.id < $1.id }.map { .upgrade($0) })
    }
    func brewSelfUpdate() async { await enqueue([.updateHomebrew]) }
    func brewCleanUp() async { await enqueue([.cleanup]) }

    func previewCleanup() async {
        guard !isPreviewingCleanup, !hasPendingOperations else { return }
        isPreviewingCleanup = true
        defer { isPreviewingCleanup = false }
        let result = await execResult(["cleanup", "--dry-run"])
        if result.succeeded {
            cleanupPreview = CleanupPreview(output: result.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    func clearCleanupPreview() { cleanupPreview = nil }

    func cancelQueuedOperation(_ id: UUID) {
        guard let index = pendingOperations.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingOperations.remove(at: index)
        updateOperation(id) { $0.status = .cancelled; $0.finishedAt = Date() }
        pending.completion()
    }

    private func enqueue(_ kinds: [PackageOperationKind]) async {
        guard isHomebrewAvailable != false, !isChangingExecutable, !isPreparingAppUpdate else { return }
        var accepted: [PackageOperationKind] = []
        for kind in kinds {
            let duplicate = operations.contains { $0.isPending && conflicts($0.kind, kind) }
                || accepted.contains { conflicts($0, kind) }
            if !duplicate { accepted.append(kind) }
        }
        guard !accepted.isEmpty else { return }
        await withCheckedContinuation { continuation in
            var remaining = accepted.count
            for kind in accepted {
                let id = UUID()
                operations.append(PackageOperation(id: id, kind: kind))
                pendingOperations.append(PendingOperation(id: id, kind: kind, completion: {
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }))
            }
            if operationWorker == nil { operationWorker = Task { await processOperations() } }
        }
    }

    private func conflicts(_ lhs: PackageOperationKind, _ rhs: PackageOperationKind) -> Bool {
        if let left = lhs.packageID, let right = rhs.packageID { return left == right }
        return lhs == rhs
    }

    private func processOperations() async {
        while !pendingOperations.isEmpty {
            let pending = pendingOperations.removeFirst()
            updateOperation(pending.id) { $0.status = .running; $0.startedAt = Date() }
            if pending.kind == .updateHomebrew { isLatestAfterUpdate = nil }
            let result: BreweryCommandResult
            if usesLiveCommands {
                result = await BreweryCommand.run(pending.kind.arguments, onOutput: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.updateOperation(pending.id) {
                            guard $0.status == .running else { return }
                            $0.output = String(($0.output + chunk).suffix(60_000))
                        }
                    }
                })
            } else { result = await commandRunner(pending.kind.arguments, true) }
            if result.succeeded {
                // A reload begun during an operation may have captured older inventory.
                if let reloadTask { await reloadTask.value }
                _ = await loadAllBrew()
                await loadOutdatedPackages()
                await loadBrewMeta()
                if pending.kind == .updateHomebrew { isLatestAfterUpdate = true }
                if pending.kind == .cleanup { cleanupMessage = result.displayOutput.isEmpty ? "Cleanup completed." : result.displayOutput }
            } else { recordFailure(result) }
            updateOperation(pending.id) {
                $0.status = result.succeeded ? .succeeded : .failed
                $0.output = String((result.succeeded ? result.displayOutput : result.failureOutput).suffix(60_000))
                $0.finishedAt = Date()
            }
            let finishedIDs = operations.filter { !$0.isPending }.dropLast(30).map(\.id)
            operations.removeAll { finishedIDs.contains($0.id) }
            pending.completion()
        }
        operationWorker = nil
    }

    private func updateOperation(_ id: UUID, _ change: (inout PackageOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        change(&operations[index])
    }

    func fetchInfo(name: String, isCask: Bool = false) async -> String {
        let result = await execResult(["info", isCask ? "--cask" : "--formula", name])
        return result.succeeded ? result.displayOutput : "Unable to load information.\n\(result.failureOutput)"
    }
    func fetchPackageInfo(name: String, isCask: Bool) async -> (formula: BreweryFormula?, cask: BreweryCask?) {
        do { return try await packageInfo(for: isCask ? .cask(name) : .formula(name)) }
        catch { return (nil, nil) }
    }
    func packageInfo(for id: PackageID) async throws -> (formula: BreweryFormula?, cask: BreweryCask?) {
        let generation = executableGeneration
        let args = ["info", "--json=v2", id.kind == .cask ? "--cask" : "--formula", id.name]
        // Throwing callers render their own retry state. A global alert would
        // dismiss the information popover before its retry button is usable.
        let result = await commandRunner(args, false)
        guard generation == executableGeneration else {
            throw PackageInfoError.unavailable("Homebrew changed while loading this package. Please try again.")
        }
        guard result.succeeded else {
            let message = result.failureOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PackageInfoError.unavailable(message.isEmpty ? "Package information could not be loaded. Please try again." : message)
        }
        do {
            let info = try JSONDecoder().decode(BrewInfoResult.self, from: Data(result.stdout.utf8))
            guard (id.kind == .formula ? !info.formulae.isEmpty : !info.casks.isEmpty) else { throw PackageInfoError.unavailable("No package information was returned.") }
            return (info.formulae.first, info.casks.first)
        } catch {
            throw PackageInfoError.unavailable("Package information could not be loaded. Please try again.")
        }
    }
    func resolveFormulaForDependencyGraph(name: String) async throws -> BreweryFormula {
        if let installed = getFormula(for: name) { return installed }
        let info = try await packageInfo(for: .formula(name))
        guard let formula = info.formula else { throw DependencyGraphLoadError.formulaUnavailable(name) }
        return formula
    }

    func recordFailure(_ result: BreweryCommandResult) { if !result.succeeded { lastCommandError = result } }
    private func recordParseFailure(_ result: BreweryCommandResult, message: String) {
        lastCommandError = BreweryCommandResult(arguments: result.arguments, stdout: "", stderr: [message, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n"), exitCode: 1)
    }
    func clearCommandError() { lastCommandError = nil }
    private func execResult(_ args: [String], logOutput: Bool = true) async -> BreweryCommandResult {
        let generation = executableGeneration
        let result = await commandRunner(args, logOutput)
        if generation == executableGeneration { recordFailure(result) }
        return result
    }
}
