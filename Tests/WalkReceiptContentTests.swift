import XCTest
@testable import OtoSanpo

final class WalkReceiptContentTests: XCTestCase {
    private let walkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
    private let otherWalkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
    private let start = Date(timeIntervalSince1970: 2_000)
    private let origin = GeoPoint(latitude: 35.0, longitude: 139.0)

    func testMatchingWalkIDBuildsReceiptWithShops() {
        let content = makeContent(discoveries: [
            discovery("a", passNumber: 1)
        ])

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.shopItems.map(\.name), ["喫茶こみち"])
    }

    func testMismatchedWalkIDDoesNotMixShopDiscoveries() {
        let summary = makeSummary(walkID: walkID)
        let discoverySummary = WalkDiscoverySummary(
            walkID: otherWalkID,
            startedAt: start,
            shopDiscoveries: [discovery("a", passNumber: 1)])

        let content = WalkReceiptContent(summary: summary,
                                         discoverySummary: discoverySummary,
                                         shopHistoryRecords: [record("a")])

        XCTAssertNil(content)
    }

    func testNewShopUsesNewLabel() {
        let content = makeContent(discoveries: [discovery("a", passNumber: 1)])

        XCTAssertEqual(content?.newShopCount, 1)
        XCTAssertEqual(content?.shopItems.first?.passageLabel, "NEW")
        XCTAssertTrue(content?.shopItems.first?.isNew ?? false)
    }

    func testRevisitedShopUsesPassNumberLabel() {
        let content = makeContent(discoveries: [discovery("a", passNumber: 4)])

        XCTAssertEqual(content?.newShopCount, 0)
        XCTAssertEqual(content?.shopItems.first?.passageLabel, "4回目")
        XCTAssertFalse(content?.shopItems.first?.isNew ?? true)
    }

    func testZeroNewShopsStillShowsRevisitedShops() {
        let content = makeContent(discoveries: [
            discovery("a", passNumber: 2),
            discovery("b", passNumber: 5)
        ], records: [record("a"), record("b", name: "音坂ベーカリー")])

        XCTAssertEqual(content?.newShopCount, 0)
        XCTAssertEqual(content?.shopItems.map(\.passageLabel), ["2回目", "5回目"])
        XCTAssertEqual(content?.shopItems.map(\.name), ["喫茶こみち", "音坂ベーカリー"])
    }

    func testNoShopsProducesEmptyShopItems() {
        let content = makeContent(discoveries: [])

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.newShopCount, 0)
        XCTAssertTrue(content?.shopItems.isEmpty ?? false)
    }

    func testMissingShopInfoFallsBackToShopID() {
        let content = makeContent(discoveries: [discovery("missing", passNumber: 1)],
                                  records: [])

        XCTAssertEqual(content?.shopItems.first?.name, "missing")
        XCTAssertEqual(content?.shopItems.first?.category, "店舗情報を取得できません")
        XCTAssertFalse(content?.shopItems.first?.isResolved ?? true)
    }

    func testTrackAndShopsCanBeShownTogether() {
        let summary = makeSummary(walkID: walkID, trackCount: 2)
        let discoverySummary = WalkDiscoverySummary(
            walkID: walkID,
            startedAt: start,
            shopDiscoveries: [discovery("a", passNumber: 1)])

        let content = WalkReceiptContent(summary: summary,
                                         discoverySummary: discoverySummary,
                                         shopHistoryRecords: [record("a")])

        XCTAssertTrue(content?.hasTrack ?? false)
        XCTAssertTrue(content?.hasShops ?? false)
        XCTAssertNotNil(content?.summary.frame(marginM: 40, minSpanM: 150))
    }

    func testTrackWithoutShopsCanStillBeShown() {
        let content = makeContent(summary: makeSummary(walkID: walkID, trackCount: 2),
                                  discoveries: [])

        XCTAssertTrue(content?.hasTrack ?? false)
        XCTAssertFalse(content?.hasShops ?? true)
        XCTAssertNotNil(content?.summary.frame(marginM: 40, minSpanM: 150))
    }

    func testExistingWalkSummaryFrameStillSupportsRouteDisplay() {
        let summary = makeSummary(walkID: walkID, trackCount: 2)

        let frame = summary.frame(marginM: 40, minSpanM: 150)

        XCTAssertNotNil(frame)
        XCTAssertGreaterThan(frame?.widthM ?? 0, 0)
        XCTAssertGreaterThan(frame?.heightM ?? 0, 0)
    }

    func testExistingShopMapContentStillBuildsCumulativeRecords() {
        let content = ShopMapContent(records: [record("a"), record("b", name: "音坂ベーカリー")])

        XCTAssertEqual(content.records.count, 2)
        XCTAssertNotNil(content.region)
    }

    private func makeContent(summary: WalkSummary? = nil,
                             discoveries: [WalkShopDiscovery],
                             records: [ShopHistoryRecord]? = nil) -> WalkReceiptContent? {
        let summary = summary ?? makeSummary(walkID: walkID)
        let discoverySummary = WalkDiscoverySummary(walkID: walkID,
                                                    startedAt: start,
                                                    shopDiscoveries: discoveries)
        return WalkReceiptContent(summary: summary,
                                  discoverySummary: discoverySummary,
                                  shopHistoryRecords: records ?? [record("a")])
    }

    private func makeSummary(walkID: WalkID, trackCount: Int = 1) -> WalkSummary {
        var summary = WalkSummary(walkID: walkID, startedAt: start, home: origin)
        for i in 0..<trackCount {
            summary.add(point(northM: Double(i) * 120), minSegmentM: 10, maxPoints: 100)
        }
        summary.finish(at: start.addingTimeInterval(1_200), pathLengthM: 1_600)
        return summary
    }

    private func discovery(_ id: String, passNumber: Int) -> WalkShopDiscovery {
        WalkShopDiscovery(shopID: id,
                          passedAt: start.addingTimeInterval(Double(passNumber) * 60),
                          distanceM: 12,
                          passNumber: passNumber)
    }

    private func record(_ id: String,
                        name: String = "喫茶こみち") -> ShopHistoryRecord {
        let location = point(eastM: id == "b" ? 80 : 0)
        return ShopHistoryRecord(
            shop: Shop(shopID: id,
                       name: name,
                       latitude: location.latitude,
                       longitude: location.longitude,
                       category: "カフェ"),
            history: ShopPassageHistory(shopID: id,
                                        firstPassedAt: start,
                                        lastPassedAt: start.addingTimeInterval(60),
                                        passCount: 1))
    }

    private func point(northM: Double = 0, eastM: Double = 0) -> GeoPoint {
        let lonScale = Geo.metersPerDegreeLat * cos(origin.latitude * .pi / 180)
        return GeoPoint(latitude: origin.latitude + northM / Geo.metersPerDegreeLat,
                        longitude: origin.longitude + eastM / lonScale)
    }
}
