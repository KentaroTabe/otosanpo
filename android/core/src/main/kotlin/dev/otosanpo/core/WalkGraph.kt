package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * `WalkMap` に空間索引を張って、道路スナップを実用的な速さで行う。
 *
 * 索引の作り: 緯度経度をおよそ `cellSizeM` 四方のセルに切り、各線分が触れるセルに
 * 「way 番号と線分番号」を登録する。探索は問い合わせ点の周囲 1 セル分だけを見る。
 *
 * なぜ要るか: 5 km 圏の way は数万本になる。毎秒の位置更新で全探索はできない。
 */
class WalkGraph(val map: WalkMap, cellSizeM: Double) {
    private val cellSizeM: Double = max(1.0, cellSizeM)
    private val buckets = HashMap<Long, MutableList<IntArray>>()

    /** 節点番号 → その節点に触れる (way 番号, 節点の位置) の一覧 */
    private val incident = HashMap<Int, MutableList<IntArray>>()

    init {
        buildIndex()
    }

    /** 登録された線分の総数(索引が張れているかの確認用) */
    val indexedSegmentCount: Int get() = buckets.values.sumOf { it.size }

    // MARK: - 索引

    private fun cell(p: GeoPoint): Pair<Int, Int> {
        val latPerCell = cellSizeM / Geo.METERS_PER_DEGREE_LAT
        // 極付近で 0 除算しないよう下限を置く(散歩スケールでは効かない)
        val cosLat = max(0.01, cos(map.centerPoint.latitude * Math.PI / 180))
        val lonPerCell = cellSizeM / (Geo.METERS_PER_DEGREE_LAT * cosLat)
        return Pair(floor(p.longitude / lonPerCell).toInt(),
                    floor(p.latitude / latPerCell).toInt())
    }

    private fun key(x: Int, y: Int): Long = (x.toLong() shl 32) xor (y.toLong() and 0xFFFFFFFFL)

    private fun buildIndex() {
        for ((wi, way) in map.ways.withIndex()) {
            if (way.n.size < 2) continue
            for ((at, node) in way.n.withIndex()) {
                incident.getOrPut(node) { mutableListOf() }.add(intArrayOf(wi, at))
            }
            for (si in 0 until way.n.size - 1) {
                val a = map.point(way.n[si]) ?: continue
                val b = map.point(way.n[si + 1]) ?: continue
                // 1 セルより長い線分もあるため、端点だけでは取りこぼす
                val (ax, ay) = cell(a)
                val (bx, by) = cell(b)
                for (x in min(ax, bx)..max(ax, bx)) {
                    for (y in min(ay, by)..max(ay, by)) {
                        buckets.getOrPut(key(x, y)) { mutableListOf() }.add(intArrayOf(wi, si))
                    }
                }
            }
        }
    }

    // MARK: - スナップ

    /** `p` に最も近い道の上の点。`maxDistanceM` を超える場合は null */
    fun snap(p: GeoPoint, maxDistanceM: Double): Snap? {
        val (cx, cy) = cell(p)
        var best: Snap? = null
        // 周囲 1 セル分を見る(セル境界のすぐ外にある線分を取りこぼさないため)
        for (dx in -1..1) {
            for (dy in -1..1) {
                val entries = buckets[key(cx + dx, cy + dy)] ?: continue
                for (e in entries) {
                    val s = evaluate(e[0], e[1], p) ?: continue
                    if (best == null || s.distanceM < best!!.distanceM) best = s
                }
            }
        }
        val b = best ?: return null
        return if (b.distanceM <= maxDistanceM) b else null
    }

    private fun evaluate(wayIndex: Int, seg: Int, p: GeoPoint): Snap? {
        val way = map.ways[wayIndex]
        val a = map.point(way.n[seg]) ?: return null
        val b = map.point(way.n[seg + 1]) ?: return null
        val r = Geo.nearestPointOnSegment(p, a, b)
        return Snap(wayIndex, seg, r.point, r.distanceM, Geo.bearingDeg(a, b))
    }

