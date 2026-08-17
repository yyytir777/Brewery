import XCTest
@testable import Brewery

private enum LoaderProbeError: Error {
    case missing
    case expectedFailure
}

private actor LoaderProbe {
    private var results: [String: Result<BreweryFormula, LoaderProbeError>]
    private var delays: [String: UInt64]
    private var calls: [String: Int] = [:]

    init(
        results: [String: Result<BreweryFormula, LoaderProbeError>],
        delays: [String: UInt64] = [:]
    ) {
        self.results = results
        self.delays = delays
    }

    func load(_ name: String) async throws -> BreweryFormula {
        calls[name, default: 0] += 1
        guard let result = results[name] else {
            throw LoaderProbeError.missing
        }
        if let delay = delays[name] {
            try await Task.sleep(nanoseconds: delay)
        }
        return try result.get()
    }

    func setResult(_ result: Result<BreweryFormula, LoaderProbeError>, for name: String) {
        results[name] = result
    }

    func callCount(for name: String) -> Int {
        calls[name, default: 0]
    }
}

@MainActor
final class DependencyGraphStoreTests: XCTestCase {
    func testInitialTreeShowsRootAndDirectDependencies() {
        let root = makeFormula("git", dependencies: ["pcre2", "gettext"])
        let store = DependencyGraphStore(root: root) { name in makeFormula(name) }

        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2", "gettext"])
        XCTAssertEqual(store.visibleNodes.map(\.depth), [0, 1, 1])
        XCTAssertEqual(store.state(for: DependencyNodeID(path: ["git"])), .expanded)
    }

    func testDuplicateRootDependenciesAreShownOnce() {
        let store = DependencyGraphStore(
            root: makeFormula("root", dependencies: ["shared", "shared"])
        ) { name in
            makeFormula(name)
        }

        XCTAssertEqual(store.visibleNodes.map(\.name), ["root", "shared"])
        XCTAssertEqual(Set(store.visibleNodes.map(\.id)).count, store.visibleNodes.count)
    }

    func testRootSelfDependencyIsANonExpandableCycleReference() async {
        let store = DependencyGraphStore(
            root: makeFormula("root", dependencies: ["root"])
        ) { name in
            makeFormula(name)
        }
        let cycleID = DependencyNodeID(path: ["root", "root"])

        XCTAssertEqual(store.visibleNodes.last?.kind, .cycleReference)
        XCTAssertEqual(store.state(for: cycleID), .cycleReference)
        let added = await store.toggleExpansion(cycleID)
        XCTAssertTrue(added.isEmpty)
    }

    func testSelectingNodeDoesNotExpandIt() {
        let store = DependencyGraphStore(root: makeFormula("git", dependencies: ["pcre2"])) { name in
            makeFormula(name, dependencies: ["child"])
        }
        let id = DependencyNodeID(path: ["git", "pcre2"])

        store.select(id)

        XCTAssertEqual(store.selectedNodeID, id)
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2"])
    }

    func testExpansionLoadsChildrenAndCollapseHidesThem() async {
        let probe = LoaderProbe(results: [
            "pcre2": .success(makeFormula("pcre2", dependencies: ["zstd"]))
        ])
        let store = DependencyGraphStore(root: makeFormula("git", dependencies: ["pcre2"])) {
            try await probe.load($0)
        }
        let pcre2 = DependencyNodeID(path: ["git", "pcre2"])

        let added = await store.toggleExpansion(pcre2)

        XCTAssertEqual(added, [DependencyNodeID(path: ["git", "pcre2", "zstd"])])
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2", "zstd"])
        XCTAssertEqual(store.state(for: pcre2), .expanded)

        _ = await store.toggleExpansion(pcre2)

        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2"])
        XCTAssertEqual(store.state(for: pcre2), .collapsed)
    }

    func testReexpansionUsesCachedFormula() async {
        let probe = LoaderProbe(results: [
            "pcre2": .success(makeFormula("pcre2", dependencies: ["zstd"]))
        ])
        let store = DependencyGraphStore(root: makeFormula("git", dependencies: ["pcre2"])) {
            try await probe.load($0)
        }
        let pcre2 = DependencyNodeID(path: ["git", "pcre2"])

        _ = await store.toggleExpansion(pcre2)
        _ = await store.toggleExpansion(pcre2)
        _ = await store.toggleExpansion(pcre2)

        let callCount = await probe.callCount(for: "pcre2")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2", "zstd"])
    }

