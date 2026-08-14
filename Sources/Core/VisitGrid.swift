import Foundation

/// 約 cellSizeM 四方のセルごとに「通過回数(指数減衰つき)」と「日常ルート除外フラグ」を持つ。
/// - 通過するたびに +1、半減期 halfLifeDays で減衰 → 半年通らなければ再び新鮮な候補に戻る
/// - 通勤路学習モード中に通ったセルは excluded となり、常に高い familiarity として扱う
/// - すべて端末内で完結する前提のデータ構造(送信しない)
public struct VisitGrid: Codable, Equatable {
    public struct CellKey: Hashable, Codable, Equatable {
        public var ix: Int
        public var iy: Int
    }

    public struct CellRecord: Codable, Equatable {
        public var count: Double
        public var lastVisit: Date
        public var excluded: Bool
    }

    public private(set) var cells: [CellKey: CellRecord] = [:]
    public var cellSizeM: Double
    public var halfLifeDays: Double

    public init(cellSizeM: Double, halfLifeDays: Double) {
        self.cellSizeM = cellSizeM
        self.halfLifeDays = halfLifeDays
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

    public mutating func recordVisit(at p: GeoPoint, date: Date) {
        let k = key(for: p)
        var r = cells[k] ?? CellRecord(count: 0, lastVisit: date, excluded: false)
        r.count = decayed(r, at: date) + 1
        r.lastVisit = date
        cells[k] = r
    }

    /// 通勤路学習モード:このセルを日常ルートとして除外する
    public mutating func markExcluded(at p: GeoPoint, date: Date) {
        let k = key(for: p)
        var r = cells[k] ?? CellRecord(count: 0, lastVisit: date, excluded: false)
        r.excluded = true
        r.lastVisit = date
        cells[k] = r
    }

    func decayed(_ r: CellRecord, at now: Date) -> Double {
        let days = now.timeIntervalSince(r.lastVisit) / 86_400
        guard days > 0 else { return r.count }
        return r.count * pow(0.5, days / halfLifeDays)
    }

    /// その地点の「馴染み度」。未踏 = 0、除外セルは excludedFamiliarity 固定。
    public func familiarity(at p: GeoPoint, now: Date, excludedFamiliarity: Double) -> Double {
        guard let r = cells[key(for: p)] else { return 0 }
        return r.excluded ? excludedFamiliarity : decayed(r, at: now)
    }

    /// origin から bearing 方向の扇形(幅 sectorWidthDeg、半径 sectorRadiusM)内にある
    /// 記録済みセルの平均馴染み度。記録が 1 つもなければ 0(=完全に未踏)。
    public func sectorFamiliarity(from origin: GeoPoint, bearingDeg: Double,
                                  params: AppParameters.Route, now: Date) -> Double {
        var total = 0.0
        var n = 0
        for (k, r) in cells {
            let c = center(of: k)
            let d = Geo.distanceM(origin, c)
            guard d > 0, d <= params.sectorRadiusM else { continue }
            let b = Geo.bearingDeg(from: origin, to: c)
            guard abs(Geo.angularDiffDeg(b, bearingDeg)) <= params.sectorWidthDeg / 2 else { continue }
            total += r.excluded ? params.excludedFamiliarity : decayed(r, at: now)
            n += 1
        }
        return n == 0 ? 0 : total / Double(n)
    }
}
