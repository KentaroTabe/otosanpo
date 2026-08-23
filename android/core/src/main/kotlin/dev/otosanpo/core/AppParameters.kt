package dev.otosanpo.core

/**
 * `config/parameters.json` に対応する型。
 *
 * **JSON は iOS 版と同じファイルを共有する**(数値の二重管理を避ける。docs/10)。
 * ここでは読み込みを持たず、型だけを定義する。JSON のデコードは段 2。
 *
 * 移植の途中なので、**まだ移していない節は存在しない**。
 * 節を足すときは iOS 版 `Sources/Core/AppParameters.swift` の同じ名前・同じ意味にする。
 */
data class AppParameters(
    val session: Session,
    val budget: Budget,
) {
    data class Session(
        val defaultDurationMin: Double,
        val minDurationMin: Double,
        val maxDurationMin: Double,
        /**
         * 延長 1 回で足す時間の、元の設定時間に対する比。
         * 固定分ではなく比例にする(30 分の散歩と 90 分の散歩で延長の意味を揃える)
         */
        val extensionRatio: Double,
        val maxExtensions: Int,
        val rePromptIntervalSec: Double,
        val arrivalRadiusM: Double,
    )

    data class Budget(
        /** 歩行速度の**初期値** [m/min]。実測が貯まればそちらを使う(SpeedEstimator) */
        val walkingSpeedMPerMin: Double,
        /** 平均速度の集計から「立ち止まっている」サンプルを除く下限 [m/s] */
        val minMovingSpeedMPerS: Double,
        /** 経路長に加算する最小の移動量 [m]。これ未満の差分は GPS の揺れとして捨てる */
        val pathSegmentMinM: Double,
        /** 実測に使う fix の水平精度の上限 [m] */
        val maxAccuracyForMetricsM: Double,
        /** 直線距離を歩く距離に直す係数。**経路データがあるときは使わない** */
        val detourFactor: Double,
        val returnReserveMin: Double,
        val softZoneRatio: Double,
        /** 散歩 1 回ぶんの平均速度をどれだけ取り込むか [0..1] */
        val speedEwmaWeight: Double,
        /** 平均速度を採用するのに要る「歩いている」サンプル数 */
        val speedMinSamples: Int,
        /** 速度の推定として認める範囲 [m/min] */
        val speedMinMPerMin: Double,
        val speedMaxMPerMin: Double,
    ) {
        val speedLimits: SpeedEstimator.Limits
            get() = SpeedEstimator.Limits(
                ewmaWeight = speedEwmaWeight, minSamples = speedMinSamples,
                minMPerMin = speedMinMPerMin, maxMPerMin = speedMaxMPerMin
            )

        val gaitLimits: GaitMetrics.Limits
            get() = GaitMetrics.Limits(
                minMovingSpeedMps = minMovingSpeedMPerS,
                minSegmentM = pathSegmentMinM,
                maxAccuracyM = maxAccuracyForMetricsM
            )
    }
}
