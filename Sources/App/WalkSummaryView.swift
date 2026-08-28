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
    /// 下地の道を取り出す。地図の走査は重いので、図を開いた時に 1 回だけ呼ぶ
    let roadsProvider: (MapFrame) -> [RoadSegment]

    @State private var roads: [RoadSegment] = []

    private var frame: MapFrame? { summary.frame(marginM: marginM, minSpanM: minSpanM) }

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
                    figure(frame)
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

    // MARK: - 経路図

    private func figure(_ frame: MapFrame) -> some View {
        Canvas { ctx, size in
            guard frame.widthM > 0, frame.heightM > 0 else { return }
            let scale = size.width / frame.widthM
            func at(_ g: GeoPoint) -> CGPoint {
                let m = frame.point(g)
                return CGPoint(x: m.x * scale, y: m.y * scale)
            }

            for r in roads {
                var path = Path()
                path.move(to: at(r.a))
                path.addLine(to: at(r.b))
                ctx.stroke(path, with: .color(.secondary.opacity(0.35)),
                           lineWidth: r.cls == .arterial ? 3 : 1.5)
            }

            if summary.track.count >= 2 {
                var path = Path()
                path.addLines(summary.track.map(at))
                ctx.stroke(path, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            if let h = summary.home {
                badge(ctx, at: at(h), text: "家", color: .primary, filled: true)
            }
            for e in summary.events {
                mark(ctx, event: e, at: at(e.at))
            }
        }
        .aspectRatio(CGFloat(max(frame.widthM, 1) / max(frame.heightM, 1)), contentMode: .fit)
        .padding(8)
    }

    /// 1 つの印。誘導は番号と、指した向きの矢印を添える
    private func mark(_ ctx: GraphicsContext, event e: WalkSummary.Event, at p: CGPoint) {
        if let bearing = e.bearingDeg {
            let t = bearing * .pi / 180
            var arrow = Path()
            arrow.move(to: p)
            arrow.addLine(to: CGPoint(x: p.x + sin(t) * 20, y: p.y - cos(t) * 20))
            ctx.stroke(arrow, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        switch e.mark {
        case .guidance:
            // 塗り = 曲がり終えた(従った)/ 白抜き = それ以外。色に頼らず形で分ける
            badge(ctx, at: p, text: e.number.map(String.init) ?? "?", color: .orange,
                  filled: e.ending == TurnGuidance.Ending.turned.rawValue)
        case .returnStart:
            badge(ctx, at: p, text: "帰", color: .green, filled: true)
        case .extended:
            badge(ctx, at: p, text: "延", color: .purple, filled: true)
        case .arrival:
            badge(ctx, at: p, text: "着", color: .red, filled: true)
        }
    }

    private func badge(_ ctx: GraphicsContext, at p: CGPoint, text: String,
                       color: Color, filled: Bool) {
        let r: CGFloat = 9
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(filled ? color : Color(white: 1, opacity: 0.9)))
        ctx.stroke(circle, with: .color(color), lineWidth: 2)
        ctx.draw(Text(text).font(.system(size: 10, weight: .bold))
            .foregroundStyle(filled ? Color.white : color), at: p)
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
