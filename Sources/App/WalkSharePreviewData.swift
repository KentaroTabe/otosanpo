import Foundation

enum WalkSharePreviewData {
    enum PreviewCase {
        case mixed
        case empty
        case revisitedOnly
        case missingShopInfo
    }

    static let walkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!)
    static let start = Date(timeIntervalSince1970: 1_820_000_000)
    static let origin = GeoPoint(latitude: 35.6812, longitude: 139.7671)

    static func receipt(_ previewCase: PreviewCase) -> WalkReceiptContent {
        switch previewCase {
        case .mixed:
            return makeContent(discoveries: [
                discovery("coffee", minutes: 7, passNumber: 1),
                discovery("bakery", minutes: 18, passNumber: 1),
                discovery("diner", minutes: 31, passNumber: 4)
            ])
        case .empty:
            return makeContent(discoveries: [])
        case .revisitedOnly:
            return makeContent(discoveries: [
                discovery("coffee", minutes: 9, passNumber: 2),
                discovery("diner", minutes: 24, passNumber: 5)
            ])
        case .missingShopInfo:
            return makeContent(discoveries: [
                discovery("unknown-hotpepper-id", minutes: 14, passNumber: 1)
            ], records: records.filter { $0.shop.shopID != "unknown-hotpepper-id" })
        }
    }

    static func shareContent(selectedShopIDs: [String]) -> WalkShareContent {
        WalkShareContent(receipt: receipt(.mixed), selectedShopIDs: selectedShopIDs)
    }

    private static func makeContent(discoveries: [WalkShopDiscovery],
                                    records: [ShopHistoryRecord] = records)
        -> WalkReceiptContent {
        let summary = makeSummary()
        let discoverySummary = WalkDiscoverySummary(walkID: walkID,
                                                    startedAt: start,
                                                    endedAt: summary.endedAt,
                                                    shopDiscoveries: discoveries)
        return WalkReceiptContent(summary: summary,
                                  discoverySummary: discoverySummary,
                                  shopHistoryRecords: records)!
    }

    private static func makeSummary() -> WalkSummary {
        var summary = WalkSummary(walkID: walkID, startedAt: start, home: origin)
        summary.add(origin, minSegmentM: 10, maxPoints: 100)
        summary.add(point(northM: 180, eastM: 80), minSegmentM: 10, maxPoints: 100)
        summary.add(point(northM: 260, eastM: 260), minSegmentM: 10, maxPoints: 100)
        summary.add(point(northM: 80, eastM: 340), minSegmentM: 10, maxPoints: 100)
        summary.startGuidance(at: point(northM: 180, eastM: 80),
                              bearingDeg: 90,
                              onReturn: false,
                              now: start.addingTimeInterval(8 * 60))
        summary.finishGuidance(ending: TurnGuidance.Ending.turned.rawValue)
        summary.addMark(.returnStart,
                        at: point(northM: 80, eastM: 340),
                        onReturn: true,
                        now: start.addingTimeInterval(34 * 60))
        summary.finish(at: start.addingTimeInterval(42 * 60), pathLengthM: 3_200)
        return summary
    }

    private static func discovery(_ id: String,
                                  minutes: TimeInterval,
                                  passNumber: Int) -> WalkShopDiscovery {
        WalkShopDiscovery(shopID: id,
                          passedAt: start.addingTimeInterval(minutes * 60),
                          distanceM: 14,
                          passNumber: passNumber)
    }

    private static let records: [ShopHistoryRecord] = [
        record(id: "coffee", name: "喫茶こみち", category: "カフェ", northM: 95, eastM: 35),
        record(id: "bakery", name: "音坂ベーカリー", category: "パン", northM: 220, eastM: 180),
        record(id: "diner", name: "まるや食堂", category: "和食", northM: 120, eastM: 330)
    ]

    private static func record(id: String,
                               name: String,
                               category: String,
                               northM: Double,
                               eastM: Double) -> ShopHistoryRecord {
        let location = point(northM: northM, eastM: eastM)
        return ShopHistoryRecord(
            shop: Shop(shopID: id,
                       name: name,
                       latitude: location.latitude,
                       longitude: location.longitude,
                       category: category),
            history: ShopPassageHistory(shopID: id,
                                        firstPassedAt: start,
                                        lastPassedAt: start.addingTimeInterval(20 * 60),
                                        passCount: 1))
    }

    private static func point(northM: Double = 0, eastM: Double = 0) -> GeoPoint {
        let lonScale = Geo.metersPerDegreeLat * cos(origin.latitude * .pi / 180)
        return GeoPoint(latitude: origin.latitude + northM / Geo.metersPerDegreeLat,
                        longitude: origin.longitude + eastM / lonScale)
    }
}
