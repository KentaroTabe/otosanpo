import XCTest
@testable import OtoSanpo

final class ShopHistoryServiceTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    func testDefaultSearchRadiusIsThreeHundredMeters() {
        XCTAssertEqual(ShopPassageRules.defaultSearchRadiusM, 300, accuracy: 0.001)
        XCTAssertEqual(ShopHistoryService.Settings().searchRadiusM, 300, accuracy: 0.001)
    }

    func testProviderSearchRadiusIsSeparateFromPassageRadius() async {
        let provider = LockedProvider()
        let farFromPassage = Geo.destination(from: origin, bearingDeg: 90, distanceM: 80)
        provider.shopsToReturn = [
            Shop(shopID: "far", name: "遠い店", latitude: farFromPassage.latitude,
                 longitude: farFromPassage.longitude, category: "cafe")
        ]
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let sessionID = await service.startSession()
        _ = await service.refreshCacheIfNeeded(around: origin, sessionID: sessionID)
        let updates = await service.recordPosition(origin,
                                                   sessionID: sessionID,
                                                   horizontalAccuracyM: 10,
                                                   at: Date())

        XCTAssertEqual(provider.nearRequests.map(\.searchRadiusM), [300])
        XCTAssertTrue(updates.isEmpty)
        XCTAssertTrue(store.savedHistories.isEmpty)
    }

    func testConcurrentRefreshForSameRangeCallsProviderOnce() async {
        let provider = DelayedProvider()
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let sessionID = await service.startSession()
        async let first: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                            sessionID: sessionID)
        async let second: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                             sessionID: sessionID)
        await provider.waitForRequests(1)
        provider.completeAll(with: [])
        _ = await (first, second)

        XCTAssertEqual(provider.nearRequests.count, 1)
    }

    func testPendingRefreshCanBeSharedAcrossSessions() async {
        let provider = DelayedProvider()
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))
        let firstID = await service.startSession()
        let secondID = await service.startSession()

        async let first: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                            sessionID: firstID)
        async let second: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                             sessionID: secondID)
        await provider.waitForRequests(1)
        provider.completeAll(with: [])
        _ = await (first, second)

        XCTAssertEqual(provider.nearRequests.count, 1)
    }

    func testMovingNearCacheEdgeStartsAnotherFetch() async {
        let provider = LockedProvider()
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let sessionID = await service.startSession()
        _ = await service.refreshCacheIfNeeded(around: origin, sessionID: sessionID)
        _ = await service.refreshCacheIfNeeded(around: Geo.destination(from: origin,
                                                                       bearingDeg: 90,
                                                                       distanceM: 269),
                                               sessionID: sessionID)
        _ = await service.refreshCacheIfNeeded(around: Geo.destination(from: origin,
                                                                       bearingDeg: 90,
                                                                       distanceM: 271),
                                               sessionID: sessionID)

        XCTAssertEqual(provider.nearRequests.count, 2)
    }

    func testDelayedProviderResponseRecordsAlreadyPassedShop() async {
        let shop = Shop(shopID: "a", name: "店", latitude: origin.latitude,
                        longitude: origin.longitude, category: "cafe")
        let provider = DelayedProvider()
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let sessionID = await service.startSession()
        async let refresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                              sessionID: sessionID)
        await provider.waitForRequests(1)
        _ = await service.recordPosition(origin,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        provider.completeAll(with: [shop])
        let updates = await refresh

        XCTAssertEqual(updates.map(\.shopID), ["a"])
        XCTAssertEqual(store.savedHistories.last?.historiesByShopID["a"]?.firstPassedAt,
                       Date(timeIntervalSince1970: 1_000))
    }

    func testFinishWaitsForDelayedProviderAndKeepsHistory() async {
        let shop = Shop(shopID: "a", name: "店", latitude: origin.latitude,
                        longitude: origin.longitude, category: "cafe")
        let provider = DelayedProvider()
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))
        let passedAt = Date(timeIntervalSince1970: 1_000)

        let sessionID = await service.startSession()
        async let refresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                              sessionID: sessionID)
        await provider.waitForRequests(1)
        _ = await service.recordPosition(origin,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: passedAt)
        async let finish: [ShopPassageUpdate] = service.finishSession(
            sessionID,
            fallbackDate: Date(timeIntervalSince1970: 2_000))
        provider.completeAll(with: [shop])
        _ = await refresh
        _ = await finish

        XCTAssertEqual(store.savedHistories.last?.historiesByShopID["a"]?.firstPassedAt, passedAt)
    }

    func testStartingNextSessionDuringPreviousFinishKeepsBothSessionsSeparate() async {
        let firstShop = Shop(shopID: "first", name: "前回", latitude: origin.latitude,
                             longitude: origin.longitude, category: "cafe")
        let secondPoint = Geo.destination(from: origin, bearingDeg: 90, distanceM: 600)
        let secondShop = Shop(shopID: "second", name: "次回", latitude: secondPoint.latitude,
                              longitude: secondPoint.longitude, category: "cafe")
        let provider = QueuedProvider(responses: [[firstShop], [secondShop]])
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let firstID = await service.startSession()
        async let firstRefresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(
            around: origin,
            sessionID: firstID)
        await provider.waitForRequests(1)
        _ = await service.recordPosition(origin,
                                         sessionID: firstID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        async let firstFinish: [ShopPassageUpdate] = service.finishSession(firstID)

        let secondID = await service.startSession()
        async let secondRefresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(
            around: secondPoint,
            sessionID: secondID)
        await provider.waitForRequests(2)
        _ = await service.recordPosition(secondPoint,
                                         sessionID: secondID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 2_000))

        provider.completeNext()
        _ = await firstRefresh
        _ = await firstFinish
        provider.completeNext()
        _ = await secondRefresh

        let history = await service.currentHistory()
        XCTAssertEqual(history.historiesByShopID["first"]?.passCount, 1)
        XCTAssertEqual(history.historiesByShopID["second"]?.passCount, 1)
    }

    func testDelayedPreviousResponseDoesNotMarkNextSessionAsPassed() async {
        let shop = Shop(shopID: "shared", name: "共有", latitude: origin.latitude,
                        longitude: origin.longitude, category: "cafe")
        let provider = QueuedProvider(responses: [[shop]])
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let firstID = await service.startSession()
        async let firstRefresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(
            around: origin,
            sessionID: firstID)
        await provider.waitForRequests(1)
        _ = await service.recordPosition(origin,
                                         sessionID: firstID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        let secondID = await service.startSession()
        _ = await service.recordPosition(origin,
                                         sessionID: secondID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 2_000))

        provider.completeNext()
        _ = await firstRefresh
        let secondUpdates = await service.recordPosition(origin,
                                                         sessionID: secondID,
                                                         horizontalAccuracyM: 10,
                                                         at: Date(timeIntervalSince1970: 2_010))

        XCTAssertEqual(secondUpdates.map(\.shopID), ["shared"])
        let history = await service.currentHistory()
        XCTAssertEqual(history.historiesByShopID["shared"]?.passCount, 2)
    }

    func testOutOfOrderPositionsUseChronologicalPassageTime() async {
        let east = Geo.destination(from: origin, bearingDeg: 90, distanceM: 100)
        let middle = Geo.destination(from: origin, bearingDeg: 90, distanceM: 50)
        let shop = Shop(shopID: "mid", name: "中間", latitude: middle.latitude,
                        longitude: middle.longitude, category: "cafe")
        let provider = LockedProvider()
        provider.shopsToReturn = [shop]
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))
        let sessionID = await service.startSession()

        _ = await service.refreshCacheIfNeeded(around: origin, sessionID: sessionID)
        _ = await service.recordPosition(east,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_100))
        _ = await service.recordPosition(origin,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        _ = await service.finishSession(sessionID)

        let history = await service.currentHistory()
        XCTAssertEqual(history.historiesByShopID["mid"]?.firstPassedAt.timeIntervalSince1970 ?? 0,
                       1_050,
                       accuracy: 0.01)
    }

    func testRefreshStartedJustBeforeFinishIsAwaited() async {
        let shop = Shop(shopID: "a", name: "店", latitude: origin.latitude,
                        longitude: origin.longitude, category: "cafe")
        let provider = DelayedProvider()
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))
        let sessionID = await service.startSession()

        _ = await service.recordPosition(origin,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        async let refresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin,
                                                                              sessionID: sessionID)
        await provider.waitForRequests(1)
        async let finish: [ShopPassageUpdate] = service.finishSession(sessionID)
        provider.completeAll(with: [shop])
        _ = await refresh
        _ = await finish

        let history = await service.currentHistory()
        XCTAssertEqual(history.historiesByShopID["a"]?.passCount, 1)
    }

    func testSameWalkCountsOnceAndDifferentWalkIncrementsPassCount() async {
        let shop = Shop(shopID: "a", name: "店", latitude: origin.latitude,
                        longitude: origin.longitude, category: "cafe")
        let provider = LockedProvider()
        provider.shopsToReturn = [shop]
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 300,
                                                  maxHorizontalAccuracyM: 50))

        let firstID = await service.startSession()
        _ = await service.refreshCacheIfNeeded(around: origin, sessionID: firstID)
        _ = await service.recordPosition(origin, sessionID: firstID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        _ = await service.recordPosition(origin, sessionID: firstID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_010))

        let secondID = await service.startSession()
        _ = await service.recordPosition(origin, sessionID: secondID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 2_000))

        let history = await service.currentHistory()
        XCTAssertEqual(history.historiesByShopID["a"]?.passCount, 2)
    }

    func testLocalStoreRoundTripsHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalShopHistoryStore(fileURL: url)
        let shop = Shop(shopID: "a", name: "店", latitude: 35, longitude: 137, category: "cafe")
        let history = ShopHistory(
            shopsByID: ["a": shop],
            historiesByShopID: [
                "a": ShopPassageHistory(shopID: "a",
                                        firstPassedAt: Date(timeIntervalSince1970: 1_000),
                                        lastPassedAt: Date(timeIntervalSince1970: 2_000),
                                        passCount: 2)
            ])

        store.save(history)

        XCTAssertEqual(store.load(), history)
    }
}

