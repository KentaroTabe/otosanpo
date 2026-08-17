import Foundation

/// GPS の点を道の上に乗せた結果。
public struct Snap: Equatable {
    /// `WalkMap.ways` への添字
    public let wayIndex: Int
    /// way の何本目の線分か(節点 i と i+1 の間)
    public let segmentIndex: Int
    /// 道の上に落とした位置
    public let point: GeoPoint
    /// 元の位置からの距離 [m]。水平精度より大きければ「どの道かは不確か」
    public let distanceM: Double
    /// その線分の向き [deg]。進行方向と突き合わせて、道に沿っているかを見る
    public let bearingDeg: Double

    public init(wayIndex: Int, segmentIndex: Int, point: GeoPoint,
                distanceM: Double, bearingDeg: Double) {
        self.wayIndex = wayIndex
        self.segmentIndex = segmentIndex
        self.point = point
        self.distanceM = distanceM
        self.bearingDeg = bearingDeg
    }
}

/// `WalkMap` に空間索引を張って、道路スナップを実用的な速さで行う。
///
/// 索引の作り: 緯度経度をおよそ `cellSizeM` 四方のセルに切り、
/// 各線分が触れるセルに「way 番号と線分番号」を登録する。
/// 探索は問い合わせ点の周囲 1 セル分だけを見る。
///
/// なぜ要るか: 5 km 圏の way は数万本になる。毎秒の位置更新で全探索はできない。
public struct WalkGraph {
    public let map: WalkMap
    private let cellSizeM: Double
    private var buckets: [Int64: [(way: Int, seg: Int)]] = [:]

    public init(map: WalkMap, cellSizeM: Double) {
        self.map = map
        self.cellSizeM = max(1, cellSizeM)
        buildIndex()
    }

    /// 登録された線分の総数(索引が張れているかの確認用)
    public var indexedSegmentCount: Int {
        buckets.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - 索引

    /// 緯度経度 → セル座標。経度方向は緯度によって縮むので、中心緯度で補正する
    private func cell(_ p: GeoPoint) -> (x: Int, y: Int) {
        let latPerCell = cellSizeM / Geo.metersPerDegreeLat
        // 極付近で 0 除算しないよう下限を置く(散歩スケールでは効かない)
        let cosLat = max(0.01, cos(map.center.latitude * .pi / 180))
        let lonPerCell = cellSizeM / (Geo.metersPerDegreeLat * cosLat)
        return (Int((p.longitude / lonPerCell).rounded(.down)),
                Int((p.latitude / latPerCell).rounded(.down)))
    }

    private func key(_ x: Int, _ y: Int) -> Int64 {
        // 32 bit ずつ詰める。散歩スケールではセル座標がこの範囲を超えない
        (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
    }

    private mutating func buildIndex() {
        for (wi, way) in map.ways.enumerated() {
            guard way.n.count >= 2 else { continue }
            for si in 0..<(way.n.count - 1) {
                guard let a = map.point(way.n[si]), let b = map.point(way.n[si + 1]) else { continue }
                // 線分の両端が属するセルと、その間を埋めるセルに登録する。
                // 1 セルより長い線分もあるため、端点だけでは取りこぼす
                let ca = cell(a), cb = cell(b)
                for x in min(ca.x, cb.x)...max(ca.x, cb.x) {
                    for y in min(ca.y, cb.y)...max(ca.y, cb.y) {
                        buckets[key(x, y), default: []].append((wi, si))
                    }
                }
            }
        }
    }

    // MARK: - スナップ

    /// `p` に最も近い道の上の点。`maxDistanceM` を超える場合は nil
    /// (地図に無い場所を無理に道へ乗せない)。
    public func snap(_ p: GeoPoint, maxDistanceM: Double) -> Snap? {
        let c = cell(p)
        var best: Snap?
        // 周囲 1 セル分を見る。セル境界のすぐ外にある線分を取りこぼさないため
        for dx in -1...1 {
            for dy in -1...1 {
                for entry in buckets[key(c.x + dx, c.y + dy)] ?? [] {
                    guard let s = evaluate(entry, at: p) else { continue }
                    if best == nil || s.distanceM < best!.distanceM { best = s }
                }
            }
        }
        guard let b = best, b.distanceM <= maxDistanceM else { return nil }
        return b
    }

    private func evaluate(_ entry: (way: Int, seg: Int), at p: GeoPoint) -> Snap? {
        let way = map.ways[entry.way]
        guard let a = map.point(way.n[entry.seg]), let b = map.point(way.n[entry.seg + 1]) else {
            return nil
        }
        let r = Geo.nearestPointOnSegment(p, from: a, to: b)
        return Snap(wayIndex: entry.way, segmentIndex: entry.seg, point: r.point,
                    distanceM: r.distanceM, bearingDeg: Geo.bearingDeg(from: a, to: b))
    }
}
