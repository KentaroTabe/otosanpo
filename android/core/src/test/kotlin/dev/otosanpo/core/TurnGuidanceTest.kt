package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** iOS 版 `TurnGuidanceTests` と同じ期待値。誘導の 3 つの欠陥への対処を固定する */
class TurnGuidanceTest {
    private val origin = GeoPoint(35.0, 137.0)
    private val corner get() = Geo.destination(origin, 0.0, 35.0)
    private val branchDeg = 90.0

    private val p = TurnGuidance.Params(
        startDistanceM = 35.0, peakBeforeM = 10.0, intervalSec = 1.2,
        gainFar = 0.3, gainNear = 1.0, endDistanceM = 45.0, leftBehindM = 12.0,
        turnedWithinDeg = 25.0, closingTones = 3
    )

    private fun guidance(d: Double = 35.0) = TurnGuidance(corner, branchDeg, d)

    /** 角までの距離 [m] の地点(角の南側 = 手前) */
    private fun approach(d: Double) = Geo.destination(corner, 180.0, d)

    private fun play(g: TurnGuidance, at: GeoPoint, travel: Double?): TurnGuidance.Step? =
        (g.next(at, travel, p) as? TurnGuidance.Outcome.Play)?.step

    /** **1 音目だけは曲がる先を指す**(前の音が無いので単独で向きを伝える必要がある) */
    @Test
    fun `first tone announces the turn direction`() {
        val g = guidance()
        val first = play(g, approach(35.0), 0.0)
        assertNotNull(first)
        assertEquals(branchDeg, first.targetBearingDeg, 1e-6)
        assertTrue(first.isAnnouncing)
    }

    @Test
    fun `announcement happens only once`() {
        val g = guidance()
        play(g, approach(35.0), 0.0)
        val second = play(g, approach(33.0), 0.0)
        assertNotNull(second)
        assertFalse(second.isAnnouncing)
    }

    /** **間隔は固定。音量で近さを表す** */
    @Test
    fun `interval is constant and gain rises toward the corner`() {
        val g = guidance()
        play(g, approach(35.0), 0.0)   // 予告
        val far = play(g, approach(30.0), 0.0)
        val near = play(g, approach(15.0), 0.0)
        assertNotNull(far); assertNotNull(near)
        assertEquals(p.intervalSec, far.intervalSec, 1e-9)
        assertEquals(p.intervalSec, near.intervalSec, 1e-9)
        assertTrue(near.gain > far.gain, "near=${near.gain} far=${far.gain}")
    }

    /** **頂点は角そのものではなく手前。** 以降は維持する */
    @Test
    fun `gain peaks before the corner and holds`() {
        val g = guidance()
        play(g, approach(35.0), 0.0)
        val atPeak = play(g, approach(10.0), 0.0)
        val closer = play(g, approach(5.0), 0.0)
        assertNotNull(atPeak); assertNotNull(closer)
        assertEquals(p.gainNear, atPeak.gain, 1e-6)
        assertEquals(p.gainNear, closer.gain, 1e-6)
    }

    /** 遠いうちは角を指し、近づくと曲がる先を指し切る */
    @Test
    fun `points at the corner when far and at the branch when near`() {
        val g = guidance()
        play(g, approach(35.0), 0.0)   // 予告を消費
        val far = play(g, approach(34.0), 0.0)
        assertNotNull(far)
        // 角は真北にあるので、遠い時点の向きは 0° 寄り
        assertTrue(abs(Geo.angularDiffDeg(far.targetBearingDeg, 0.0)) < 30.0,
                   "far=${far.targetBearingDeg}")
        val near = play(g, approach(8.0), 0.0)
        assertNotNull(near)
        assertEquals(branchDeg, near.targetBearingDeg, 1e-6)
    }

    /** **通過後に角へ戻さない**(右に曲がった直後に音が左へ流れる欠陥) */
    @Test
    fun `does not swing back to the corner after passing it`() {
        val g = guidance()
        for (d in listOf(35.0, 25.0, 15.0, 8.0)) play(g, approach(d), 0.0)
        // 角を東へ 5 m 抜けた地点。角は背後(西)になる
        val past = Geo.destination(corner, 90.0, 5.0)
        val step = play(g, past, branchDeg)
        assertNotNull(step)
        assertEquals(branchDeg, step.targetBearingDeg, 1e-6)
    }

    /** 曲がり終えたら数音かけて閉じる */
    @Test
    fun `closing tones fade out after the turn is complete`() {
        val g = guidance()
        for (d in listOf(35.0, 25.0, 15.0, 8.0, 4.0)) play(g, approach(d), 0.0)
        val past = Geo.destination(corner, 90.0, 6.0)
        val gains = mutableListOf<Double>()
        var outcome = g.next(past, branchDeg, p)
        while (outcome is TurnGuidance.Outcome.Play) {
            assertTrue(outcome.step.isClosing)
            gains.add(outcome.step.gain)
            outcome = g.next(past, branchDeg, p)
        }
        assertEquals(TurnGuidance.Ending.TURNED, (outcome as TurnGuidance.Outcome.Finished).ending)
        assertEquals(p.closingTones, gains.size)
        assertTrue(gains.zipWithNext().all { (a, b) -> b < a }, "gains=$gains")
    }

