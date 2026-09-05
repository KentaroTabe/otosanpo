import Combine
import XCTest
@testable import OtoSanpo

@MainActor
final class ShopHistoryControllerTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    func testSavedHistoryIsLoadedForPublishedRecords() async throws {
        let store = MemoryStore()
        store.historyToLoad = ShopHistory(
            shopsByID: ["a": shop(id: "a", name: "起動時の店", point: origin)],
            historiesByShopID: [
                "a": ShopPassageHistory(shopID: "a",
                                        firstPassedAt: Date(timeIntervalSince1970: 1_000),
                                        lastPassedAt: Date(timeIntervalSince1970: 2_000),
                                        passCount: 2)
            ])
        let service = ShopHistoryService(provider: EmptyShopCandidateProvider(),
                                         store: store)
        let controller = try makeController(service: service)

        if controller.shopHistoryRecords.isEmpty {
            let loaded = expectation(description: "shop history loaded")
            var cancellable: AnyCancellable?
            cancellable = controller.$shopHistoryRecords
                .dropFirst()
                .sink { records in
                    if records.map(\.shop.name) == ["起動時の店"] {
                        loaded.fulfill()
                    }
                }
            await fulfillment(of: [loaded], timeout: 1)
            cancellable?.cancel()
        }

        XCTAssertEqual(controller.shopHistoryRecords.map(\.shop.name), ["起動時の店"])
        XCTAssertEqual(controller.shopHistoryRecords.first?.history.passCount, 2)
    }

    func testPublishedRecordsRefreshAfterPassageUpdate() async throws {
        let provider = StaticProvider(shopsToReturn: [shop(id: "a", name: "通った店", point: origin)])
        let service = ShopHistoryService(provider: provider,
                                         store: MemoryStore(),
                                         settings: ShopHistoryService.Settings(passageRadiusM: 30,
                                                                               searchRadiusM: 300,
                                                                               maxHorizontalAccuracyM: 50))
        let controller = try makeController(service: service)
        let sessionID = await service.startSession()

        _ = await service.refreshCacheIfNeeded(around: origin, sessionID: sessionID)
        _ = await service.recordPosition(origin,
                                         sessionID: sessionID,
                                         horizontalAccuracyM: 10,
                                         at: Date(timeIntervalSince1970: 1_000))
        await controller.refreshShopHistoryRecords()

        XCTAssertEqual(controller.shopHistoryRecords.map(\.shop.name), ["通った店"])
        XCTAssertEqual(controller.shopHistoryRecords.first?.history.passCount, 1)
    }

    private func makeController(service: ShopHistoryService) throws -> WalkSessionController {
        let params = try ConfigLoader.load(from: repositoryParametersURL())
        return WalkSessionController(params: params,
                                     shopHistory: service,
                                     startLocationServices: false)
    }

    private func repositoryParametersURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config/parameters.json")
    }

    private func shop(id: String, name: String, point: GeoPoint) -> Shop {
        Shop(shopID: id, name: name, latitude: point.latitude,
             longitude: point.longitude, category: "カフェ")
    }
}

private final class StaticProvider: ShopCandidateProviding, @unchecked Sendable {
    let shopsToReturn: [Shop]

    init(shopsToReturn: [Shop]) {
        self.shopsToReturn = shopsToReturn
    }

    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] {
        shopsToReturn
    }

    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] {
        shopsToReturn
    }
}

private final class MemoryStore: ShopHistoryStoring, @unchecked Sendable {
    var historyToLoad = ShopHistory()
    private(set) var savedHistories: [ShopHistory] = []

    func load() -> ShopHistory {
        historyToLoad
    }

    func save(_ history: ShopHistory) {
        savedHistories.append(history)
        historyToLoad = history
    }
}
