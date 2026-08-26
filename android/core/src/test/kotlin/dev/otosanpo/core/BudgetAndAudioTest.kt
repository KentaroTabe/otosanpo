package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private val budget = AppParameters.Budget(
    walkingSpeedMPerMin = 70.0, minMovingSpeedMPerS = 0.5, pathSegmentMinM = 10.0,
    maxAccuracyForMetricsM = 20.0, detourFactor = 1.3, routeStraightMaxRatio = 2.0,
    returnReserveMin = 3.0,
    softZoneRatio = 0.7, speedEwmaWeight = 0.4, speedMinSamples = 60,
    speedMinMPerMin = 45.0, speedMaxMPerMin = 90.0
)

class ReturnBudgetTest {
    /** **経路長が取れるなら迂回率を掛けない。** 直線のときだけ掛ける */
    @Test
    fun `route distance is used as is and straight is inflated`() {
        assertEquals(500.0, ReturnBudget.Distance.Route(500.0).walkingM(budget), 1e-9)
        assertEquals(650.0, ReturnBudget.Distance.Straight(500.0).walkingM(budget), 1e-9)
    }

    @Test
    fun `estimated time divides by the measured speed`() {
        val d = ReturnBudget.Distance.Route(700.0)
        assertEquals(10.0, ReturnBudget.estimatedReturnMin(d, 70.0, budget), 1e-9)
        // 速度が 0 なら無限大(帰れない)
        assertTrue(ReturnBudget.estimatedReturnMin(d, 0.0, budget).isInfinite())
    }

    @Test
    fun `allowed radius shrinks with the remaining time`() {
        // (30 − 3) 分 × 70 / 1.3
        assertEquals(27 * 70 / 1.3, ReturnBudget.allowedRadiusM(30.0, 70.0, budget), 1e-6)
        // 予備時間より短ければ 0
        assertEquals(0.0, ReturnBudget.allowedRadiusM(2.0, 70.0, budget), 1e-9)
    }

    /** 「今帰り始めれば設定時間ちょうどに着く」瞬間で発火する */
    @Test
    fun `prompt fires when the remaining time equals the return estimate plus reserve`() {
        val d = ReturnBudget.Distance.Route(700.0)   // 70 m/min なら 10 分
        assertFalse(ReturnBudget.shouldPromptReturn(20.0, d, 70.0, budget))
        assertTrue(ReturnBudget.shouldPromptReturn(13.0, d, 70.0, budget))
        assertTrue(ReturnBudget.shouldPromptReturn(5.0, d, 70.0, budget))
    }

    // 経路長の跳ねを直線距離で抑える(2026-08-27 の iOS 実測に合わせる)

    /** ふつうの遠回りはそのまま通す。実測の比は中央 1.42 / 95% 1.68 */
    @Test
    fun `ordinary detour passes through`() {
        assertEquals(ReturnBudget.Distance.Route(760.0),
                     ReturnBudget.distance(760.0, 450.0, budget))
    }

    /**
     * **跳ねた経路長は上限で頭を押さえる。**
     * 実測値: 直線 543m に対し経路 1587m(2.92 倍)が 42 秒間だけ出た
     */
    @Test
    fun `spiked route is capped`() {
        assertEquals(ReturnBudget.Distance.CappedRoute(1086.0),
                     ReturnBudget.distance(1587.0, 543.0, budget))
    }

    /**
     * この修正が効くことの本体。**同じ場面で帰宅プロンプトが撃たれなくなる。**
     * 実測: 残り 26 分・65m/min・予備 3 分のところへ経路 1587m が出て発火した
     */
    @Test
    fun `spike no longer fires the prompt`() {
        val spiked = ReturnBudget.distance(1587.0, 543.0, budget)
        assertFalse(ReturnBudget.shouldPromptReturn(26.0, spiked, 65.0, budget))
        // 抑えなければ発火していた(iOS で実際に起きたこと)
        assertTrue(ReturnBudget.shouldPromptReturn(
            26.0, ReturnBudget.Distance.Route(1587.0), 65.0, budget))
    }

    /**
     * 抑えた後でも、直線 × 迂回率より大きい値が残る。
     * 川や線路の向こうで本当に大回りが要る場所を、過小評価にしないため
     */
    @Test
    fun `capped estimate stays above the straight line guess`() {
        val capped = ReturnBudget.estimatedReturnMin(
            ReturnBudget.distance(1587.0, 543.0, budget), 65.0, budget)
        val byStraight = ReturnBudget.estimatedReturnMin(
            ReturnBudget.Distance.Straight(543.0), 65.0, budget)
        assertTrue(capped > byStraight)
    }

