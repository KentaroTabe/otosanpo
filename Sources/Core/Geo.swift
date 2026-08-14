import Foundation

/// 緯度経度(度)。CoreLocation 非依存の純粋型。
public struct GeoPoint: Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 地理計算ユーティリティ。散歩スケール(数 km)を前提とした精度。
public enum Geo {
    /// 物理定数(パラメータ化の対象外)
    public static let earthRadiusM = 6_371_000.0
    public static let metersPerDegreeLat = 111_320.0

    /// ハーバサイン距離 [m]
    public static func distanceM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p1 = a.latitude * .pi / 180
        let p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// a から b への方位角 [deg, 0..360)。北=0、東=90。
    public static func bearingDeg(from a: GeoPoint, to b: GeoPoint) -> Double {
        let p1 = a.latitude * .pi / 180
        let p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizeDeg(atan2(y, x) * 180 / .pi)
    }

    /// 角度を 0..360 に正規化
    public static func normalizeDeg(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    /// a - b を -180..180 に正規化(符号は a が b から見て右回りに何度ずれているか)
    public static func angularDiffDeg(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// 平面近似で bearing 方向へ distance 進んだ点(近距離用)
    public static func destination(from p: GeoPoint, bearingDeg: Double, distanceM: Double) -> GeoPoint {
        let t = bearingDeg * .pi / 180
        let dLat = distanceM * cos(t) / metersPerDegreeLat
        let dLon = distanceM * sin(t) / (metersPerDegreeLat * cos(p.latitude * .pi / 180))
        return GeoPoint(latitude: p.latitude + dLat, longitude: p.longitude + dLon)
    }
}
