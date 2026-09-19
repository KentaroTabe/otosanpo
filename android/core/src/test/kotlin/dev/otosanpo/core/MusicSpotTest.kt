package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 音楽スポットの置き方(→ docs/08)。
 *
 * **iOS 版(`Tests/MusicSpotTests.swift`)と同じ期待値で通ること。**
 * 片方だけ通る状態を作らない(docs/10)。式が分かれた瞬間に、
 * 同じ設定で違う鳴り方になり、実測の比較ができなくなる。
 *
 * Android 版は**頭の向きを使わない**(2026-09-19 利用者判断)ので、
 * 正面の強調(`facingDb`)を使う場面は無い。仰角と広がりは距離だけで決まるので効く。
 */
class MusicSpotTest {
    private val origin = GeoPoint(35.0, 139.0)

    private fun params(
        min: Double = 75.0,
        max: Double = 105.0,
        steps: Int = 3,
        reached: Double = 15.0,
        step: Double = 30.0,
        tolerance: Double = 0.001,
        directivity: Double = 0.0,
        rearStart: Double = 90.0,
        rearDepth: Double = 0.0,
        height: Double = 0.0,
        spreadFar: Double = 0.0,
        spreadNear: Double = 0.0,
    ) = MusicSpot.Params(
        minDistanceM = min, maxDistanceM = max, distanceStepCount = steps,
        reachedM = reached, bearingStepDeg = step, sameDistanceToleranceM = tolerance,
        referenceDistanceM = 15.0, gainMinSpanM = 30.0,
        maxGain = 0.9, minGain = 0.08,
        pinpointStartM = 15.0, pinpointFullM = 5.0,
        pinpointBeamDeg = 60.0, pinpointDepthDb = 12.0,
        directivityDepthDb = directivity,
        rearShelfStartDeg = rearStart, rearShelfDepthDb = rearDepth,
        listenerHeightM = height, spreadFarM = spreadFar, spreadNearM = spreadNear,
    )

    @Test
    fun `gain rises from the starting distance to the spot`() {
        val p = params()
        // 鳴り始めた地点(90 m)で最小、手前(15 m)で最大
        assertEquals(0.08, p.gain(atDistanceM = 90.0, fromDistanceM = 90.0), 0.005)
        assertEquals(0.9, p.gain(atDistanceM = 15.0, fromDistanceM = 90.0), 0.005)
        // 途中は dB で均等(中点は幾何平均)
        val mid = p.gain(atDistanceM = 52.5, fromDistanceM = 90.0)
        assertEquals(kotlin.math.sqrt(0.08 * 0.9), mid, 0.01)
    }

    @Test
    fun `pinpoint weight ramps between the two distances`() {
        val p = params()
        assertEquals(0.0, p.pinpointWeight(atDistanceM = 20.0), 1e-9)
        assertEquals(0.0, p.pinpointWeight(atDistanceM = 15.0), 1e-9)
        assertEquals(0.5, p.pinpointWeight(atDistanceM = 10.0), 1e-9)
        assertEquals(1.0, p.pinpointWeight(atDistanceM = 5.0), 1e-9)
        assertEquals(1.0, p.pinpointWeight(atDistanceM = 1.0), 1e-9)
    }

    @Test
    fun `directivity allocates loudness by direction`() {
        val p = params(directivity = 9.0)
        assertEquals(0.0, p.directivityDb(0.0), 1e-9)
        assertEquals(-4.5, p.directivityDb(90.0), 0.01)
        assertEquals(-9.0, p.directivityDb(180.0), 0.01)
    }

    @Test
    fun `rear shelf only darkens behind`() {
        val p = params(rearStart = 90.0, rearDepth = 6.0)
        assertEquals(0.0, p.rearShelfDb(0.0), 1e-9)
        assertEquals(0.0, p.rearShelfDb(90.0), 1e-9)
        assertEquals(-6.0, p.rearShelfDb(180.0), 0.01)
        // 北をまたいでも同じ(200° は −160° と同じ)
        assertEquals(p.rearShelfDb(-160.0), p.rearShelfDb(200.0), 1e-9)
    }

