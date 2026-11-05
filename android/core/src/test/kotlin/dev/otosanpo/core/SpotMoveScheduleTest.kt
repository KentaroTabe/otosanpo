package dev.otosanpo.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * スポットを移すイベントの日程(→ `SpotMoveSchedule`・docs/08)。
 *
 * **iOS 版(`Tests/SpotMoveScheduleTests.swift`)と同じ期待値で通ること。**
 * 片方だけ通る状態を作らない(docs/10)。
 *
 * 「ある程度時間が経ったらイベントが発生し、うなずくとスポット位置が変更される。
 * 拒否した場合はイベントまでの長さが倍々に増え、合意して移動したときは長さを同じにする」
 * (2026-09-18 利用者依頼)
 */
class SpotMoveScheduleTest {

    private fun params(base: Double = 180.0, delay: Double = 0.5, window: Double = 8.0) =
        SpotMoveSchedule.Params(baseIntervalSec = base, responseDelaySec = delay,
                                responseWindowSec = window)

    /** **音楽が鳴り始めた時から数える**(待っていた時間は含めない → 合議 E1) */
    @Test
    fun firstDeadlineIsBaseIntervalAfterTheMusicStarts() {
        val s = SpotMoveSchedule()
        s.start(1000.0, params())
        assertFalse(s.isDue(1179.0))
        assertTrue(s.isDue(1180.0))
        assertEquals(180.0, s.intervalSec, 1e-9)
    }

    /** 始める前は何も起きない */
    @Test
    fun nothingIsDueBeforeStart() {
        val s = SpotMoveSchedule()
        assertFalse(s.isDue(99999.0))
        assertFalse(s.acceptsResponse(99999.0))
    }

    /** **応答の窓は、鳴り終わってから待って開く**(→ 合議 E3) */
    @Test
    fun theResponseWindowOpensAfterThePromptFinishes() {
        val s = SpotMoveSchedule()
        val p = params(delay = 0.5, window = 8.0)
        s.start(0.0, p)
        s.prompted(200.0, p)
        assertFalse(s.acceptsResponse(200.4), "鳴り終わり直後はまだ受け付けない")
        assertTrue(s.acceptsResponse(200.5))
        assertTrue(s.acceptsResponse(208.4))
        assertFalse(s.acceptsResponse(208.5), "窓が閉じたら受け付けない")
        assertTrue(s.windowExpired(208.5))
    }

    /** 応答待ちの間は、次のイベントを出さない */
    @Test
    fun nothingIsDueWhileWaitingForAResponse() {
        val s = SpotMoveSchedule()
        val p = params()
        s.start(0.0, p)
        s.prompted(180.0, p)
        assertFalse(s.isDue(1000.0))
    }

    /** **合意したら間隔はそのまま**(→ 合議 E4) */
    @Test
    fun acceptingKeepsTheInterval() {
        val s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.accepted(185.0)
        assertEquals(180.0, s.intervalSec, 1e-9)
        assertEquals(1, s.moves)
        assertFalse(s.isDue(364.0))
        assertTrue(s.isDue(365.0), "移した時刻 + 現在の間隔")
    }

    /** **断ったら倍**(→ 合議 E5) */
    @Test
    fun refusingDoublesTheInterval() {
        val s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.refused(188.0)
        assertEquals(360.0, s.intervalSec, 1e-9)
        assertEquals(1, s.refusals)
        assertTrue(s.isDue(548.0), "応答が決まった時刻 + 新しい間隔")
    }

    /** **拒否 → 拒否 → 移動成功で 360 → 720 → 720**(→ 合議 E6) */
    @Test
    fun doublingSequence() {
        val s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.refused(190.0)
        assertEquals(360.0, s.intervalSec, 1e-9)
        s.prompted(550.0, p)
        s.refused(560.0)
        assertEquals(720.0, s.intervalSec, 1e-9)
        s.prompted(1280.0, p)
        s.accepted(1290.0)
        assertEquals(720.0, s.intervalSec, 1e-9, "合意では間隔を変えない")
    }

    /** **中断は断りに数えない**(→ 合議 E10) */
    @Test
    fun postponeDoesNotCountAsRefusal() {
        val s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.postpone(182.0)
        assertEquals(180.0, s.intervalSec, 1e-9)
        assertEquals(0, s.refusals)
        assertTrue(s.isDue(362.0))
    }

    /** 倍々を繰り返しても、短い間隔へ戻らない(→ 合議 E12) */
    @Test
    fun doublingNeverWrapsAround() {
        val s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        var t = 180.0
        repeat(80) {
            s.prompted(t, p)
            s.refused(t + 10)
            t += s.intervalSec
            assertTrue(s.intervalSec >= 180.0)
            assertTrue(s.intervalSec.isFinite())
        }
    }

    /** 止めたら予約も応答待ちも消える(→ 合議 E11) */
    @Test
    fun stopClearsEverything() {
        val s = SpotMoveSchedule()
        val p = params()
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.stop()
        assertFalse(s.isDue(10000.0))
        assertFalse(s.acceptsResponse(181.0))
        assertFalse(s.windowExpired(10000.0))
    }

    /** 新しい散歩は初期化された状態から始まる(→ 合議 E11) */
    @Test
    fun aNewWalkStartsFresh() {
        var s = SpotMoveSchedule()
        val p = params(base = 180.0)
        s.start(0.0, p)
        s.prompted(180.0, p)
        s.refused(190.0)
        s = SpotMoveSchedule()
        s.start(5000.0, p)
        assertEquals(180.0, s.intervalSec, 1e-9)
        assertEquals(0, s.refusals)
        assertEquals(0, s.moves)
    }

    /** 音が鳴り終わる長さは freqs の数から決まる(窓を開く時刻の根拠) */
    @Test
    fun toneDurationMatchesTheNumberOfBlips() {
        val tone = AppParameters.ToneSpec(
            freqsHz = listOf(698.5, 587.3, 698.5), blipSec = 0.1, gapSec = 0.06,
            noiseMix = 0.0, harmonics = 1, harmonicDecay = 0.7, attackRatio = 0.5)
        // 3 音 × 0.1 + 2 つの間 × 0.06
        assertEquals(0.42, tone.durationSec, 1e-9)
    }
}