private final class LockedProvider: ShopCandidateProviding, @unchecked Sendable {
    var shopsToReturn: [Shop] = []
    private let lock = NSLock()
    private var lockedNearRequests: [(position: GeoPoint, searchRadiusM: Double)] = []

    var nearRequests: [(position: GeoPoint, searchRadiusM: Double)] {
        lock.withLock { lockedNearRequests }
    }

    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] {
        lock.withLock {
            lockedNearRequests.append((position, searchRadiusM))
        }
        return shopsToReturn
    }

    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] {
        shopsToReturn
    }
}

private final class DelayedProvider: ShopCandidateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<[Shop], Error>] = []
    private var lockedNearRequests: [(position: GeoPoint, searchRadiusM: Double)] = []

    var nearRequests: [(position: GeoPoint, searchRadiusM: Double)] {
        lock.withLock { lockedNearRequests }
    }

    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                lockedNearRequests.append((position, searchRadiusM))
                continuations.append(continuation)
            }
        }
    }

    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func waitForRequests(_ count: Int) async {
        while nearRequests.count < count {
            await Task.yield()
        }
    }

    func completeAll(with shops: [Shop]) {
        let pending = lock.withLock {
            let pending = continuations
            continuations = []
            return pending
        }
        for continuation in pending {
            continuation.resume(returning: shops)
        }
    }
}

