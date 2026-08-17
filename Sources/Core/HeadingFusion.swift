import Foundation

/// 「顔がどちらを向いているか」を絶対方位として推定する純粋ロジック。
///
/// なぜ推定が必要か:
/// `CMHeadphoneMotionManager` の yaw は**接続ごとに基準が引き直される相対値**で、
/// 「頭が北を向いている」は分からない(段階 8 の実測では再装着直後に 200° 跳んだ)。
/// 一方 `CLLocation.course` は絶対方位だが、体の進行方向であって顔の向きではない。
///
/// 推定の考え方:
/// 歩いている間、顔は**平均すれば進行方向を向いている**。したがって
/// `yaw − 進行方位` の移動平均を「基準線」とみなせば、そこからの差が
/// 「進行方向に対して首をどれだけ振っているか」になる。基準線は数十秒の時定数で
/// ゆっくり追従させる。速すぎると首振りごと吸収してしまい、遅すぎると
/// 基準の引き直しに追いつけない。
///
/// この推定により、音は**世界に対して固定されて**聞こえる。顔を右に向ければ、
/// 自宅方向の音は相対的に左へ動く。docs/01「音の鳴る方に歩くと面白い散歩ができる」の
/// 前半(方向が信じられること)を支える部品。
public struct HeadingFusion: Equatable {
    public struct Params: Equatable {
        /// 基準線の追従係数 [0..1]。1 サンプルあたりの更新量。小さいほどゆっくり
        public let baselineAlpha: Double
        /// 首の相対角として認める上限 [deg]。これを超える差は基準の狂いとみなして丸める
        public let maxOffsetDeg: Double
        /// 基準線が使えると判断するまでの最小サンプル数
        public let minSamples: Int

        public init(baselineAlpha: Double, maxOffsetDeg: Double, minSamples: Int) {
            self.baselineAlpha = baselineAlpha
            self.maxOffsetDeg = maxOffsetDeg
            self.minSamples = minSamples
        }
    }

    /// 基準線は角度なので、単純な平均ではなく単位ベクトルの平均で保持する
    /// (359° と 1° の平均が 180° になる事故を避ける)
    private var sinAcc = 0.0
    private var cosAcc = 0.0
    private var samples = 0

    public init() {}

    /// 基準線が育ちきっているか(育つまでは進行方位をそのまま使う)
    public var isReady: Bool { samples > 0 }

    /// サンプルを 1 件与え、基準線を更新して「顔が向いている絶対方位」を返す。
    /// 基準線が十分に育つまでは nil(呼び出し側は進行方位をそのまま使う)。
    public mutating func ingest(headYawDeg: Double, travelBearingDeg: Double,
                                p: Params) -> Double? {
        let raw = Geo.normalizeDeg(headYawDeg - travelBearingDeg)
        let rad = raw * .pi / 180

        defer {
            // 更新は返り値を決めた後。いま来たサンプルで基準線を動かしてから
            // そのサンプルの差分を測ると、首振りが自分自身に吸収される
            if samples == 0 {
                // 初回は単位ベクトルで初期化する。0 から EWMA で立ち上げると、
                // ベクトルが短いあいだ角度が新しいサンプルに引きずられ、
                // 意図した時定数よりはるかに速く基準線が動いてしまう
                sinAcc = sin(rad)
                cosAcc = cos(rad)
            } else {
                let a = p.baselineAlpha
                sinAcc = sinAcc * (1 - a) + sin(rad) * a
                cosAcc = cosAcc * (1 - a) + cos(rad) * a
            }
            samples += 1
        }

        guard samples >= p.minSamples else { return nil }
        guard let baseline = baselineDeg else { return nil }

        let offset = Geo.angularDiffDeg(raw, baseline)
        let clamped = max(-p.maxOffsetDeg, min(p.maxOffsetDeg, offset))
        return Geo.normalizeDeg(travelBearingDeg + clamped)
    }

    /// 現在の基準線 [deg]。ベクトルが縮退している(向きが定まらない)場合は nil
    public var baselineDeg: Double? {
        let magnitude = (sinAcc * sinAcc + cosAcc * cosAcc).squareRoot()
        guard magnitude > 1e-6 else { return nil }
        return Geo.normalizeDeg(atan2(sinAcc, cosAcc) * 180 / .pi)
    }

    /// 姿勢の基準が引き直された(再装着など)ときに捨てる
    public mutating func reset() {
        sinAcc = 0
        cosAcc = 0
        samples = 0
    }
}
