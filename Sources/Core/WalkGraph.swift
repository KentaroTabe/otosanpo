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

/// 経路図に描く道の 1 線分。
public struct RoadSegment: Equatable {
    public let a: GeoPoint
    public let b: GeoPoint
    public let cls: WayClass

    public init(a: GeoPoint, b: GeoPoint, cls: WayClass) {
        self.a = a
        self.b = b
        self.cls = cls
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
public struct WalkGraph: @unchecked Sendable {
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

    // MARK: - 経路探索のための入り口

    /// `p` に最も近い**節点**。スナップした線分の端点のうち近い方を返す。
    /// 経路探索の出発点・目的地を決めるために使う。
    public func nearestNode(to p: GeoPoint, maxDistanceM: Double) -> Int? {
        guard let s = snap(p, maxDistanceM: maxDistanceM) else { return nil }
        let way = map.ways[s.wayIndex]
        let a = way.n[s.segmentIndex], b = way.n[s.segmentIndex + 1]
        guard let pa = map.point(a), let pb = map.point(b) else { return nil }
        return Geo.distanceM(p, pa) <= Geo.distanceM(p, pb) ? a : b
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

    /// いま乗っている道を前方へ辿って、最初に出会う交差点。
    ///
    /// **空間的に近いだけの節点は拾わない。** 以前は周囲を走査して
    /// 「前方 35 m・±60° にある交差点」を選んでいたが、それだと
    /// **隣の通りの交差点**が選ばれる。街区の幅は 30〜50 m しかないので、
    /// 前方の扇形には日常的に別の通りが入る。そこを指せば街区を突っ切る向き —
    /// 利用者の報告「私有地と思われる場所に向かおうとする」がこれ
    /// (2026-08-19 実測で 3 回)。
    ///
    /// 道を辿って探せば、返る交差点は**必ずいまの道の延長上にある**。
    public func upcomingIntersection(from p: GeoPoint, bearingDeg: Double, withinM: Double,
                                     snapMaxDistanceM: Double = 25) -> UpcomingIntersection? {
        guard let s = snap(p, maxDistanceM: snapMaxDistanceM) else { return nil }
        let way = map.ways[s.wayIndex]
        let a = way.n[s.segmentIndex], b = way.n[s.segmentIndex + 1]
        guard let pa = map.point(a), let pb = map.point(b) else { return nil }
        // 進行方向に合う側へ歩き出す
        let forward = abs(Geo.angularDiffDeg(Geo.bearingDeg(from: pa, to: pb), bearingDeg)) <= 90
        var previous = forward ? a : b
        var current = forward ? b : a
        guard var here = map.point(current) else { return nil }
        var travelled = Geo.distanceM(s.point, here)
        // 同じ節点を二度踏まない(環状の道で回り続けないため)
        var visited: Set<Int> = [previous]

        while travelled <= withinM {
            guard visited.insert(current).inserted else { return nil }
            let br = branches(at: current)
            if br.count >= 3 {
                return UpcomingIntersection(nodeIndex: current, point: here,
                                            distanceM: travelled, branches: br)
            }
            // 道が続いているだけの節点。来た方でないほうへ進む
            guard let next = continuation(at: current, from: previous, heading: here) else {
                return nil
            }
            guard let np = map.point(next) else { return nil }
            travelled += Geo.distanceM(here, np)
            previous = current
            current = next
            here = np
        }
        return nil
    }

    /// 節点 `node` を、`from` から来て通り抜ける先。行き止まりなら nil。
    /// 候補が複数あるときは**最も真っ直ぐ**なものを選ぶ
    /// (向きで畳まれて交差点扱いされなかった節点でも、道なりに進めるようにする)。
    private func continuation(at node: Int, from previous: Int, heading: GeoPoint) -> Int? {
        guard let pp = map.point(previous) else { return nil }
        let incoming = Geo.bearingDeg(from: pp, to: heading)
        var best: (node: Int, turn: Double)?
        for n in adjacentNodes(of: node) where n != previous {
            guard let q = map.point(n) else { continue }
            let turn = abs(Geo.angularDiffDeg(Geo.bearingDeg(from: heading, to: q), incoming))
            if best == nil || turn < best!.turn { best = (n, turn) }
        }
        return best?.node
    }

    /// その分岐へ入ってから `withinM` 進むまでの、**道の上の点列**(`stepM` 間隔)。
    ///
    /// 何のためか: 分岐の新鮮さを「その方向の扇形」ではなく**その道そのもの**で測るため。
    /// 扇形(`sectorFamiliarity`)は空間を切り取るだけなので、交差点の東の扇形には
    /// 東へ行く道も、そこから行けない別の道も、道でない場所も入る。
    /// 実際に歩く道を辿って測れば、「この道が新しいか」を直接答えられる。
    ///
    /// 分岐の先で交差点に出たら、最も真っ直ぐな道へ進む(「この道を進んだらどうなるか」の模型)。
    public func samplesAlong(branch: Branch, from node: Int,
                             withinM: Double, stepM: Double) -> [GeoPoint] {
        guard stepM > 0, withinM > 0, let origin = map.point(node) else { return [] }
        // 分岐の向きに最も近い隣接節点へ踏み出す
        var first: (node: Int, diff: Double)?
        for n in adjacentNodes(of: node) {
            guard let q = map.point(n) else { continue }
            let d = abs(Geo.angularDiffDeg(Geo.bearingDeg(from: origin, to: q), branch.bearingDeg))
            if first == nil || d < first!.diff { first = (n, d) }
        }
        guard var current = first?.node else { return [] }

        // 道なりの折れ線を作る
        var polyline = [origin]
        var previous = node
        var visited: Set<Int> = [node]
        var length = 0.0
        while visited.insert(current).inserted, let here = map.point(current) {
            length += Geo.distanceM(polyline[polyline.count - 1], here)
            polyline.append(here)
            if length >= withinM { break }
            guard let next = continuation(at: current, from: previous, heading: here) else { break }
            previous = current
            current = next
        }
        guard polyline.count >= 2 else { return [] }

        // 等間隔に標本を取る。緯度経度の線形補間で足りる距離(数十 m)
        var out: [GeoPoint] = []
        var travelled = 0.0
        var target = stepM
        for i in 1..<polyline.count {
            let a = polyline[i - 1], b = polyline[i]
            let seg = Geo.distanceM(a, b)
            while target <= travelled + seg, target <= withinM {
                let t = seg > 0 ? (target - travelled) / seg : 0
                out.append(GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                    longitude: a.longitude + (b.longitude - a.longitude) * t))
                target += stepM
            }
            travelled += seg
            if travelled >= withinM { break }
        }
        return out
    }

    /// その節点に隣接する節点。`branches` と違い**向きで畳まない**
    public func adjacentNodes(of node: Int) -> [Int] {
        var out: [Int] = []
        for e in incident[node] ?? [] {
            let way = map.ways[e.way]
            for at in [e.at - 1, e.at + 1] {
                guard way.n.indices.contains(at) else { continue }
                let n = way.n[at]
                if n != node, !out.contains(n) { out.append(n) }
            }
        }
        return out
    }

    /// 枠に入る道の線分。**経路図の下地**に使う(docs/06「散歩の記録」)。
    /// 索引は 1 点の近傍を引くためのものなので、ここは way を素直に走査する。
    /// 図を開いた時に 1 回だけ呼ぶ前提(毎秒の判定には使わない)
    public func roadSegments(in frame: MapFrame) -> [RoadSegment] {
        var out: [RoadSegment] = []
        for way in map.ways {
            guard way.n.count >= 2 else { continue }
            for i in 0..<(way.n.count - 1) {
                guard let a = map.point(way.n[i]), let b = map.point(way.n[i + 1]),
                      frame.mayContain(a, b) else { continue }
                out.append(RoadSegment(a: a, b: b, cls: way.cls))
            }
        }
        return out
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
