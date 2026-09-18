import Foundation

/// **左右の音量差を、利用者が自分で合わせた値で決める**(2026-09-18 利用者依頼)。
///
/// ## なぜ要るか
///
/// 利用者の報告(2026-09-18):
///
/// - 「前後は 1 も 2 も成り立たず、左右に顔を振らないと分からない」
/// - 「左右のイヤホンから聞こえる音量の合計値がほぼ一定な影響で、
///   左右に偏った時のみはっきり分かる。実際に人間が聞くときの、耳の形による影響や
///   脳の意識の向け方などから決まる値をもとに割り振っても良い」
///
/// 汎用 HRTF の左右差は「平均的な頭」のもので、**その人にとって 90° に聞こえる保証は無い**。
/// そこで、**真横(90°)でどれだけ左右差をつけるか**を利用者自身に合わせてもらい、
/// その 1 点から間の角度を作る。
///
/// ## 作り方(2026-09-18 の合議)
///
/// 左右**それぞれ**の 90° を測る(右だけ測って左へ鏡写しにしない。耳は左右対称ではない)。
///
/// ```
/// θ   = 相対方位(0 = 正面・+90 = 右・180 = 真後ろ)
/// 差dB = (右側なら +rightDb / 左側なら −leftDb) × |sin θ|
/// r    = 10^(差dB / 20)                        … 右 / 左 の振幅比
/// 左 = 1 / √(1 + r²)   右 = r / √(1 + r²)      … 左² + 右² = 1
/// ```
///
/// - 正面と真後ろ(|sin θ| = 0)では左右が等しい
/// - 真横で、利用者が合わせた値そのものになる
/// - 間は連続。**45° の聞こえ方を保証する式ではなく、1 点から作る最小の補間規則**
///
/// 前後の区別はここでは扱わない(指向性と後方の高域シェルフが担う)。
///
/// ## 保証しないこと
///
/// - `左² + 右² = 1` は**電力の係数**の話で、聞こえる大きさが一定になる保証ではない
/// - HRTF を外すと、左右差だけでなく**時間差や周波数ごとの手がかりも失う**。
///   「左右の利得だけで同じように定位する」とはまだ言えない(合議で指摘)
public struct EarBalance: Equatable, Codable {

    /// 右 90° のときの左右レベル差 [dB](正 = 右が大きい)
    public var rightDb: Double
    /// 左 90° のときの左右レベル差 [dB](正 = 左が大きい)
    public var leftDb: Double

    public init(rightDb: Double, leftDb: Double) {
        self.rightDb = rightDb
        self.leftDb = leftDb
    }

    /// 校正の下限・上限 [dB]。画面のつまみの範囲でもある
    public static let minDb = 0.0
    public static let maxDb = 24.0

    /// 有限で範囲内か。**範囲外の値は校正済みとして扱わない**
    public var isValid: Bool {
        rightDb.isFinite && leftDb.isFinite
            && rightDb >= Self.minDb && rightDb <= Self.maxDb
            && leftDb >= Self.minDb && leftDb <= Self.maxDb
    }

    /// この向きでの左右レベル差 [dB](正 = 右が大きい)
    public func differenceDb(relativeBearingDeg deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        let rad = Geo.normalizeDeg(deg) * .pi / 180
        let s = sin(rad)                       // 右で正・左で負・正面と真後ろで 0
        let depth = s >= 0 ? rightDb : leftDb
        return depth * s
    }

    /// 左右の利得。**左² + 右² = 1**
    public func gains(relativeBearingDeg deg: Double) -> (left: Double, right: Double) {
        let db = differenceDb(relativeBearingDeg: deg)
        let r = pow(10, db / 20)
        let norm = (1 + r * r).squareRoot()
        return (1 / norm, r / norm)
    }

    /// **等電力パンのつまみ**(−1 = 左だけ / 0 = 中央 / +1 = 右だけ)へ写す。
    ///
    /// `AVAudioMixerNode.pan` はモノラル入力に等電力の法則で効くので、
    /// 角度 φ = atan(右 / 左) を [0, π/2] から [−1, +1] へ線形に写せば、
    /// 求めた左右比がそのまま出る。
    ///
    /// **法則の細部が違っても校正が吸収する** — 利用者は耳で合わせるので、
    /// ここで必要なのは「単調であること」だけ
    public func pan(relativeBearingDeg deg: Double) -> Double {
        let g = gains(relativeBearingDeg: deg)
        let phi = atan2(g.right, g.left)       // 0(左だけ)〜 π/2(右だけ)
        return Swift.max(-1, Swift.min(1, 4 * phi / .pi - 1))
    }

    /// 校正の途中で聴かせる音の左右比。**角度ではなく差 [dB] を直に渡す**
    /// (校正中は「90° に感じるか」だけを聞くので、角度の式を通さない)
    public static func pan(differenceDb db: Double) -> Double {
        guard db.isFinite else { return 0 }
        let r = pow(10, db / 20)
        let phi = atan2(r / (1 + r * r).squareRoot(), 1 / (1 + r * r).squareRoot())
        return Swift.max(-1, Swift.min(1, 4 * phi / .pi - 1))
    }
}
