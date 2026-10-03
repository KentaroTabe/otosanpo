package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * **「面白い」を広域で決める**ための地帯の地図。
 *
 * 交差点ごとの評価(`BranchSuggester`)は局所的で、曲がった直後の評価が高くても
 * その先がつまらない場所に出ることがある。「どちらへ曲がるか」の前に
 * **「どのあたりへ向かうか」**を決めておけば、局所の選択に一貫した向きが与えられる。
 *
 * 地帯の良さは 2 つの掛け算:
 * - **新鮮さ**: そこをどれだけ歩いていないか
 * - **道の多さ**: **道が無い地帯に価値は無い**。未踏なだけの田畑や川の上を選ばないため
 */
class ZoneMap(map: WalkMap, private val zoneSizeM: Double) {
    data class Zone(val center: GeoPoint, val roadLengthM: Double)

    /** 選ばれた行き先と、その理由(ログに残して後から判断できるようにする) */
    data class Target(val zone: Zone, val novelty: Double, val score: Double,
                      val distanceM: Double)

    data class Params(
        val zoneSizeM: Double,
        /** 行き先として認める道の総延長の下限 [m] */
        val minRoadM: Double,
        /** 地帯の馴染み度を測るときの 1 辺あたりの標本数 */
        val sampleGrid: Int,
        /** 行き先として認める現在地からの最短距離 [m] */
        val minDistanceM: Double,
        /**
         * 上の距離を、**行ける範囲に対する比でも抑える**。
         * 固定値だけだと短い散歩で仕組みが丸ごと止まる
         * (2026-08-19 実測: 10 分の散歩で行き先は 9 秒しか保たなかった)
         */
        val minDistanceRatio: Double,
        val excludedFamiliarity: Double,
    ) {
        fun effectiveMinDistanceM(allowedRadiusM: Double): Double =
            min(minDistanceM, allowedRadiusM * minDistanceRatio)
    }

    val zones: List<Zone>

    init {
        val roadLength = HashMap<Long, Double>()
        val seen = HashMap<Long, GeoPoint>()
        val latPerZone = zoneSizeM / Geo.METERS_PER_DEGREE_LAT
        val cosLat = max(0.01, cos(map.centerPoint.latitude * Math.PI / 180))
        val lonPerZone = zoneSizeM / (Geo.METERS_PER_DEGREE_LAT * cosLat)

        fun key(p: GeoPoint): Long {
            val x = floor(p.longitude / lonPerZone).toInt()
            val y = floor(p.latitude / latPerZone).toInt()
            return (x.toLong() shl 32) xor (y.toLong() and 0xFFFFFFFFL)
        }

        for (way in map.ways) {
            if (way.n.size < 2) continue
            for (i in 0 until way.n.size - 1) {
                val a = map.point(way.n[i]) ?: continue
                val b = map.point(way.n[i + 1]) ?: continue
                // 線分は中点の属する地帯に丸ごと入れる(地帯 300 m 角に対し線分は数十 m)
                val mid = GeoPoint((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2)
                val k = key(mid)
                roadLength[k] = (roadLength[k] ?: 0.0) + Geo.distanceM(a, b)
                // 代表点は道の上に置く(幾何的な中心だと道の無い場所を指しうる)
                if (!seen.containsKey(k)) seen[k] = mid
            }
        }
        zones = roadLength.mapNotNull { (k, length) -> seen[k]?.let { Zone(it, length) } }
    }

    /**
     * いま向かうべき地帯を選ぶ。
     *
     * @param allowedRadiusM 自宅からこの距離までなら帰ってこられる。
     *   **選ぶときは予算いっぱいではなく余裕を持たせた値を渡す**
     *   (許容半径は時間とともに縮むので、縁ぎりぎりの地帯は数秒で無効になる)
     */
    fun chooseTarget(from: GeoPoint, home: GeoPoint, allowedRadiusM: Double,
                     grid: VisitGrid, p: Params): Target? {
        var best: Target? = null
        val minDistanceM = p.effectiveMinDistanceM(allowedRadiusM)
        for (zone in zones) {
            // 帰ってこられない地帯は行き先にしない(「約束を守る」docs/01)
            if (Geo.distanceM(zone.center, home) > allowedRadiusM) continue
            val d = Geo.distanceM(from, zone.center)
            if (d < minDistanceM) continue
            if (zone.roadLengthM < p.minRoadM) continue

            val novelty = 1.0 / (1.0 + familiarity(zone, grid, p))
            // 道が多いほど歩きでがある。際限なく効かないよう 1 で頭打ちにする
            val density = min(1.0, zone.roadLengthM / (p.minRoadM * 3))
            val score = novelty * density
            val b = best
            if (b == null) {
                best = Target(zone, novelty, score, d)
                continue
            }
            // **同点なら近いほうを選ぶ。** 未踏の地帯は同点で並びやすく、score だけで
            // 比べると選択が並び順まかせになって毎回変わる
            val better = score > b.score + 1e-9 ||
                (abs(score - b.score) <= 1e-9 && d < b.distanceM)
            if (better) best = Target(zone, novelty, score, d)
        }
        return best
    }

    /** 地帯の馴染み度。地帯は通過履歴のセルより大きいので、格子状に標本を取って平均する */
    private fun familiarity(zone: Zone, grid: VisitGrid, p: Params): Double {
        val n = max(1, p.sampleGrid)
        if (n <= 1) return grid.familiarity(zone.center, p.excludedFamiliarity)
        var total = 0.0
        val step = zoneSizeM / n
        val half = zoneSizeM / 2
        for (i in 0 until n) {
            for (j in 0 until n) {
                val dx = -half + step * (i + 0.5)
                val dy = -half + step * (j + 0.5)
                val q = Geo.destination(Geo.destination(zone.center, 90.0, dx), 0.0, dy)
                total += grid.familiarity(q, p.excludedFamiliarity)
            }
        }
        return total / (n * n)
    }
}

/**
 * 実際に曲がれる道の中から 1 本を選ぶ。
 *
 * 候補が **±45° / ±90° の推測ではなく、その交差点に実在する道**になるので、
 * 通行可否が保証され、横断コストと道の種別をスコアに入れられ、
 * **来た道を除外できる**(折り返しの提案が構造的に消える)。
 */
object BranchSuggester {
    data class Choice(
        val branch: Branch,
        /** 進行方向に対する相対角 [deg]。音の定位に使う */
        val relativeBearingDeg: Double,
        val score: Double,
        /** この分岐の新鮮さ(penalty を引く前)。直進との比較はこちらで行う */
        val novelty: Double,
    )

