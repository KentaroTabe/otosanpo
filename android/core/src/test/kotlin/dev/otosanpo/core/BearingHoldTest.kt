package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 向きの揺れを落とす保持と、真横の角度の写像。
 * **iOS 版(`Tests/BearingHoldTests.swift` / `EarAngleMapTests.swift`)と同じ期待値**。
 */
class BearingHoldTest {

    private fun params(min: Double = 2.0, max: Double = 10.0, tau: Double = 0.25) =
        BearingHold.Params(minDeadbandDeg = min, maxDeadbandDeg = max, timeConstantSec = tau)

    private fun settled(h: BearingHold, p: BearingHold.Params): Double {
        repeat(40) { h.output(afterSec = 0.1, p = p) }
        return h.deg ?: Double.NaN
    }

    @Test
    fun `the first sample is adopted as is`() {
        val h = BearingHold()
        assertNull(h.deg)
        h.ingest(210.0, p = params())
        assertEquals(210.0, h.deg!!, 1e-9)
        assertEquals(210.0, h.target!!, 1e-9)
    }

    @Test
    fun `jitter inside the band is rejected completely`() {
        val h = BearingHold()
        val p = params(min = 5.0)
        h.ingest(200.0, p = p)
        for (d in listOf(202.0, 198.0, 203.0, 197.0, 201.0, 204.0, 196.0)) {
            h.ingest(d, p = p)
            assertEquals(200.0, h.target!!, 1e-9)
        }
        assertEquals(200.0, settled(h, p), 1e-9)
    }

    @Test
    fun `exactly at the band keeps the target`() {
        val h = BearingHold()
        val p = params(min = 5.0)
        h.ingest(0.0, p = p)
        h.ingest(5.0, p = p)
        assertEquals(0.0, h.target!!, 1e-9)
    }

    @Test
    fun `the target moves only by the excess`() {
        val h = BearingHold()
        val p = params(min = 5.0)
        h.ingest(0.0, p = p)
        h.ingest(4.0, p = p)
        assertEquals(0.0, h.target!!, 1e-9)
        h.ingest(8.0, p = p)
        assertEquals(3.0, h.target!!, 1e-9)
    }

    @Test
    fun `it wraps around north`() {
        val h = BearingHold()
        val p = params(min = 5.0)
        h.ingest(359.0, p = p)
        h.ingest(1.0, p = p)
        assertEquals(359.0, h.target!!, 1e-9)
        h.ingest(10.0, p = p)
        assertEquals(5.0, h.target!!, 1e-9)
    }

    @Test
    fun `repeating the same measurement does not advance the target`() {
        val h = BearingHold()
        val p = params(min = 5.0)
        h.ingest(0.0, p = p)
        repeat(50) { h.ingest(20.0, p = p) }
        assertEquals(15.0, h.target!!, 1e-9)
    }

    @Test
    fun `the deadband comes from the position uncertainty`() {
        assertEquals(30.96, BearingHold.uncertaintyDeg(accuracyM = 3.0, distanceM = 5.0), 0.05)
        assertEquals(8.53, BearingHold.uncertaintyDeg(accuracyM = 3.0, distanceM = 20.0), 0.05)
    }

    @Test
    fun `the deadband is clamped`() {
        val p = params(min = 2.0, max = 10.0)
        assertEquals(2.0, BearingHold.deadbandDeg(0.0, p), 1e-9)
        assertEquals(6.0, BearingHold.deadbandDeg(6.0, p), 1e-9)
        assertEquals(10.0, BearingHold.deadbandDeg(70.0, p), 1e-9)
    }

    @Test
    fun `the output does not jump when the target moves`() {
        val h = BearingHold()
        val p = params(min = 5.0, tau = 0.25)
        h.ingest(0.0, p = p)
        h.ingest(90.0, p = p)
        assertEquals(85.0, h.target!!, 1e-9)
        val step = h.output(afterSec = 0.02, p = p)!!
        assertTrue(step > 0 && step < 20, "1 コマで目標へ飛ばないこと(得た値 $step)")
        assertEquals(85.0, settled(h, p), 0.01)
    }

    @Test
    fun `the output depends on elapsed time not on update count`() {
        val p = params(min = 5.0, tau = 0.25)
        val sparse = BearingHold()
        val dense = BearingHold()
        sparse.ingest(0.0, p = p); dense.ingest(0.0, p = p)
        sparse.ingest(100.0, p = p); dense.ingest(100.0, p = p)
        repeat(5) { sparse.output(afterSec = 0.1, p = p) }
        repeat(50) { dense.output(afterSec = 0.01, p = p) }
        assertEquals(sparse.deg!!, dense.deg!!, 0.6)
    }

    @Test
    fun `it catches up fast enough to follow a pass`() {
        val h = BearingHold()
        val p = params(min = 2.0, max = 10.0, tau = 0.25)
        h.ingest(0.0, p = p)
        h.ingest(180.0, p = p)
        repeat(15) { h.output(afterSec = 0.1, p = p) }
        val err = abs(Geo.angularDiffDeg(h.deg!!, 180.0))
        assertTrue(err <= 11, "1.5 秒で 11° 以内へ寄ること(実測 $err)")
    }

    @Test
    fun `reset forgets everything`() {
        val h = BearingHold()
        val p = params()
        h.ingest(200.0, p = p)
        h.reset()
        assertNull(h.deg)
        assertNull(h.target)
        h.ingest(20.0, p = p)
        assertEquals(20.0, h.deg!!, 1e-9)
    }

    // MARK: - 真横に聞こえる角度

    @Test
    fun `ninety means identity`() {
        val m = EarAngleMap.identity
        var deg = -180.0
        while (deg <= 180.0) {
            assertEquals(deg, m.rendered(deg), 1e-6)
            deg += 15.0
        }
    }

    @Test
    fun `front and back are fixed`() {
        val m = EarAngleMap(rightAnchorDeg = 130.0, leftAnchorDeg = 55.0)
        assertEquals(0.0, m.rendered(0.0), 1e-9)
        assertEquals(180.0, abs(m.rendered(180.0)), 1e-6)
    }

    @Test
    fun `ninety goes to the anchor`() {
        val m = EarAngleMap(rightAnchorDeg = 120.0, leftAnchorDeg = 70.0)
        assertEquals(120.0, m.rendered(90.0), 0.01)
        assertEquals(-70.0, m.rendered(-90.0), 0.01)
    }

    @Test
    fun `intermediate angles open together`() {
        val m = EarAngleMap(rightAnchorDeg = 120.0, leftAnchorDeg = 120.0)
        assertEquals(60.0, m.rendered(45.0), 0.01)
        assertEquals(40.0, m.rendered(30.0), 0.01)
        assertEquals(150.0, m.rendered(135.0), 0.01)
    }

    @Test
    fun `the slope near the front is bounded`() {
        val m = EarAngleMap(rightAnchorDeg = 130.0, leftAnchorDeg = 60.0)
        assertEquals(0.05 * 130 / 90, m.rendered(0.05), 1e-6)
        assertTrue(m.rendered(1.0) < 2.0)
    }

    @Test
    fun `validity is checked`() {
        assertTrue(EarAngleMap(20.0, 160.0).isValid)
        assertTrue(!EarAngleMap(10.0, 90.0).isValid)
        assertTrue(!EarAngleMap(170.0, 90.0).isValid)
        assertTrue(!EarAngleMap(Double.NaN, 90.0).isValid)
    }
}
