import Foundation

/// **「面白い」を広域で決める**ための地帯の地図。
///
/// なぜ要るか(2026-08-19 の指摘):
/// 交差点ごとの評価(`BranchSuggester`)は局所的で、曲がった直後の評価が高くても
/// その先がつまらない場所に出ることがある。「どちらへ曲がるか」の前に
/// **「どのあたりへ向かうか」**を決めておけば、局所の選択に一貫した向きが与えられる。
///
/// 地帯の良さは 2 つの掛け算で決める。
/// - **新鮮さ**: そこをどれだけ歩いていないか(VisitGrid から)
/// - **道の多さ**: そこにどれだけ歩ける道があるか。**道が無い地帯に価値は無い**。
///   未踏なだけの田畑や川の上を「最も新鮮」と選んでしまうのを防ぐ
public struct ZoneMap {
    public struct Zone: Equatable {
        public let center: GeoPoint
        /// その地帯にある道の総延長 [m]。地帯の「歩きでのある度合い」
        public let roadLengthM: Double

        public init(center: GeoPoint, roadLengthM: Double) {
            self.center = center
            self.roadLengthM = roadLengthM
        }
    }

    /// 選ばれた行き先と、その理由(ログに残して後から判断できるようにする)
    public struct Target: Equatable {
        public let zone: Zone
        public let novelty: Double
        public let score: Double
        public let distanceM: Double
    }

    public struct Params: Equatable {
        /// 地帯の一辺 [m]
        public let zoneSizeM: Double
        /// 行き先として認める道の総延長の下限 [m]
        public let minRoadM: Double
        /// 地帯の馴染み度を測るときの 1 辺あたりの標本数(3 なら 3×3 = 9 点)
        public let sampleGrid: Int
        /// 行き先として認める現在地からの最短距離 [m]。すぐ隣は行き先にならない
        public let minDistanceM: Double
        /// 上の距離を、**行ける範囲に対する比でも抑える**。
        /// 固定値だけだと短い散歩で「行ける範囲より遠い場所しか行き先にできない」状態になり、
        /// 仕組みが丸ごと止まる(2026-08-19 実測: 10 分の散歩で行き先は 9 秒しか保たなかった)
        public let minDistanceRatio: Double
        public let excludedFamiliarity: Double

        public init(zoneSizeM: Double, minRoadM: Double, sampleGrid: Int,
                    minDistanceM: Double, minDistanceRatio: Double,
                    excludedFamiliarity: Double) {
            self.zoneSizeM = zoneSizeM
            self.minRoadM = minRoadM
            self.sampleGrid = sampleGrid
            self.minDistanceM = minDistanceM
            self.minDistanceRatio = minDistanceRatio
            self.excludedFamiliarity = excludedFamiliarity
        }

        /// その予算で実際に使う最短距離 [m]
        public func effectiveMinDistanceM(allowedRadiusM: Double) -> Double {
            min(minDistanceM, allowedRadiusM * minDistanceRatio)
        }
    }

    public let zones: [Zone]
    private let zoneSizeM: Double

