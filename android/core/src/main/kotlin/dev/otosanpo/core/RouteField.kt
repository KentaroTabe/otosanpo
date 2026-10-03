package dev.otosanpo.core

import java.util.PriorityQueue
import kotlin.math.abs

/**
 * **自宅までの経路を、地図全体にあらかじめ配っておく**構造。
 *
 * なぜ「経路」ではなく「場」なのか:
 * 帰宅推定は散策中も毎回の位置更新で要る。そのたびに経路を引き直すのは重いし、
 * 利用者が経路から外れるたびに引き直す設計は「叱らない」原則と相性が悪い。
 * **終点が自宅で固定**なので、自宅から全節点への最短経路を 1 回だけ解いておけば、
 * どこに居ても引くだけで分かる。**逸脱しても再計算は要らない。**
 *
 * 距離を 2 本持つ理由:
 * - `cost`: 経路の**選び方**に使う重み付き距離(横断と道の種別を嫌う)
 * - `metres`: 帰宅**時間の見積もり**に使う実距離
 */
class RouteField private constructor(
    val goal: GeoPoint,
    private val cost: DoubleArray,
    private val metres: DoubleArray,
    private val next: IntArray,
    private val snapMaxDistanceM: Double,
) {
    /** 経路の選び方。分岐提案と同じ価値観を使い、好みを一箇所に保つ */
    data class Weights(val crossCostWeight: Double, val wayClassWeight: Double)

    /** 自宅へ到達できる節点の数(地図が繋がっているかの確認用) */
    val reachableNodes: Int = metres.count { it.isFinite() }

    companion object {
        /**
         * 自宅から全節点への最短経路木を 1 回だけ解く。
         * 5 km 圏で数万節点になるので、計算はセッション開始時の 1 回に限る。
         */
        fun build(graph: WalkGraph, goal: GeoPoint, snapMaxDistanceM: Double,
                  weights: Weights): RouteField? {
            val goalNode = graph.nearestNode(goal, snapMaxDistanceM) ?: return null
            val count = graph.map.nodes.size

            // **隣接を平坦な配列に前計算する。** 辞書引きと配列の作り直しを探索の内側から追い出す
            val degree = IntArray(count)
            for (way in graph.map.ways) {
                if (way.n.size < 2) continue
                for (i in 0 until way.n.size - 1) {
                    degree[way.n[i]]++
                    degree[way.n[i + 1]]++
                }
            }
            val start = IntArray(count + 1)
            for (i in 0 until count) start[i + 1] = start[i] + degree[i]
            val edgeCount = start[count]
            val to = IntArray(edgeCount)
            val length = DoubleArray(edgeCount)
            val weighted = DoubleArray(edgeCount)
            val fill = start.copyOf()
            for (way in graph.map.ways) {
                if (way.n.size < 2) continue
                // 横断と道の種別は「その道を通る負担」として距離を割り増しする
                val penalty = 1 + way.cross * weights.crossCostWeight +
                    way.cls.preferenceRank * weights.wayClassWeight
                for (i in 0 until way.n.size - 1) {
                    val a = way.n[i]
                    val b = way.n[i + 1]
                    val pa = graph.map.point(a) ?: continue
                    val pb = graph.map.point(b) ?: continue
                    val d = Geo.distanceM(pa, pb)
                    to[fill[a]] = b; length[fill[a]] = d; weighted[fill[a]] = d * penalty; fill[a]++
                    to[fill[b]] = a; length[fill[b]] = d; weighted[fill[b]] = d * penalty; fill[b]++
                }
            }

            val cost = DoubleArray(count) { Double.POSITIVE_INFINITY }
            val metres = DoubleArray(count) { Double.POSITIVE_INFINITY }
            val next = IntArray(count) { -1 }
            val done = BooleanArray(count)

            cost[goalNode] = 0.0
            metres[goalNode] = 0.0
            // 距離が縮んだ節点は再度積む(古い項目は done で弾く)ので、削除操作は要らない
            val heap = PriorityQueue<DoubleArray>(compareBy { it[1] })
            heap.add(doubleArrayOf(goalNode.toDouble(), 0.0))

            while (heap.isNotEmpty()) {
                val u = heap.poll()[0].toInt()
                if (done[u]) continue
                done[u] = true
                for (e in start[u] until start[u + 1]) {
                    val v = to[e]
                    if (done[v]) continue
                    val c = cost[u] + weighted[e]
                    if (c >= cost[v]) continue
                    cost[v] = c
                    metres[v] = metres[u] + length[e]
                    // v から見れば、自宅へ向かう次の一歩は u
                    next[v] = u
                    heap.add(doubleArrayOf(v.toDouble(), c))
                }
            }
            return RouteField(goal, cost, metres, next, snapMaxDistanceM)
        }
    }

    /**
     * いま乗っている線分の端点のうち、**そこを通ると自宅までが最短になるほう**。
     *
     * 幾何的に最寄りの端点を使ってはいけない。線分の手前寄りに居れば最寄りは
     * **背後の端点**になり、そこを指すと「戻れ」と言うことになる。
     *
     * **実距離ではなく重み付きコストで比べる。** 経路そのものは重みで選んでいるので、
     * 実距離で比べると Dijkstra の選択と食い違い、長さが同じ別の道へ入り込む。
     */
    private fun forwardNode(from: GeoPoint, graph: WalkGraph): Int? {
        val s = graph.snap(from, snapMaxDistanceM) ?: return null
        val way = graph.map.ways[s.wayIndex]
        var bestNode: Int? = null
        var bestTotal = Double.POSITIVE_INFINITY
        for (n in listOf(way.n[s.segmentIndex], way.n[s.segmentIndex + 1])) {
            if (n !in cost.indices || !cost[n].isFinite()) continue
            val q = graph.map.point(n) ?: continue
            val total = Geo.distanceM(from, q) + cost[n]
            if (total < bestTotal) { bestTotal = total; bestNode = n }
        }
        return bestNode
    }

    /** 現在地から自宅までの**実際に歩く距離** [m]。道に乗らない場所では null */
    fun pathLengthM(from: GeoPoint, graph: WalkGraph): Double? {
        val node = forwardNode(from, graph) ?: return null
        val np = graph.map.point(node) ?: return null
        return Geo.distanceM(from, np) + metres[node]
    }

    /**
     * **いま進むべき向き**(経路の次の一歩の方位)。
     *
     * ビーコンはこれを指す。自宅を直線で指すと川や街区や私有地の向こうを指しうる。
     * **道の上を指していれば「音の鳴る方に歩く」が成り立つ。**
     */
    fun nextBearingDeg(from: GeoPoint, graph: WalkGraph, nodeToleranceM: Double): Double? {
        val node = forwardNode(from, graph) ?: return null
        val here = graph.map.point(node) ?: return null
        // まだ手前の節点に着いていなければ、まずそこへ向かう。
        // 目の前の節点を飛ばして次を指すと、曲がる前に曲がった先を指すことになる
        if (Geo.distanceM(from, here) > nodeToleranceM) return Geo.bearingDeg(from, here)
        val n = next[node]
        if (n < 0) return Geo.bearingDeg(from, goal)   // 自宅そのもの
        val np = graph.map.point(n) ?: return Geo.bearingDeg(from, goal)
        return Geo.bearingDeg(here, np)
    }

    data class Turn(val corner: GeoPoint, val branchBearingDeg: Double, val distanceM: Double)

    /**
     * 経路上で**次に曲がる地点**と、そこで踏み出す向き。
     * 曲がり角の誘導(TurnGuidance)にそのまま渡せる形で返す。
     */
    fun nextTurn(from: GeoPoint, graph: WalkGraph, straightWithinDeg: Double,
                 maxLookM: Double, nodeToleranceM: Double): Turn? {
        // 幾何的な最寄りではなく**経路上で先にある端点**から辿る
        val start = forwardNode(from, graph) ?: return null
        var current = start
        var here = graph.map.point(start) ?: return null
        var travelled = Geo.distanceM(from, here)
        // **最初の節点そのものが角**でありうるので、そこへ向かう向きを入りの向きとする。
        // ただし節点が目の前(数 m)なら、その向きは雑音でしかないので使わない
        var incoming: Double? =
            if (travelled >= nodeToleranceM) Geo.bearingDeg(from, here) else null

        while (travelled <= maxLookM) {
            val n = next[current]
            if (n < 0) return null
            val np = graph.map.point(n) ?: return null
            val outgoing = Geo.bearingDeg(here, np)
            val inbound = incoming
            if (inbound != null && abs(Geo.angularDiffDeg(outgoing, inbound)) > straightWithinDeg) {
                return Turn(here, outgoing, travelled)
            }
            travelled += Geo.distanceM(here, np)
            incoming = outgoing
            current = n
            here = np
        }
        return null
    }
}
