import SwiftUI

/// `WalkSummaryView` とシェアカードで共用する経路図。
/// 経路記録や `MapFrame` の作り方は `WalkSummary` 側に寄せたまま、描画だけを再利用する。
struct WalkRouteFigureView: View {
    let summary: WalkSummary
    let frame: MapFrame
    let roads: [RoadSegment]
    var showsHome: Bool = true
    var showsEvents: Bool = true

    var body: some View {
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

            if showsHome, let h = summary.home {
                badge(ctx, at: at(h), text: "家", color: .primary, filled: true)
            }
            if showsEvents {
                for e in summary.events {
                    mark(ctx, event: e, at: at(e.at))
                }
            }
        }
        .aspectRatio(CGFloat(max(frame.widthM, 1) / max(frame.heightM, 1)), contentMode: .fit)
        .padding(8)
    }

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
}