    func testExpandedFormulaWithoutDependenciesBecomesLeaf() async {
        let store = DependencyGraphStore(root: makeFormula("root", dependencies: ["leaf"])) { name in
            makeFormula(name)
        }
        let leaf = DependencyNodeID(path: ["root", "leaf"])

        let added = await store.toggleExpansion(leaf)

        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(store.state(for: leaf), .leaf)
    }

    func testConcurrentDuplicatePathsShareOneLoaderTask() async {
        let probe = LoaderProbe(
            results: [
                "left": .success(makeFormula("left", dependencies: ["shared"])),
                "right": .success(makeFormula("right", dependencies: ["shared"])),
                "shared": .success(makeFormula("shared", dependencies: ["leaf"]))
            ],
            delays: ["shared": 50_000_000]
        )
        let store = DependencyGraphStore(root: makeFormula("root", dependencies: ["left", "right"])) {
            try await probe.load($0)
        }
        let left = DependencyNodeID(path: ["root", "left"])
        let right = DependencyNodeID(path: ["root", "right"])
        _ = await store.toggleExpansion(left)
        _ = await store.toggleExpansion(right)
        let leftShared = DependencyNodeID(path: ["root", "left", "shared"])
        let rightShared = DependencyNodeID(path: ["root", "right", "shared"])

        async let leftResult = store.toggleExpansion(leftShared)
        async let rightResult = store.toggleExpansion(rightShared)
        _ = await (leftResult, rightResult)

        let callCount = await probe.callCount(for: "shared")
        XCTAssertEqual(callCount, 1)
    }

    func testSameFormulaUnderDifferentParentsHasDistinctPathIDs() async {
        let probe = LoaderProbe(results: [
            "left": .success(makeFormula("left", dependencies: ["shared"])),
            "right": .success(makeFormula("right", dependencies: ["shared"]))
        ])
        let store = DependencyGraphStore(root: makeFormula("root", dependencies: ["left", "right"])) {
            try await probe.load($0)
        }

        _ = await store.toggleExpansion(DependencyNodeID(path: ["root", "left"]))
        _ = await store.toggleExpansion(DependencyNodeID(path: ["root", "right"]))

        let sharedNodes = store.visibleNodes.filter { $0.name == "shared" }
        XCTAssertEqual(sharedNodes.count, 2)
        XCTAssertEqual(Set(sharedNodes.map(\.id)).count, 2)
    }

    func testAncestryCycleCreatesNonExpandableReference() async {
        let probe = LoaderProbe(results: [
            "child": .success(makeFormula("child", dependencies: ["root"]))
        ])
        let store = DependencyGraphStore(root: makeFormula("root", dependencies: ["child"])) {
            try await probe.load($0)
        }
        let child = DependencyNodeID(path: ["root", "child"])

        _ = await store.toggleExpansion(child)

        let cycleID = DependencyNodeID(path: ["root", "child", "root"])
        XCTAssertEqual(store.visibleNodes.last?.kind, .cycleReference)
        XCTAssertEqual(store.state(for: cycleID), .cycleReference)
        let cycleExpansion = await store.toggleExpansion(cycleID)
        XCTAssertTrue(cycleExpansion.isEmpty)
    }

    func testFailureIsScopedToNodeAndRetryCanRecover() async {
        let probe = LoaderProbe(results: [
            "pcre2": .failure(.expectedFailure)
        ])
        let store = DependencyGraphStore(root: makeFormula("git", dependencies: ["pcre2"])) {
            try await probe.load($0)
        }
        let pcre2 = DependencyNodeID(path: ["git", "pcre2"])

        _ = await store.toggleExpansion(pcre2)

        guard case .failed = store.state(for: pcre2) else {
            return XCTFail("Expected only pcre2 to enter the failed state")
        }
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2"])

        await probe.setResult(.success(makeFormula("pcre2", dependencies: ["zstd"])), for: "pcre2")
        let added = await store.retry(pcre2)

        XCTAssertEqual(added.map(\.name), ["zstd"])
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2", "zstd"])
        let callCount = await probe.callCount(for: "pcre2")
        XCTAssertEqual(callCount, 2)
    }

    func testExpansionBeyondVisibleLimitIsRejected() async {
        let probe = LoaderProbe(results: [
            "child": .success(makeFormula("child", dependencies: ["one", "two"]))
        ])
        let store = DependencyGraphStore(
            root: makeFormula("root", dependencies: ["child"]),
            loader: { try await probe.load($0) },
            maxVisibleNodes: 3
        )
        let child = DependencyNodeID(path: ["root", "child"])

        let added = await store.toggleExpansion(child)

        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(store.visibleNodes.count, 2)
        XCTAssertNotNil(store.limitMessage)
        XCTAssertEqual(store.state(for: child), .collapsed)
    }
}
