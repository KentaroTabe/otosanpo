package dev.otosanpo.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** iOS 版 `WalkGraphTests` / `RouteFieldTests` / `ZoneMapTests` と同じ期待値 */
class WalkGraphTest {
    private fun lat(meters: Double) = 35.0 + meters / 111_320.0
    private fun lon(meters: Double) = 139.0 + meters / (111_320.0 * Math.cos(35.0 * Math.PI / 180))

    /** 東西に走る道(y = 0)と、南北に走る道(x = 100)が交わる小さな地図 */
    private fun crossMap() = WalkMap(
        center = WalkMap.GeoPointDto(lat(0.0), lon(100.0)),
        radiusM = 5000.0, generated = "2026-08-18",
        nodes = listOf(
            listOf(lat(0.0), lon(0.0)),       // 0
            listOf(lat(0.0), lon(200.0)),     // 1
            listOf(lat(-100.0), lon(100.0)),  // 2
            listOf(lat(100.0), lon(100.0)),   // 3
        ),
        ways = listOf(
            WalkMap.Way(listOf(0, 1), WayClass.RESIDENTIAL.raw, 0),
            WalkMap.Way(listOf(2, 3), WayClass.FOOTWAY.raw, 0),
        )
    )

    @Test
    fun `snaps to the nearest way`() {
        val g = WalkGraph(crossMap(), 50.0)
        val s = g.snap(GeoPoint(lat(10.0), lon(50.0)), 30.0)
        assertNotNull(s)
        assertEquals(0, s.wayIndex)
        assertEquals(10.0, s.distanceM, 1.5)
    }

    @Test
    fun `does not snap beyond the limit`() {
        val g = WalkGraph(crossMap(), 50.0)
        assertNull(g.snap(GeoPoint(lat(100.0), lon(0.0)), 30.0))
    }

    /** 交わっていない 2 本の道では、交差点は生まれない */
    @Test
    fun `a crossing without a shared node is not an intersection`() {
        val g = WalkGraph(crossMap(), 50.0)
        // 節点を共有していないので、どの節点も分岐は 1 本だけ
        assertTrue((0..3).none { g.isIntersection(it) })
    }

    /** 節点を共有すれば交差点になり、分岐が 4 本出る */
    @Test
    fun `shared node makes an intersection with four branches`() {
        val nodes = listOf(
            listOf(lat(0.0), lon(0.0)),      // 0 西
            listOf(lat(0.0), lon(100.0)),    // 1 中心
            listOf(lat(0.0), lon(200.0)),    // 2 東
            listOf(lat(-100.0), lon(100.0)), // 3 南
            listOf(lat(100.0), lon(100.0)),  // 4 北
        )
        val map = WalkMap(
            WalkMap.GeoPointDto(lat(0.0), lon(100.0)), 5000.0, "2026-08-18", nodes,
            listOf(
                WalkMap.Way(listOf(0, 1, 2), WayClass.RESIDENTIAL.raw, 0),
                WalkMap.Way(listOf(3, 1, 4), WayClass.FOOTWAY.raw, 0),
            )
        )
        val g = WalkGraph(map, 50.0)
        assertEquals(4, g.branches(1).size)
        assertTrue(g.isIntersection(1))

        // 西から東へ歩けば、前方 150 m 以内にその交差点が見つかる
        val x = g.upcomingIntersection(GeoPoint(lat(0.0), lon(20.0)), 90.0, 150.0)
        assertNotNull(x)
        assertEquals(1, x.nodeIndex)
        assertEquals(80.0, x.distanceM, 5.0)
    }

    /** 退化した way(節点 1 つ)は索引に入らない */
    @Test
    fun `degenerate way is skipped`() {
        val map = WalkMap(
            WalkMap.GeoPointDto(lat(0.0), lon(0.0)), 5000.0, "2026-08-18",
            listOf(listOf(lat(0.0), lon(0.0))),
            listOf(WalkMap.Way(listOf(0), WayClass.FOOTWAY.raw, 0))
        )
        val g = WalkGraph(map, 50.0)
        assertEquals(0, g.indexedSegmentCount)
        assertNull(g.snap(GeoPoint(lat(0.0), lon(0.0)), 30.0))
    }