    /** `p` に最も近い**節点**。経路探索の出発点・目的地を決めるために使う */
    fun nearestNode(to: GeoPoint, maxDistanceM: Double): Int? {
        val s = snap(to, maxDistanceM) ?: return null
        val way = map.ways[s.wayIndex]
        val a = way.n[s.segmentIndex]
        val b = way.n[s.segmentIndex + 1]
        val pa = map.point(a) ?: return null
        val pb = map.point(b) ?: return null
        return if (Geo.distanceM(to, pa) <= Geo.distanceM(to, pb)) a else b
    }

    // MARK: - 交差点と分岐

    /**
     * その節点から選べる道の一覧。
     * 節点が way の途中にあれば前後 2 方向、端にあれば 1 方向。
     * 同じ向きが重複しないよう、近い向きは 1 本に畳む。
     */
    fun branches(node: Int, mergeWithinDeg: Double = 20.0): List<Branch> {
        val origin = map.point(node) ?: return emptyList()
        val out = mutableListOf<Branch>()
        for (e in incident[node] ?: emptyList()) {
            val way = map.ways[e[0]]
            for (neighbor in listOf(e[1] - 1, e[1] + 1)) {
                if (neighbor !in way.n.indices) continue
                val q = map.point(way.n[neighbor]) ?: continue
                if (q == origin) continue
                val bearing = Geo.bearingDeg(origin, q)
                val duplicate = out.any {
                    abs(Geo.angularDiffDeg(it.bearingDeg, bearing)) < mergeWithinDeg
                }
                if (duplicate) continue
                out.add(Branch(bearing, way.cls, way.cross, e[0]))
            }
        }
        return out.sortedBy { it.bearingDeg }
    }

    /** 交差点かどうか。**選べる道が 3 方向以上**ある節点を交差点とみなす */
    fun isIntersection(node: Int): Boolean = branches(node).size >= 3

    /**
     * いま乗っている道を前方へ辿って、最初に出会う交差点。
     *
     * **空間的に近いだけの節点は拾わない。** 周囲を走査して「前方 35 m・±60°」で
     * 選ぶと、街区の幅が 30〜50 m しかないので**隣の通りの交差点**が入る。
     * そこを指せば街区を突っ切る向きになる(2026-08-19 実測で 3 回)。
     * 道を辿って探せば、返る交差点は**必ずいまの道の延長上にある**。
     */
    fun upcomingIntersection(from: GeoPoint, bearingDeg: Double, withinM: Double,
                             snapMaxDistanceM: Double = 25.0): UpcomingIntersection? {
        val s = snap(from, snapMaxDistanceM) ?: return null
        val way = map.ways[s.wayIndex]
        val a = way.n[s.segmentIndex]
        val b = way.n[s.segmentIndex + 1]
        val pa = map.point(a) ?: return null
        val pb = map.point(b) ?: return null
        // 進行方向に合う側へ歩き出す
        val forward = abs(Geo.angularDiffDeg(Geo.bearingDeg(pa, pb), bearingDeg)) <= 90
        var previous = if (forward) a else b
        var current = if (forward) b else a
        var here = map.point(current) ?: return null
        var travelled = Geo.distanceM(s.point, here)
        // 同じ節点を二度踏まない(環状の道で回り続けないため)
        val visited = mutableSetOf(previous)

        while (travelled <= withinM) {
            if (!visited.add(current)) return null
            val br = branches(current)
            if (br.size >= 3) return UpcomingIntersection(current, here, travelled, br)
            // 道が続いているだけの節点。来た方でないほうへ進む
            val next = continuation(current, previous, here) ?: return null
            val np = map.point(next) ?: return null
            travelled += Geo.distanceM(here, np)
            previous = current
            current = next
            here = np
        }
        return null
    }

