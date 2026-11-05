package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.pow

/**
 * 約 cellSizeM 四方のセルごとに「通過回数(指数減衰つき)」と「日常ルート除外フラグ」を持つ。
 *
 * **減衰の時計は日数ではなく「歩いた総距離」**(2026-08-20 決定)。
 * 歩かなかった期間に新鮮さが戻るのはおかしい。1 ヶ月ぶりの散歩でも、その 1 ヶ月で
 * 何も歩いていないなら馴染みは薄れていない。逆に 20 km 歩いてなお通らなかった道は
 * それだけ「選ばれなかった道」で、新鮮さが戻ってよい。
 *
 * すべて端末内で完結する前提のデータ構造(送信しない)。
 */
class VisitGrid(
    var cellSizeM: Double,
    /** 通過の重みが半分になるまでに歩く距離 [m] */
    var halfLifeM: Double,
) {
    data class CellKey(val ix: Int, val iy: Int)

    data class CellRecord(
        var count: Double,
        /** この記録を最後に更新した時点の積算歩行距離 [m] */
        var lastOdometerM: Double,
        var excluded: Boolean,
    )

    val cells: MutableMap<CellKey, CellRecord> = mutableMapOf()

    /** 積算歩行距離 [m]。**これが減衰の時計** */
    var odometerM: Double = 0.0
        private set

    fun key(p: GeoPoint): CellKey {
        val y = p.latitude * Geo.METERS_PER_DEGREE_LAT
        val x = p.longitude * Geo.METERS_PER_DEGREE_LAT * cos(p.latitude * Math.PI / 180)
        return CellKey(floor(x / cellSizeM).toInt(), floor(y / cellSizeM).toInt())
    }

    fun center(k: CellKey): GeoPoint {
        val y = (k.iy + 0.5) * cellSizeM
        val lat = y / Geo.METERS_PER_DEGREE_LAT
        val x = (k.ix + 0.5) * cellSizeM
        val lon = x / (Geo.METERS_PER_DEGREE_LAT * cos(lat * Math.PI / 180))
        return GeoPoint(lat, lon)
    }

    /** 減衰の時計を進める。**歩いた分だけ**呼ぶ(位置更新の差分を積んだ実距離) */
    fun advance(distanceM: Double) {
        if (distanceM > 0) odometerM += distanceM
    }

    fun recordVisit(p: GeoPoint) {
        val k = key(p)
        val r = cells[k] ?: CellRecord(0.0, odometerM, false)
        r.count = decayed(r) + 1
        r.lastOdometerM = odometerM
        cells[k] = r
    }

    /** 通勤路学習モード: このセルを日常ルートとして除外する */
    fun markExcluded(p: GeoPoint) {
        val k = key(p)
        val r = cells[k] ?: CellRecord(0.0, odometerM, false)
        r.excluded = true
        r.lastOdometerM = odometerM
        cells[k] = r
    }

    fun decayed(r: CellRecord): Double {
        val walked = odometerM - r.lastOdometerM
        if (walked <= 0 || halfLifeM <= 0) return r.count
        return r.count * 0.5.pow(walked / halfLifeM)
    }

    /** その地点の「馴染み度」。未踏 = 0、除外セルは excludedFamiliarity 固定 */
    fun familiarity(p: GeoPoint, excludedFamiliarity: Double): Double {
        val r = cells[key(p)] ?: return 0.0
        return if (r.excluded) excludedFamiliarity else decayed(r)
    }

    /**
     * 与えた点列の平均馴染み度。**通っていない点は 0 として数える**。
     * 道に沿って標本を取り、その平均を「その道の馴染み度」とする。
     * 半分だけ歩いた道は半分の馴染み度になる。
     */
    fun averageFamiliarity(points: List<GeoPoint>, excludedFamiliarity: Double): Double {
        if (points.isEmpty()) return 0.0
        return points.sumOf { familiarity(it, excludedFamiliarity) } / points.size
    }

    /**
     * origin から bearing 方向の扇形内にある記録済みセルの平均馴染み度。
     * 経路データが無いときの代用(通常は `averageFamiliarity` を道なりに使う)。
     */
    fun sectorFamiliarity(origin: GeoPoint, bearingDeg: Double, p: AppParameters.Route): Double {
        var total = 0.0
        var n = 0
        for ((k, r) in cells) {
            val c = center(k)
            val d = Geo.distanceM(origin, c)
            if (d <= 0 || d > p.sectorRadiusM) continue
            val b = Geo.bearingDeg(origin, c)
            if (abs(Geo.angularDiffDeg(b, bearingDeg)) > p.sectorWidthDeg / 2) continue
            total += if (r.excluded) p.excludedFamiliarity else decayed(r)
            n += 1
        }
        return if (n == 0) 0.0 else total / n
    }

    /** 永続化のための素の形(Android 側で JSON に落とす) */
    fun snapshot(): List<Triple<CellKey, Double, Boolean>> =
        cells.map { (k, r) -> Triple(k, r.count, r.excluded) }

    fun restore(entries: List<CellRecordEntry>, odometerM: Double) {
        cells.clear()
        for (e in entries) {
            cells[CellKey(e.ix, e.iy)] = CellRecord(e.count, e.lastOdometerM, e.excluded)
        }
        this.odometerM = odometerM
    }

    /** 保存の受け渡しに使う素の形(**保存の仕方は Services 側の責務**) */
    data class CellRecordEntry(
        val ix: Int, val iy: Int,
        val count: Double, val lastOdometerM: Double, val excluded: Boolean,
    )

    fun entries(): List<CellRecordEntry> =
        cells.map { (k, r) -> CellRecordEntry(k.ix, k.iy, r.count, r.lastOdometerM, r.excluded) }
}