    @Test
    fun `covers only within the radius`() {
        val m = crossMap()
        assertTrue(m.covers(m.centerPoint))
        assertTrue(!m.covers(Geo.destination(m.centerPoint, 0.0, 6000.0)))
    }

    /** 経路図の下地。枠に入る線分だけを返す */
    @Test
    fun `road segments are clipped to the frame`() {
        val g = WalkGraph(crossMap(), 50.0)
        val s = WalkSummary(0L, GeoPoint(lat(0.0), lon(100.0)))
        s.add(GeoPoint(lat(0.0), lon(100.0)), 10.0, 100)
        val frame = s.frame(10.0, 60.0)
        assertNotNull(frame)
        assertEquals(2, g.roadSegments(frame).size)
    }
}

class RouteFieldTest {
    private fun lat(meters: Double) = 35.0 + meters / 111_320.0
    private fun lon(meters: Double) = 139.0 + meters / (111_320.0 * Math.cos(35.0 * Math.PI / 180))
    private val weights = RouteField.Weights(0.12, 0.08)

    /** 東西に 100 m ずつ 3 節点が並ぶ 1 本道 */
    private fun straightMap() = WalkMap(
        WalkMap.GeoPointDto(lat(0.0), lon(100.0)), 5000.0, "2026-08-18",
        listOf(
            listOf(lat(0.0), lon(0.0)),
            listOf(lat(0.0), lon(100.0)),
            listOf(lat(0.0), lon(200.0)),
        ),
        listOf(WalkMap.Way(listOf(0, 1, 2), WayClass.RESIDENTIAL.raw, 0))
    )

    @Test
    fun `path length follows the road`() {
        val g = WalkGraph(straightMap(), 50.0)
        val f = RouteField.build(g, GeoPoint(lat(0.0), lon(0.0)), 25.0, weights)
        assertNotNull(f)
        assertEquals(3, f.reachableNodes)
        val d = f.pathLengthM(GeoPoint(lat(0.0), lon(200.0)), g)
        assertNotNull(d)
        assertEquals(200.0, d, 5.0)
    }

    /**
     * **背後の端点を指さない。**
     * 線分の手前寄りに居ると幾何的な最寄りは背後になり、そこを指すと「戻れ」になる
     */
    @Test
    fun `points forward not at the nearest node behind`() {
        val g = WalkGraph(straightMap(), 50.0)
        val f = RouteField.build(g, GeoPoint(lat(0.0), lon(0.0)), 25.0, weights)
        assertNotNull(f)
        // 東端の少し西(節点 2 のすぐ手前)。自宅は西なので、指す向きは西(270°)
        val bearing = f.nextBearingDeg(GeoPoint(lat(0.0), lon(190.0)), g, 8.0)
        assertNotNull(bearing)
        assertTrue(abs(Geo.angularDiffDeg(bearing, 270.0)) < 20.0, "bearing=$bearing")
    }

    /** 曲がりの無い道では角を返さない */
    @Test
    fun `no turn on a straight road`() {
        val g = WalkGraph(straightMap(), 50.0)
        val f = RouteField.build(g, GeoPoint(lat(0.0), lon(0.0)), 25.0, weights)
        assertNotNull(f)
        assertNull(f.nextTurn(GeoPoint(lat(0.0), lon(200.0)), g, 25.0, 200.0, 8.0))
    }

    /** L 字の道では、曲がる節点と踏み出す向きが返る */
    @Test
    fun `finds the corner on an L shaped road`() {
        val map = WalkMap(
            WalkMap.GeoPointDto(lat(0.0), lon(100.0)), 5000.0, "2026-08-18",
            listOf(
                listOf(lat(0.0), lon(0.0)),      // 0 自宅(西)
                listOf(lat(0.0), lon(100.0)),    // 1 角
                listOf(lat(100.0), lon(100.0)),  // 2 北端(出発)
            ),
            listOf(WalkMap.Way(listOf(0, 1, 2), WayClass.RESIDENTIAL.raw, 0))
        )
        val g = WalkGraph(map, 50.0)
        val f = RouteField.build(g, GeoPoint(lat(0.0), lon(0.0)), 25.0, weights)
        assertNotNull(f)
        val turn = f.nextTurn(GeoPoint(lat(90.0), lon(100.0)), g, 25.0, 200.0, 8.0)
        assertNotNull(turn)
        // 角で西(270°)へ踏み出す
        assertTrue(abs(Geo.angularDiffDeg(turn.branchBearingDeg, 270.0)) < 20.0,
                   "branch=${turn.branchBearingDeg}")
        assertEquals(90.0, turn.distanceM, 15.0)
    }

