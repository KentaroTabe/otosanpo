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
        /// スポットを置いてよい上限の距離 [m]
        public var maxDistanceM: Double
        /// 狙う距離 [m]。候補のうちこれに最も近いものを選ぶ
        public var targetDistanceM: Double
        /// これより近づいたら「着いた」として止める [m]
        public var reachedM: Double
        /// 候補を探す方位の刻み [deg]
        public var bearingStepDeg: Double
        /// 距離から音量を決める設定(ビーコンと同じ形を使う)
        public var rhythm: BeaconRhythm.Params

        public init(maxDistanceM: Double, targetDistanceM: Double, reachedM: Double,
                    bearingStepDeg: Double, rhythm: BeaconRhythm.Params) {
            self.maxDistanceM = maxDistanceM
            self.targetDistanceM = targetDistanceM
            self.reachedM = reachedM
            self.bearingStepDeg = bearingStepDeg
            self.rhythm = rhythm
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
        let step = max(1, p.bearingStepDeg)
        var out: [GeoPoint] = []
        var bearing = 0.0
        while bearing < 360 {
            out.append(Geo.destination(from: start, bearingDeg: bearing,
                                       distanceM: p.targetDistanceM))
            bearing += step
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
            guard d <= p.maxDistanceM else { continue }
            let error = abs(d - p.targetDistanceM)
            if best == nil || error < best!.error - 1e-9 {
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
                BeaconRhythm.gain(distanceM: distance, p: p.rhythm),
                distance)
    }

    /// 着いたか。着いたら音楽を止める(**一度だけ鳴る**という約束のため)
    public func isReached(from listener: GeoPoint, p: Params) -> Bool {
        Geo.distanceM(listener, center) <= p.reachedM
    }
}
