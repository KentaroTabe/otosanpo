package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** 緯度経度(度)。プラットフォーム非依存の純粋型(iOS 版の `GeoPoint` と同じ)。 */
data class GeoPoint(val latitude: Double, val longitude: Double)

/** 線分上の最近点を返すときの結果 */
data class NearestOnSegment(val point: GeoPoint, val distanceM: Double, val t: Double)

/**
 * 地理計算。散歩スケール(数 km)を前提とした精度。
 *
 * iOS 版 `Sources/Core/Geo.swift` の移植。**式も定数も変えない** —
 * 同じ入力に同じ答えを返すことが、2 実装を保つ唯一の担保になる。
 */
object Geo {
    /** 物理定数(パラメータ化の対象外) */
    const val EARTH_RADIUS_M = 6_371_000.0
    const val METERS_PER_DEGREE_LAT = 111_320.0

    /** ハーバサイン距離 [m] */
    fun distanceM(a: GeoPoint, b: GeoPoint): Double {
        val p1 = a.latitude * Math.PI / 180
        val p2 = b.latitude * Math.PI / 180
        val dp = (b.latitude - a.latitude) * Math.PI / 180
        val dl = (b.longitude - a.longitude) * Math.PI / 180
        val h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * EARTH_RADIUS_M * asin(min(1.0, sqrt(h)))
    }

    /** a から b への方位角 [deg, 0..360)。北=0、東=90 */
    fun bearingDeg(from: GeoPoint, to: GeoPoint): Double {
        val p1 = from.latitude * Math.PI / 180
        val p2 = to.latitude * Math.PI / 180
        val dl = (to.longitude - from.longitude) * Math.PI / 180
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizeDeg(atan2(y, x) * 180 / Math.PI)
    }

    /** 角度を 0..360 に正規化 */
    fun normalizeDeg(d: Double): Double {
        var v = d % 360
        if (v < 0) v += 360
        return v
    }

    /** a − b を −180..180 に正規化(符号は a が b から見て右回りに何度ずれているか) */
    fun angularDiffDeg(a: Double, b: Double): Double {
        var d = (a - b) % 360
        if (d > 180) d -= 360
        if (d < -180) d += 360
        return d
    }

    /**
     * 線分 a→b 上で p に最も近い点と、そこまでの距離 [m]。
     * 道路スナップ(GPS の点をどの道の上に乗せるか)の基礎になる。
     */
    fun nearestPointOnSegment(p: GeoPoint, a: GeoPoint, b: GeoPoint): NearestOnSegment {
        // a を原点に、東西方向を x、南北方向を y のメートルに変換する
        val lonScale = METERS_PER_DEGREE_LAT * cos(a.latitude * Math.PI / 180)
        fun toXY(q: GeoPoint) = Pair((q.longitude - a.longitude) * lonScale,
                                     (q.latitude - a.latitude) * METERS_PER_DEGREE_LAT)
        val (dx, dy) = toXY(b)
        val (px, py) = toXY(p)
        val lenSq = dx * dx + dy * dy
        // 退化した線分(同じ点が続く way)は端点として扱う
        if (lenSq <= 0) return NearestOnSegment(a, distanceM(p, a), 0.0)
        // 線分上に射影し、0..1 に丸める(線分の外へは出さない)
        val t = ((px * dx + py * dy) / lenSq).coerceIn(0.0, 1.0)
        val nearest = GeoPoint(
            latitude = a.latitude + (dy * t) / METERS_PER_DEGREE_LAT,
            longitude = a.longitude + (dx * t) / lonScale
        )
        return NearestOnSegment(nearest, distanceM(p, nearest), t)
    }

    /** 平面近似で bearing 方向へ distance 進んだ点(近距離用) */
    fun destination(from: GeoPoint, bearingDeg: Double, distanceM: Double): GeoPoint {
        val t = bearingDeg * Math.PI / 180
        val dLat = distanceM * cos(t) / METERS_PER_DEGREE_LAT
        val dLon = distanceM * sin(t) / (METERS_PER_DEGREE_LAT * cos(from.latitude * Math.PI / 180))
        return GeoPoint(from.latitude + dLat, from.longitude + dLon)
    }

    /** 絶対値つきの角度差(呼び出し側の見通しのため) */
    fun absAngularDiffDeg(a: Double, b: Double): Double = abs(angularDiffDeg(a, b))
}
