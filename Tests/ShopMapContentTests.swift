import XCTest
@testable import OtoSanpo

final class ShopMapContentTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    func testEmptyRecordsProduceNoRegion() {
        let content = ShopMapContent(records: [])

        XCTAssertTrue(content.records.isEmpty)
        XCTAssertNil(content.region)
    }

    func testSingleShopUsesLimitedRegion() {
        let record = makeRecord(id: "a", point: origin)

        let content = ShopMapContent(records: [record])

        XCTAssertEqual(content.records.map(\.shop.shopID), ["a"])
        XCTAssertEqual(content.region?.center.latitude ?? 0, origin.latitude, accuracy: 0.000001)
        XCTAssertEqual(content.region?.center.longitude ?? 0, origin.longitude, accuracy: 0.000001)
        XCTAssertEqual(content.region?.latitudinalMeters ?? 0, ShopMapContent.minSpanM, accuracy: 0.001)
        XCTAssertEqual(content.region?.longitudinalMeters ?? 0, ShopMapContent.minSpanM, accuracy: 0.001)
    }

    func testMultipleShopsFitInsidePaddedRegion() {
        let west = Geo.destination(from: origin, bearingDeg: 270, distanceM: 700)
        let east = Geo.destination(from: origin, bearingDeg: 90, distanceM: 700)

        let content = ShopMapContent(records: [
            makeRecord(id: "w", point: west),
            makeRecord(id: "e", point: east)
        ])

        XCTAssertEqual(content.records.count, 2)
        XCTAssertGreaterThan(content.region?.longitudinalMeters ?? 0, 1_400)
        XCTAssertGreaterThanOrEqual(content.region?.latitudinalMeters ?? 0, ShopMapContent.minSpanM)
    }

    func testDuplicateShopIDsAreCollapsed() {
        let older = makeRecord(id: "same",
                               name: "古い店名",
                               point: origin,
                               lastPassedAt: Date(timeIntervalSince1970: 1_000),
                               passCount: 1)
        let newer = makeRecord(id: "same",
                               name: "新しい店名",
                               point: origin,
                               lastPassedAt: Date(timeIntervalSince1970: 2_000),
                               passCount: 2)

        let content = ShopMapContent(records: [older, newer])

        XCTAssertEqual(content.records.count, 1)
        XCTAssertEqual(content.records[0].shop.name, "新しい店名")
        XCTAssertEqual(content.records[0].history.passCount, 2)
    }

    private func makeRecord(id: String,
                            name: String? = nil,
                            point: GeoPoint,
                            lastPassedAt: Date = Date(timeIntervalSince1970: 2_000),
                            passCount: Int = 1) -> ShopHistoryRecord {
        ShopHistoryRecord(
            shop: Shop(shopID: id,
                       name: name ?? "店 \(id)",
                       latitude: point.latitude,
                       longitude: point.longitude,
                       category: "カフェ"),
            history: ShopPassageHistory(shopID: id,
                                        firstPassedAt: Date(timeIntervalSince1970: 1_000),
                                        lastPassedAt: lastPassedAt,
                                        passCount: passCount))
    }
}
