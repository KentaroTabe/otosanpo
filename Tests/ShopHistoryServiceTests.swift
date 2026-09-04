import XCTest
@testable import OtoSanpo

final class ShopHistoryServiceTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    func testProviderSearchRadiusIsSeparateFromPassageRadius() async {
        let searched = LockedProvider()
        let farFromPassage = Geo.destination(from: origin, bearingDeg: 90, distanceM: 80)
        searched.shopsToReturn = [
            Shop(shopID: "far", name: "遠い店", latitude: farFromPassage.latitude,
                 longitude: farFromPassage.longitude, category: "cafe")
        ]
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: searched,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 120,
                                                  maxHorizontalAccuracyM: 50))
        var session = service.startSession()

        await service.refreshCache(around: origin)
        let updates = service.recordCachedPassages(near: origin,
                                                   horizontalAccuracyM: 10,
                                                   session: &session,
                                                   at: Date())

        XCTAssertEqual(searched.nearRequests.map(\.searchRadiusM), [120])
        XCTAssertTrue(updates.isEmpty)
        XCTAssertTrue(store.savedHistories.isEmpty)
    }

    func testAreaCacheAvoidsProviderCallsInsideSameArea() async {
        let provider = LockedProvider()
        provider.shopsToReturn = [
            Shop(shopID: "a", name: "店", latitude: origin.latitude,
                 longitude: origin.longitude, category: "cafe")
        ]
        let service = ShopHistoryService(
            provider: provider,
            store: MemoryShopHistoryStore(),
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 120,
                                                  maxHorizontalAccuracyM: 50))

        await service.refreshCache(around: origin)
        await service.refreshCache(around: origin)

        XCTAssertEqual(provider.nearRequests.count, 1)
    }

    func testCachedProviderResultCanBePersistedAfterGoodAccuracy() async {
        let provider = LockedProvider()
        provider.shopsToReturn = [
            Shop(shopID: "a", name: "店", latitude: origin.latitude,
                 longitude: origin.longitude, category: "cafe")
        ]
        let store = MemoryShopHistoryStore()
        let service = ShopHistoryService(
            provider: provider,
            store: store,
            settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                  searchRadiusM: 120,
                                                  maxHorizontalAccuracyM: 50))
        var session = service.startSession()

        await service.refreshCache(around: origin)
        let updates = service.recordCachedPassages(near: origin,
                                                   horizontalAccuracyM: 10,
                                                   session: &session,
                                                   at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(updates.map(\.shopID), ["a"])
        XCTAssertEqual(store.savedHistories.last?.historiesByShopID["a"]?.passCount, 1)
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

private final class MemoryShopHistoryStore: ShopHistoryStoring, @unchecked Sendable {
    var savedHistories: [ShopHistory] = []
    private let lock = NSLock()
    private var history = ShopHistory()

    func load() -> ShopHistory {
        lock.withLock { history }
    }

    func save(_ history: ShopHistory) {
        lock.withLock {
            self.history = history
            savedHistories.append(history)
        }
    }
}
