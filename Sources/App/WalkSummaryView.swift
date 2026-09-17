import SwiftUI

/// 散歩の記録の画面。**開発中の振り返り用**。
///
/// 音だけの体験なので、歩いている最中に「いま何が起きたか」を書き留められない。
/// 帰ってから「3 番目の案内が道の無い方を指した」と言えるように、
/// 経路図に**イベント番号**を振る(2026-08-21 の要望)。
/// 一般の利用者にどこまで見せるかは未決(docs/06 判断待ち)。
struct WalkSummaryView: View {
    let summary: WalkSummary
    let marginM: Double
    let minSpanM: Double
    let discoveredShops: [WalkReceiptShopItem]
    let showsDiscoveredShops: Bool
    /// 下地の道を取り出す。地図の走査は重いので、図を開いた時に 1 回だけ呼ぶ
    let roadsProvider: (MapFrame) -> [RoadSegment]

    @State private var roads: [RoadSegment] = []

    private var frame: MapFrame? { summary.frame(marginM: marginM, minSpanM: minSpanM) }

    init(summary: WalkSummary,
         marginM: Double,
         minSpanM: Double,
         discoveredShops: [WalkReceiptShopItem] = [],
         showsDiscoveredShops: Bool = false,
         roadsProvider: @escaping (MapFrame) -> [RoadSegment]) {
        self.summary = summary
        self.marginM = marginM
        self.minSpanM = minSpanM
        self.discoveredShops = discoveredShops
        self.showsDiscoveredShops = showsDiscoveredShops
        self.roadsProvider = roadsProvider
    }

    var body: some View {
        List {
            Section("この散歩") {
                LabeledContent("距離", value: String(format: "%.0f m", summary.pathLengthM))
                LabeledContent("時間", value: String(format: "%.0f 分", summary.durationSec / 60))
                LabeledContent("イベント", value: "\(summary.guidanceEvents.count) 件")
                ForEach(summary.endingCounts(), id: \.ending) { row in
                    LabeledContent(row.ending, value: "\(row.count) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("経路図") {
                if let frame {
                    WalkRouteFigureView(summary: summary, frame: frame, roads: roads,
                                        showsHome: true, showsEvents: true)
                        .listRowInsets(EdgeInsets())
                    Text(String(format: "北が上・図の幅 約 %.0f m・道は端末内の経路データ",
                                frame.widthM))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("経路が記録されていません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsDiscoveredShops {
                if !discoveredShops.isEmpty {
                    Section("見つけた店") {
                        ForEach(discoveredShops) { shop in
                            shopRow(shop)
                        }
                    }
                } else {
                    Section("見つけた店") {
                        Text("今日は新しい店との出会いはありませんでした")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("イベント") {
                if summary.events.isEmpty {
                    Text("イベントはありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(summary.events.enumerated()), id: \.offset) { _, e in
                    row(e)
                }
            }
        }
        .navigationTitle("散歩の記録")
        .task {
            guard let frame, roads.isEmpty else { return }
            roads = roadsProvider(frame)
        }
    }

    // MARK: - イベントの一覧

    private func row(_ e: WalkSummary.Event) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title(e)).font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f 分", e.elapsedSec / 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(detail(e)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func shopRow(_ shop: WalkReceiptShopItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
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

    private func title(_ e: WalkSummary.Event) -> String {
        switch e.mark {
        case .guidance: "#\(e.number ?? 0) 誘導"
        case .returnStart: "帰路開始"
        case .extended: "延長"
        case .arrival: "到着"
        }
    }

    private func detail(_ e: WalkSummary.Event) -> String {
        var parts = [e.onReturn ? "帰路" : "散策"]
        if let b = e.bearingDeg {
            parts.append(String(format: "指した向き %.0f°(北=0°)", b))
        }
        if e.mark == .guidance {
            parts.append(e.ending ?? "終わり方の記録なし")
        }
        return parts.joined(separator: " / ")
    }
}
