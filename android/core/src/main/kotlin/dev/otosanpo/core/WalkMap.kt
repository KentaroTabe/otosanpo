package dev.otosanpo.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * 歩ける道の種別。OSM の `highway` タグを、提案スコアに効く粒度まで畳んだもの。
 * 数値は保存形式に載るため、**既存の値を変えない**(増やすのは可)。
 */
enum class WayClass(val raw: Int) {
    /** 歩行者専用(footway / path / pedestrian / steps) */
    FOOTWAY(0),

    /** 生活道路(residential / living_street / service) */
    RESIDENTIAL(1),

    /** 幹線・準幹線(primary / secondary / tertiary)。横断コストが高い */
    ARTERIAL(2);

    /** 散歩として気持ちよい順の重み(序列であって係数ではない) */
    val preferenceRank: Int get() = raw

    companion object {
        fun from(raw: Int): WayClass = entries.firstOrNull { it.raw == raw } ?: RESIDENTIAL
    }
}

/**
 * 端末に置く経路データ。OSM から**必要な属性だけに削ぎ落とした**もの。
 * **iOS 版が作った `otosanpo-map.json` をそのまま読む**(生成側は 1 つ)。
 *
 * 落とすもの: 名前・住所・建物・POI。サイズが縮むだけでなく、
 * 余計な情報を端末に置かないため(docs/04 プライバシー)。
 */
@Serializable
data class WalkMap(
    val center: GeoPointDto,
    @SerialName("radius_m") val radiusM: Double,
    /** 生成日(ISO 8601 の日付)。地図の鮮度を画面に出すために持つ */
    val generated: String,
    /** [緯度, 経度] の並び。添字が節点番号 */
    val nodes: List<List<Double>>,
    val ways: List<Way>,
) {
    @Serializable
    data class Way(
        /** `nodes` への添字列。2 点未満の way は生成側で捨てる */
        val n: List<Int>,
        @SerialName("class") val clsRaw: Int,
        /** 横断コストの階級(0 = 横断ではない / 大きいほど渡るのが負担) */
        val cross: Int,
    ) {
        val cls: WayClass get() = WayClass.from(clsRaw)
    }

    /** GeoPoint と同じ形。JSON に載るのはこちら(Core の GeoPoint は素の値型のまま) */
    @Serializable
    data class GeoPointDto(val latitude: Double, val longitude: Double) {
        fun toPoint() = GeoPoint(latitude, longitude)
    }

    val centerPoint: GeoPoint get() = center.toPoint()

    fun point(index: Int): GeoPoint? {
        if (index !in nodes.indices) return null
        val n = nodes[index]
        if (n.size < 2) return null
        return GeoPoint(n[0], n[1])
    }

    /** 与えた地点がこの地図の圏内か。圏外ならグリッドのみで動作する */
    fun covers(p: GeoPoint): Boolean = Geo.distanceM(centerPoint, p) <= radiusM

    companion object {
        fun decode(text: String): WalkMap = mapJson.decodeFromString(serializer(), text)
    }
}

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
private val mapJson = kotlinx.serialization.json.Json {
    namingStrategy = kotlinx.serialization.json.JsonNamingStrategy.SnakeCase
    ignoreUnknownKeys = true
}

/** GPS の点を道の上に乗せた結果 */
data class Snap(
    val wayIndex: Int,
    /** way の何本目の線分か(節点 i と i+1 の間) */
    val segmentIndex: Int,
    val point: GeoPoint,
    /** 元の位置からの距離 [m] */
    val distanceM: Double,
    /** その線分の向き [deg] */
    val bearingDeg: Double,
)

/** 交差点で選べる 1 本の道 */
data class Branch(
    /** その道へ踏み出す向き [deg] */
    val bearingDeg: Double,
    val cls: WayClass,
    /** その道に入るために横断する負担 */
    val crossCost: Int,
    val wayIndex: Int,
)

/** 進行方向の先にある交差点 */
data class UpcomingIntersection(
    val nodeIndex: Int,
    val point: GeoPoint,
    val distanceM: Double,
    /** そこから選べる道(来た道を含む。除外は呼び出し側の判断) */
    val branches: List<Branch>,
)

/** 経路図に描く道の 1 線分 */
data class RoadSegment(val a: GeoPoint, val b: GeoPoint, val cls: WayClass)
