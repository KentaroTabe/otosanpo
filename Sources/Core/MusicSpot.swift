import Foundation

/// 音楽が鳴っている 1 点(→ docs/08 方針 C・docs/14 方針 B の連続音)。
///
/// ## なぜ点の音楽を試すのか
///
/// いまの案内は「点の earcon」で、鳴った瞬間しか方向の手がかりが無い。
/// **連続音なら、聴きながら向きを直せる**。方針 B / C はどちらもそこに賭けている。
/// 実際に「音の鳴る方へ歩くと面白い」ことは実測で裏づけが取れている(docs/01)。
///
/// ## この実装の位置づけ(2026-09-08 利用者判断)
///
/// **実験の最小形**。出発前に選んだ時だけ、**100 m 以内に 1 つだけ**作り、
/// **一度だけ**鳴らす。方針 C の本体(複数スポット・再訪・音楽の配信)は含まない。
///
/// **前半球への畳みを行わない。** 点の earcon は「後ろから鳴らない」ために
/// 前へ畳んでいる(docs/03)が、音楽は通り過ぎれば後ろにあるのが自然で、
/// 畳むと通り過ぎたことが分からなくなる。
public struct MusicSpot: Equatable {

    public struct Params: Equatable {
        /// スポットを置いてよい距離の**下限と上限** [m]。
        /// **散歩時間に比例して決める**(2026-09-09 利用者判断)。
        /// 短い散歩で遠くに置くと辿り着けず、長い散歩で近くに置くとすぐ通り過ぎる
        public var minDistanceM: Double
        public var maxDistanceM: Double
        /// 帯の真ん中。候補のうちこれに最も近いものを選ぶ
        public var targetDistanceM: Double { (minDistanceM + maxDistanceM) / 2 }
        /// 候補を探す距離の刻み数(下限から上限までを何段に分けるか)
        public var distanceStepCount: Int
        /// これより近づいたら「着いた」として止める [m]
        public var reachedM: Double
        /// 候補を探す方位の刻み [deg]
        public var bearingStepDeg: Double
        /// 距離の差がこれ未満なら「同じ距離」とみなす [m]。
        ///
        /// `Geo.destination` は平面近似、`Geo.distanceM` は haversine なので、
        /// 同じ距離を指定して往復させても方位によってごく小さな差が出る。
        /// **これが 0 だと、同点の決まり方が浮動小数の誤差で決まる**(2026-09-09 に踏んだ)。
        /// 触る必要のある値ではないが、**候補の選ばれ方を変える閾値**なので設定に置く
        public var sameDistanceToleranceM: Double
        /// 音量が最大になる距離 [m]。これより近づいても大きくならない
        public var referenceDistanceM: Double
        /// 距離による減り方の強さ。**1.0 で現実の音と同じ**(距離が倍で −6 dB)。
        /// 大きいほど急に小さくなり、近づく手応えが強くなる
        public var rolloff: Double
        /// 音量の上限・下限 [0..1]。下限は「遠くても消えない」ための床
        public var maxGain: Double
        public var minGain: Double
        /// **直線の向きと、道をたどる向きをどれだけ混ぜるか** [0..1]。
        /// 0 = 直線だけ / 1 = 道だけ。
        ///
        /// 直線だけだと、建物の向こうから鳴っているのに「そちらへ行けない」ことになる。
        /// 道だけだと、曲がり角のたびに音が飛んで**スポットに居る感じ**が薄れる。
        /// 間を取ると「あちらに在って、こう行けば着く」が同時に伝わる
        /// (2026-09-10 利用者依頼)
        public var routeBlend: Double

        /// 距離 `d` [m] での音量。**逆二乗則**(現実の音の減り方)を使う。
        ///
        /// ## なぜ線形をやめたか(2026-09-10 利用者依頼)
        ///
        /// 「スポットが左右にあることは分かるが**前後が分からない**」。
        /// 前後は HRTF では伝わらないと確定しているので(docs/03)、
        /// **近づけば大きく・遠ざかれば小さく**で伝えるほかない。
        ///
        /// 線形の写像は、遠い側では 10 m 動いてもほとんど変わらなかった
        /// (30 分の散歩で 15〜240 m を 0.9〜0.25 に張ると、10 m で 0.027 =
        /// **0.3 dB 弱**。人が気づくのは 1 dB 前後から)。
        /// 逆二乗則なら**近いほど急に変わる**ので、近づく手応えが出る
        public func gain(atDistanceM d: Double) -> Double {
            let clamped = Swift.max(referenceDistanceM, d)
            let raw = maxGain * pow(referenceDistanceM / clamped, rolloff)
            return Swift.min(maxGain, Swift.max(minGain, raw))
        }

        /// `d` から 10 m 近づいた時の音量差 [dB]。**設計の狙いを測るための窓**。
        /// 1 dB 前後で人は気づき、3 dB ではっきり分かる
        public func decibelGainPer10m(atDistanceM d: Double) -> Double {
            let near = gain(atDistanceM: Swift.max(0, d - 10))
            let far = gain(atDistanceM: d)
            guard far > 0, near > 0 else { return 0 }
            return 20 * log10(near / far)
        }