    /** 経路データが無ければ直線距離に落ちる(圏外・地図未読込) */
    @Test
    fun `falls back to straight without route data`() {
        assertEquals(ReturnBudget.Distance.Straight(543.0),
                     ReturnBudget.distance(null, 543.0, budget))
    }

    /** 上限ちょうどは通す(境界) */
    @Test
    fun `exactly at the cap is still trusted`() {
        assertEquals(ReturnBudget.Distance.Route(1086.0),
                     ReturnBudget.distance(1086.0, 543.0, budget))
    }

    @Test
    fun `homeward bias stays zero inside the soft zone`() {
        val allowed = 1000.0
        assertEquals(0.0, ReturnBudget.homewardBias(500.0, allowed, budget), 1e-9)
        assertEquals(0.0, ReturnBudget.homewardBias(700.0, allowed, budget), 1e-9)
        assertEquals(0.5, ReturnBudget.homewardBias(850.0, allowed, budget), 1e-9)
        assertEquals(1.0, ReturnBudget.homewardBias(1000.0, allowed, budget), 1e-9)
        assertEquals(1.0, ReturnBudget.homewardBias(1500.0, allowed, budget), 1e-9)
    }

    /** 予算が尽きていれば、どこに居ても帰宅方向へ寄せる */
    @Test
    fun `homeward bias is one when there is no budget left`() {
        assertEquals(1.0, ReturnBudget.homewardBias(10.0, 0.0, budget), 1e-9)
    }
}

class SpeedEstimatorTest {
    private val limits = budget.speedLimits

    @Test
    fun `ignores a walk with too few samples`() {
        val e = SpeedEstimator()
        e.record(80.0, movingSamples = 10, limits = limits)
        assertEquals(null, e.mPerMin)
        assertEquals(0, e.walks)
    }

    @Test
    fun `first walk is adopted and later walks blend in`() {
        val e = SpeedEstimator()
        e.record(80.0, movingSamples = 100, limits = limits)
        assertEquals(80.0, e.mPerMin!!, 1e-9)
        e.record(60.0, movingSamples = 100, limits = limits)
        // 80 × 0.6 + 60 × 0.4
        assertEquals(72.0, e.mPerMin!!, 1e-9)
        assertEquals(2, e.walks)
    }

    /** **走った回に引きずられない。** 上限で丸める */
    @Test
    fun `clamps an unrealistic average`() {
        val e = SpeedEstimator()
        e.record(200.0, movingSamples = 100, limits = limits)
        assertEquals(90.0, e.mPerMin!!, 1e-9)
    }

    @Test
    fun `effective speed prefers the current walk then history then the setting`() {
        val e = SpeedEstimator()
        assertEquals(70.0, e.effectiveMPerMin(null, 0, 70.0, limits), 1e-9)
        e.record(80.0, movingSamples = 100, limits = limits)
        assertEquals(80.0, e.effectiveMPerMin(null, 0, 70.0, limits), 1e-9)
        assertEquals(65.0, e.effectiveMPerMin(65.0, 100, 70.0, limits), 1e-9)
    }
}

class GaitMetricsTest {
    private val limits = budget.gaitLimits
    private val origin = GeoPoint(35.0, 139.0)

    /** 水平精度が悪い fix は丸ごと捨てる(位置が飛んで経路長が水増しされるため) */
    @Test
    fun `rejects inaccurate fixes entirely`() {
        val m = GaitMetrics()
        m.add(origin, 1.2, 5.0, limits)
        m.add(Geo.destination(origin, 0.0, 50.0), 3.6, 69.0, limits)
        assertEquals(0.0, m.pathLengthM, 1e-9)
        assertEquals(1, m.rejectedSamples)
        assertEquals(1, m.movingSamples)
    }

    /** 揺れの範囲内の動きは経路長に積まない */
    @Test
    fun `drops jitter below the minimum segment`() {
        val m = GaitMetrics()
        m.add(origin, 1.2, 4.0, limits)
        m.add(Geo.destination(origin, 0.0, 3.0), 1.2, 4.0, limits)
        assertEquals(0.0, m.pathLengthM, 1e-9)
        m.add(Geo.destination(origin, 0.0, 12.0), 1.2, 4.0, limits)
        assertEquals(12.0, m.pathLengthM, 1.0)
    }

