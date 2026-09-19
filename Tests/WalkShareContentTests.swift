import XCTest
@testable import OtoSanpo

final class WalkShareContentTests: XCTestCase {
    private let walkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!)
    private let start = Date(timeIntervalSince1970: 4_000)
    private let origin = GeoPoint(latitude: 35.0, longitude: 139.0)

    func testShareContentKeepsWalkDateAndDuration() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: [])

        XCTAssertEqual(content.date, start)
        XCTAssertEqual(content.durationSec, 42 * 60)
        XCTAssertEqual(content.durationMinutes, 42)
    }

    func testShareContentKeepsDistance() {
        let receipt = makeReceipt(pathLengthM: 3_200)

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: [])

        XCTAssertEqual(content.distanceM, 3_200)
        XCTAssertEqual(content.distanceKilometers, 3.2, accuracy: 0.001)
    }

    func testNewShopCountComesFromReceiptContent() {
        let receipt = makeReceipt(discoveries: [
            discovery("new-a", passNumber: 1),
            discovery("new-b", passNumber: 1),
            discovery("again", passNumber: 4)
        ])

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: [])

        XCTAssertEqual(content.newShopCount, 2)
    }

    func testNoSelectedShopsProducesEmptySelectedShops() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: [])

        XCTAssertTrue(content.selectedShops.isEmpty)
    }

    func testOnlySelectedShopsAreIncluded() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: ["new-b"])

        XCTAssertEqual(content.selectedShops.map(\.shopID), ["new-b"])
    }

    func testNewShopPassageLabelIsPreserved() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: ["new-a"])

        XCTAssertEqual(content.selectedShops.first?.passageLabel, "NEW")
    }

    func testRevisitedShopPassageLabelIsPreserved() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt, selectedShopIDs: ["again"])

        XCTAssertEqual(content.selectedShops.first?.passageLabel, "4回目")
    }

    func testSelectedShopsAreLimitedToTwo() {
        let receipt = makeReceipt()

        let content = WalkShareContent(receipt: receipt,
                                       selectedShopIDs: ["new-a", "new-b", "again"])

        XCTAssertEqual(content.selectedShops.count, 2)
        XCTAssertEqual(content.selectedShops.map(\.shopID), ["new-a", "new-b"])
    }

    func testOriginalWalkSummaryIsNotChanged() {
        let receipt = makeReceipt()
        let before = receipt.summary

        _ = WalkShareContent(receipt: receipt, selectedShopIDs: ["new-a", "again"])

        XCTAssertEqual(receipt.summary, before)
    }

    func testWalkReceiptContentStillBuildsSameShopItems() {
        let receipt = makeReceipt()

        XCTAssertEqual(receipt.shopItems.map(\.shopID), ["new-a", "new-b", "again"])
        XCTAssertEqual(receipt.shopItems.map(\.passageLabel), ["NEW", "NEW", "4回目"])
    }

    private func makeReceipt(pathLengthM: Double = 3_200,
                             discoveries: [WalkShopDiscovery]? = nil) -> WalkReceiptContent {
        let discoveries = discoveries ?? [
            discovery("new-a", passNumber: 1),
            discovery("new-b", passNumber: 1),
            discovery("again", passNumber: 4)
        ]
        let summary = makeSummary(pathLengthM: pathLengthM)
        let discoverySummary = WalkDiscoverySummary(walkID: walkID,
                                                    startedAt: start,
                                                    endedAt: summary.endedAt,
                                                    shopDiscoveries: discoveries)
        return WalkReceiptContent(summary: summary,
                                  discoverySummary: discoverySummary,
                                  shopHistoryRecords: [
                                    record("new-a", name: "喫茶こみち"),
                                    record("new-b", name: "音坂ベーカリー"),
                                    record("again", name: "まるや食堂")
                                  ])!
    }

    private func makeSummary(pathLengthM: Double) -> WalkSummary {
        var summary = WalkSummary(walkID: walkID, startedAt: start, home: origin)
        summary.add(origin, minSegmentM: 10, maxPoints: 100)
        summary.add(point(northM: 200, eastM: 100), minSegmentM: 10, maxPoints: 100)
        summary.finish(at: start.addingTimeInterval(42 * 60), pathLengthM: pathLengthM)
        return summary
    }

    private func discovery(_ id: String, passNumber: Int) -> WalkShopDiscovery {
        WalkShopDiscovery(shopID: id,
                          passedAt: start.addingTimeInterval(Double(passNumber) * 60),
                          distanceM: 12,
                          passNumber: passNumber)
    }

    private func record(_ id: String, name: String) -> ShopHistoryRecord {
        ShopHistoryRecord(
            shop: Shop(shopID: id,
                       name: name,
                       latitude: origin.latitude,
                       longitude: origin.longitude,
                       category: "カフェ"),
            history: ShopPassageHistory(shopID: id,
                                        firstPassedAt: start,
                                        lastPassedAt: start,
                                        passCount: 1))
    }

    private func point(northM: Double = 0, eastM: Double = 0) -> GeoPoint {
        let lonScale = Geo.metersPerDegreeLat * cos(origin.latitude * .pi / 180)
        return GeoPoint(latitude: origin.latitude + northM / Geo.metersPerDegreeLat,
                        longitude: origin.longitude + eastM / lonScale)
    }
}