    @Test
    fun `elevation deepens as you approach`() {
        val p = params(height = 1.5)
        assertEquals(-1.72, p.elevationDeg(horizontalDistanceM = 50.0), 0.05)
        assertEquals(-8.53, p.elevationDeg(horizontalDistanceM = 10.0), 0.05)
        assertEquals(-16.70, p.elevationDeg(horizontalDistanceM = 5.0), 0.05)
        assertEquals(-45.0, p.elevationDeg(horizontalDistanceM = 1.5), 0.05)
        assertEquals(-90.0, p.elevationDeg(horizontalDistanceM = 0.0), 0.05)
    }

    @Test
    fun `zero height means no elevation`() {
        assertEquals(0.0, params(height = 0.0).elevationDeg(horizontalDistanceM = 5.0), 1e-9)
    }

    @Test
    fun `spread narrows as you approach`() {
        val p = params(spreadFar = 60.0, spreadNear = 5.0)
        assertEquals(1.0, p.spread(atDistanceM = 100.0), 1e-9)
        assertEquals(1.0, p.spread(atDistanceM = 60.0), 1e-9)
        assertEquals(0.5, p.spread(atDistanceM = 32.5), 0.01)
        assertEquals(0.0, p.spread(atDistanceM = 5.0), 1e-9)
        assertEquals(0.0, p.spread(atDistanceM = 1.0), 1e-9)
    }

    @Test
    fun `spread is off when the range is not set`() {
        assertEquals(0.0, params(spreadFar = 0.0, spreadNear = 0.0).spread(atDistanceM = 30.0), 1e-9)
        assertEquals(0.0, params(spreadFar = 5.0, spreadNear = 60.0).spread(atDistanceM = 30.0), 1e-9)
    }

    @Test
    fun `placement carries elevation and spread`() {
        val p = params(height = 1.5, spreadFar = 60.0, spreadNear = 5.0)
        val spot = MusicSpot(Geo.destination(origin, 0.0, 10.0))
        val placed = spot.placement(
            from = origin, referenceBearingDeg = 0.0, gainFromDistanceM = 90.0, p = p,
        )
        assertEquals(-8.53, placed.elevationDeg, 0.1)
        assertEquals(p.spread(atDistanceM = placed.distanceM), placed.spread, 1e-9)
    }

    @Test
    fun `the relative bearing is measured from the reference`() {
        val p = params()
        val spot = MusicSpot(Geo.destination(origin, 90.0, 90.0))
        // 進む向きが北なら、真東のスポットは右 90°
        val east = spot.placement(
            from = origin, referenceBearingDeg = 0.0, gainFromDistanceM = 90.0, p = p,
        )
        assertEquals(90.0, east.relDeg, 1.0)
        // 進む向きが東なら正面
        val ahead = spot.placement(
            from = origin, referenceBearingDeg = 90.0, gainFromDistanceM = 90.0, p = p,
        )
        assertEquals(0.0, ahead.relDeg, 1.0)
    }

    @Test
    fun `a held bearing can be given from outside`() {
        val p = params()
        val spot = MusicSpot(Geo.destination(origin, 90.0, 90.0))
        val placed = spot.placement(
            from = origin, referenceBearingDeg = 0.0, directBearingDeg = 45.0,
            gainFromDistanceM = 90.0, p = p,
        )
        assertEquals(45.0, placed.worldBearingDeg, 1e-9)
        assertEquals(45.0, placed.relDeg, 1e-9)
    }

    @Test
    fun `candidates stay inside the band and choose picks the target distance`() {
        val p = params()
        val list = MusicSpot.candidates(origin, p)
        assertTrue(list.isNotEmpty())
        val spot = MusicSpot.choose(list, origin, p)
        assertNotNull(spot)
        val d = Geo.distanceM(origin, spot.center)
        assertTrue(d >= p.minDistanceM && d <= p.maxDistanceM, "帯の中に置くこと(得た距離 $d)")
        assertEquals(p.targetDistanceM, d, 1.0)
    }

    @Test
    fun `choose returns null when nothing is in the band`() {
        val p = params()
        val tooNear = listOf(Geo.destination(origin, 0.0, 5.0))
        assertNull(MusicSpot.choose(tooNear, origin, p))
    }

