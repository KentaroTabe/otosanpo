package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * 1 つの「曲がるイベント」に対する連続音の作り方を決める純粋ロジック。
 *
 * 設計の要点は 3 つ(いずれも実測から決まったもの。docs/03):
 * 1. **距離は音量で表す。** 間隔の変化では距離として伝わらなかった
 * 2. **音量の頂点は角そのものではなく手前に置く。** 曲がっている最中に頂点が来ていた
 * 3. **向きのブレンドは片道。** 通過後に角へ戻すと、右に曲がった直後に音が左へ流れる
 */
class TurnGuidance(
    val corner: GeoPoint,
    /** 曲がった先へ踏み出す絶対方位 */
    val branchBearingDeg: Double,
    distanceM: Double,
) {
    data class Params(
        /** 補間と音量の起点となる距離 [m] */
        val startDistanceM: Double,
        /** ここで音量が最大になり、向きも曲がる先を指し切る [m] */
        val peakBeforeM: Double,
        /** 音の間隔 [sec](固定) */
        val intervalSec: Double,
        val gainFar: Double,
        val gainNear: Double,
        /** 角からこの距離以上離れたら終える [m] */
        val endDistanceM: Double,
        /** 最接近点からこれ以上遠ざかったら終える [m] */
        val leftBehindM: Double,
        /** 進行方位と曲がる先の差がこれ以内になったら「曲がり終えた」 [deg] */
        val turnedWithinDeg: Double,
        /** 曲がり終えた後、音量を落としながら鳴らす音の数 */
        val closingTones: Int,
        /** 冒頭に「曲がる先」を指す音の数。0 で無効 */
        val announceTones: Int = 1,
        /** 角への方位が進行方向からこれ以上離れたら止める [deg] */
        val abandonBehindDeg: Double = 100.0,
    )

    /** 誘導が終わった理由。ログの読み手が「うまくいったのか」を判別できるようにする */
    enum class Ending(val label: String) {
        /** 曲がり終えた(狙いどおりの終わり方) */
        TURNED("曲がり終えた"),

        /** 角に寄らないまま離れた */
        LEFT_BEHIND("角から離れた"),

        /** 角が背後に回った = 従わなかったことがはっきりした */
        DECLINED("従わなかった"),
    }

    /** 1 音ぶんの指示 */
    data class Step(
        /** 鳴らす向き(絶対方位) */
        val targetBearingDeg: Double,
        val gain: Double,
        val intervalSec: Double,
        val distanceM: Double,
        /** 終端(曲がり終えた後の減衰)の音か */
        val isClosing: Boolean,
        /** 冒頭の「どちらへ曲がるか」を告げる音か */
        val isAnnouncing: Boolean = false,
    )

    sealed interface Outcome {
        data class Play(val step: Step) : Outcome
        data class Finished(val ending: Ending) : Outcome
    }

    /** これまでの最接近距離 [m] */
    var closestM: Double = distanceM
        private set

    /** 補間係数。1 = 角を指す、0 = 曲がる先を指す。**単調にしか減らない** */
    private var blend: Double = 1.0
    private var closingLeft: Int? = null
    private var announced: Int = 0

    companion object {
        /**
         * その角はもう背後か。**角に寄る前に背後へ回ったら、従わなかったということ。**
         *
         * 90° を超えるとは幾何的に「その角から遠ざかっている」ということで、
         * そこを指し続けるのは「戻れ」と言っているのと同じ = 叱っている(docs/01)。
         *
         * **始める前にも同じ判定を通せるよう公開する。**
         */
        fun isBehind(corner: GeoPoint, from: GeoPoint, travelBearingDeg: Double?,
                     closestM: Double, p: Params): Boolean {
            if (closestM <= p.peakBeforeM || travelBearingDeg == null) return false
            val toCorner = Geo.bearingDeg(from, corner)
            return abs(Geo.angularDiffDeg(toCorner, travelBearingDeg)) >= p.abandonBehindDeg
        }
    }

    /**
     * 曲がり終えたと判断できるか。**角まで寄ったうえで**、
     * 進行方位が曲がる先に揃ったときだけ成立させる。
     */
    private fun hasTurned(travelBearingDeg: Double?, p: Params): Boolean {
        if (closestM > p.peakBeforeM || travelBearingDeg == null) return false
        return abs(Geo.angularDiffDeg(branchBearingDeg, travelBearingDeg)) <= p.turnedWithinDeg
    }

    /** 次の 1 音を決める。位置更新ではなく**音を鳴らす直前**に呼ぶ */
    fun next(position: GeoPoint, travelBearingDeg: Double?, p: Params): Outcome {
        val d = Geo.distanceM(position, corner)
        closestM = min(closestM, d)

        // 終端に入っていれば、残りを鳴らして終わる。距離による打ち切りより優先する
        val left = closingLeft
        if (left != null) {
            if (left <= 0) return Outcome.Finished(Ending.TURNED)
            closingLeft = left - 1
            val step = left.toDouble() / (p.closingTones + 1)
            return Outcome.Play(
                Step(branchBearingDeg, p.gainNear * step, p.intervalSec, d, isClosing = true)
            )
        }

        if (hasTurned(travelBearingDeg, p)) {
            if (p.closingTones <= 0) return Outcome.Finished(Ending.TURNED)
            closingLeft = p.closingTones - 1
            return Outcome.Play(
                Step(branchBearingDeg,
                     p.gainNear * p.closingTones / (p.closingTones + 1),
                     p.intervalSec, d, isClosing = true)
            )
        }

        if (d > p.endDistanceM) return Outcome.Finished(Ending.LEFT_BEHIND)
        if (d > closestM + p.leftBehindM) return Outcome.Finished(Ending.LEFT_BEHIND)

        if (isBehind(corner, position, travelBearingDeg, closestM, p)) {
            return Outcome.Finished(Ending.DECLINED)
        }

        // **冒頭の数音は曲がる先を指す。** 1 音目は前の音が無いので、
        // それ単独で「どちらへ曲がるか」を伝える必要がある
        if (announced < p.announceTones) {
            announced += 1
            return Outcome.Play(
                Step(branchBearingDeg, p.gainFar, p.intervalSec, d,
                     isClosing = false, isAnnouncing = true)
            )
        }

        // **補間は片道。** 一度詰まった向きは、離れても角へ戻さない
        val span = p.startDistanceM - p.peakBeforeM
        val raw = if (span > 0) min(1.0, max(0.0, (d - p.peakBeforeM) / span)) else 0.0
        blend = min(blend, raw)

        val toCorner = Geo.bearingDeg(position, corner)
        val target = Geo.normalizeDeg(
            branchBearingDeg + Geo.angularDiffDeg(toCorner, branchBearingDeg) * blend
        )
        val gain = p.gainFar + (p.gainNear - p.gainFar) * (1 - blend)
        return Outcome.Play(Step(target, gain, p.intervalSec, d, isClosing = false))
    }
}

