package dev.otosanpo.core

import kotlin.math.cos
import kotlin.math.sin

/**
 * 方向の推定に使う生データ。Android では `Location.bearing` / `bearingAccuracyDegrees` /
 * `speed` を Services 側で詰める(iOS の course / courseAccuracy / speed と 1 対 1)。
 * 無効値は負値で表される場合があるため、判定はこのファイルに集約する。
 */
data class MotionFix(
    /** 進行方向 [deg, 0..360)。負値・null は無効 */
    val courseDeg: Double? = null,
    /** 進行方向の誤差 [deg]。負値・null は不明として扱う */
    val courseAccuracyDeg: Double? = null,
    val speedMps: Double? = null,
    /** 端末そのものの向き。ポケットに入れると進行方向と一致しない */
    val compassHeadingDeg: Double? = null,
    /** 位置更新からの経過秒 */
    val ageSec: Double? = null,
    val horizontalAccuracyM: Double? = null,
)

/** 方向をどこから得たか。ログに残して事後検証する */
enum class DirectionSource(val label: String) {
    COURSE("移動方向"),
    HELD_COURSE("移動方向(保持)"),
    COMPASS("端末コンパス"),
}

/** 直前まで有効だった course。**状態は Core の外に置く**(Core を純粋に保つため) */
data class HeldCourse(val deg: Double, val ageSec: Double)

data class TravelDirectionFix(val deg: Double, val source: DirectionSource)

/**
 * 「いま体はどちらを向いて進んでいるか」を決める純粋ロジック。
 *
 * - 端末をポケットに入れる前提なので、**端末コンパスは進行方向の代用にならない**。
 *   歩行中は移動の軌跡から出る方向を第一候補にする
 * - 静止・低速・GPS 不良で無効になる間は、直前の有効な値を `courseHoldSec` まで使う。
 *   数十秒前の移動方向のほうが、ポケットの中の端末の向きよりはるかに確からしい
 * - それも尽きた場合のみコンパスへ退避(既定は false)
 * - どれも使えなければ null。呼び出し側は「鳴らさない」か「中央で鳴らす」を選ぶ
 */
object TravelDirection {
    fun resolve(fix: MotionFix, held: HeldCourse? = null,
                params: AppParameters.Location): TravelDirectionFix? {
        validCourse(fix, params)?.let {
            return TravelDirectionFix(Geo.normalizeDeg(it), DirectionSource.COURSE)
        }
        if (held != null && held.ageSec <= params.courseHoldSec) {
            return TravelDirectionFix(Geo.normalizeDeg(held.deg), DirectionSource.HELD_COURSE)
        }
        val compass = fix.compassHeadingDeg
        if (params.allowCompassFallback && compass != null && compass >= 0) {
            return TravelDirectionFix(Geo.normalizeDeg(compass), DirectionSource.COMPASS)
        }
        return null
    }

    /** course が無効になった理由。「なぜ左右が付かなかったか」を追えるようにする */
    fun rejectionReason(fix: MotionFix, params: AppParameters.Location): String? {
        val course = fix.courseDeg
        if (course == null || course < 0) return "course が無効"
        val speed = fix.speedMps ?: return "速度が不明"
        if (speed < params.minSpeedForCourseMPerS) {
            return "速度不足(%.2f < %.2f m/s)".format(speed, params.minSpeedForCourseMPerS)
        }
        val age = fix.ageSec
        if (age != null && age > params.maxFixAgeSec) {
            return "fix が古い(%.1f > %.1f s)".format(age, params.maxFixAgeSec)
        }
        val acc = fix.courseAccuracyDeg
        if (acc != null && acc >= 0 && acc > params.maxCourseAccuracyDeg) {
            return "course 精度不足(%.0f > %.0f°)".format(acc, params.maxCourseAccuracyDeg)
        }
        return null
    }

    private fun validCourse(fix: MotionFix, params: AppParameters.Location): Double? {
        val course = fix.courseDeg ?: return null
        if (course < 0) return null
        val speed = fix.speedMps ?: return null
        if (speed < params.minSpeedForCourseMPerS) return null
        val age = fix.ageSec
        if (age != null && age > params.maxFixAgeSec) return null
        val acc = fix.courseAccuracyDeg
        if (acc != null && acc >= 0 && acc > params.maxCourseAccuracyDeg) return null
        return course
    }
}

/**
 * earcon の波形を作る純粋な計算。
 *
 * **アプリと書き出しで同じ音を鳴らすために Core へ置く。**
 * Android では `AudioTrack` にそのまま流す。**iOS とまったく同じ標本列**になる。
 */
object ToneRenderer {
    /**
     * 周波数列を Hann 窓エンベロープのサイン波ブリップとして並べ、標本列にする。
     * 返すのはモノラル。定位は再生側が付ける(パン)
     */
    fun samples(tone: AppParameters.ToneSpec, sampleRate: Double, gain: Double): FloatArray {
        val blipFrames = (tone.blipSec * sampleRate).toInt()
        val gapFrames = (tone.gapSec * sampleRate).toInt()
        val count = tone.freqsHz.size
        if (count == 0 || blipFrames <= 0) return FloatArray(0)

        val out = ArrayList<Float>(count * blipFrames + maxOf(0, count - 1) * gapFrames)

        // 雑音は再現性のために自前の線形合同法で作る(同じ設定なら毎回同じ音になる)
        var seed = 0x9E3779B97F4A7C15uL
        fun nextNoise(): Double {
            seed = seed * 6_364_136_223_846_793_005uL + 1_442_695_040_888_963_407uL
            return (seed shr 11).toLong().toDouble() / (1L shl 52).toDouble() - 1.0
        }
        val mix = tone.noiseMix.coerceIn(0.0, 1.0)

        for ((i, f) in tone.freqsHz.withIndex()) {
            for (n in 0 until blipFrames) {
                val t = n / sampleRate
                val env = 0.5 * (1 - cos(2 * Math.PI * n / blipFrames))
                val tonal = sin(2 * Math.PI * f * t)
                val v = tonal * (1 - mix) + nextNoise() * mix
                out.add((v * env * gain).toFloat())
            }
            if (i < count - 1) repeat(gapFrames) { out.add(0f) }
        }
        return out.toFloatArray()
    }

    /**
     * 音色を暗くする(周波数を下げ、雑音成分を削る)。
     * HRTF では前後を判別できなかった(2026-08-18 実測)ため、背後は音色で分ける。
     * **Android はパンなので、前後を分ける手段はこれだけ。**
     */
    fun darken(tone: AppParameters.ToneSpec, darkness: Double): AppParameters.ToneSpec {
        val d = darkness.coerceIn(0.0, 1.0)
        return tone.copy(
            freqsHz = tone.freqsHz.map { it * (1 - 0.5 * d) },
            noiseMix = tone.noiseMix * (1 - d)
        )
    }
}
