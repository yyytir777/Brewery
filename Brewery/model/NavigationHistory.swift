enum BreweryDestination: Hashable {
    case home
    case discover
    case installed(outdatedOnly: Bool)
    case package(PackageID)
}

struct NavigationHistory {
    private(set) var current: BreweryDestination = .home
    private var backStack: [BreweryDestination] = []
    private var forwardStack: [BreweryDestination] = []

    init(current: BreweryDestination = .home) { self.current = current }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func navigate(to destination: BreweryDestination) {
        guard destination != current else { return }
        backStack.append(current)
        current = destination
        forwardStack.removeAll()
    }

    mutating func goBack() {
        guard let destination = backStack.popLast() else { return }
        forwardStack.append(current)
        current = destination
    }

    mutating func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        backStack.append(current)
        current = destination
    }

    mutating func removePackages(_ packageIDs: Set<PackageID>) {
        guard !packageIDs.isEmpty else { return }
        func isRemoved(_ destination: BreweryDestination) -> Bool {
            if case .package(let id) = destination { return packageIDs.contains(id) }
            return false
        }
        backStack.removeAll(where: isRemoved)
        forwardStack.removeAll(where: isRemoved)
        if isRemoved(current) {
            current = .installed(outdatedOnly: false)
            while backStack.last == current { backStack.removeLast() }
            while forwardStack.last == current { forwardStack.removeLast() }
        }
    }
}
