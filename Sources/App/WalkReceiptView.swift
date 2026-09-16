import SwiftUI

struct WalkReceiptView: View {
    let content: WalkReceiptContent
    let marginM: Double
    let minSpanM: Double
    let roadsProvider: (MapFrame) -> [RoadSegment]

    init(content: WalkReceiptContent,
         marginM: Double,
         minSpanM: Double,
         roadsProvider: @escaping (MapFrame) -> [RoadSegment]) {
        self.content = content
        self.marginM = marginM
        self.minSpanM = minSpanM
        self.roadsProvider = roadsProvider
    }

    var body: some View {
        Section("今日の音さんぽ") {
            VStack(alignment: .leading, spacing: 4) {
                Text(walkDateLine(content.summary))
                    .font(.subheadline.bold())
                Text(walkTimeRangeLine(content.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("歩いた時間",
                           value: String(format: "%.0f 分", content.summary.durationSec / 60))
            LabeledContent("距離",
                           value: String(format: "%.1f km", content.summary.pathLengthM / 1_000))
            discoveryMetric(title: "NEW", value: "\(content.newShopCount) 軒")

            VStack(alignment: .leading, spacing: 8) {
                Text("今日見つけた店")
                    .font(.subheadline.bold())
                if content.shopItems.isEmpty {
                    Text("今日は新しい店との出会いはありませんでした")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(content.shopItems) { item in
                        receiptShopRow(item)
                    }
                }
            }
            .padding(.vertical, 4)

            NavigationLink("経路図と店を見る") {
                WalkSummaryView(summary: content.summary,
                                marginM: marginM,
                                minSpanM: minSpanM,
                                discoveredShops: content.shopItems,
                                showsDiscoveredShops: true,
                                roadsProvider: roadsProvider)
            }
        }
    }

    private func discoveryMetric(title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("街の発見")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.bold())
            }
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    private func receiptShopRow(_ shop: WalkReceiptShopItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.name)
                    .font(.subheadline)
                if let category = shop.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(shop.passageLabel)
                .font(.caption.bold())
                .foregroundStyle(shop.isNew ? Color.accentColor : Color.secondary)
        }
    }

    private func walkDateLine(_ summary: WalkSummary) -> String {
        summary.startedAt.formatted(.dateTime.month().day())
    }

    private func walkTimeRangeLine(_ summary: WalkSummary) -> String {
        let start = summary.startedAt.formatted(.dateTime.hour().minute())
        guard let endedAt = summary.endedAt else { return start }
        let end = endedAt.formatted(.dateTime.hour().minute())
        return "\(start)-\(end)"
    }
}

#Preview("NEW 2件 + 再訪1件") {
    NavigationStack {
        Form {
            WalkReceiptView.preview(.mixed)
        }
        .navigationTitle("音さんぽ")
    }
}

#Preview("店舗0件") {
    NavigationStack {
        Form {
            WalkReceiptView.preview(.empty)
        }
        .navigationTitle("音さんぽ")
    }
}

#Preview("NEW 0件 + 再訪のみ") {
    NavigationStack {
        Form {
            WalkReceiptView.preview(.revisitedOnly)
        }
        .navigationTitle("音さんぽ")
    }
}

#Preview("店舗情報解決失敗") {
    NavigationStack {
        Form {
            WalkReceiptView.preview(.missingShopInfo)
        }
        .navigationTitle("音さんぽ")
    }
}

private extension WalkReceiptView {
    enum PreviewCase {
        case mixed
        case empty
        case revisitedOnly
        case missingShopInfo
    }

    static func preview(_ previewCase: PreviewCase) -> WalkReceiptView {
        WalkReceiptView(content: PreviewData.content(previewCase),
                        marginM: 40,
                        minSpanM: 150,
                        roadsProvider: { _ in [] })
    }

    enum PreviewData {
        static let walkID = WalkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!)
        static let start = Date(timeIntervalSince1970: 1_820_000_000)
        static let origin = GeoPoint(latitude: 35.6812, longitude: 139.7671)

        static func content(_ previewCase: PreviewCase) -> WalkReceiptContent {
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
}
