import SwiftUI

struct WalkShareCardView: View {
    static let logicalSize = CGSize(width: 360, height: 640)
    static let renderScale: CGFloat = 3

    let content: WalkShareContent
    let roads: [RoadSegment]
    var marginM: Double = 40
    var minSpanM: Double = 150

    private var frame: MapFrame? {
        content.walkSummary.frame(marginM: marginM, minSpanM: minSpanM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(content.date.formatted(.dateTime.year().month().day()))
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text("今日の")
                    .font(.system(size: 28, weight: .medium))
                Text("音さんぽ")
                    .font(.system(size: 38, weight: .bold))
            }

            HStack(spacing: 28) {
                stat(title: "TIME", value: "\(content.durationMinutes)", unit: "min")
                stat(title: "DISTANCE",
                     value: String(format: "%.1f", content.distanceKilometers),
                     unit: "km")
            }

            routePanel

            discoveryColumns

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: Self.logicalSize.width, height: Self.logicalSize.height, alignment: .topLeading)
        .background(Color(red: 0.98, green: 0.97, blue: 0.94))
        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.07))
    }

    private func stat(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var routePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
            if let frame {
                // 自宅・印と同じく、**音楽スポットの ♪ も出さない**(場所が分かってしまう)
                WalkRouteFigureView(summary: content.walkSummary, frame: frame, roads: roads,
                                    showsHome: false, showsEvents: false, showsMusicSpot: false)
                    .padding(8)
            } else {
                Text("経路図")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 190)
    }

    private var discoveryColumns: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("街の発見")
                    .font(.system(size: 14, weight: .semibold))
                Text("NEW")
                    .font(.system(size: 16, weight: .bold))
                Text("\(content.newShopCount)")
                    .font(.system(size: 34, weight: .bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !content.selectedShops.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日見つけた店")
                        .font(.system(size: 14, weight: .semibold))
                    ForEach(content.selectedShops) { shop in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(shop.name)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(shop.passageLabel)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(shop.isNew ? Color.accentColor : Color.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview("WalkShareCardView: 店舗未選択") {
    WalkShareCardView(content: WalkSharePreviewData.shareContent(selectedShopIDs: []),
                      roads: [])
}

#Preview("WalkShareCardView: 店舗2件選択") {
    WalkShareCardView(content: WalkSharePreviewData.shareContent(selectedShopIDs: ["coffee", "bakery"]),
                      roads: [])
}