    /** **角が背後に回ったら止める**(指し続けるのは「戻れ」= 叱っている) */
    @Test
    fun `stops once the corner is behind`() {
        val g = guidance(30.0)
        play(g, approach(30.0), 0.0)
        val past = Geo.destination(corner, 135.0, 20.0)
        val outcome = g.next(past, 90.0, p)
        assertEquals(TurnGuidance.Ending.DECLINED,
                     (outcome as TurnGuidance.Outcome.Finished).ending)
    }

    /** **角まで寄った後は対象外**(曲がっている最中は背後になるのが当たり前) */
    @Test
    fun `does not abandon while turning at the corner`() {
        val g = guidance()
        var d = 35.0
        while (d >= 4.0) { play(g, approach(d), 0.0); d -= 1.0 }
        val past = Geo.destination(corner, 90.0, 10.0)
        val step = play(g, past, branchDeg)
        assertNotNull(step)
        assertTrue(step.isClosing, "曲がり終えた直後に打ち切ってはいけない")
    }

    /** **始める前にも同じ判定を通せる**(1 音も鳴らさない誘導を作らないため) */
    @Test
    fun `isBehind answers the same question before starting`() {
        val past = Geo.destination(corner, 135.0, 20.0)
        assertTrue(TurnGuidance.isBehind(corner, past, 90.0, 20.0, p))
        assertFalse(TurnGuidance.isBehind(corner, approach(30.0), 0.0, 30.0, p))
        assertFalse(TurnGuidance.isBehind(corner, past, 90.0, p.peakBeforeM, p))
        assertFalse(TurnGuidance.isBehind(corner, past, null, 20.0, p))
    }

    @Test
    fun `finishes when leaving without approaching`() {
        val g = guidance(33.0)
        play(g, approach(33.0), 180.0)
        val outcome = g.next(approach(46.0), 180.0, p)
        assertEquals(TurnGuidance.Ending.LEFT_BEHIND,
                     (outcome as TurnGuidance.Outcome.Finished).ending)
    }

    @Test
    fun `tracks the closest approach`() {
        val g = guidance()
        play(g, approach(35.0), 0.0)
        play(g, approach(12.0), 0.0)
        play(g, approach(20.0), 0.0)
        assertEquals(12.0, g.closestM, 1.0)
    }
}

/** iOS 版 `HeadTrackerTests` と同じ期待値 */
class HeadTrackerTest {
    private val p = HeadTracker.Params(halfLifeSec = 4.0, maxOffsetDeg = 90.0,
                                       deadbandDegPerSec = 3.0, sign = 1.0, maxGapSec = 0.5)

    @Test
    fun `integrates rotation into an offset`() {
        val t = HeadTracker()
        var time = 0.0
        t.ingest(0.0, time, p)
        repeat(10) { time += 0.02; t.ingest(90.0, time, p) }
        assertEquals(18.0, t.offsetDeg, 1.0)
    }

    /** **絶対基準を持たないので、放っておけば 0 へ戻る**(ドリフト対策) */
    @Test
    fun `decays back to zero when the head stops`() {
        val t = HeadTracker()
        var time = 0.0
        t.ingest(0.0, time, p)
        repeat(10) { time += 0.02; t.ingest(90.0, time, p) }
        val turned = t.offsetDeg
        repeat(200) { time += 0.02; t.ingest(0.0, time, p) }   // 4 秒 = 半減期 1 つ
        assertEquals(turned / 2, t.offsetDeg, turned * 0.1)
    }

    @Test
    fun `ignores drift below the deadband`() {
        val t = HeadTracker()
        var time = 0.0
        t.ingest(0.0, time, p)
        repeat(500) { time += 0.02; t.ingest(2.0, time, p) }
        assertEquals(0.0, t.offsetDeg, 0.001)
    }

    @Test
    fun `clamps to the maximum offset`() {
        val t = HeadTracker()
        var time = 0.0
        t.ingest(0.0, time, p)
        repeat(100) { time += 0.02; t.ingest(500.0, time, p) }
        assertTrue(abs(t.offsetDeg) <= p.maxOffsetDeg)
    }

    /** **間が空いたら積分しない**(外していた間の回転は分からない) */
    @Test
    fun `skips gaps that are too long`() {
        val t = HeadTracker()
        t.ingest(0.0, 0.0, p)
        t.ingest(90.0, 5.0, p)
        assertEquals(0.0, t.offsetDeg, 0.001)
        t.ingest(90.0, 5.02, p)
        assertTrue(t.offsetDeg > 0)
    }

    /** 減衰なしの積分は別に持つ(ジャイロが旋回を追えているかの検証用) */
    @Test
    fun `keeps an undecayed rotation for verification`() {
        val t = HeadTracker()
        var time = 0.0
        t.ingest(0.0, time, p)
        repeat(100) { time += 0.02; t.ingest(45.0, time, p) }
        assertEquals(90.0, t.rotationDeg, 1.0)
        assertTrue(t.offsetDeg < t.rotationDeg)
        val taken = t.takeRotation()
        assertEquals(90.0, taken, 1.0)
        assertEquals(0.0, t.rotationDeg, 1e-9)
    }
}
