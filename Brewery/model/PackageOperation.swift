import Foundation

enum PackageOperationKind: Equatable {
    case install(PackageID)
    case upgrade(PackageID)
    case uninstall(PackageID, deleteData: Bool)
    case updateHomebrew
    case cleanup

    var packageID: PackageID? {
        switch self {
        case .install(let id), .upgrade(let id), .uninstall(let id, _): return id
        case .updateHomebrew, .cleanup: return nil
        }
    }

    var title: String {
        switch self {
        case .install(let id): return "Install \(id.name)"
        case .upgrade(let id): return "Update \(id.name)"
        case .uninstall(let id, _): return "Uninstall \(id.name)"
        case .updateHomebrew: return "Refresh Homebrew"
        case .cleanup: return "Clean up old files"
        }
    }

    var localizedTitle: String {
        switch self {
        case .install(let id): BreweryLocalization.format("Install %@", id.name)
        case .upgrade(let id): BreweryLocalization.format("Update %@", id.name)
        case .uninstall(let id, _): BreweryLocalization.format("Uninstall %@", id.name)
        case .updateHomebrew: BreweryLocalization.string("Refresh Homebrew")
        case .cleanup: BreweryLocalization.string("Clean up old files")
        }
    }

    var arguments: [String] {
        switch self {
        case .install(let id): return ["install", id.kind == .formula ? "--formula" : "--cask", id.name]
        case .upgrade(let id): return ["upgrade", id.kind == .formula ? "--formula" : "--cask", id.name]
        case .uninstall(let id, let deleteData):
            return ["uninstall", id.kind == .formula ? "--formula" : "--cask"] + (deleteData && id.kind == .cask ? ["--zap"] : []) + [id.name]
        case .updateHomebrew: return ["update"]
        case .cleanup: return ["cleanup"]
        }
    }
}

struct PackageOperation: Identifiable {
    enum Status: String { case queued = "Waiting", running = "Running", succeeded = "Completed", failed = "Failed", cancelled = "Cancelled" }
    let id: UUID
    let kind: PackageOperationKind
    var status: Status = .queued
    var output = ""
    var startedAt: Date?
    var finishedAt: Date?
    var isPending: Bool { status == .queued || status == .running }
}

struct CleanupPreview: Identifiable {
    let id = UUID()
    let output: String
}

enum PackageInfoError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}
