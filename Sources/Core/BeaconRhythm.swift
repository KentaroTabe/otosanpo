import Foundation

/// 帰路ビーコンの鳴らし方(間隔と音量)を決める純粋な計算。
///
/// **歩調に同期させる**(2026-08-16 の利用者要望「歩くペースに合わせた頻度でなる」)。
/// 歩幅と無関係な固定周期で鳴ると、音が歩行から浮いて「機械が鳴っている」感じになる。
/// N 歩に 1 回で鳴らせば、音が歩みの一部として馴染む。
///
/// ここで**距離の表し方が変わる**。間隔は歩調に取られるので、距離は音量で表す。
/// これは曲がり角の誘導で先に採った方式で、実測で「音量で角を識別できる」ことが
/// 確認できている(2026-08-19)。間隔で距離を表す旧方式(ガイガーカウンター)は、
/// 誘導では**伝わらなかった**と利用者が判断している。
public enum BeaconRhythm {
    public struct Params: Equatable {
        /// 何歩に 1 回鳴らすか
        public let stepsPerTone: Double
        /// 間隔の下限・上限 [sec]。歩調が極端なとき(走った・立ち止まった)に暴れないよう挟む
        public let minIntervalSec: Double
        public let maxIntervalSec: Double
        /// 歩調が取れないときに使う間隔 [sec]
        public let fallbackIntervalSec: Double
        /// 音量の範囲 [0..1]。自宅に近いほど大きい
        public let gainFar: Double
        public let gainNear: Double
        /// 音量が最大・最小になる自宅までの距離 [m]
        public let nearDistanceM: Double
        public let farDistanceM: Double

        public init(stepsPerTone: Double, minIntervalSec: Double, maxIntervalSec: Double,
                    fallbackIntervalSec: Double, gainFar: Double, gainNear: Double,
                    nearDistanceM: Double, farDistanceM: Double) {
            self.stepsPerTone = stepsPerTone
            self.minIntervalSec = minIntervalSec
            self.maxIntervalSec = maxIntervalSec
            self.fallbackIntervalSec = fallbackIntervalSec
            self.gainFar = gainFar
            self.gainNear = gainNear
            self.nearDistanceM = nearDistanceM
            self.farDistanceM = farDistanceM
        }
    }

    /// 次のビーコンまでの間隔 [sec]。
    /// - Parameter cadenceStepsPerSec: 実測の歩調。取れないときは nil
    public static func intervalSec(cadenceStepsPerSec: Double?, p: Params) -> Double {
        guard let c = cadenceStepsPerSec, c > 0 else { return p.fallbackIntervalSec }
        return min(p.maxIntervalSec, max(p.minIntervalSec, p.stepsPerTone / c))
    }

    /// 自宅までの距離に応じた音量 [0..1]。近いほど大きい。
    /// 距離を間隔ではなく音量で表すのは、間隔が歩調に取られるため
    public static func gain(distanceM: Double, p: Params) -> Double {
        let span = p.farDistanceM - p.nearDistanceM
        guard span > 0 else { return p.gainNear }
        // t = 0(近い)〜 1(遠い)
        let t = min(1, max(0, (distanceM - p.nearDistanceM) / span))
        return p.gainNear + (p.gainFar - p.gainNear) * t
    }
}