private final class QueuedProvider: ShopCandidateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<[Shop], Error>] = []
    private var responses: [[Shop]]
    private var lockedNearRequests: [(position: GeoPoint, searchRadiusM: Double)] = []

    init(responses: [[Shop]]) {
        self.responses = responses
    }

    var nearRequests: [(position: GeoPoint, searchRadiusM: Double)] {
        lock.withLock { lockedNearRequests }
    }

    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                lockedNearRequests.append((position, searchRadiusM))
                continuations.append(continuation)
            }
        }
    }

    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func waitForRequests(_ count: Int) async {
        while nearRequests.count < count {
            await Task.yield()
        }
    }

    func completeNext() {
        let next = lock.withLock { () -> (CheckedContinuation<[Shop], Error>, [Shop])? in
            guard !continuations.isEmpty else { return nil }
            let continuation = continuations.removeFirst()
            let response = responses.isEmpty ? [] : responses.removeFirst()
            return (continuation, response)
        }
        if let (continuation, response) = next {
            continuation.resume(returning: response)
        }
    }
}

private final class MemoryShopHistoryStore: ShopHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var history = ShopHistory()
    private var lockedSavedHistories: [ShopHistory] = []

    var savedHistories: [ShopHistory] {
        lock.withLock { lockedSavedHistories }
    }

    func load() -> ShopHistory {
        lock.withLock { history }
    }

    func save(_ history: ShopHistory) {
        lock.withLock {
            self.history = history
            lockedSavedHistories.append(history)
        }
    }
}
