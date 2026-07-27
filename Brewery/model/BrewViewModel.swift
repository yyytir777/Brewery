//
//  brewViewModel.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI
import Combine

@MainActor
class BreweryViewModel: ObservableObject {
    // 설치된 formula 정보
    @Published private var formulaMap: [String: BreweryFormula] = [:]
    // 설치된 cask정보
    @Published private var caskMap: [String: BreweryCask] = [:]
    // 업데이트 중인 패키지 정보
    @Published var updatingPackageNames: Set<String> = []
    
    @Published var isLatestAfterUpdate: Bool? = nil
    
    @Published var isLoading = false
    
    @Published var isRunningUpdate = false
    @Published var isRunningCleanup = false
    
    @Published var installingPackages: Set<String> = []
    @Published var uninstallingPackages: Set<String> = []
    @Published var lastCommandError: BreweryCommandResult?
    
    @Published var brewVersion: String = ""
    @Published var brewSize: String = ""
    
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching = false
    
    var commandErrorMessage: String {
        guard let result = lastCommandError else { return "" }
        let command = "brew " + result.arguments.joined(separator: " ")
        let output = result.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return "\(command) failed with exit code \(result.exitCode)."
        }
        return "\(command) failed with exit code \(result.exitCode).\n\n\(output)"
    }

    var installedFormula: [BreweryFormula] {
        formulaMap.values.sorted { $0.name < $1.name }
    }

    var installedCasks: [BreweryCask] {
        caskMap.values.sorted { $0.name < $1.name }
    }

    func getFormula(for name: String) -> BreweryFormula? {
        formulaMap[name]
    }

    func getCask(for name: String) -> BreweryCask? {
        caskMap[name]
    }

    func formula(for id: PackageID) -> BreweryFormula? {
        guard id.kind == .formula else { return nil }
        return formulaMap[id.name]
    }

    func cask(for id: PackageID) -> BreweryCask? {
        guard id.kind == .cask else { return nil }
        return caskMap[id.name]
    }
    
    func updateBrew(name: String, isCask: Bool = false) async -> Void {
        updatingPackageNames.insert(name)
        defer {
            updatingPackageNames.remove(name)
        }
        
        let args = isCask ? ["upgrade", "--cask", name] : ["upgrade", name]
        let result = await execResult(args)
        guard result.succeeded else { return }
        await loadAllBrew()
    }

    init(loadOnInit: Bool = true) {
        if loadOnInit {
            Task { await loadInstalled() }
        }
    }

    func loadInstalled() async {
        isLoading = true
        await loadAllBrew()
        await loadBrewMeta()
        isLoading = false
    }
    
    public func loadBrewMeta() async {
        let version = await exec(["--version"])
        brewVersion = version.components(separatedBy: "").first ?? ""
        
        let info = await exec(["info"])
        brewSize = info.components(separatedBy: ", ").last ?? ""
        
    }

    public func loadAllBrew() async {
        let json = await exec(["info", "--json=v2", "--installed"], logOutput: false)
        guard let data = json.data(using: .utf8) else { return }

        do {
            let result = try JSONDecoder().decode(BrewInfoResult.self, from: data)
            self.formulaMap = Dictionary(uniqueKeysWithValues: result.formulae.map { ($0.name, $0) })
            self.caskMap = Dictionary(uniqueKeysWithValues: result.casks.map { ($0.token, $0) })
        } catch {
            print("JSON parse error: \(error)")
        }
    }
    
    public func brewSelfUpdate() async {
        isRunningUpdate = true
        isLatestAfterUpdate = nil
        defer {
            isRunningUpdate = false
        }
        
        let versionBefore = brewVersion
        let result = await execResult(["update"])
        guard result.succeeded else { return }
        await loadBrewMeta()
        
        isLatestAfterUpdate = (brewVersion == versionBefore)
        await loadAllBrew()
    }
    
    public func brewCleanUp() async {
        isRunningCleanup = true
        defer {
            isRunningCleanup = false
        }
        let result = await execResult(["cleanup"])
        guard result.succeeded else { return }
        await loadAllBrew()
    }
    
    public func uninstallCask(name: String) async {
        uninstallingPackages.insert(name)
        defer {
            uninstallingPackages.remove(name)
        }
        let result = await execResult(["uninstall", "--cask", name])
        guard result.succeeded else { return }
        await loadAllBrew()
    }
    
    public func uninstallCaskWithZap(name: String) async {
        uninstallingPackages.insert(name)
        defer {
            uninstallingPackages.remove(name)
        }
        let result = await execResult(["uninstall", "--cask", "--zap", name])
        guard result.succeeded else { return }
        await loadAllBrew()
    }

    public func uninstallFormula(name: String) async {
        uninstallingPackages.insert(name)
        defer {
            uninstallingPackages.remove(name)
        }
        let result = await execResult(["uninstall", name])
        guard result.succeeded else { return }
        await loadAllBrew()
    }

    func fetchInfo(name: String) async -> String {
        return await exec(["info", name])
    }
    
    public func installCask(name: String) async {
        installingPackages.insert(name)
        defer {
            installingPackages.remove(name)
        }
        
        let result = await execResult(["install", "--cask", name])
        guard result.succeeded else { return }
        await loadAllBrew()
    }
    
    public func installFormula(name: String) async {
        installingPackages.insert(name)
        defer {
            installingPackages.remove(name)
        }
        
        let result = await execResult(["install", name])
        guard result.succeeded else { return }
        await loadAllBrew()
    }
    
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        defer {
            isSearching = false
        }
        
        let output = await exec(["search", query])
        searchResults = parseSearchOutput(output)
    }
    
    public func fetchPackageInfo(name: String, isCask: Bool) async -> (formula: BreweryFormula?, cask: BreweryCask?) {
        let args = isCask ? ["info", "--json=v2", "--cask", name] : ["info", "--json=v2", name]
        let json = await exec(args, logOutput: false)
        guard let data = json.data(using: .utf8), let result = try? JSONDecoder().decode(BrewInfoResult.self, from: data) else { return(nil, nil) }
        return (result.formulae.first, result.casks.first)
    }

    func recordFailure(_ result: BreweryCommandResult) {
        guard !result.succeeded else { return }
        lastCommandError = result
    }

    func clearCommandError() {
        lastCommandError = nil
    }

    private func execResult(_ args: [String], logOutput: Bool = true) async -> BreweryCommandResult {
        let result = await BreweryCommand.run(args, logOutput: logOutput)
        if !result.succeeded {
            recordFailure(result)
        }
        return result
    }

    private func exec(_ args: [String], logOutput: Bool = true) async -> String {
        await execResult(args, logOutput: logOutput).displayOutput
    }
    
    /*
     search 결과를 파싱하여 패키지 이름을 저장
     */
    private func parseSearchOutput(_ output: String) -> [SearchResult] {
        var results: [SearchResult] = []
        var isCask = false
        
        for line in output.components(separatedBy: "\n") {
            if line.contains("==> Formulae") { isCask = false }
            else if line.contains("==> Casks") { isCask = true }
            else {
                let names = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                results += names.map { SearchResult(name: $0, isCask: isCask)}
            }
        }
        return results
    }
}
