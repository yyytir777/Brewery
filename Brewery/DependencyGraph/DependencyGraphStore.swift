import Combine
import Foundation

@MainActor
final class DependencyGraphStore: ObservableObject {
    @Published private(set) var selectedNodeID: DependencyNodeID?
    @Published private(set) var expandedNodeIDs: Set<DependencyNodeID>
    @Published private(set) var loadingNodeIDs: Set<DependencyNodeID> = []
    @Published private(set) var failures: [DependencyNodeID: String] = [:]
    @Published private(set) var limitMessage: String?

    private let loader: DependencyFormulaLoader
    private var rootID: DependencyNodeID
    private var rootMetadata: DependencyGraphRootMetadata
    private let maxVisibleNodes: Int
    private var nodesByID: [DependencyNodeID: DependencyGraphNode] = [:]
    private var childrenByParent: [DependencyNodeID: [DependencyNodeID]] = [:]
    private var loadedNodeIDs: Set<DependencyNodeID> = []
    private var formulaCache: [String: BreweryFormula] = [:]
    private var inFlightLoads: [String: Task<BreweryFormula, Error>] = [:]
    private var loadGeneration = 0

    init(
        root: BreweryFormula,
        loader: @escaping DependencyFormulaLoader,
        maxVisibleNodes: Int = 150
    ) {
        self.loader = loader
        self.rootID = DependencyNodeID(path: [root.full_name])
        self.rootMetadata = DependencyGraphRootMetadata(root)
        self.maxVisibleNodes = maxVisibleNodes
        self.expandedNodeIDs = []
        installRoot(root)
    }

    private func installRoot(_ root: BreweryFormula) {
        rootID = DependencyNodeID(path: [root.full_name])
        expandedNodeIDs = [rootID]
        loadedNodeIDs = [rootID]
        formulaCache = [root.full_name: root]
        selectedNodeID = nil
        failures = [:]
        limitMessage = nil

        let rootNode = DependencyGraphNode(
            id: rootID,
            parentID: nil,
            name: root.name,
            depth: 0,
            kind: .formula
        )
        var initialNodes = [rootID: rootNode]
        var seenDependencies: Set<String> = []
        let uniqueDependencies = root.dependencies.filter {
            seenDependencies.insert($0).inserted
        }
        let visibleDependencies = Array(uniqueDependencies.prefix(max(0, maxVisibleNodes - 1)))
        let childIDs = visibleDependencies.map { dependency in
            let id = DependencyNodeID(path: [root.full_name, dependency])
            initialNodes[id] = DependencyGraphNode(
                id: id,
                parentID: rootID,
                name: dependency,
                depth: 1,
                kind: dependency == root.full_name ? .cycleReference : .formula
            )
            return id
        }
        self.nodesByID = initialNodes
        self.childrenByParent = [rootID: childIDs]
        if visibleDependencies.count < uniqueDependencies.count {
            self.limitMessage = Self.limitMessage(maxVisibleNodes)
        }
    }

    var visibleNodes: [DependencyGraphNode] {
        var result: [DependencyGraphNode] = []

        func appendVisible(_ id: DependencyNodeID) {
            guard let node = nodesByID[id] else { return }
            result.append(node)
            guard expandedNodeIDs.contains(id) else { return }
            for childID in childrenByParent[id] ?? [] {
                appendVisible(childID)
            }
        }

        appendVisible(rootID)
        return result
    }

    @discardableResult
    func updateRoot(_ root: BreweryFormula) -> Bool {
        let metadata = DependencyGraphRootMetadata(root)
        guard metadata != rootMetadata else {
            formulaCache[root.full_name] = root
            return false
        }
        cancelPendingLoads()
        rootMetadata = metadata
        installRoot(root)
        return true
    }

    func cancelPendingLoads() {
        loadGeneration += 1
        inFlightLoads.values.forEach { $0.cancel() }
        inFlightLoads.removeAll()
        loadingNodeIDs.removeAll()
    }

    func select(_ id: DependencyNodeID) {
        selectedNodeID = id
    }

    func state(for id: DependencyNodeID) -> DependencyGraphNodeState {
        guard let node = nodesByID[id] else { return .leaf }
        if node.kind == .cycleReference { return .cycleReference }
        if loadingNodeIDs.contains(id) { return .loading }
        if let message = failures[id] { return .failed(message) }
        if loadedNodeIDs.contains(id), childrenByParent[id, default: []].isEmpty { return .leaf }
        if expandedNodeIDs.contains(id) { return .expanded }
        return .collapsed
    }

    func toggleExpansion(_ id: DependencyNodeID) async -> [DependencyNodeID] {
        guard let node = nodesByID[id], node.kind != .cycleReference else { return [] }

        limitMessage = nil
        if expandedNodeIDs.contains(id) {
            expandedNodeIDs.remove(id)
            return []
        }

        if loadedNodeIDs.contains(id) {
            return revealLoadedChildren(of: id)
        }

        loadingNodeIDs.insert(id)
        failures[id] = nil
        let generation = loadGeneration
        defer {
            if generation == loadGeneration { loadingNodeIDs.remove(id) }
        }

        do {
            let formula = try await loadFormula(named: node.id.name)
            guard generation == loadGeneration, !Task.isCancelled else { return [] }
            installChildren(of: formula, beneath: node)
            loadedNodeIDs.insert(id)
            return revealLoadedChildren(of: id)
        } catch is CancellationError {
            return []
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return [] }
            failures[id] = error.localizedDescription
            return []
        }
    }

    func retry(_ id: DependencyNodeID) async -> [DependencyNodeID] {
        failures[id] = nil
        return await toggleExpansion(id)
    }

    private func loadFormula(named name: String) async throws -> BreweryFormula {
        if let cached = formulaCache[name] {
            return cached
        }
        if let inFlight = inFlightLoads[name] {
            return try await inFlight.value
        }

        let generation = loadGeneration
        let task = Task { try await loader(name) }
        inFlightLoads[name] = task
        do {
            let formula = try await task.value
            guard generation == loadGeneration else { throw CancellationError() }
            formulaCache[name] = formula
            inFlightLoads[name] = nil
            return formula
        } catch {
            if generation == loadGeneration { inFlightLoads[name] = nil }
            throw error
        }
    }

    private func installChildren(
        of formula: BreweryFormula,
        beneath parent: DependencyGraphNode
    ) {
        var seenNames: Set<String> = []
        let childIDs = formula.dependencies.compactMap { dependency -> DependencyNodeID? in
            guard seenNames.insert(dependency).inserted else { return nil }

            let childID = DependencyNodeID(path: parent.id.path + [dependency])
            let kind: DependencyGraphNodeKind = parent.id.path.contains(dependency)
                ? .cycleReference
                : .formula
            nodesByID[childID] = DependencyGraphNode(
                id: childID,
                parentID: parent.id,
                name: dependency,
                depth: parent.depth + 1,
                kind: kind
            )
            return childID
        }
        childrenByParent[parent.id] = childIDs
    }

    private func revealLoadedChildren(of id: DependencyNodeID) -> [DependencyNodeID] {
        let previouslyVisible = Set(visibleNodes.map(\.id))
        expandedNodeIDs.insert(id)
        let candidate = visibleNodes
        guard candidate.count <= maxVisibleNodes else {
            expandedNodeIDs.remove(id)
            limitMessage = Self.limitMessage(maxVisibleNodes)
            return []
        }
        return candidate.map(\.id).filter { !previouslyVisible.contains($0) }
    }

    private static func limitMessage(_ maximum: Int) -> String {
        "This graph can show up to \(maximum) visible packages. Collapse another branch to continue."
    }
}
