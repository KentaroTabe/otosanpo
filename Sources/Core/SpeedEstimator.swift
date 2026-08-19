import Foundation

/// 歩行速度を**実測から決める**。設定ファイルの固定値は初期値に格下げする。
///
/// なぜ要るか: `walking_speed_m_per_min` は人によって違い、同じ人でも日によって違う。
/// 実測は 62〜94 m/min に散らばっていた(2026-08-18 の回はランニングを含んで 94)。
/// 固定値のままでは帰宅時刻の約束(docs/01 の 3 原則)を支えきれない。
///
/// 散歩 1 回ぶんの平均を指数移動平均で積む。1 回の異常(走った・信号待ちが多かった)で
/// 推定が飛ばないよう、取り込む重みを抑え、常識的な範囲に丸める。
public struct SpeedEstimator: Codable, Equatable {
    public struct Limits: Equatable {
        /// 1 回の散歩の平均をどれだけ取り込むか [0..1]。小さいほど過去を重んじる
        public let ewmaWeight: Double
        /// この件数以上の「歩いている」サンプルが無ければ、その回の平均は使わない
        public let minSamples: Int
        /// 推定として認める範囲 [m/min]。走った回に引きずられて帰宅推定が
        /// 楽観的になる(= 帰りが間に合わない)のを防ぐ
        public let minMPerMin: Double
        public let maxMPerMin: Double

        public init(ewmaWeight: Double, minSamples: Int,
                    minMPerMin: Double, maxMPerMin: Double) {
            self.ewmaWeight = ewmaWeight
            self.minSamples = minSamples
            self.minMPerMin = minMPerMin
            self.maxMPerMin = maxMPerMin
        }
    }

    /// 散歩をまたいで積んだ推定 [m/min]。1 回も実測が無ければ nil
    public private(set) var mPerMin: Double?
    /// 取り込んだ散歩の回数(推定の信頼度を画面とログに出すため)
    public private(set) var walks: Int = 0

    public init() {}

    /// 散歩 1 回ぶんの実測を取り込む。サンプル数が足りない回は捨てる
    public mutating func record(sessionAverageMPerMin: Double?, movingSamples: Int,
                                limits: Limits) {
        guard let s = sessionAverageMPerMin, movingSamples >= limits.minSamples else { return }
        let clamped = min(limits.maxMPerMin, max(limits.minMPerMin, s))
        if let current = mPerMin {
            mPerMin = current * (1 - limits.ewmaWeight) + clamped * limits.ewmaWeight
        } else {
            mPerMin = clamped
        }
        walks += 1
    }

    /// いま帰宅推定に使うべき速度 [m/min]。
    /// **歩いている最中の実測を優先し**、無ければ過去の推定、それも無ければ設定値。
    ///
    /// 走っている最中に「走って帰る前提」で見積もると帰りが間に合わなくなるため、
    /// 上限で丸める。下限は立ち止まりがちな回で推定が 0 に近づくのを防ぐ。
    public func effectiveMPerMin(sessionAverageMPerMin: Double?, movingSamples: Int,
                                 fallback: Double, limits: Limits) -> Double {
        let candidate: Double? = {
            if let s = sessionAverageMPerMin, movingSamples >= limits.minSamples { return s }
            return mPerMin
        }()
        guard let c = candidate else { return fallback }
        return min(limits.maxMPerMin, max(limits.minMPerMin, c))
    }
}
