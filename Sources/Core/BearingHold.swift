import Foundation

/// **位置から決まる向きの「揺れ」を落とす保持**(2026-09-18)。
///
/// ## なぜ要るか
///
/// 利用者の報告「スポットが小刻みに移動している」。
/// スポットの中心は鳴り始めに決めて動かしていないので、動いて聞こえる原因は
/// **自分の位置の推定の揺れ**しかない。角度への効き方は距離に反比例する。
///
/// 実測(`scripts/music_jitter.awk`・field-log-20260918-165323。約 1 秒間隔の行の差):
///
/// | 距離帯 | 音源方位の変化(平均 / 最大) |
/// |---|---|
/// | 0〜5 m | **19.4° / 82.0°** |
/// | 5〜10 m | 3.4° / 8.0° |
/// | 10〜20 m | 1.6° / 4.0° |
/// | 20 m 以上 | 1.0° 以下 |
///
/// 水平精度 3 m なら 5 m 先で 31°・20 m 先で 8° の角度を張る。**近い所だけの問題**。
///
/// ## 2 段で作る(2026-09-18 の合議)
///
/// ```
///  生の向き ──[遊び(不感帯)]──> 目標 ──[短い時定数で追従]──> 鳴らす向き
/// ```
///
/// 1. **遊び**: 目標との差が不感帯以下なら目標を動かさない。
///    超えたら**はみ出したぶんだけ**動かす(超えた瞬間に生の値へ飛ばさない)
/// 2. **追従**: 鳴らす向きは目標へ `1 − exp(−Δt/τ)` の割合で近づく。
///    遊びを抜けた大きな飛び(実測 82°)を、ここで滑らかに吸収する
///
/// 遊びだけでは、**入力そのものが飛んだ時に出力も飛ぶ**。
/// 追従だけでは、小さな揺れが遅れて出続ける。両方要る。
///
/// ## 何に掛けるか / 掛けないか
///
/// - **位置から決まる向きにだけ掛ける。** 頭の向き(基準)には掛けない —
///   首を振った時の追従が鈍ると、音を探せなくなる(相対方位 = 世界の向き − 基準)
/// - **位置は「新しい fix を見た時だけ」取り込む**(`ingest`)。
///   音は頭方位の受信ごと(50 Hz)に付け直すので、同じ位置を 50 回取り込むと
///   遊びが 50 回ぶん進んでしまう。時間で進むのは追従(`output`)だけ
///
/// ## 保証しないこと
///
/// `atan(精度 / 距離)` は**調整の尺度**であって、「この角度以内は誤差」という保証ではない。
/// 誤差の円がスポットを含む所まで近づけば、真の向きは全周にわたりうる。
/// **誤った位置と本当の通過を、位置だけで見分けることはできない。**
public struct BearingHold: Equatable {

    public struct Params: Equatable {
        /// 不感帯の下限 [deg]。位置の不確かさが小さくてもこれだけは遊びを持つ
        public var minDeadbandDeg: Double
        /// 不感帯の上限 [deg]。**近距離で凍結させない**ための蓋。
        /// 大きくしすぎると、通り過ぎても向きが前のままになる
        public var maxDeadbandDeg: Double
        /// 目標へ追従する時定数 [sec]。大きいほど滑らかで遅い。
        /// **通り過ぎる場面に間に合う長さにする**(2〜3 秒では長すぎる)
        public var timeConstantSec: Double

        public init(minDeadbandDeg: Double, maxDeadbandDeg: Double,
                    timeConstantSec: Double) {
            self.minDeadbandDeg = minDeadbandDeg
            self.maxDeadbandDeg = maxDeadbandDeg
            self.timeConstantSec = timeConstantSec
        }
    }

    /// 遊びを抜けた先の目標
    private var targetDeg: Double?
    /// 実際に鳴らす向き(目標へ追従する)
    private var outputDeg: Double?

    public init() {}

    /// 目標の向き [deg](ログ用)。まだ 1 つも入れていなければ nil
    public var target: Double? { targetDeg }
    /// いま鳴らすべき向き [deg]。まだ 1 つも入れていなければ nil
    public var deg: Double? { outputDeg }

    /// **位置の不確かさが張る角度** [deg]。
    ///
    /// 水平精度 `accuracyM` の円が、距離 `distanceM` の相手に対して張る角度。
    /// 距離が 0 に近いと 90° へ飽和する(そこでは向きに意味が無い)
    public static func uncertaintyDeg(accuracyM: Double, distanceM: Double) -> Double {
        guard accuracyM > 0, distanceM > 0, accuracyM.isFinite, distanceM.isFinite else {
            return 0
        }
        return atan(accuracyM / distanceM) * 180 / .pi
    }

    /// この標本に使う不感帯 [deg](下限と上限で挟む)
    public static func deadbandDeg(uncertaintyDeg: Double, p: Params) -> Double {
        let lo = Swift.max(0, p.minDeadbandDeg)
        let hi = Swift.max(lo, p.maxDeadbandDeg)
        return Swift.min(hi, Swift.max(lo, uncertaintyDeg))
    }

    /// **新しい位置を見た時だけ**呼ぶ。遊びを通して目標を動かす。
    ///
    /// - Parameters:
    ///   - deg: 位置から計算した生の向き [deg]。非有限なら無視する
    ///   - uncertaintyDeg: 位置の不確かさが張る角度。分からなければ 0(下限だけが効く)
    public mutating func ingest(_ deg: Double, uncertaintyDeg: Double = 0, p: Params) {
        guard deg.isFinite else { return }
        let fresh = Geo.normalizeDeg(deg)
        guard let target = targetDeg else {
            targetDeg = fresh
            outputDeg = fresh          // 最初の 1 つは追従を待たずにその場で使う
            return
        }
        let band = Self.deadbandDeg(uncertaintyDeg: uncertaintyDeg, p: p)
        let diff = Geo.angularDiffDeg(fresh, target)
        if diff > band {
            targetDeg = Geo.normalizeDeg(fresh - band)
        } else if diff < -band {
            targetDeg = Geo.normalizeDeg(fresh + band)
        }
    }

    /// **鳴らす向きを進める。** 音を付け直すたびに呼ぶ。
    ///
    /// - Parameter dt: 前に呼んでからの経過 [sec]。**経過時間だけで決まる**ので、
    ///   呼ぶ回数(更新頻度)を変えても同じ時刻には同じ値になる
    @discardableResult
    public mutating func output(after dt: Double, p: Params) -> Double? {
        guard let target = targetDeg else { return nil }
        guard let out = outputDeg else {
            outputDeg = target
            return target
        }
        guard dt > 0, dt.isFinite, p.timeConstantSec > 0 else { return out }
        let k = 1 - exp(-dt / p.timeConstantSec)
        // **最短の回転方向へ近づける**(350° → 10° は +20° 側から寄る)
        let moved = out + Geo.angularDiffDeg(target, out) * k
        outputDeg = Geo.normalizeDeg(moved)
        return outputDeg
    }

    /// 保持を捨てる(スポットを置き直した時など。次の標本がそのまま基準になる)
    public mutating func reset() {
        targetDeg = nil
        outputDeg = nil
    }
}