/**
 * 角速度から「頭が進行方向からどれだけ横を向いているか」を短い窓で推定する。
 *
 * **姿勢ではなく角速度を使う。** iOS の実測(2026-08-19)で、AirPods の `attitude.yaw` は
 * 旋回そのものを追えていなかった。角速度は基準の取り直しや飛びの影響を受けない。
 *
 * **絶対方位は作れない。作らない。** ジャイロは角速度しか出せず、積分すれば必ず
 * ドリフトする。そこで**時間で 0 へ戻す**。根拠は「頭は平均すれば正面を向く」で、
 * 必要なのは「音のする方を見た数秒」だけだから成り立つ(docs/08)。
 */
class HeadTracker {
    data class Params(
        /** 推定が 0 へ戻る半減期 [sec] */
        val halfLifeSec: Double,
        /** 首の相対角として認める上限 [deg] */
        val maxOffsetDeg: Double,
        /** これ未満の角速度は 0 とみなす [deg/sec] */
        val deadbandDegPerSec: Double,
        /** 角速度の向きを「右が正」に合わせる符号(+1 / −1) */
        val sign: Double,
        /** サンプルの間隔がこれを超えたら積分しない [sec] */
        val maxGapSec: Double,
    )

    /** 進行方向を 0 とした顔の向き [deg]。右が正 */
    var offsetDeg: Double = 0.0
        private set

    /** 減衰を掛けない生の積分 [deg]。**ジャイロが旋回を追えているかの検証に使う** */
    var rotationDeg: Double = 0.0
        private set

    private var lastTime: Double? = null

    fun ingest(yawRateDegPerSec: Double, time: Double, p: Params): Double {
        val last = lastTime
        lastTime = time
        if (last == null) return offsetDeg
        val dt = time - last
        // 時刻が戻った・間が空きすぎた場合は、間の回転を知らないので積分しない
        if (dt <= 0 || dt > p.maxGapSec) return offsetDeg

        val r = if (abs(yawRateDegPerSec) < p.deadbandDegPerSec) 0.0 else yawRateDegPerSec
        val turned = p.sign * r * dt
        rotationDeg += turned
        offsetDeg += turned
        if (p.halfLifeSec > 0) offsetDeg *= 0.5.pow(dt / p.halfLifeSec)
        offsetDeg = max(-p.maxOffsetDeg, min(p.maxOffsetDeg, offsetDeg))
        return offsetDeg
    }

    /** 生の積分を読み出して 0 に戻す(ログに一定間隔で出すため) */
    fun takeRotation(): Double {
        val v = rotationDeg
        rotationDeg = 0.0
        return v
    }

    fun reset() {
        offsetDeg = 0.0
        rotationDeg = 0.0
        lastTime = null
    }
}
