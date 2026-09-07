import XCTest
@testable import OtoSanpo

final class WalkDiscoverySummaryTests: XCTestCase {
    private let walkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstPassageBecomesNew() {
        var summary = WalkDiscoverySummary(walkID: walkID, startedAt: start)

        summary.record([update("a", passNumber: 1)])

        XCTAssertEqual(summary.shopCount, 1)
        XCTAssertEqual(summary.newShopCount, 1)
        XCTAssertEqual(summary.revisitedShopCount, 0)
        XCTAssertTrue(summary.shopDiscoveries[0].isNew)
    }

    func testFourthPassageIsRevisit() {
        var summary = WalkDiscoverySummary(walkID: walkID, startedAt: start)

        summary.record([update("a", passNumber: 4)])

        XCTAssertEqual(summary.newShopCount, 0)
        XCTAssertEqual(summary.revisitedShopCount, 1)
        XCTAssertFalse(summary.shopDiscoveries[0].isNew)
    }

    func testSameShopDetectedTwiceInWalkIsOneDiscovery() {
        var summary = WalkDiscoverySummary(walkID: walkID, startedAt: start)

        summary.record([
            update("a", at: start.addingTimeInterval(10), distanceM: 12, passNumber: 1),
            update("a", at: start.addingTimeInterval(20), distanceM: 8, passNumber: 1)
        ])

        XCTAssertEqual(summary.shopDiscoveries.count, 1)
        XCTAssertEqual(summary.shopDiscoveries[0].passedAt, start.addingTimeInterval(10))
    }

    func testNoNewShops() {
        let summary = WalkDiscoverySummary(walkID: walkID,
                                           startedAt: start,
                                           shopDiscoveries: [
                                            discovery("a", passNumber: 2),
                                            discovery("b", passNumber: 5)
                                           ])

        XCTAssertEqual(summary.newShopCount, 0)
        XCTAssertEqual(summary.revisitedShopCount, 2)
    }

    func testMultipleNewShops() {
        let summary = WalkDiscoverySummary(walkID: walkID,
                                           startedAt: start,
                                           shopDiscoveries: [
                                            discovery("a", passNumber: 1),
                                            discovery("b", passNumber: 1)
                                           ])

        XCTAssertEqual(summary.newShopCount, 2)
        XCTAssertEqual(summary.newShops.map(\.shopID), ["a", "b"])
    }

    func testMixedNewAndRevisitedShops() {
        let summary = WalkDiscoverySummary(walkID: walkID,
                                           startedAt: start,
                                           shopDiscoveries: [
                                            discovery("a", passNumber: 1),
                                            discovery("b", passNumber: 4)
                                           ])

        XCTAssertEqual(summary.shopCount, 2)
        XCTAssertEqual(summary.newShopCount, 1)
        XCTAssertEqual(summary.revisitedShopCount, 1)
    }

    func testFinishSetsEndDate() {
        var summary = WalkDiscoverySummary(walkID: walkID, startedAt: start)
        let end = start.addingTimeInterval(600)

        summary.finish(at: end)

        XCTAssertEqual(summary.endedAt, end)
        XCTAssertTrue(summary.isFinished)
    }

    func testStoreRoundTripsDiscoverySummary() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = WalkDiscoverySummary(walkID: walkID,
                                           startedAt: start,
                                           endedAt: start.addingTimeInterval(600),
                                           shopDiscoveries: [
                                            discovery("a", passNumber: 1),
                                            discovery("b", passNumber: 4)
                                           ])

        DiscoverySummaryStore.save(summary, to: url)

        XCTAssertEqual(DiscoverySummaryStore.load(from: url), summary)
    }

    private func update(_ id: String,
                        at date: Date? = nil,
                        distanceM: Double = 10,
                        passNumber: Int) -> ShopPassageUpdate {
        ShopPassageUpdate(shopID: id,
                          isFirstPassage: passNumber == 1,
                          passedAt: date ?? start,
                          distanceM: distanceM,
                          passNumber: passNumber)
    }

    private func discovery(_ id: String, passNumber: Int) -> WalkShopDiscovery {
        WalkShopDiscovery(shopID: id, passedAt: start, distanceM: 10, passNumber: passNumber)
    }
}
