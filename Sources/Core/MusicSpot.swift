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
        /// 音量の範囲 [0..1] と、それが最大・最小になる距離 [m]。
        /// 写像はビーコンと同じもの(`BeaconRhythm.gain`)を使う
        public var gainNear: Double
        public var gainFar: Double
        public var nearDistanceM: Double
        public var farDistanceM: Double

        public init(minDistanceM: Double, maxDistanceM: Double, distanceStepCount: Int,
                    reachedM: Double,
                    bearingStepDeg: Double, sameDistanceToleranceM: Double,
                    gainNear: Double, gainFar: Double,
                    nearDistanceM: Double, farDistanceM: Double) {
            self.minDistanceM = minDistanceM
            self.maxDistanceM = maxDistanceM
            self.distanceStepCount = distanceStepCount
            self.reachedM = reachedM
            self.bearingStepDeg = bearingStepDeg
            self.sameDistanceToleranceM = sameDistanceToleranceM
            self.gainNear = gainNear
            self.gainFar = gainFar
            self.nearDistanceM = nearDistanceM
            self.farDistanceM = farDistanceM
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
    public func placement(from listener: GeoPoint, referenceBearingDeg: Double,
                          p: Params) -> (relDeg: Double, gain: Double, distanceM: Double) {
        let bearing = Geo.bearingDeg(from: listener, to: center)
        let distance = Geo.distanceM(listener, center)
        return (Geo.angularDiffDeg(bearing, referenceBearingDeg),
                BeaconRhythm.gain(distanceM: distance,
                                  nearDistanceM: p.nearDistanceM, farDistanceM: p.farDistanceM,
                                  gainNear: p.gainNear, gainFar: p.gainFar),
                distance)
    }

    /// 着いたか。着いたら音楽を止める(**一度だけ鳴る**という約束のため)
    public func isReached(from listener: GeoPoint, p: Params) -> Bool {
        Geo.distanceM(listener, center) <= p.reachedM
    }
}
