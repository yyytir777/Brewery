import XCTest
@testable import Brewery

final class CatalogServiceTests: XCTestCase {
    @MainActor
    func testClearCacheDiscardsInFlightCatalogAndRankingResponses() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        _ = try await service.refreshCatalogIfNeeded(force: true)
        _ = await service.refreshRankingsIfNeeded(for: .days30, force: true)
        fixture.network.pause = true
        let catalogRequest = Task { try await service.refreshCatalogIfNeeded(force: true) }
        let rankingRequest = Task { await service.refreshRankingsIfNeeded(for: .days30, force: true) }
        await waitForRequests(fixture.network, count: 4)
        try await service.clearCache()
        fixture.network.complete(index: 0)
        let staleCatalog = try await catalogRequest.value
        let staleRanking = await rankingRequest.value
        XCTAssertNil(staleCatalog, "An invalidated request must not publish its deleted catalog")
        XCTAssertNil(staleRanking.snapshot, "An invalidated request must not publish deleted rankings")
        let size = try await service.cacheSizeBytes()
        XCTAssertEqual(size, 0, "Late responses must not recreate deleted files")
        let local = try await service.loadLocalData(for: .days30)
        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["git", "firefox"])
        XCTAssertNil(local.rankings)
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        let restored = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(Set(restored.catalog.packages.map(\.name)), ["git", "firefox"])
        XCTAssertNil(restored.rankings)
    }

    @MainActor
    func testCatalogRefreshPolicyUsesConfiguredTTL() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let bundleDate = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        for (policy, hours, expectedName) in [("hourly", 2.0, "new-tool"), ("daily", 2.0, "git"), ("daily", 25.0, "new-tool"), ("weekly", 25.0, "git"), ("weekly", 169.0, "new-tool")] {
            let instant = bundleDate.addingTimeInterval(hours * 3600)
            let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, now: { instant }, refreshPolicy: { policy })
            let result = try await service.refreshCatalogIfNeeded()
            XCTAssertEqual(result?.packages.first(where: { $0.kind == .formula })?.name, expectedName, policy)
        }
    }

    @MainActor
    func testClearCacheInvalidatesMemoryAndPreservesUnrelatedFiles() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        _ = try await service.refreshCatalogIfNeeded(force: true)
        _ = await service.refreshRankingsIfNeeded(for: .days30, force: true)
        let size = try await service.cacheSizeBytes()
        XCTAssertGreaterThan(size, 0)
        let unrelated = fixture.cacheURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try await service.clearCache()
        let clearedSize = try await service.cacheSizeBytes()
        XCTAssertEqual(clearedSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let local = try await service.loadLocalData(for: .days30)
        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["git", "firefox"])
        XCTAssertNil(local.rankings)
    }

    @MainActor
    func testManualRefreshPolicyKeepsLocalCatalogUntilExplicitRefresh() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, refreshPolicy: { "manual" })
        let local = try await service.refreshCatalogIfNeeded()
        XCTAssertEqual(Set(local?.packages.map(\.name) ?? []), ["git", "firefox"])
        let rankings = await service.refreshRankingsIfNeeded(for: .days30)
        XCTAssertNil(rankings.snapshot)
        let refreshed = try await service.refreshCatalogIfNeeded(force: true)
        XCTAssertEqual(Set(refreshed?.packages.map(\.name) ?? []), ["new-tool", "firefox"])
    }

    @MainActor
    func testInitialBundleReadAndDecodeRunOutsideMainThread() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let probe = BackgroundWorkProbe()
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL,
                                     onBackgroundWork: { probe.recordCurrentThread() })

        let local = try await service.loadLocalData(for: .days30)

        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["git", "firefox"])
        assertBackgroundWork(probe)
    }

    @MainActor
    func testCacheRestoreReadAndDecodeRunOutsideMainThread() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let first = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        _ = try await first.refreshCatalogIfNeeded(force: true)
        _ = await first.refreshRankingsIfNeeded(for: .days30, force: true)
        let probe = BackgroundWorkProbe()
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: nil, cacheDirectory: fixture.cacheURL,
                                       onBackgroundWork: { probe.recordCurrentThread() })

        let restored = try await restarted.loadLocalData(for: .days30)

        XCTAssertEqual(Set(restored.catalog.packages.map(\.name)), ["new-tool", "firefox"])
        XCTAssertEqual(restored.rankings?.formula?.entries.first?.installs, 30)
        XCTAssertEqual(restored.rankings?.cask?.entries.first?.installs, 20)
        assertBackgroundWork(probe)
    }

    @MainActor
    func testForcedRefreshDecodingAndCacheSavingRunOutsideMainThread() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let probe = BackgroundWorkProbe()
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL,
                                     onBackgroundWork: { probe.recordCurrentThread() })
        _ = try await service.loadLocalData(for: .days30)
        probe.clear()

        let catalog = try await service.refreshCatalogIfNeeded(force: true)
        let rankings = await service.refreshRankingsIfNeeded(for: .days30, force: true)

        XCTAssertEqual(Set(catalog?.packages.map(\.name) ?? []), ["new-tool", "firefox"])
        XCTAssertEqual(rankings.snapshot?.formula?.entries.first?.installs, 30)
        XCTAssertEqual(rankings.snapshot?.cask?.entries.first?.installs, 20)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cacheURL.path).sorted(), ["catalog.json", "rankings-30d.json"])
        assertBackgroundWork(probe)
    }

    @MainActor
    func testCatalogRefreshIncludesNewPackages() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL)
        _ = try await service.loadLocalData(for: .days30)
        let refreshed = try await service.refreshCatalogIfNeeded()
        XCTAssertEqual(Set(refreshed?.packages.map(\.id) ?? []), [.formula("new-tool"), .cask("firefox")])
    }

    @MainActor
    func testFailedRankingSourceRetainsItsLastSuccess() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL)
        _ = await service.refreshRankingsIfNeeded(for: .days30)
        fixture.network.responses["/api/analytics/cask-install/homebrew-cask/30d.json"] = .failure
        let result = await service.refreshRankingsIfNeeded(for: .days30, force: true)
        XCTAssertEqual(result.snapshot?.cask?.entries.first?.installs, 20)
        XCTAssertTrue(result.messages.contains { $0.contains("Cask rankings") && $0.contains("Last successful data") })
    }

    @MainActor
    func testBundledSchemaAndIdentityAreValidated() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try Data(#"{"schemaVersion":99,"generatedAt":"2026-10-01T00:00:00Z","packages":[]}"#.utf8).write(to: fixture.bundleURL)
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL)
        do {
            _ = try await service.loadLocalData(for: .days30)
            XCTFail("Unsupported schema must fail rather than show an empty catalog")
        } catch {}
    }

    @MainActor
    func testRankingsRespectOneHourTTLAndForcedRefresh() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let clock = FixtureClock()
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = await service.refreshRankingsIfNeeded(for: .days30)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"99"}]}"#)
        clock.advance(3_599)
        let fresh = await service.refreshRankingsIfNeeded(for: .days30)
        XCTAssertEqual(fresh.snapshot?.formula?.entries.first?.installs, 30)
        clock.advance(1)
        let expired = await service.refreshRankingsIfNeeded(for: .days30)
        XCTAssertEqual(expired.snapshot?.formula?.entries.first?.installs, 99)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"101"}]}"#)
        let forced = await service.refreshRankingsIfNeeded(for: .days30, force: true)
        XCTAssertEqual(forced.snapshot?.formula?.entries.first?.installs, 101)
    }

    @MainActor
    func testCatalogRespects24HourTTLAndPreservesFailedSource() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let clock = FixtureClock()
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = try await service.refreshCatalogIfNeeded()
        fixture.network.responses["/api/formula.json"] = .json(#"[{"name":"newer-tool","versions":{"stable":"2.0"}}]"#)
        fixture.network.responses["/api/cask.json"] = .failure
        clock.advance(86_399)
        let fresh = try await service.refreshCatalogIfNeeded()
        XCTAssertEqual(Set(fresh?.packages.map(\.name) ?? []), ["new-tool", "firefox"])
        clock.advance(1)
        let expired = try await service.refreshCatalogIfNeeded()
        XCTAssertEqual(Set(expired?.packages.map(\.name) ?? []), ["newer-tool", "firefox"])
        XCTAssertTrue(service.catalogRefreshMessages.contains { $0.contains("Cask catalog") })
    }

    @MainActor
    func testOfflineRestartRestoresCatalogAndSeparatePeriods() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let clock = FixtureClock()
        fixture.network.responses["/api/analytics/install-on-request/90d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"90"}]}"#)
        fixture.network.responses["/api/analytics/cask-install/homebrew-cask/90d.json"] = .json(#"{"formulae":{"firefox":[{"cask":"firefox","count":"60"}]}}"#)
        let first = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = try await first.refreshCatalogIfNeeded()
        _ = await first.refreshRankingsIfNeeded(for: .days30)
        _ = await first.refreshRankingsIfNeeded(for: .days90)
        clock.advance(90_000)
        fixture.network.responses = [:]
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: nil, cacheDirectory: fixture.cacheURL, now: { clock.date })
        let local = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["new-tool", "firefox"])
        XCTAssertEqual(local.rankings?.formula?.entries.first?.installs, 30)
        let otherPeriod = await restarted.refreshRankingsIfNeeded(for: .days90)
        XCTAssertEqual(otherPeriod.snapshot?.formula?.entries.first?.installs, 90)
        XCTAssertEqual(otherPeriod.snapshot?.cask?.entries.first?.installs, 60)
        XCTAssertEqual(otherPeriod.messages.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cacheURL.path).sorted(), ["catalog.json", "rankings-30d.json", "rankings-90d.json"])
    }

    @MainActor
    func testCorruptCacheFallsBackToBundleAndValidRankingSource() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: fixture.cacheURL.appendingPathComponent("catalog.json"))
        try Data(#"{"schemaVersion":1,"window":"30d","formula":{"fetchedAt":"2026-10-01T00:00:00Z","entries":[{"packageID":"formula:git","installs":30,"rank":1},{"packageID":"formula:git","installs":20,"rank":2}]},"cask":{"fetchedAt":"2026-10-01T00:00:00Z","entries":[{"packageID":"cask:firefox","installs":20,"rank":1}]}}"#.utf8).write(to: fixture.cacheURL.appendingPathComponent("rankings-30d.json"))
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        let local = try await service.loadLocalData(for: .days30)
        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["git", "firefox"])
        XCTAssertNil(local.rankings?.formula)
        XCTAssertEqual(local.rankings?.cask?.entries.first?.installs, 20)
    }

    @MainActor
    func testInvalidNetworkRankingsAndEmptyCatalogPreservePriorData() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL)
        _ = await service.refreshRankingsIfNeeded(for: .days30)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"-1"}]}"#)
        fixture.network.responses["/api/formula.json"] = .json("[]")
        let rankings = await service.refreshRankingsIfNeeded(for: .days30, force: true)
        XCTAssertEqual(rankings.snapshot?.formula?.entries.first?.installs, 30)
        let catalog = try await service.refreshCatalogIfNeeded(force: true)
        XCTAssertEqual(Set(catalog?.packages.map(\.name) ?? []), ["git", "firefox"])
    }

    @MainActor
    func testMismatchedCatalogIdentityIsRejected() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try Data(#"{"schemaVersion":1,"generatedAt":"2026-10-01T00:00:00Z","packages":[{"id":"cask:git","name":"git","kind":"formula"}]}"#.utf8).write(to: fixture.bundleURL)
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL)
        do {
            _ = try await service.loadLocalData(for: .days30)
            XCTFail("Mismatched kind must fail")
        } catch {}
    }

    @MainActor
    func testForceRefreshRecoversFromUnusableBundle() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try Data("invalid bundle".utf8).write(to: fixture.bundleURL)
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        do { _ = try await service.loadLocalData(for: .days30); XCTFail("Fixture bundle must fail") } catch {}
        let recovered = try await service.refreshCatalogIfNeeded(force: true)
        XCTAssertEqual(Set(recovered?.packages.map(\.name) ?? []), ["new-tool", "firefox"])
        let local = try await service.loadLocalData(for: .days30)
        XCTAssertEqual(Set(local.catalog.packages.map(\.name)), ["new-tool", "firefox"])
    }

    @MainActor
    func testRecoveredSingleCatalogSourceSurvivesOfflineRestart() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        fixture.network.responses["/api/cask.json"] = .failure
        let first = CatalogService(session: fixture.session, bundleCatalogURL: nil, cacheDirectory: fixture.cacheURL)
        _ = try await first.refreshCatalogIfNeeded(force: true)
        fixture.network.responses = [:]
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: nil, cacheDirectory: fixture.cacheURL)
        let local = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(local.catalog.packages.map(\.name), ["new-tool"])
    }

    @MainActor
    func testEarlierRefreshCannotOverwriteNewerCachedRankings() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        fixture.network.pause = true
        let service = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        let earlier = Task { await service.refreshRankingsIfNeeded(for: .days30, force: true) }
        await waitForRequests(fixture.network, count: 2)
        let later = Task { await service.refreshRankingsIfNeeded(for: .days30, force: true) }
        await waitForRequests(fixture.network, count: 4)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"300"}]}"#)
        fixture.network.complete(index: 1)
        _ = await later.value
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"30"}]}"#)
        fixture.network.complete(index: 0)
        _ = await earlier.value
        let local = try await service.loadLocalData(for: .days30)
        XCTAssertEqual(local.rankings?.formula?.entries.first?.installs, 300)
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL)
        let restored = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(restored.rankings?.formula?.entries.first?.installs, 300)
    }

    @MainActor
    func testStaleServiceFailurePreservesNewerCatalogSavedByAnotherService() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let clock = FixtureClock()
        clock.advance(0.2)
        let stale = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = try await stale.refreshCatalogIfNeeded(force: true)
        clock.advance(0.1)
        fixture.network.responses["/api/formula.json"] = .json(#"[{"name":"newer-tool","versions":{"stable":"2.0"}}]"#)
        let newer = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = try await newer.refreshCatalogIfNeeded(force: true)
        fixture.network.responses = [:]
        let failedRefresh = try await stale.refreshCatalogIfNeeded(force: true)
        XCTAssertEqual(Set(failedRefresh?.packages.map(\.name) ?? []), ["newer-tool", "firefox"])
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: nil, cacheDirectory: fixture.cacheURL, now: { clock.date })
        let restored = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(Set(restored.catalog.packages.map(\.name)), ["newer-tool", "firefox"])
    }

    @MainActor
    func testStaleServicesMergeLatestRankingSourcesBeforeSaving() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let clock = FixtureClock()
        clock.advance(0.2)
        let stale = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = await stale.refreshRankingsIfNeeded(for: .days30, force: true)
        let partial = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = try await partial.loadLocalData(for: .days30)
        clock.advance(0.1)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"300"}]}"#)
        fixture.network.responses["/api/analytics/cask-install/homebrew-cask/30d.json"] = .json(#"{"formulae":{"firefox":[{"cask":"firefox","count":"200"}]}}"#)
        let newer = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        _ = await newer.refreshRankingsIfNeeded(for: .days30, force: true)
        fixture.network.responses = [:]
        let failed = await stale.refreshRankingsIfNeeded(for: .days30, force: true)
        XCTAssertEqual(failed.snapshot?.formula?.entries.first?.installs, 300)
        XCTAssertEqual(failed.snapshot?.cask?.entries.first?.installs, 200)
        clock.advance(0.1)
        fixture.network.responses["/api/analytics/install-on-request/30d.json"] = .json(#"{"items":[{"number":1,"formula":"git","count":"1000"}]}"#)
        let mixed = await partial.refreshRankingsIfNeeded(for: .days30, force: true)
        XCTAssertEqual(mixed.snapshot?.formula?.entries.first?.installs, 1000)
        XCTAssertEqual(mixed.snapshot?.cask?.entries.first?.installs, 200)
        let restarted = CatalogService(session: fixture.session, bundleCatalogURL: fixture.bundleURL, cacheDirectory: fixture.cacheURL, now: { clock.date })
        let restored = try await restarted.loadLocalData(for: .days30)
        XCTAssertEqual(restored.rankings?.formula?.entries.first?.installs, 1000)
        XCTAssertEqual(restored.rankings?.cask?.entries.first?.installs, 200)
    }

    @MainActor private func waitForRequests(_ network: FixtureNetwork, count: Int) async {
        for _ in 0..<1_000 {
            if network.pendingCount >= count { break }
            await Task.yield()
        }
        XCTAssertEqual(network.pendingCount, count)
    }

    private func assertBackgroundWork(_ probe: BackgroundWorkProbe, file: StaticString = #filePath, line: UInt = #line) {
        let observations = probe.mainThreadObservations
        XCTAssertFalse(observations.isEmpty, "The real catalog read/decode/save path must be observed", file: file, line: line)
        XCTAssertFalse(observations.contains(true), "Catalog disk and JSON work must not execute on the main thread", file: file, line: line)
    }
}