    /// 地図から地帯を作る。道の総延長を地帯ごとに積むだけなので、
    /// 経路探索と違って安い(セッション開始時に 1 回)。
    public init(map: WalkMap, zoneSizeM: Double) {
        self.zoneSizeM = zoneSizeM
        var roadLength: [Int64: Double] = [:]
        let latPerZone = zoneSizeM / Geo.metersPerDegreeLat
        let cosLat = max(0.01, cos(map.center.latitude * .pi / 180))
        let lonPerZone = zoneSizeM / (Geo.metersPerDegreeLat * cosLat)

        func key(_ p: GeoPoint) -> Int64 {
            let x = Int((p.longitude / lonPerZone).rounded(.down))
            let y = Int((p.latitude / latPerZone).rounded(.down))
            return (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
        }

        var seen: [Int64: GeoPoint] = [:]
        for way in map.ways where way.n.count >= 2 {
            for i in 0..<(way.n.count - 1) {
                guard let a = map.point(way.n[i]), let b = map.point(way.n[i + 1]) else { continue }
                // 線分は中点の属する地帯に丸ごと入れる。地帯は 300 m 角で線分は数十 m なので、
                // 境界をまたぐ線分を分割してまで精密にする意味は無い
                let mid = GeoPoint(latitude: (a.latitude + b.latitude) / 2,
                                   longitude: (a.longitude + b.longitude) / 2)
                let k = key(mid)
                roadLength[k, default: 0] += Geo.distanceM(a, b)
                if seen[k] == nil {
                    // 地帯の代表点は、その地帯で最初に見つけた道の上の点。
                    // 幾何的な中心だと道の無い場所を指しうるので、道の上に置く
                    seen[k] = mid
                }
            }
        }
        zones = roadLength.compactMap { k, length in
            seen[k].map { Zone(center: $0, roadLengthM: length) }
        }
    }

    /// いま向かうべき地帯を選ぶ。
    ///
    /// - Parameters:
    ///   - position: 現在地
    ///   - home: 自宅(予算の中心)
    ///   - allowedRadiusM: 自宅からこの距離までなら帰ってこられる(ReturnBudget)。
    ///     **選ぶときは予算いっぱいではなく余裕を持たせた値を渡す**。
    ///     許容半径は時間とともに縮むので、縁ぎりぎりの地帯を選ぶと数秒で無効になる
    public func chooseTarget(from position: GeoPoint, home: GeoPoint,
                             allowedRadiusM: Double, grid: VisitGrid, now: Date,
                             p: Params) -> Target? {
        var best: Target?
        let minDistanceM = p.effectiveMinDistanceM(allowedRadiusM: allowedRadiusM)
        for zone in zones {
            // 帰ってこられない地帯は行き先にしない(「約束を守る」docs/01)
            guard Geo.distanceM(zone.center, home) <= allowedRadiusM else { continue }
            let d = Geo.distanceM(position, zone.center)
            guard d >= minDistanceM else { continue }
            guard zone.roadLengthM >= p.minRoadM else { continue }

            let novelty = 1.0 / (1.0 + familiarity(of: zone, grid: grid, now: now, p: p))
            // 道が多いほど歩きでがある。下限で正規化し、際限なく効かないよう 1 で頭打ちにする
            let density = min(1.0, zone.roadLengthM / (p.minRoadM * 3))
            let score = novelty * density
            guard let b = best else {
                best = Target(zone: zone, novelty: novelty, score: score, distanceM: d)
                continue
            }
            // **同点なら近いほうを選ぶ。** 未踏の地帯は同点(新鮮さ 1.00)で並びやすく、
            // 比較を score だけにすると選択が辞書の並び順まかせになって毎回変わる。
            // 近いほうを選べば、着いた後も予算が残り「行って帰るだけ」にならない
            let better = score > b.score + 1e-9
                || (abs(score - b.score) <= 1e-9 && d < b.distanceM)
            if better {
                best = Target(zone: zone, novelty: novelty, score: score, distanceM: d)
            }
        }
        return best
    }

    /// 地帯の馴染み度。地帯は通過履歴のセルより大きいので、格子状に標本を取って平均する
    private func familiarity(of zone: Zone, grid: VisitGrid, now: Date, p: Params) -> Double {
        let n = max(1, p.sampleGrid)
        guard n > 1 else {
            return grid.familiarity(at: zone.center, now: now,
                                    excludedFamiliarity: p.excludedFamiliarity)
        }
        var total = 0.0
        let step = zoneSizeM / Double(n)
        let half = zoneSizeM / 2
        for i in 0..<n {
            for j in 0..<n {
                let dx = -half + step * (Double(i) + 0.5)
                let dy = -half + step * (Double(j) + 0.5)
                let q = Geo.destination(
                    from: Geo.destination(from: zone.center, bearingDeg: 90, distanceM: dx),
                    bearingDeg: 0, distanceM: dy)
                total += grid.familiarity(at: q, now: now,
                                          excludedFamiliarity: p.excludedFamiliarity)
            }
        }
        return total / Double(n * n)
    }
}
