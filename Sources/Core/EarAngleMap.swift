import Foundation

/// **「その人にとって真横に聞こえる角度」で、音の置き方を合わせる**(2026-09-18 利用者依頼)。
///
/// ## 何を合わせるか
///
/// > 「音を左後ろから正面を経由して右後ろまでのいずれかで流せる 1 本のつまみを用意し、
/// > それを元に校正する」
///
/// つまみを動かすと音が周りを回る。**真右に聞こえた所**でつまみを止めてもらい、
/// その角度を覚える。真左も同じ。以後は「真横に置きたい時、その角度へ置く」。
///
/// 汎用 HRTF の左右差は「平均的な頭」のもので、**その人にとって 90° に聞こえる保証は無い**。
/// 2026-09-18 の散歩でも「左右のイヤホンの音量の合計がほぼ一定なので、
/// 左右に偏った時だけはっきり分かる」という感想が出ていた。
/// 真横が 120° の所にあると感じる人なら、45° の音は 60° あたりへ置いた方が、
/// その人の感覚では 45° に聞こえる — **間の角度も一緒に開く**のがこの写像の役目。
///
/// ## 写像
///
/// 正面(0°)・真横(合わせた角度)・真後ろ(180°)の **3 点を通る折れ線**。
///
/// ```
/// |置きたい角度| ≤ 90 : |置く角度| = |置きたい角度| × (合わせた角度 / 90)
/// |置きたい角度| > 90 : |置く角度| = 合わせた角度
///                                  + (|置きたい角度| − 90) × (180 − 合わせた角度) / 90
/// ```
///
/// - 合わせた角度が 90° なら**何もしない**(校正前と同じ)
/// - 120° なら内側は 1.33 倍(45° → 60°)、外側は 0.67 倍(135° → 150°)
/// - 単調で、0° と 180° を動かさない
///
/// **冪(`180 × (θ/180)^k`)は使わない。** 正面のすぐ横で傾きが発散し、
/// 0.05° の入力が 3.9° になった(テストで検出)。首のわずかな動きが
/// 大きな移動に化けるので、この用途には向かない。
/// 折れ線なら傾きは一定で、**手がかりが 1 つしか無い以上、これがいちばん余計な仮定が少ない**。
///
/// 左右は別々に持つ(**耳は左右対称ではない**)。
///
/// ## なぜ左右の利得を直に触らないか(2026-09-18・作り直し)
///
/// 最初は「真横での左右のレベル差 [dB]」を直に合わせる形にした。しかしそれだと
/// **音楽だけ環境ノード(HRTF)を通らない経路**にする必要があり、
/// 近づいた時に下から鳴る手がかり(仰角)と、遠いほど広がる手がかりを失う。
/// 角度の写像なら**同じ経路のまま**なので、どちらも残る。
public struct EarAngleMap: Equatable, Codable {

    /// 真右に聞こえた角度 [deg](0 < x < 180)
    public var rightAnchorDeg: Double
    /// 真左に聞こえた角度 [deg](0 < x < 180・左側の絶対値で持つ)
    public var leftAnchorDeg: Double

    public init(rightAnchorDeg: Double, leftAnchorDeg: Double) {
        self.rightAnchorDeg = rightAnchorDeg
        self.leftAnchorDeg = leftAnchorDeg
    }

    /// つまみの範囲。**真後ろまで振れる**(音楽は後ろにも置かれる)
    public static let minAnchorDeg = 20.0
    public static let maxAnchorDeg = 160.0

    /// 有限で範囲内か。**範囲外は校正済みとして扱わない**
    public var isValid: Bool {
        rightAnchorDeg.isFinite && leftAnchorDeg.isFinite
            && rightAnchorDeg >= Self.minAnchorDeg && rightAnchorDeg <= Self.maxAnchorDeg
            && leftAnchorDeg >= Self.minAnchorDeg && leftAnchorDeg <= Self.maxAnchorDeg
    }

    /// **何もしない写像**(真横が 90° に聞こえる人と同じ)
    public static let identity = EarAngleMap(rightAnchorDeg: 90, leftAnchorDeg: 90)

    /// 置きたい角度 [deg] を、**その人に合わせた置き場所** [deg] へ写す。
    ///
    /// 0° と ±180° は動かない。右は `rightAnchorDeg`、左は `leftAnchorDeg` を通る
    public func rendered(intendedDeg deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        let d = Geo.angularDiffDeg(deg, 0)          // −180..180
        let side = d >= 0 ? rightAnchorDeg : leftAnchorDeg
        let magnitude = Swift.min(180, abs(d))
        guard magnitude > 0 else { return 0 }
        let anchor = Swift.min(Self.maxAnchorDeg, Swift.max(Self.minAnchorDeg, side))
        // 0° → 0、90° → 合わせた角度、180° → 180 の 3 点を通る折れ線
        let mapped = magnitude <= 90
            ? magnitude * (anchor / 90)
            : anchor + (magnitude - 90) * (180 - anchor) / 90
        return (d >= 0 ? 1 : -1) * mapped
    }
}
