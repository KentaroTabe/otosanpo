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

/// 交差点で選べる 1 本の道。
public struct Branch: Equatable {
    /// その道へ踏み出す向き [deg]
    public let bearingDeg: Double
    public let cls: WayClass
    /// その道に入るために横断する負担(way の cross をそのまま持つ)
    public let crossCost: Int
    public let wayIndex: Int

    public init(bearingDeg: Double, cls: WayClass, crossCost: Int, wayIndex: Int) {
        self.bearingDeg = bearingDeg
        self.cls = cls
        self.crossCost = crossCost
        self.wayIndex = wayIndex
    }
}

/// 進行方向の先にある交差点。
public struct UpcomingIntersection: Equatable {
    public let nodeIndex: Int
    public let point: GeoPoint
    public let distanceM: Double
    /// そこから選べる道(来た道を含む。除外は呼び出し側の判断)
    public let branches: [Branch]

    public init(nodeIndex: Int, point: GeoPoint, distanceM: Double, branches: [Branch]) {
        self.nodeIndex = nodeIndex
        self.point = point
        self.distanceM = distanceM
        self.branches = branches
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
    /// 節点番号 → その節点に触れる (way 番号, 節点の位置) の一覧。交差点の判定と分岐の列挙に使う
    private var incident: [Int: [(way: Int, at: Int)]] = [:]

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
            for (at, node) in way.n.enumerated() {
                incident[node, default: []].append((wi, at))
            }
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

    // MARK: - 交差点と分岐

    /// その節点から選べる道の一覧。
    /// 節点が way の途中にあれば前後 2 方向、端にあれば 1 方向を数える。
    /// 同じ向きが重複しないよう、近い向きは 1 本に畳む。
    public func branches(at node: Int, mergeWithinDeg: Double = 20) -> [Branch] {
        guard let origin = map.point(node) else { return [] }
        var out: [Branch] = []
        for e in incident[node] ?? [] {
            let way = map.ways[e.way]
            // 節点の前と後、それぞれ隣の節点へ向かう向きが 1 本の分岐になる
            for neighbor in [e.at - 1, e.at + 1] {
                guard way.n.indices.contains(neighbor), let q = map.point(way.n[neighbor]),
                      q != origin else { continue }
                let bearing = Geo.bearingDeg(from: origin, to: q)
                let duplicate = out.contains {
                    abs(Geo.angularDiffDeg($0.bearingDeg, bearing)) < mergeWithinDeg
                }
                guard !duplicate else { continue }
                out.append(Branch(bearingDeg: bearing, cls: way.cls,
                                  crossCost: way.cross, wayIndex: e.way))
            }
        }
        return out.sorted { $0.bearingDeg < $1.bearingDeg }
    }

    /// 交差点かどうか。**選べる道が 3 方向以上**ある節点を交差点とみなす
    /// (2 方向は道が続いているだけ、1 方向は行き止まり)。
    public func isIntersection(_ node: Int) -> Bool {
        branches(at: node).count >= 3
    }

    /// 進行方向の前方 `withinM` 以内にある、最も近い交差点。
    /// 「曲がれる地点」でだけ提案するために使う(タイマー駆動をやめる)。
    /// 前方の判定は `forwardHalfAngleDeg` の扇形で行う。
    public func upcomingIntersection(from p: GeoPoint, bearingDeg: Double, withinM: Double,
                                     forwardHalfAngleDeg: Double = 60) -> UpcomingIntersection? {
        var best: UpcomingIntersection?
        // 前方 withinM を覆うセル範囲だけ見る
        let c = cell(p)
        let reach = max(1, Int((withinM / cellSizeM).rounded(.up)))
        var seen = Set<Int>()
        for dx in -reach...reach {
            for dy in -reach...reach {
                for entry in buckets[key(c.x + dx, c.y + dy)] ?? [] {
                    let way = map.ways[entry.way]
                    for node in [way.n[entry.seg], way.n[entry.seg + 1]] {
                        guard seen.insert(node).inserted else { continue }
                        guard let q = map.point(node) else { continue }
                        let d = Geo.distanceM(p, q)
                        guard d <= withinM else { continue }
                        // 真横や後ろの交差点は「これから曲がる場所」ではない
                        guard abs(Geo.angularDiffDeg(Geo.bearingDeg(from: p, to: q), bearingDeg))
                                <= forwardHalfAngleDeg else { continue }
                        let br = branches(at: node)
                        guard br.count >= 3 else { continue }
                        if best == nil || d < best!.distanceM {
                            best = UpcomingIntersection(nodeIndex: node, point: q,
                                                        distanceM: d, branches: br)
                        }
                    }
                }
            }
        }
        return best
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
