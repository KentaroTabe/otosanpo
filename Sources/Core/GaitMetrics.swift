import Foundation

/// 歩行の実測値を積む純粋な計算。
/// 帰宅予算模型の係数(`walking_speed_m_per_min` / `detour_factor`)は仮置きのままで、
/// しかも人によって、同じ人でも日によって変わる。将来これらを動的に決めるための土台として、
/// まずは 1 回の散歩から実測値を取り出せるようにする。
///
/// 通信は不要。速度は CLLocation が端末内で返す値であり、経路長は位置更新の差分の総和。
public struct GaitMetrics: Equatable {
    /// 実測値を積むときの除外条件。パラメータは呼び出し側から渡す(Core に数値を持たせない)
    public struct Limits: Equatable {
        /// この速度未満のサンプルは平均速度に入れない [m/s](信号待ち・立ち止まり)
        public let minMovingSpeedMps: Double
        /// これ未満の差分は経路長に積まない [m](水平精度の範囲内の揺れ)
        public let minSegmentM: Double
        /// 水平精度がこれより悪い fix は、経路長も速度も一切使わない [m]
        public let maxAccuracyM: Double

        public init(minMovingSpeedMps: Double, minSegmentM: Double, maxAccuracyM: Double) {
            self.minMovingSpeedMps = minMovingSpeedMps
            self.minSegmentM = minSegmentM
            self.maxAccuracyM = maxAccuracyM
        }
    }

    /// 位置更新をつないだ実経路長 [m]
    public private(set) var pathLengthM: Double = 0
    /// 「歩いている」と見なしたサンプルの速度合計 [m/s] と件数
    public private(set) var movingSpeedSumMps: Double = 0
    public private(set) var movingSamples: Int = 0
    public private(set) var maxSpeedMps: Double = 0
    /// 精度不足で捨てた fix の数。実測値の信頼度を後から判断するために残す
    public private(set) var rejectedSamples: Int = 0
    private var lastPoint: GeoPoint?

    public init() {}

    /// 位置更新を 1 件加える。
    ///
    /// - **水平精度が悪い fix は丸ごと捨てる**。段階 8 の実測で水平精度 69 m の区間があり、
    ///   位置が飛んで経路長が水増しされた(迂回率 1.67 と過大に出た)。同じ区間で
    ///   CLLocation 自身の速度も 3.6 m/s(歩行ではありえない)を報告していたため、
    ///   速度の平均からも除く必要がある
    /// - `minSegmentM` 以上動いたときだけ経路長を積む。位置更新は 1 秒ごとに来るが、
    ///   歩行では 1 秒 = 約 1.2 m しか進まない一方、水平精度は良い時でも 3〜5 m ある。
    ///   毎回の差分をそのまま足すと揺れが累積する
    /// - `minMovingSpeedMps` 未満のサンプルは平均速度に入れない
    public mutating func add(_ p: GeoPoint, speedMps: Double?, accuracyM: Double?,
                             limits: Limits) {
        // 精度が不明(nil)なら判定しない。負値は CoreLocation の「無効」表現なので捨てる
        if let acc = accuracyM, acc < 0 || acc > limits.maxAccuracyM {
            rejectedSamples += 1
            return
        }
        if let last = lastPoint {
            let d = Geo.distanceM(last, p)
            // 揺れの範囲内の動きは捨てる。基準点は動かさないので、真の移動は次回以降に拾われる
            if d >= limits.minSegmentM {
                pathLengthM += d
                lastPoint = p
            }
        } else {
            lastPoint = p
        }
        guard let s = speedMps, s >= limits.minMovingSpeedMps else { return }
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
