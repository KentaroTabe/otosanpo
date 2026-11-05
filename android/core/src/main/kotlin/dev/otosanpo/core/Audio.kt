package dev.otosanpo.core

import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * 帰路ビーコンの鳴らし方(間隔と音量)を決める純粋な計算。
 *
 * **歩調に同期させる**(利用者要望「歩くペースに合わせた頻度でなる」)。
 * 間隔は歩調に取られるので、**距離は音量で表す**。
 */
object BeaconRhythm {
    data class Params(
        /** 何歩に 1 回鳴らすか */
        val stepsPerTone: Double,
        /** 間隔の下限・上限 [sec] */
        val minIntervalSec: Double,
        val maxIntervalSec: Double,
        /** 歩調が取れないときに使う間隔 [sec] */
        val fallbackIntervalSec: Double,
        /** 音量の範囲 [0..1]。自宅に近いほど大きい */
        val gainFar: Double,
        val gainNear: Double,
        /** 音量が最大・最小になる自宅までの距離 [m] */
        val nearDistanceM: Double,
        val farDistanceM: Double,
    )

    /** 次のビーコンまでの間隔 [sec]。歩調が取れないときは fallback */
    fun intervalSec(cadenceStepsPerSec: Double?, p: Params): Double {
        if (cadenceStepsPerSec == null || cadenceStepsPerSec <= 0) return p.fallbackIntervalSec
        return min(p.maxIntervalSec, max(p.minIntervalSec, p.stepsPerTone / cadenceStepsPerSec))
    }

    /** 自宅までの距離に応じた音量 [0..1]。近いほど大きい */
    fun gain(distanceM: Double, p: Params): Double {
        val span = p.farDistanceM - p.nearDistanceM
        if (span <= 0) return p.gainNear
        val t = min(1.0, max(0.0, (distanceM - p.nearDistanceM) / span))
        return p.gainNear + (p.gainFar - p.gainNear) * t
    }
}

/** 音を置く位置(3D 用)。聴取者は原点で **−Z を向く**。+X が右、+Y が上 */
data class SoundPosition(val x: Double, val y: Double, val z: Double)

/**
 * 相対方位(顔の向きを 0、右を正)から、音の置き場所を決める純粋な変換。
 *
 * **Android はパンだけを使う。** `AVAudioEnvironmentNode` に相当するものが無く、
 * かつ iOS の実測で HRTF でも前後は判別できなかった(docs/03)。
 * 前後は音色を暗くして分けており、それはパンでもそのまま使える(docs/10)。
 */
object SoundPlacement {
    /** ステレオパン(−1 = 左, +1 = 右)。真横で ±1、正面と真後ろがどちらも 0 */
    fun pan(relativeBearingDeg: Double): Double = sin(relativeBearingDeg * Math.PI / 180)

    /** 3D の位置(iOS 版と同じ式。Android では当面使わないが、移植の対称性のため残す) */
    fun position(relativeBearingDeg: Double, radiusM: Double = 1.0): SoundPosition {
        val rad = relativeBearingDeg * Math.PI / 180
        return SoundPosition(x = sin(rad) * radiusM, y = 0.0, z = -cos(rad) * radiusM)
    }
}

/**
 * 帰路に同意した直後の確認音を、いつまで繰り返すか。
 *
 * 役目は**「同意が伝わったか」の不安を消すこと**だけ。
 * **案内が始まれば、それ自体が答えになる。** 実測(2026-08-19)では確認音が
 * 誘導とビーコンを 60 秒せき止め、帰路の最初の 64 秒間、方向の手がかりがゼロだった。
 */
object ReturnAck {
    fun shouldRepeat(directionStarted: Boolean, elapsedSec: Double, durationSec: Double): Boolean =
        !directionStarted && elapsedSec < durationSec
}