    /** 自宅が道に乗らなければ場を作れない */
    @Test
    fun `returns null when home is off the map`() {
        val g = WalkGraph(straightMap(), 50.0)
        assertNull(RouteField.build(g, GeoPoint(lat(5000.0), lon(5000.0)), 25.0, weights))
    }
}

class ZoneMapTest {
    private fun lat(meters: Double) = 35.0 + meters / 111_320.0
    private fun lon(meters: Double) = 139.0 + meters / (111_320.0 * Math.cos(35.0 * Math.PI / 180))

    private val params = ZoneMap.Params(
        zoneSizeM = 300.0, minRoadM = 400.0, sampleGrid = 3,
        minDistanceM = 300.0, minDistanceRatio = 0.4, excludedFamiliarity = 8.0
    )

    /**
     * 東へ 2 km・南北に 3 本の格子。**1 本道では地帯あたりの道が 300 m しか無く、
     * 下限(400 m)に届かないので行き先が 1 つも選べない。** 実際の街に近い密度にする
     */
    private fun longRoad(): WalkMap {
        val rows = listOf(0.0, 100.0, 200.0)
        val cols = (0..20).map { it * 100.0 }
        val nodes = rows.flatMap { y -> cols.map { x -> listOf(lat(y), lon(x)) } }
        val ways = rows.indices.map { r ->
            WalkMap.Way(cols.indices.map { c -> r * cols.size + c }, WayClass.RESIDENTIAL.raw, 0)
        }
        return WalkMap(
            WalkMap.GeoPointDto(lat(100.0), lon(1000.0)), 5000.0, "2026-08-18", nodes, ways
        )
    }

    @Test
    fun `zones are built where roads are`() {
        val z = ZoneMap(longRoad(), 300.0)
        assertTrue(z.zones.isNotEmpty())
        assertTrue(z.zones.all { it.roadLengthM > 0 })
    }

    /** **道の少ない地帯は行き先にしない** */
    @Test
    fun `ignores zones with too little road`() {
        val z = ZoneMap(longRoad(), 300.0)
        val grid = VisitGrid(50.0, 20_000.0)
        val t = z.chooseTarget(GeoPoint(lat(0.0), lon(0.0)), GeoPoint(lat(0.0), lon(0.0)),
                               3000.0, grid, params)
        assertNotNull(t)
        assertTrue(t.zone.roadLengthM >= params.minRoadM)
    }

    /** 帰ってこられない地帯は選ばない(「約束を守る」) */
    @Test
    fun `respects the budget radius`() {
        val z = ZoneMap(longRoad(), 300.0)
        val grid = VisitGrid(50.0, 20_000.0)
        val home = GeoPoint(lat(0.0), lon(0.0))
        val t = z.chooseTarget(home, home, 700.0, grid, params)
        if (t != null) assertTrue(Geo.distanceM(t.zone.center, home) <= 700.0)
    }

    /** **短い散歩でも行き先を選べる**(固定の最短距離だけだと仕組みが止まる) */
    @Test
    fun `short budget still finds a target`() {
        assertEquals(200.0, params.effectiveMinDistanceM(500.0), 1e-9)
        assertEquals(300.0, params.effectiveMinDistanceM(3000.0), 1e-9)
    }

    /** 歩き込んだ地帯より、歩いていない地帯を選ぶ */
    @Test
    fun `avoids familiar areas`() {
        val z = ZoneMap(longRoad(), 300.0)
        val grid = VisitGrid(50.0, 20_000.0)
        val home = GeoPoint(lat(0.0), lon(0.0))
        // 東 400〜600 m あたりを歩き込む
        for (m in 400..600 step 25) {
            repeat(5) { grid.recordVisit(GeoPoint(lat(0.0), lon(m.toDouble()))) }
        }
        val t = z.chooseTarget(home, home, 3000.0, grid, params)
        assertNotNull(t)
        val d = Geo.distanceM(home, t.zone.center)
        assertTrue(d < 400 || d > 650, "歩き込んだ地帯が選ばれている d=$d")
    }
}
