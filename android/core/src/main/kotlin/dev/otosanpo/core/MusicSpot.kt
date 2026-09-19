package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * 音楽の鳴る場所(→ docs/08)。**iOS 版 `Sources/Core/MusicSpot.swift` の移植**。
 *
 * **式は iOS と 1 対 1 に保つ。** 片方だけ直すと、同じ設定で違う鳴り方になり、
 * 実測の比較ができなくなる(docs/10 の移植方針)。
 *
 * ## Android 版で使わないもの(2026-09-19 利用者判断)
 *
 * **頭の向きは使わない。** 基準は進む向き(GPS の course)だけなので、
 * 首を振って探す前提の `facingDb`(正面の強調)は常に 0 になる。
 * 仰角と広がりは**水平距離だけで決まる**ので、頭の向きが無くてもそのまま効く。
 */
data class MusicSpot(val center: GeoPoint) {

    data class Params(
        val minDistanceM: Double,
        val maxDistanceM: Double,
        val distanceStepCount: Int,
        val reachedM: Double,
        val bearingStepDeg: Double,
        val sameDistanceToleranceM: Double,
        val referenceDistanceM: Double,
        val gainMinSpanM: Double,
        val maxGain: Double,
        val minGain: Double,
        val pinpointStartM: Double,
        val pinpointFullM: Double,
        val pinpointBeamDeg: Double,
        val pinpointDepthDb: Double,
        val directivityDepthDb: Double,
        val rearShelfStartDeg: Double,
        val rearShelfDepthDb: Double,
        /** 耳の高さ [m](スポットは地表にある)。0 で仰角を付けない */
        val listenerHeightM: Double,
        /** 広がりが最大になる距離 [m]。これより遠いと一番広い */
        val spreadFarM: Double,
        /** 広がりが消える距離 [m]。これより近いと一点に締まる */
        val spreadNearM: Double,
    ) {
        /** 帯の真ん中(置きたい距離) */
        val targetDistanceM: Double get() = (minDistanceM + maxDistanceM) / 2

        /**
         * 距離 `d` での音量。**鳴り始めた地点の距離 `start` で最小、
         * スポットの手前 `referenceDistanceM` で最大**とし、その間を dB で均等につなぐ
         */
        fun gain(atDistanceM: Double, fromDistanceM: Double): Double {
            val near = referenceDistanceM
            val far = max(fromDistanceM, near + gainMinSpanM)
            if (far <= near) return maxGain
            val t = (min(max(atDistanceM, near), far) - near) / (far - near)
            val maxDb = 20 * log10(maxGain)
            val minDb = 20 * log10(minGain)
            return 10.0.pow((maxDb - (maxDb - minDb) * t) / 20)
        }

        /** スポットの近さ [0..1]。`pinpointStartM` で 0、`pinpointFullM` で 1 */
        fun pinpointWeight(atDistanceM: Double): Double {
            if (pinpointStartM <= pinpointFullM) return if (atDistanceM <= pinpointFullM) 1.0 else 0.0
            val t = (pinpointStartM - atDistanceM) / (pinpointStartM - pinpointFullM)
            return min(1.0, max(0.0, t))
        }

        /**
         * 正面の強調 [dB]。**頭の向きを基準にしている時だけ意味がある**ので、
         * Android 版では呼ばない(進む向きが基準なので、首を回しても基準が動かない)
         */
        fun facingDb(relativeBearingDeg: Double, weight: Double): Double {
            if (weight <= 0 || pinpointDepthDb <= 0 || pinpointBeamDeg <= 0) return 0.0
            val off = abs(Geo.angularDiffDeg(relativeBearingDeg, 0.0))
            val w = min(1.0, weight)
            return -pinpointDepthDb * w * min(1.0, off / pinpointBeamDeg)
        }

        /** 向きで音量を割り振る [dB]。正面 0 → 真後ろ −`directivityDepthDb` */
        fun directivityDb(relativeBearingDeg: Double): Double {
            if (directivityDepthDb <= 0) return 0.0
            val t = (1 - cos(relativeBearingDeg * Math.PI / 180)) / 2
            return -directivityDepthDb * min(1.0, max(0.0, t))
        }

        /** 後ろの時に高域を落とす量 [dB] */
        fun rearShelfDb(relativeBearingDeg: Double): Double {
            if (rearShelfDepthDb <= 0 || rearShelfStartDeg >= 180) return 0.0
            val off = abs(Geo.angularDiffDeg(relativeBearingDeg, 0.0))
            if (off <= rearShelfStartDeg) return 0.0
            val t = min(1.0, (off - rearShelfStartDeg) / (180 - rearShelfStartDeg))
            return -rearShelfDepthDb * (1 - cos(Math.PI * t)) / 2
        }

        /**
         * **見下ろす角度** [deg]。負が下。水平距離 `d` と耳の高さ `h` から `−atan(h / d)`。
         *
         * **水平距離だけで決まる**ので、方位と違って位置の誤差に強い
         * (5 m で −16.7°・2 m で −36.9°・真上で −90°)
         */
        fun elevationDeg(horizontalDistanceM: Double): Double {
            if (listenerHeightM <= 0 || !horizontalDistanceM.isFinite()) return 0.0
            return -atan2(listenerHeightM, max(0.0, horizontalDistanceM)) * 180 / Math.PI
        }

        /** **音の広がり** [0..1]。1 = 遠くて広い・0 = 近くて一点 */
        fun spread(atDistanceM: Double): Double {
            if (spreadFarM <= spreadNearM || !atDistanceM.isFinite()) return 0.0
            if (atDistanceM >= spreadFarM) return 1.0
            if (atDistanceM <= spreadNearM) return 0.0
            val t = (atDistanceM - spreadNearM) / (spreadFarM - spreadNearM)
            return (1 - cos(Math.PI * t)) / 2
        }
    }

