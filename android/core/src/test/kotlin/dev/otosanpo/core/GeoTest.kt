package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * iOS 版と**同じ期待値**で通ること。片方だけ通る状態を作らない(docs/10)。
 */
class GeoTest {
    private val origin = GeoPoint(35.0, 139.0)

    @Test
    fun `distance matches the metre scale`() {
        // 緯度 1 度 ≒ 111.32 km
        val north = GeoPoint(35.001, 139.0)
        assertEquals(111.32, Geo.distanceM(origin, north), 0.5)
    }

    @Test
    fun `bearing is north zero and east ninety`() {
        assertEquals(0.0, Geo.bearingDeg(origin, Geo.destination(origin, 0.0, 100.0)), 0.5)
        assertEquals(90.0, Geo.bearingDeg(origin, Geo.destination(origin, 90.0, 100.0)), 0.5)
        assertEquals(180.0, Geo.bearingDeg(origin, Geo.destination(origin, 180.0, 100.0)), 0.5)
        assertEquals(270.0, Geo.bearingDeg(origin, Geo.destination(origin, 270.0, 100.0)), 0.5)
    }

    @Test
    fun `angular difference wraps at the boundary`() {
        assertEquals(-20.0, Geo.angularDiffDeg(350.0, 10.0), 1e-9)
        assertEquals(20.0, Geo.angularDiffDeg(10.0, 350.0), 1e-9)
        assertEquals(180.0, abs(Geo.angularDiffDeg(0.0, 180.0)), 1e-9)
    }

    @Test
    fun `normalize keeps the angle inside one turn`() {
        assertEquals(10.0, Geo.normalizeDeg(370.0), 1e-9)
        assertEquals(350.0, Geo.normalizeDeg(-10.0), 1e-9)
    }

    @Test
    fun `nearest point projects onto the segment`() {
        val a = origin
        val b = Geo.destination(origin, 90.0, 100.0)
        // 線分の中ほどの 10 m 北にある点
        val p = Geo.destination(Geo.destination(origin, 90.0, 50.0), 0.0, 10.0)
        val r = Geo.nearestPointOnSegment(p, a, b)
        assertEquals(10.0, r.distanceM, 1.0)
        assertTrue(r.t in 0.4..0.6, "t=${r.t}")
    }

    @Test
    fun `nearest point clamps outside the segment`() {
        val a = origin
        val b = Geo.destination(origin, 90.0, 100.0)
        val beyond = Geo.destination(origin, 90.0, 200.0)
        val r = Geo.nearestPointOnSegment(beyond, a, b)
        assertEquals(1.0, r.t, 1e-9)
        assertEquals(100.0, r.distanceM, 1.0)
    }

    @Test
    fun `degenerate segment falls back to the endpoint`() {
        val r = Geo.nearestPointOnSegment(Geo.destination(origin, 0.0, 30.0), origin, origin)
        assertEquals(origin, r.point)
        assertEquals(30.0, r.distanceM, 1.0)
    }
}
