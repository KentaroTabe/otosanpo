import Foundation

/// 歩行の実測値を積む純粋な計算。
/// 帰宅予算模型の係数(`walking_speed_m_per_min` / `detour_factor`)は仮置きのままで、
/// しかも人によって、同じ人でも日によって変わる。将来これらを動的に決めるための土台として、
/// まずは 1 回の散歩から実測値を取り出せるようにする。
///
/// 通信は不要。速度は CLLocation が端末内で返す値であり、経路長は位置更新の差分の総和。
public struct GaitMetrics: Equatable {
    /// 位置更新をつないだ実経路長 [m]
    public private(set) var pathLengthM: Double = 0
    /// 「歩いている」と見なしたサンプルの速度合計 [m/s] と件数
    public private(set) var movingSpeedSumMps: Double = 0
    public private(set) var movingSamples: Int = 0
    public private(set) var maxSpeedMps: Double = 0
    private var lastPoint: GeoPoint?

    public init() {}

    /// 位置更新を 1 件加える。
    /// `minMovingSpeedMps` 未満のサンプルは平均速度に入れない(信号待ち・立ち止まりを混ぜない)。
    /// 経路長は止まっている間も加算されるが、GPS の揺れは水平精度の範囲に収まるため許容する。
    public mutating func add(_ p: GeoPoint, speedMps: Double?, minMovingSpeedMps: Double) {
        if let last = lastPoint {
            pathLengthM += Geo.distanceM(last, p)
        }
        lastPoint = p
        guard let s = speedMps, s >= minMovingSpeedMps else { return }
        movingSpeedSumMps += s
        movingSamples += 1
        maxSpeedMps = max(maxSpeedMps, s)
    }

    /// 歩いている間の平均速度 [m/min]。予算模型の walking_speed_m_per_min に対応する
    public var averageMovingSpeedMPerMin: Double? {
        guard movingSamples > 0 else { return nil }
        return movingSpeedSumMps / Double(movingSamples) * 60
    }

    /// 実経路長 / 直線距離。予算模型の detour_factor に対応する。
    /// 帰路(目的地が決まっている区間)でのみ意味を持つ。散策中は寄り道そのものが目的なので
    /// この比を迂回率とは呼べない。
    public func detourFactor(straightLineM: Double) -> Double? {
        guard straightLineM > 0, pathLengthM > 0 else { return nil }
        return pathLengthM / straightLineM
    }
}