    @Test
    fun `reached uses the configured radius`() {
        val p = params(reached = 15.0)
        val spot = MusicSpot(Geo.destination(origin, 0.0, 10.0))
        assertTrue(spot.isReached(origin, p))
        val far = MusicSpot(Geo.destination(origin, 0.0, 30.0))
        assertTrue(!far.isReached(origin, p))
    }

    // MARK: - 置き直す時の選び方(2026-09-18 利用者依頼「特定の箇所に固まらないように」)

    /** **これまでに置いた所の近くは選ばない**(→ 合議 M2) */
    @Test
    fun `spread choice avoids previous spots`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val north = Geo.destination(origin, 0.0, 80.0)
        val candidates = MusicSpot.candidates(origin, p)
        // 北を避けると、北の候補は 1 つも選ばれない
        for (i in 0 until 12) {
            val spot = MusicSpot.chooseSpread(candidates, origin, listOf(north), 20.0, p) { i }
            assertNotNull(spot)
            assertTrue(Geo.distanceM(spot.center, north) >= 20.0)
        }
    }

    /**
     * ちょうどの距離は許す(→ 合議 M2)。
     *
     * **期待値は測った距離から作る。** `destination` で 20 m 先を作っても、
     * `distanceM` で測り返すと 20 m ちょうどにはならない(平面近似と haversine の往復)
     */
    @Test
    fun `exactly the separation is allowed`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val spotPoint = Geo.destination(origin, 0.0, 80.0)
        val away = Geo.destination(spotPoint, 90.0, 20.0)
        val measured = Geo.distanceM(spotPoint, away)
        assertEquals(20.0, measured, 0.05, "前提: ほぼ 20 m(実測 $measured)")
        assertNotNull(
            MusicSpot.chooseSpread(listOf(away), origin, listOf(spotPoint), measured, p) { 0 },
            "ちょうどの距離は残ること")
        assertNull(
            MusicSpot.chooseSpread(listOf(away), origin, listOf(spotPoint), measured + 0.01, p) { 0 },
            "それより近ければ外れること")
    }

    /** **北や先頭に固定的に寄らない**(→ 合議 M4) */
    @Test
    fun `spread choice can pick any eligible candidate`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val candidates = MusicSpot.candidates(origin, p)
        val seen = mutableSetOf<String>()
        for (i in 0 until 12) {
            val s = MusicSpot.chooseSpread(candidates, origin, emptyList(), 20.0, p) { i }
                ?: continue
            seen.add("%.4f,%.4f".format(s.center.latitude, s.center.longitude))
        }
        assertTrue(seen.size > 4, "選び先が散らばること(得た数 ${seen.size})")
    }

    /** 同じ地点に重なった候補は 1 票にまとめる(道へ寄せると重なる → 合議 M3) */
    @Test
    fun `duplicate points count once`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val a = Geo.destination(origin, 0.0, 80.0)
        val chosen = MusicSpot.chooseSpread(listOf(a, a, a), origin, emptyList(), 20.0, p) { count ->
            assertEquals(1, count, "3 つ渡しても 1 票")
            0
        }
        assertNotNull(chosen)
    }

    /** **選べなければ null。条件を黙って緩めない**(→ 合議 M5) */
    @Test
    fun `no eligible candidate returns null`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val candidates = MusicSpot.candidates(origin, p)
        // **全候補を避ければ**何も残らない
        assertNull(MusicSpot.chooseSpread(candidates, origin, candidates, 20.0, p) { 0 })
    }

    /** 帯の外は選ばない(既存の `choose` と同じ条件 → 合議 M1) */
    @Test
    fun `spread choice keeps the distance band`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val tooNear = Geo.destination(origin, 0.0, 30.0)
        val tooFar = Geo.destination(origin, 180.0, 300.0)
        assertNull(
            MusicSpot.chooseSpread(listOf(tooNear, tooFar), origin, emptyList(), 20.0, p) { 0 })
    }

    /** 範囲外の番号を返されても落ちない(挟み込む) */
    @Test
    fun `pick is clamped`() {
        val p = params(min = 60.0, max = 100.0, steps = 1)
        val candidates = MusicSpot.candidates(origin, p)
        assertNotNull(MusicSpot.chooseSpread(candidates, origin, emptyList(), 20.0, p) { 9999 })
        assertNotNull(MusicSpot.chooseSpread(candidates, origin, emptyList(), 20.0, p) { -5 })
    }
}