    /**
     * 節点 `node` を、`from` から来て通り抜ける先。行き止まりなら null。
     * 候補が複数あるときは**最も真っ直ぐ**なものを選ぶ。
     */
    private fun continuation(node: Int, from: Int, heading: GeoPoint): Int? {
        val pp = map.point(from) ?: return null
        val incoming = Geo.bearingDeg(pp, heading)
        var bestNode: Int? = null
        var bestTurn = Double.POSITIVE_INFINITY
        for (n in adjacentNodes(node)) {
            if (n == from) continue
            val q = map.point(n) ?: continue
            val turn = abs(Geo.angularDiffDeg(Geo.bearingDeg(heading, q), incoming))
            if (turn < bestTurn) { bestTurn = turn; bestNode = n }
        }
        return bestNode
    }

    /**
     * その分岐へ入ってから `withinM` 進むまでの、**道の上の点列**(`stepM` 間隔)。
     *
     * 何のためか: 分岐の新鮮さを「その方向の扇形」ではなく**その道そのもの**で測るため。
     * 扇形は空間を切り取るだけなので、東の扇形には東へ行く道も、そこから行けない別の道も、
     * 道でない場所も入る。実際に歩く道を辿れば「この道が新しいか」を直接答えられる。
     */
    fun samplesAlong(branch: Branch, from: Int, withinM: Double, stepM: Double): List<GeoPoint> {
        if (stepM <= 0 || withinM <= 0) return emptyList()
        val origin = map.point(from) ?: return emptyList()
        // 分岐の向きに最も近い隣接節点へ踏み出す
        var current: Int? = null
        var bestDiff = Double.POSITIVE_INFINITY
        for (n in adjacentNodes(from)) {
            val q = map.point(n) ?: continue
            val d = abs(Geo.angularDiffDeg(Geo.bearingDeg(origin, q), branch.bearingDeg))
            if (d < bestDiff) { bestDiff = d; current = n }
        }
        var node = current ?: return emptyList()

        // 道なりの折れ線を作る
        val polyline = mutableListOf(origin)
        var previous = from
        val visited = mutableSetOf(from)
        var length = 0.0
        while (visited.add(node)) {
            val here = map.point(node) ?: break
            length += Geo.distanceM(polyline.last(), here)
            polyline.add(here)
            if (length >= withinM) break
            val next = continuation(node, previous, here) ?: break
            previous = node
            node = next
        }
        if (polyline.size < 2) return emptyList()

        // 等間隔に標本を取る(数十 m なら緯度経度の線形補間で足りる)
        val out = mutableListOf<GeoPoint>()
        var travelled = 0.0
        var target = stepM
        for (i in 1 until polyline.size) {
            val a = polyline[i - 1]
            val b = polyline[i]
            val seg = Geo.distanceM(a, b)
            while (target <= travelled + seg && target <= withinM) {
                val t = if (seg > 0) (target - travelled) / seg else 0.0
                out.add(GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                                 a.longitude + (b.longitude - a.longitude) * t))
                target += stepM
            }
            travelled += seg
            if (travelled >= withinM) break
        }
        return out
    }

    /** その節点に隣接する節点。`branches` と違い**向きで畳まない** */
    fun adjacentNodes(node: Int): List<Int> {
        val out = mutableListOf<Int>()
        for (e in incident[node] ?: emptyList()) {
            val way = map.ways[e[0]]
            for (at in listOf(e[1] - 1, e[1] + 1)) {
                if (at !in way.n.indices) continue
                val n = way.n[at]
                if (n != node && !out.contains(n)) out.add(n)
            }
        }
        return out
    }

    /** 枠に入る道の線分。**経路図の下地**に使う(図を開いた時に 1 回だけ呼ぶ) */
    fun roadSegments(frame: MapFrame): List<RoadSegment> {
        val out = mutableListOf<RoadSegment>()
        for (way in map.ways) {
            if (way.n.size < 2) continue
            for (i in 0 until way.n.size - 1) {
                val a = map.point(way.n[i]) ?: continue
                val b = map.point(way.n[i + 1]) ?: continue
                if (!frame.mayContain(a, b)) continue
                out.add(RoadSegment(a, b, way.cls))
            }
        }
        return out
    }
}
