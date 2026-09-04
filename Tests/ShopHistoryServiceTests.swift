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

        await service.startSession()
        _ = await service.refreshCacheIfNeeded(around: origin)
        let updates = await service.recordPosition(origin,
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

        async let first: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin)
        async let second: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin)
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

        _ = await service.refreshCacheIfNeeded(around: origin)
        _ = await service.refreshCacheIfNeeded(around: Geo.destination(from: origin,
                                                                       bearingDeg: 90,
                                                                       distanceM: 269))
        _ = await service.refreshCacheIfNeeded(around: Geo.destination(from: origin,
                                                                       bearingDeg: 90,
                                                                       distanceM: 271))

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

        await service.startSession()
        async let refresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin)
        await provider.waitForRequests(1)
        _ = await service.recordPosition(origin,
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

        await service.startSession()
        async let refresh: [ShopPassageUpdate] = service.refreshCacheIfNeeded(around: origin)
        await provider.waitForRequests(1)
        let route = [TimedGeoPoint(point: origin, date: passedAt)]
        async let finish: [ShopPassageUpdate] = service.finishSession(
            finalRoute: route,
            fallbackDate: Date(timeIntervalSince1970: 2_000))
        provider.completeAll(with: [shop])
        _ = await refresh
        _ = await finish

        XCTAssertEqual(store.savedHistories.last?.historiesByShopID["a"]?.firstPassedAt, passedAt)
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