    /** 置いた結果 */
    data class Placement(
        val relDeg: Double,
        val gain: Double,
        val distanceGain: Double,
        val directivityDb: Double,
        val rearShelfDb: Double,
        val pinpointWeight: Double,
        val elevationDeg: Double,
        val spread: Double,
        val distanceM: Double,
        val worldBearingDeg: Double,
    )

    /** 着いたか(音は止めない。記録のためだけに見る) */
    fun isReached(from: GeoPoint, p: Params): Boolean =
        Geo.distanceM(from, center) <= p.reachedM

    /**
     * 鳴らし方を決める。
     *
     * @param directBearingDeg 揺れを落とした「自分 → スポット」の向き(→ [BearingHold])。
     *   null なら位置から素直に計算する
     */
    fun placement(
        from: GeoPoint,
        referenceBearingDeg: Double,
        directBearingDeg: Double? = null,
        gainFromDistanceM: Double,
        p: Params,
    ): Placement {
        val world = directBearingDeg ?: Geo.bearingDeg(from, center)
        val distance = Geo.distanceM(from, center)
        val weight = p.pinpointWeight(distance)
        val rel = Geo.angularDiffDeg(world, referenceBearingDeg)
        val distanceGain = p.gain(atDistanceM = distance, fromDistanceM = gainFromDistanceM)
        // **正面の強調は掛けない**(進む向きが基準なので、首を回しても基準が動かない)
        val directivity = p.directivityDb(rel)
        return Placement(
            relDeg = rel,
            gain = distanceGain * 10.0.pow(directivity / 20),
            distanceGain = distanceGain,
            directivityDb = directivity,
            rearShelfDb = p.rearShelfDb(rel),
            pinpointWeight = weight,
            elevationDeg = p.elevationDeg(distance),
            spread = p.spread(distance),
            distanceM = distance,
            worldBearingDeg = world,
        )
    }

    companion object {
        /** 置く場所の候補を、まわりに円状に並べる */
        fun candidates(around: GeoPoint, p: Params): List<GeoPoint> {
            if (p.bearingStepDeg <= 0 || p.distanceStepCount <= 0 ||
                p.maxDistanceM < p.minDistanceM
            ) {
                return emptyList()
            }
            val radii = if (p.distanceStepCount == 1) {
                listOf(p.targetDistanceM)
            } else {
                val span = p.maxDistanceM - p.minDistanceM
                (0 until p.distanceStepCount).map {
                    p.minDistanceM + span * it / (p.distanceStepCount - 1)
                }
            }
            val out = ArrayList<GeoPoint>()
            var bearing = 0.0
            while (bearing < 360) {
                for (radius in radii) {
                    out.add(Geo.destination(around, bearing, radius))
                }
                bearing += p.bearingStepDeg
            }
            return out
        }

        /** 候補から 1 つ選ぶ。**帯の外は選ばない**。同点なら並び順で最初のもの */
        fun choose(candidates: List<GeoPoint>, start: GeoPoint, p: Params): MusicSpot? {
            var bestPoint: GeoPoint? = null
            var bestError = Double.MAX_VALUE
            for (c in candidates) {
                val d = Geo.distanceM(start, c)
                if (d < p.minDistanceM || d > p.maxDistanceM) continue
                val error = abs(d - p.targetDistanceM)
                if (bestPoint == null || error < bestError - p.sameDistanceToleranceM) {
                    bestPoint = c
                    bestError = error
                }
            }
            return bestPoint?.let { MusicSpot(it) }
        }
    }
}