    @Test
    fun `average speed excludes standing still`() {
        val m = GaitMetrics()
        m.add(origin, 0.1, 4.0, limits)          // 立ち止まり
        m.add(Geo.destination(origin, 0.0, 12.0), 1.2, 4.0, limits)
        assertEquals(1, m.movingSamples)
        assertEquals(72.0, m.averageMovingSpeedMPerMin!!, 1e-9)
    }

    @Test
    fun `detour factor needs both lengths`() {
        val m = GaitMetrics()
        assertEquals(null, m.detourFactor(100.0))
        m.add(origin, 1.2, 4.0, limits)
        m.add(Geo.destination(origin, 0.0, 130.0), 1.2, 4.0, limits)
        assertEquals(1.3, m.detourFactor(100.0)!!, 0.05)
    }
}

class BeaconRhythmTest {
    private val p = BeaconRhythm.Params(
        stepsPerTone = 4.0, minIntervalSec = 1.0, maxIntervalSec = 4.0,
        fallbackIntervalSec = 2.0, gainFar = 0.45, gainNear = 1.0,
        nearDistanceM = 60.0, farDistanceM = 600.0
    )

    /** **間隔は歩調に同期する。** 1.74 歩/秒 なら 4 ÷ 1.74 ≒ 2.3 秒 */
    @Test
    fun `interval follows the cadence`() {
        assertEquals(2.30, BeaconRhythm.intervalSec(1.74, p), 0.01)
        assertEquals(2.0, BeaconRhythm.intervalSec(2.0, p), 1e-9)
    }

    @Test
    fun `interval is clamped and falls back without a cadence`() {
        assertEquals(2.0, BeaconRhythm.intervalSec(null, p), 1e-9)
        assertEquals(2.0, BeaconRhythm.intervalSec(0.0, p), 1e-9)
        assertEquals(1.0, BeaconRhythm.intervalSec(10.0, p), 1e-9)   // 走っても下限で止まる
        assertEquals(4.0, BeaconRhythm.intervalSec(0.5, p), 1e-9)    // 遅くても上限で止まる
    }

    /** **距離は音量で表す。** 近いほど大きい */
    @Test
    fun `gain rises as home gets closer`() {
        assertEquals(1.0, BeaconRhythm.gain(60.0, p), 1e-9)
        assertEquals(1.0, BeaconRhythm.gain(10.0, p), 1e-9)
        assertEquals(0.45, BeaconRhythm.gain(600.0, p), 1e-9)
        assertEquals(0.45, BeaconRhythm.gain(2000.0, p), 1e-9)
        assertTrue(BeaconRhythm.gain(300.0, p) in 0.45..1.0)
    }
}

class SoundPlacementTest {
    /** 真横で ±1、正面と真後ろがどちらも 0(前後の曖昧性) */
    @Test
    fun `pan is one at the sides and zero front and back`() {
        assertEquals(0.0, SoundPlacement.pan(0.0), 1e-9)
        assertEquals(1.0, SoundPlacement.pan(90.0), 1e-9)
        assertEquals(-1.0, SoundPlacement.pan(-90.0), 1e-9)
        assertTrue(abs(SoundPlacement.pan(180.0)) < 1e-9)
    }

    /** 正面 = −Z、右 = +X */
    @Test
    fun `position places the source on the unit circle`() {
        val front = SoundPlacement.position(0.0)
        assertEquals(0.0, front.x, 1e-9)
        assertEquals(-1.0, front.z, 1e-9)
        val right = SoundPlacement.position(90.0)
        assertEquals(1.0, right.x, 1e-9)
        assertEquals(0.0, right.z, 1e-9)
    }
}

class ReturnAckTest {
    /** 案内が始まれば「同意が伝わった」ことは伝わっている。上限を待たない */
    @Test
    fun `stops as soon as guidance starts`() {
        assertFalse(ReturnAck.shouldRepeat(directionStarted = true, elapsedSec = 1.0,
                                           durationSec = 60.0))
    }

    @Test
    fun `keeps going while no direction is available`() {
        assertTrue(ReturnAck.shouldRepeat(directionStarted = false, elapsedSec = 30.0,
                                          durationSec = 60.0))
    }

    @Test
    fun `stops at the upper bound`() {
        assertFalse(ReturnAck.shouldRepeat(directionStarted = false, elapsedSec = 60.0,
                                           durationSec = 60.0))
    }
}