        public init(minDistanceM: Double, maxDistanceM: Double, distanceStepCount: Int,
                    reachedM: Double,
                    bearingStepDeg: Double, sameDistanceToleranceM: Double,
                    referenceDistanceM: Double, rolloff: Double,
                    maxGain: Double, minGain: Double, routeBlend: Double) {
            self.minDistanceM = minDistanceM
            self.maxDistanceM = maxDistanceM
            self.distanceStepCount = distanceStepCount
            self.reachedM = reachedM
            self.bearingStepDeg = bearingStepDeg
            self.sameDistanceToleranceM = sameDistanceToleranceM
            self.referenceDistanceM = referenceDistanceM
            self.rolloff = rolloff
            self.maxGain = maxGain
            self.minGain = minGain
            self.routeBlend = routeBlend
        }
    }

    public let center: GeoPoint

    public init(center: GeoPoint) {
        self.center = center
    }

    /// 出発点のまわりに置く候補を作る。**道に乗せるのは呼び出し側**
    /// (スナップは地図が要るので Core には置かない)。
    /// 方位を刻んで狙う距離の点を並べるだけの純粋な計算。
    ///
    /// 刻みは北から時計回り。**順序が決まっている**ので、同じ出発点なら同じ候補が出る
    public static func candidates(around start: GeoPoint, p: Params) -> [GeoPoint] {
        // 刻みが 0 以下なら候補は作れない(無限ループを避ける)。
        // **既定値を代わりに置かない** — 設定の誤りを黙って埋めると気づけなくなる
        guard p.bearingStepDeg > 0, p.distanceStepCount > 0,
              p.maxDistanceM >= p.minDistanceM else { return [] }
        // **帯の中を何段かに分けて並べる。** 1 つの距離だけで作ると、道へ寄せた後に
        // 帯から外れて候補が全滅しうる(下限を入れたことで起きうるようになった)
        var radii: [Double] = []
        if p.distanceStepCount == 1 {
            radii = [p.targetDistanceM]
        } else {
            let span = p.maxDistanceM - p.minDistanceM
            for i in 0..<p.distanceStepCount {
                radii.append(p.minDistanceM + span * Double(i) / Double(p.distanceStepCount - 1))
            }
        }
        var out: [GeoPoint] = []
        var bearing = 0.0
        while bearing < 360 {
            for radius in radii {
                out.append(Geo.destination(from: start, bearingDeg: bearing, distanceM: radius))
            }
            bearing += p.bearingStepDeg
        }
        return out
    }

    /// 候補から 1 つ選ぶ。**上限の内側で、狙う距離にいちばん近いもの。**
    /// 同点は候補の並び順(= 方位の小さい方)で決める — 再現できるようにするため
    public static func choose(from candidates: [GeoPoint], start: GeoPoint,
                              p: Params) -> MusicSpot? {
        var best: (point: GeoPoint, error: Double)?
        for c in candidates {
            let d = Geo.distanceM(start, c)
            // **帯の外は選ばない。** 下限も上限も散歩時間から決まる
            guard d >= p.minDistanceM, d <= p.maxDistanceM else { continue }
            let error = abs(d - p.targetDistanceM)
            // 差がこの許容より小さければ同点とみなし、**最初のものを残す**(= 並び順で決まる)
            if best == nil || error < best!.error - p.sameDistanceToleranceM {
                best = (c, error)
            }
        }
        return best.map { MusicSpot(center: $0.point) }
    }

    /// 聴取者から見た**畳まない**相対方位と、距離から決めた音量。
    ///
    /// - Parameter referenceBearingDeg: 定位の基準(顔の向き。取れなければ進行方位)
    /// - Parameter routeBearingDeg: **道をたどってスポットへ向かう向き**。
    ///   取れなければ nil(直線の向きだけを使う)
    public func placement(from listener: GeoPoint, referenceBearingDeg: Double,
                          routeBearingDeg: Double? = nil,
                          p: Params) -> (relDeg: Double, gain: Double, distanceM: Double,
                                         worldBearingDeg: Double) {
        let direct = Geo.bearingDeg(from: listener, to: center)
        let distance = Geo.distanceM(listener, center)
        let world = Self.blend(direct: direct, route: routeBearingDeg, weight: p.routeBlend)
        return (Geo.angularDiffDeg(world, referenceBearingDeg),
                p.gain(atDistanceM: distance), distance, world)
    }

    /// 直線の向きと、道をたどる向きの**間**を取る(→ `Params.routeBlend`)。
    ///
    /// 角度は円周上の量なので、**線形に混ぜてはいけない**(350° と 10° の中間は 0° で、
    /// 平均の 180° ではない)。単位ベクトルにして足し、向きに戻す
    public static func blend(direct: Double, route: Double?, weight: Double) -> Double {
        guard let route, weight > 0 else { return direct }
        let w = min(1, max(0, weight))
        let a = direct * .pi / 180, b = route * .pi / 180
        let x = cos(a) * (1 - w) + cos(b) * w
        let y = sin(a) * (1 - w) + sin(b) * w
        // 真反対を等分に混ぜると原点になり向きが決まらない。その時は直線を採る
        guard x * x + y * y > 1e-12 else { return direct }
        return Geo.normalizeDeg(atan2(y, x) * 180 / .pi)
    }

    /// 着いたか。着いたら音楽を止める(**一度だけ鳴る**という約束のため)
    public func isReached(from listener: GeoPoint, p: Params) -> Bool {
        Geo.distanceM(listener, center) <= p.reachedM
    }
}
