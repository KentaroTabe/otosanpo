package dev.otosanpo.core

import kotlin.math.max
import kotlin.math.min

/**
 * 歩行の実測値を積む純粋な計算。予算模型の係数を実測から決めるための土台。
 * iOS 版 `GaitMetrics` の移植。
 */
class GaitMetrics {
    /** 実測値を積むときの除外条件。数値は呼び出し側から渡す(Core に数値を持たせない) */
    data class Limits(
        /** この速度未満のサンプルは平均速度に入れない [m/s](信号待ち・立ち止まり) */
        val minMovingSpeedMps: Double,
        /** これ未満の差分は経路長に積まない [m](水平精度の範囲内の揺れ) */
        val minSegmentM: Double,
        /** 水平精度がこれより悪い fix は、経路長も速度も一切使わない [m] */
        val maxAccuracyM: Double,
    )

    /** 位置更新をつないだ実経路長 [m] */
    var pathLengthM: Double = 0.0
        private set
    var movingSpeedSumMps: Double = 0.0
        private set
    var movingSamples: Int = 0
        private set
    var maxSpeedMps: Double = 0.0
        private set

    /** 精度不足で捨てた fix の数。実測値の信頼度を後から判断するために残す */
    var rejectedSamples: Int = 0
        private set

    private var lastPoint: GeoPoint? = null

    /**
     * 位置更新を 1 件加える。
     *
     * - **水平精度が悪い fix は丸ごと捨てる**(位置が飛んで経路長が水増しされるため)
     * - `minSegmentM` 以上動いたときだけ経路長を積む(1 秒 1.2 m に対し精度は 3〜5 m)
     * - `minMovingSpeedMps` 未満のサンプルは平均速度に入れない
     */
    fun add(p: GeoPoint, speedMps: Double?, accuracyM: Double?, limits: Limits) {
        // 精度が不明(null)なら判定しない。負値は「無効」表現なので捨てる
        if (accuracyM != null && (accuracyM < 0 || accuracyM > limits.maxAccuracyM)) {
            rejectedSamples += 1
            return
        }
        val last = lastPoint
        if (last == null) {
            lastPoint = p
        } else {
            val d = Geo.distanceM(last, p)
            // 揺れの範囲内の動きは捨てる。基準点は動かさないので、真の移動は次回以降に拾われる
            if (d >= limits.minSegmentM) {
                pathLengthM += d
                lastPoint = p
            }
        }
        if (speedMps == null || speedMps < limits.minMovingSpeedMps) return
        movingSpeedSumMps += speedMps
        movingSamples += 1
        maxSpeedMps = max(maxSpeedMps, speedMps)
    }

    /** 歩いている間の平均速度 [m/min] */
    val averageMovingSpeedMPerMin: Double?
        get() = if (movingSamples > 0) movingSpeedSumMps / movingSamples * 60 else null

    /** 実経路長 / 直線距離。**帰路でのみ意味を持つ** */
    fun detourFactor(straightLineM: Double): Double? =
        if (straightLineM > 0 && pathLengthM > 0) pathLengthM / straightLineM else null
}

/**
 * 歩行速度を**実測から決める**。設定ファイルの固定値は初期値に格下げする。
 * 実測は 62〜94 m/min に散らばっており、固定値では帰宅時刻の約束を支えきれない。
 */
data class SpeedEstimator(
    /** 散歩をまたいで積んだ推定 [m/min]。1 回も実測が無ければ null */
    var mPerMin: Double? = null,
    /** 取り込んだ散歩の回数(推定の信頼度を画面とログに出すため) */
    var walks: Int = 0,
) {
    data class Limits(
        /** 1 回の散歩の平均をどれだけ取り込むか [0..1] */
        val ewmaWeight: Double,
        /** この件数以上の「歩いている」サンプルが無ければ、その回の平均は使わない */
        val minSamples: Int,
        /** 推定として認める範囲 [m/min] */
        val minMPerMin: Double,
        val maxMPerMin: Double,
    )

    /** 散歩 1 回ぶんの実測を取り込む。サンプル数が足りない回は捨てる */
    fun record(sessionAverageMPerMin: Double?, movingSamples: Int, limits: Limits) {
        if (sessionAverageMPerMin == null || movingSamples < limits.minSamples) return
        val clamped = min(limits.maxMPerMin, max(limits.minMPerMin, sessionAverageMPerMin))
        val current = mPerMin
        mPerMin = if (current != null) {
            current * (1 - limits.ewmaWeight) + clamped * limits.ewmaWeight
        } else {
            clamped
        }
        walks += 1
    }

    /**
     * いま帰宅推定に使うべき速度 [m/min]。
     * **歩いている最中の実測を優先し**、無ければ過去の推定、それも無ければ設定値。
     */
    fun effectiveMPerMin(sessionAverageMPerMin: Double?, movingSamples: Int,
                         fallback: Double, limits: Limits): Double {
        val candidate = if (sessionAverageMPerMin != null && movingSamples >= limits.minSamples) {
            sessionAverageMPerMin
        } else {
            mPerMin
        }
        if (candidate == null) return fallback
        return min(limits.maxMPerMin, max(limits.minMPerMin, candidate))
    }
}
