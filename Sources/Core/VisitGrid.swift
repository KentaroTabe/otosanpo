import Foundation

/// 約 cellSizeM 四方のセルごとに「通過回数(指数減衰つき)」と「日常ルート除外フラグ」を持つ。
///
/// **減衰の時計は日数ではなく「歩いた総距離」**(2026-08-20 決定)。
/// 歩かなかった期間に新鮮さが戻るのはおかしい。1 ヶ月ぶりに散歩へ出たとき、
/// その 1 ヶ月で何も歩いていないのなら、その道の馴染みは薄れていない。
/// 逆に 20 km 歩いてなお通らなかった道は、それだけ「選ばれなかった道」であり、
/// 新鮮さが戻ってよい。**新鮮さが戻る速さは、時間ではなく歩いた量で決まる。**
///
/// - 通過するたびに +1、半減期 `halfLifeM` で減衰
/// - 通勤路学習モード中に通ったセルは excluded となり、常に高い familiarity として扱う
/// - すべて端末内で完結する前提のデータ構造(送信しない)
public struct VisitGrid: Codable, Equatable {
    public struct CellKey: Hashable, Codable, Equatable {
        public var ix: Int
        public var iy: Int
    }

    public struct CellRecord: Codable, Equatable {
        public var count: Double
        /// この記録を最後に更新した時点の積算歩行距離 [m]
        public var lastOdometerM: Double
        public var excluded: Bool

        public init(count: Double, lastOdometerM: Double, excluded: Bool) {
            self.count = count
            self.lastOdometerM = lastOdometerM
            self.excluded = excluded
        }

        enum CodingKeys: String, CodingKey { case count, lastOdometerM, excluded }

        /// 旧形式(`lastVisit: Date` で日数減衰していた頃)も読めるようにする。
        /// 距離の時計へ載せ替える術は無いので **0 とみなす**(= 移行直後は減衰なし。
        /// 以後、歩いた分だけ減っていく)
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = try c.decode(Double.self, forKey: .count)
            excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
            lastOdometerM = try c.decodeIfPresent(Double.self, forKey: .lastOdometerM) ?? 0
        }
    }

    public private(set) var cells: [CellKey: CellRecord] = [:]
    /// 積算歩行距離 [m]。**これが減衰の時計**
    public private(set) var odometerM: Double = 0
    public var cellSizeM: Double
    /// 通過の重みが半分になるまでに歩く距離 [m]
    public var halfLifeM: Double

    public init(cellSizeM: Double, halfLifeM: Double) {
        self.cellSizeM = cellSizeM
        self.halfLifeM = halfLifeM
    }

    enum CodingKeys: String, CodingKey { case cells, odometerM, cellSizeM, halfLifeM }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cells = try c.decodeIfPresent([CellKey: CellRecord].self, forKey: .cells) ?? [:]
        odometerM = try c.decodeIfPresent(Double.self, forKey: .odometerM) ?? 0
        // 設定値は呼び出し側(GridStore)が読み込み後に上書きする
        cellSizeM = try c.decodeIfPresent(Double.self, forKey: .cellSizeM) ?? 50
        halfLifeM = try c.decodeIfPresent(Double.self, forKey: .halfLifeM) ?? 20_000
    }

    public func key(for p: GeoPoint) -> CellKey {
        let y = p.latitude * Geo.metersPerDegreeLat
        let x = p.longitude * Geo.metersPerDegreeLat * cos(p.latitude * .pi / 180)
        return CellKey(ix: Int(floor(x / cellSizeM)), iy: Int(floor(y / cellSizeM)))
    }

    public func center(of k: CellKey) -> GeoPoint {
        let y = (Double(k.iy) + 0.5) * cellSizeM
        let lat = y / Geo.metersPerDegreeLat
        let x = (Double(k.ix) + 0.5) * cellSizeM
        let lon = x / (Geo.metersPerDegreeLat * cos(lat * .pi / 180))
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// 減衰の時計を進める。**歩いた分だけ**呼ぶ(位置更新の差分を積んだ実距離)
    public mutating func advance(byM distanceM: Double) {
        guard distanceM > 0 else { return }
        odometerM += distanceM
    }

    public mutating func recordVisit(at p: GeoPoint) {
        let k = key(for: p)
        var r = cells[k] ?? CellRecord(count: 0, lastOdometerM: odometerM, excluded: false)
        r.count = decayed(r) + 1
        r.lastOdometerM = odometerM
        cells[k] = r
    }

    /// 通勤路学習モード:このセルを日常ルートとして除外する
    public mutating func markExcluded(at p: GeoPoint) {
        let k = key(for: p)
        var r = cells[k] ?? CellRecord(count: 0, lastOdometerM: odometerM, excluded: false)
        r.excluded = true
        r.lastOdometerM = odometerM
        cells[k] = r
    }

    func decayed(_ r: CellRecord) -> Double {
        let walked = odometerM - r.lastOdometerM
        guard walked > 0, halfLifeM > 0 else { return r.count }
        return r.count * pow(0.5, walked / halfLifeM)
    }

    /// その地点の「馴染み度」。未踏 = 0、除外セルは excludedFamiliarity 固定。
    public func familiarity(at p: GeoPoint, excludedFamiliarity: Double) -> Double {
        guard let r = cells[key(for: p)] else { return 0 }
        return r.excluded ? excludedFamiliarity : decayed(r)
    }

    /// 与えた点列の平均馴染み度。**通っていない点は 0 として数える**。
    ///
    /// 道に沿って標本を取り、その平均を「その道の馴染み度」とする(`WalkGraph.samplesAlong`)。
    /// 扇形版と違い記録の無い点も分母に入れるので、半分だけ歩いた道は半分の馴染み度になる。
    /// 「その道をどれだけ歩いたか」としてはこちらが正しい。
    public func averageFamiliarity(at points: [GeoPoint], excludedFamiliarity: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        var total = 0.0
        for p in points {
            total += familiarity(at: p, excludedFamiliarity: excludedFamiliarity)
        }
        return total / Double(points.count)
    }

    /// origin から bearing 方向の扇形(幅 sectorWidthDeg、半径 sectorRadiusM)内にある
    /// 記録済みセルの平均馴染み度。記録が 1 つもなければ 0(=完全に未踏)。
    /// 経路データが無いときの代用(通常は `averageFamiliarity` を道なりに使う)。
    public func sectorFamiliarity(from origin: GeoPoint, bearingDeg: Double,
                                  params: AppParameters.Route) -> Double {
        var total = 0.0
        var n = 0
        for (k, r) in cells {
            let c = center(of: k)
            let d = Geo.distanceM(origin, c)
            guard d > 0, d <= params.sectorRadiusM else { continue }
            let b = Geo.bearingDeg(from: origin, to: c)
            guard abs(Geo.angularDiffDeg(b, bearingDeg)) <= params.sectorWidthDeg / 2 else { continue }
            total += r.excluded ? params.excludedFamiliarity : decayed(r)
            n += 1
        }
        return n == 0 ? 0 : total / Double(n)
    }
}
