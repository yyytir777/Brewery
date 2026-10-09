import Foundation

struct DependencyGraphRootMetadata: Equatable {
    let fullName: String
    let name: String
    let dependencies: [String]

    init(_ formula: BreweryFormula) {
        fullName = formula.full_name
        name = formula.name
        dependencies = formula.dependencies
    }
}

struct DependencyNodeID: Hashable {
    let path: [String]

    var name: String {
        path.last ?? ""
    }
}

enum DependencyGraphNodeKind: Equatable {
    case formula
    case cycleReference
}

struct DependencyGraphNode: Identifiable, Equatable {
    let id: DependencyNodeID
    let parentID: DependencyNodeID?
    let name: String
    let depth: Int
    let kind: DependencyGraphNodeKind
}

enum DependencyGraphNodeState: Equatable {
    case collapsed
    case expanded
    case loading
    case leaf
    case failed(String)
    case cycleReference
}

enum DependencyGraphLoadError: LocalizedError, Equatable {
    case formulaUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .formulaUnavailable(let name):
            return "Could not load dependencies for \(name)."
        }
    }
}

typealias DependencyFormulaLoader = (String) async throws -> BreweryFormula
