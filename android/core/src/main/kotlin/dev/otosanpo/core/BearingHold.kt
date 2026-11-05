package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * 位置から決まる向きの「揺れ」を落とす保持。
 * **iOS 版 `Sources/Core/BearingHold.swift` の移植**(式は 1 対 1 に保つ)。
 *
 * スポットの中心は動かないのに「小刻みに移動して聞こえる」のは、自分の位置の推定が
 * 揺れるため。実測(iOS・約 1 秒間隔の行の差)では 0〜5 m で平均 19.4°・最大 82° 動き、
 * 20 m より遠いと 1° 以下だった。
 *
 * ## 2 段で作る
 *
 * ```
 *  生の向き ──[遊び(不感帯)]──> 目標 ──[短い時定数で追従]──> 鳴らす向き
 * ```
 *
 * 遊びだけでは**入力が飛んだ時に出力も飛ぶ**。追従だけでは小さな揺れが遅れて出続ける。
 *
 * **位置は「新しい fix を見た時だけ」取り込む**([ingest])。
 * 音を付け直すたびに取り込むと、遊びがその回数ぶん進んでしまう。
 */
class BearingHold {

    data class Params(
        val minDeadbandDeg: Double,
        val maxDeadbandDeg: Double,
        val timeConstantSec: Double,
    )

    private var targetDeg: Double? = null
    private var outputDeg: Double? = null

    /** 遊びを抜けた先の目標 [deg](ログ用) */
    val target: Double? get() = targetDeg

    /** いま鳴らすべき向き [deg] */
    val deg: Double? get() = outputDeg

    /** **新しい位置を見た時だけ**呼ぶ。遊びを通して目標を動かす */
    fun ingest(deg: Double, uncertaintyDeg: Double = 0.0, p: Params) {
        if (!deg.isFinite()) return
        val fresh = Geo.normalizeDeg(deg)
        val current = targetDeg
        if (current == null) {
            targetDeg = fresh
            outputDeg = fresh
            return
        }
        val band = deadbandDeg(uncertaintyDeg, p)
        val diff = Geo.angularDiffDeg(fresh, current)
        if (diff > band) {
            targetDeg = Geo.normalizeDeg(fresh - band)
        } else if (diff < -band) {
            targetDeg = Geo.normalizeDeg(fresh + band)
        }
    }

    /**
     * **鳴らす向きを進める。** 音を付け直すたびに呼ぶ。
     * 経過時間だけで決まるので、呼ぶ回数を変えても同じ時刻には同じ値になる
     */
    fun output(afterSec: Double, p: Params): Double? {
        val target = targetDeg ?: return null
        val out = outputDeg ?: run {
            outputDeg = target
            return target
        }
        if (afterSec <= 0 || !afterSec.isFinite() || p.timeConstantSec <= 0) return out
        val k = 1 - exp(-afterSec / p.timeConstantSec)
        val moved = out + Geo.angularDiffDeg(target, out) * k
        outputDeg = Geo.normalizeDeg(moved)
        return outputDeg
    }

    /** 保持を捨てる(スポットを置き直した時など) */
    fun reset() {
        targetDeg = null
        outputDeg = null
    }

    companion object {
        /**
         * **位置の不確かさが張る角度** [deg]。
         * 水平精度 `accuracyM` の円が、距離 `distanceM` の相手に対して張る角度
         */
        fun uncertaintyDeg(accuracyM: Double, distanceM: Double): Double {
            if (accuracyM <= 0 || distanceM <= 0 ||
                !accuracyM.isFinite() || !distanceM.isFinite()
            ) {
                return 0.0
            }
            return atan(accuracyM / distanceM) * 180 / Math.PI
        }

        /** この標本に使う不感帯 [deg](下限と上限で挟む) */
        fun deadbandDeg(uncertaintyDeg: Double, p: Params): Double {
            val lo = max(0.0, p.minDeadbandDeg)
            val hi = max(lo, p.maxDeadbandDeg)
            return min(hi, max(lo, uncertaintyDeg))
        }
    }
}

/**
 * 「その人にとって真横に聞こえる角度」で音の置き方を合わせる。
 * **iOS 版 `Sources/Core/EarAngleMap.swift` の移植**。
 *
 * 正面(0°)・真横(合わせた角度)・真後ろ(180°)の **3 点を通る折れ線**。
 * 合わせた角度が 90° なら何もしない。
 */
data class EarAngleMap(val rightAnchorDeg: Double, val leftAnchorDeg: Double) {

    val isValid: Boolean
        get() = rightAnchorDeg.isFinite() && leftAnchorDeg.isFinite() &&
            rightAnchorDeg >= MIN_ANCHOR_DEG && rightAnchorDeg <= MAX_ANCHOR_DEG &&
            leftAnchorDeg >= MIN_ANCHOR_DEG && leftAnchorDeg <= MAX_ANCHOR_DEG

    /** 置きたい角度 [deg] を、その人に合わせた置き場所 [deg] へ写す */
    fun rendered(intendedDeg: Double): Double {
        if (!intendedDeg.isFinite()) return 0.0
        val d = Geo.angularDiffDeg(intendedDeg, 0.0)
        val side = if (d >= 0) rightAnchorDeg else leftAnchorDeg
        val magnitude = min(180.0, abs(d))
        if (magnitude <= 0) return 0.0
        val anchor = min(MAX_ANCHOR_DEG, max(MIN_ANCHOR_DEG, side))
        val mapped = if (magnitude <= 90) {
            magnitude * (anchor / 90)
        } else {
            anchor + (magnitude - 90) * (180 - anchor) / 90
        }
        return (if (d >= 0) 1 else -1) * mapped
    }

    companion object {
        const val MIN_ANCHOR_DEG = 20.0
        const val MAX_ANCHOR_DEG = 160.0
        val identity = EarAngleMap(rightAnchorDeg = 90.0, leftAnchorDeg = 90.0)
    }
}
