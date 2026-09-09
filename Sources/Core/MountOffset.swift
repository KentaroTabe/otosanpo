import Foundation

/// 取り付けのずれ(スマホの方位軸と顔の向きの定常差)を、**歩きながら学習する**。
///
/// ## なぜ固定値にしないか(2026-09-01・利用者判断)
///
/// 初回の実験で、`offset_deg` を決め忘れたまま歩いてしまった。ずれは一定の +94° で、
/// 検疫が 84% 退避し、**実験としては何も検証されない散歩**になった。
/// 固定値は「付け直すたびにずれる・決め忘れても気づけない」を構造的に抱える。
/// ずれは course との差の**定常成分**としてログから正確に推定できた(残差の中央値 9.2°)
/// のだから、同じ計算を歩き出しにその場でやればよい。
///
/// ## 仕組み
///
/// heading − course の差を**円平均**(cos/sin の減衰つき合計)で追う。
/// 平均を「使ってよい」と判断する条件は 2 つ:
///
/// 1. **量**: 実効の標本量(減衰後の重み)が `minWeight` 以上
/// 2. **質**: 平均合成ベクトルの長さ R が `minConcentration` 以上。
///    R は差が一定なら 1 に近づき、散らばる(= 磁気が乱れている・
///    ポケットの中で揺れている)ほど 0 へ落ちる。**ずれが定数である証拠**を要求する
///
/// ポケットに入れて歩けば差が揺れて R が立たず、学習は成立しない
/// (= 頭部基準は使われない)。装置を外した A/B 比較がそのまま成立する。
public struct MountOffset: Equatable {

    public struct Params: Equatable {
        /// 学習が成立するのに要る実効の標本量(減衰後の重み。10 Hz なら 200 ≈ 20 秒)
        public var minWeight: Double
        /// 平均の半減期 [sec]。長め = 付け直し程度の変化にゆっくり追従する
        public var halfLifeSec: Double
        /// 差が定数だと認める合成ベクトル長 R の下限(0..1)。1 に近いほど厳しい
        public var minConcentration: Double
        /// **推定から大きく外れた標本を捨てる門** [deg]。0 で無効(2026-09-09 以前の挙動)。
        ///
        /// なぜ要るか: ずれの推定は「頭は進む方を向いている」を前提にしている。
        /// **首を回すとその前提が崩れ、R(差の一定さ)が落ちる。** すると頭方位が
        /// 信用されなくなり、音が首に追従しなくなる — つまり
        /// **「追従するか確かめようと首を回すほど追従しなくなる」循環**になる
        /// (2026-09-09 の実測: R が 1.00 から 0.77 まで落ち、採用は 7% に留まった)。
        ///
        /// 標本が貯まった後は、**いま推定している値から離れた標本を捨てる**。
        /// 首を回している間の標本が平均を汚さないので、ずれの推定が保たれる
        public var gateDeg: Double

        public init(minWeight: Double, halfLifeSec: Double, minConcentration: Double,
                    gateDeg: Double = 0) {
            self.minWeight = minWeight
            self.halfLifeSec = halfLifeSec
            self.minConcentration = minConcentration
            self.gateDeg = gateDeg
        }
    }

    private var x = 0.0
    private var y = 0.0
    private var weight = 0.0
    private var lastT: TimeInterval?

    public init() {}

    /// 1 標本を取り込む。course が無い間は何もしない(揺れた標本で平均を汚さない)
    public mutating func ingest(headingDeg: Double, courseDeg: Double?,
                                at t: TimeInterval, p: Params) {
        guard let course = courseDeg else { return }
        // **標本が貯まったら、推定から離れた標本を捨てる。**
        // 首を回している間の差は「ずれ」ではなく「首の向き」なので、混ぜると平均が汚れる。
        // 門を通す中心は**閾値を通っていない生の円平均**を使う — R が落ちて
        // 学習が外れた後こそ門が要るので、`offsetDeg` の判定に依存させない
        if p.gateDeg > 0, weight >= p.minWeight,
           abs(Geo.angularDiffDeg(Geo.normalizeDeg(headingDeg - course), meanDeg)) > p.gateDeg {
            return
        }
        if let last = lastT, t > last, p.halfLifeSec > 0 {
            let decay = pow(0.5, (t - last) / p.halfLifeSec)
            x *= decay
            y *= decay
            weight *= decay
        }
        lastT = t
        let diff = (headingDeg - course) * .pi / 180
        x += cos(diff)
        y += sin(diff)
        weight += 1
    }

    /// 閾値を通していない生の円平均 [deg]。**門の中心に使う**(表に出す値ではない)
    private var meanDeg: Double {
        Geo.normalizeDeg(atan2(y, x) * 180 / .pi)
    }

    /// 差の散らばりの少なさ(合成ベクトル長 R・0..1)。1 = 完全に一定
    public var concentration: Double {
        weight > 0 ? (x * x + y * y).squareRoot() / weight : 0
    }

    /// 学習できたずれ [deg]。量と質の両方を満たすまで nil(= 補正しない)
    public func offsetDeg(p: Params) -> Double? {
        guard weight >= p.minWeight, concentration >= p.minConcentration else { return nil }
        return Geo.normalizeDeg(atan2(y, x) * 180 / .pi)
    }
}