    /** 分岐を選ばなかった理由。「鳴らない」の内訳が分からないと調整できない */
    enum class Silence(val label: String) {
        NO_CANDIDATES("候補なし"),
        STRAIGHT_IS_BEST("直進が最良"),
        MARGIN_TOO_SMALL("直進との差が小さい"),
    }

    sealed interface Decision {
        data class Suggest(val choice: Choice) : Decision

        /**
         * 黙った理由と、そのとき最良だった候補。
         * **「惜しかったのか、遠く及ばなかったのか」が分からないと閾値を動かせない**
         */
        data class Silent(val why: Silence, val bestSoFar: Choice?) : Decision

        /** そのとき最良だった候補(鳴らした場合はそれ自身) */
        val best: Choice? get() = when (this) {
            is Suggest -> choice
            is Silent -> bestSoFar
        }
    }

    /**
     * @param target 向かっている地帯(ZoneMap が選ぶ)。局所の選択に広域の向きを与える
     * @param graph 与えると**新鮮さをその道に沿って測る**。無ければ扇形で代用する
     */
    fun decide(intersection: UpcomingIntersection, travelBearingDeg: Double,
               position: GeoPoint, home: GeoPoint, grid: VisitGrid, homewardBias: Double,
               target: GeoPoint? = null, graph: WalkGraph? = null,
               route: AppParameters.Route): Decision {
        val homeBearing = Geo.bearingDeg(position, home)
        val targetBearing = target?.let { Geo.bearingDeg(position, it) }
        // 行き先の寄与は帰宅バイアスの裏返し。**帰宅が常に優先**
        val targetWeight = route.targetBiasWeight * (1 - homewardBias)
        var straightNovelty: Double? = null
        var best: Choice? = null

        for (b in intersection.branches) {
            val rel = Geo.angularDiffDeg(b.bearingDeg, travelBearingDeg)
            // 来た道(ほぼ真後ろ)は候補にしない。折り返しは困惑とストレスの元
            if (abs(rel) >= route.branchBackwardDeg) continue

            // **その道に沿って測る。** 扇形だと、そこから行けない別の道も混ざる
            val samples = graph?.samplesAlong(b, intersection.nodeIndex,
                                              route.sectorRadiusM, route.cellSizeM) ?: emptyList()
            val fam = if (samples.isEmpty()) {
                grid.sectorFamiliarity(intersection.point, b.bearingDeg, route)
            } else {
                grid.averageFamiliarity(samples, route.excludedFamiliarity)
            }
            val novelty = 1.0 / (1.0 + fam)
            val angleToHome = abs(Geo.angularDiffDeg(b.bearingDeg, homeBearing)) / 180.0
            val crossPenalty = b.crossCost * route.crossCostWeight
            val classPenalty = b.cls.preferenceRank * route.wayClassWeight
            val targetPenalty = targetBearing?.let {
                targetWeight * abs(Geo.angularDiffDeg(b.bearingDeg, it)) / 180.0
            } ?: 0.0
            val score = novelty - homewardBias * angleToHome - crossPenalty - classPenalty -
                targetPenalty

            // 直進に相当する分岐(進行方向にいちばん近い道)を基準にする
            if (abs(rel) <= route.branchStraightDeg) {
                if (straightNovelty == null || novelty > straightNovelty!!) straightNovelty = novelty
            }
            if (best == null || score > best!!.score) {
                best = Choice(b, rel, score, novelty)
            }
        }

        val b = best ?: return Decision.Silent(Silence.NO_CANDIDATES, null)
        // 直進が最良なら鳴らさない(直進に音は要らない)
        if (abs(b.relativeBearingDeg) <= route.branchStraightDeg) {
            return Decision.Silent(Silence.STRAIGHT_IS_BEST, b)
        }
        // **絶対値の下限は課さない。** 分岐選択は「ここにある道のうちどれが良いか」の
        // 相対比較で、絶対的な下限を課すと歩き込んだ界隈では一切鳴らなくなる
        // (実測 2026-08-18: 交差点接近 824 回に対し提案 0 件)。
        //
        // 直進との比較は**絶対差ではなく比**で見る。新鮮さは馴染むほど 0 に圧縮されるので、
        // 絶対差では歩き込んだ地点ほど黙ってしまう
        val s = straightNovelty
        if (s != null && s > 0 && b.novelty < s * route.branchNoveltyRatio) {
            return Decision.Silent(Silence.MARGIN_TOO_SMALL, b)
        }
        return Decision.Suggest(b)
    }
}
