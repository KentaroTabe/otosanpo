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

            NavigationLink("シェア用画像を作る") {
                WalkShareView(receipt: content,
                              marginM: marginM,
                              minSpanM: minSpanM,
                              roadsProvider: roadsProvider)
            }

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
    static func preview(_ previewCase: WalkSharePreviewData.PreviewCase) -> WalkReceiptView {
        WalkReceiptView(content: WalkSharePreviewData.receipt(previewCase),
                        marginM: 40,
                        minSpanM: 150,
                        roadsProvider: { _ in [] })
    }
}