private final class BackgroundWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []

    var mainThreadObservations: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }

    func recordCurrentThread() {
        let isMainThread = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        observations.append(isMainThread)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        observations.removeAll()
    }
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}

private final class FixtureNetwork: @unchecked Sendable {
    enum Response { case json(String), failure }
    private let lock = NSLock()
    private var storage: [String: Response] = [:]
    private var paused = false
    private var pending: [String: [CatalogFixtureProtocol]] = [:]
    var pause: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); defer { lock.unlock() }; paused = newValue }
    }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.values.reduce(0) { $0 + $1.count } }
    func enqueue(_ request: CatalogFixtureProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard paused, let path = request.request.url?.path else { return false }
        pending[path, default: []].append(request)
        return true
    }
    func complete(index: Int) {
        lock.lock()
        let requests = pending.values.compactMap { $0.indices.contains(index) ? $0[index] : nil }
        lock.unlock()
        for request in requests { request.respond() }
    }
    var responses: [String: Response] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private final class CatalogFixture {
    let directory: URL
    let bundleURL: URL
    let session: URLSession
    let network = FixtureNetwork()
    var cacheURL: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bundleURL = directory.appendingPathComponent("bundle.json")
        try Data(#"{"schemaVersion":1,"generatedAt":"2026-10-01T00:00:00Z","packages":[{"id":"formula:git","name":"git","kind":"formula"},{"id":"cask:firefox","name":"firefox","kind":"cask"}]}"#.utf8).write(to: bundleURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureProtocol.self]
        session = URLSession(configuration: configuration)
        network.responses = [
            "/api/formula.json": .json(#"[{"name":"new-tool","desc":"New tool","homepage":"https://example.com","versions":{"stable":"1.0"}}]"#),
            "/api/cask.json": .json(#"[{"token":"firefox","desc":"Browser","homepage":"https://example.com","version":"1.0"}]"#),
            "/api/analytics/install-on-request/30d.json": .json(#"{"items":[{"number":1,"formula":"git","count":"30"}]}"#),
            "/api/analytics/cask-install/homebrew-cask/30d.json": .json(#"{"formulae":{"firefox":[{"cask":"firefox","count":"20"}]}}"#)
        ]
        CatalogFixtureProtocol.network = network
    }
    func remove() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
}

private final class FixtureNetworkReference: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FixtureNetwork?
    var value: FixtureNetwork? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private final class CatalogFixtureProtocol: URLProtocol {
    // XCTest executes this suite serially; each fixture has its own synchronized response table.
    private static let networkReference = FixtureNetworkReference()
    static var network: FixtureNetwork? {
        get { networkReference.value }
        set { networkReference.value = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.network?.enqueue(self) == true { return }
        respond()
    }
    func respond() {
        guard let url = request.url else { return }
        switch Self.network?.responses[url.path] ?? .failure {
        case .failure: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .json(let value):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(value.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
