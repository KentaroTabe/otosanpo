package dev.otosanpo.core

import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

/**
 * 経路図の枠。緯度経度を「左上を原点とするメートルの平面」に落とす。
 * 散歩スケール(数 km)なので等距円筒近似で足りる。
 */
data class MapFrame(
    val northLat: Double,
    val southLat: Double,
    val westLon: Double,
    val eastLon: Double,
    /** 経度 1 度あたりのメートル(枠の中央緯度で決める) */
    val metersPerDegreeLon: Double,
) {
    val widthM: Double get() = (eastLon - westLon) * metersPerDegreeLon
    val heightM: Double get() = (northLat - southLat) * Geo.METERS_PER_DEGREE_LAT

    /** 枠の中でのメートル座標。x は東へ、y は南へ(**北が上**の図になる) */
    fun point(p: GeoPoint): Pair<Double, Double> =
        Pair((p.longitude - westLon) * metersPerDegreeLon,
             (northLat - p.latitude) * Geo.METERS_PER_DEGREE_LAT)

    /** 線分が枠と重なりうるか(図の下地を間引くための粗い判定) */
    fun mayContain(a: GeoPoint, b: GeoPoint): Boolean =
        min(a.latitude, b.latitude) <= northLat && max(a.latitude, b.latitude) >= southLat &&
            min(a.longitude, b.longitude) <= eastLon && max(a.longitude, b.longitude) >= westLon
}

/**
 * 1 回の散歩の記録。**開発中の振り返りのために残す**。
 *
 * 音だけの体験は歩いている最中に書き留められない。帰ってから
 * 「3 番目の案内が道の無い方を指した」と言えるように、経路と**番号を振ったイベント**を残す。
 * 番号の単位は利用者の言う「n 回目のイベント」= 曲がる誘導 1 件。
 *
 * 端末内にのみ保存し、送信しない。
 */
class WalkSummary(
    val startedAt: Long,
    val home: GeoPoint?,
) {
    /** 経路図に置く印 */
    enum class Mark { GUIDANCE, RETURN_START, EXTENDED, ARRIVAL }

    data class Event(
        /** 誘導だけに振る 1 起点の連番。他の印は null */
        val number: Int?,
        val mark: Mark,
        /** 印を置く場所。誘導は角そのもの */
        val at: GeoPoint,
        /** 誘導が指した向き [deg]。図の矢印になる */
        val bearingDeg: Double?,
        /** 散歩の開始からの経過 [sec] */
        val elapsedSec: Double,
        /** 誘導の終わり方。鳴っている間は null */
        var ending: String?,
        val onReturn: Boolean,
    )

    var endedAt: Long? = null
        private set
    val track = mutableListOf<GeoPoint>()
    val events = mutableListOf<Event>()

    /** 実経路長 [m]。**測るのは GaitMetrics の仕事**なので、閉じるときに受け取るだけ */
    var pathLengthM: Double = 0.0
        private set

    private var thinScale: Double = 1.0
    private var guidanceCount: Int = 0

    /**
     * 位置更新を経路に足す。`minSegmentM` 未満の動きは GPS の揺れとして捨てる
     * (経路長と同じ基準を使う。図と距離が食い違わないため)。
     *
     * 点が上限に達したら 1 つおきに間引き、以後の間隔を 2 倍にする。
     */
    fun add(p: GeoPoint, minSegmentM: Double, maxPoints: Int) {
        val last = track.lastOrNull()
        if (last != null && Geo.distanceM(last, p) < minSegmentM * thinScale) return
        track.add(p)
        if (maxPoints < 2 || track.size <= maxPoints) return
        val kept = ArrayList<GeoPoint>(track.size / 2 + 1)
        for ((i, q) in track.withIndex()) if (i % 2 == 0) kept.add(q)
        // 末尾は必ず残す。現在地が消えると図の末端が切れて見える
        val tail = track.last()
        if (kept.lastOrNull() != tail) kept.add(tail)
        track.clear()
        track.addAll(kept)
        thinScale *= 2
    }

    /** 曲がる誘導が鳴った。**番号はここで振る**(鳴らずに終わった誘導は番号を持たない) */
    fun startGuidance(corner: GeoPoint, bearingDeg: Double, onReturn: Boolean,
                      nowMillis: Long): Int {
        guidanceCount += 1
        events.add(Event(guidanceCount, Mark.GUIDANCE, corner, bearingDeg,
                         (nowMillis - startedAt) / 1000.0, null, onReturn))
        return guidanceCount
    }

    /** まだ終わり方の書かれていない誘導に、終わり方を書き込む */
    fun finishGuidance(ending: String) {
        val e = events.lastOrNull { it.mark == Mark.GUIDANCE && it.ending == null } ?: return
        e.ending = ending
    }

    /** 誘導以外の印(帰路開始・延長・到着) */
    fun addMark(mark: Mark, at: GeoPoint, onReturn: Boolean, nowMillis: Long) {
        events.add(Event(null, mark, at, null, (nowMillis - startedAt) / 1000.0, null, onReturn))
    }

    /** 記録を閉じる。距離は計測側(GaitMetrics)の値をそのまま受け取る */
    fun finish(atMillis: Long, pathLengthM: Double) {
        endedAt = atMillis
        this.pathLengthM = pathLengthM
    }

    val durationSec: Double get() = ((endedAt ?: startedAt) - startedAt) / 1000.0

    /** 番号の振られたイベント(利用者が「n 回目」と数える単位) */
    val guidanceEvents: List<Event> get() = events.filter { it.mark == Mark.GUIDANCE }

    /** 終わり方ごとの件数。件数の多い順、同数なら名前順(表示が回ごとに入れ替わらないように) */
    fun endingCounts(): List<Pair<String, Int>> =
        guidanceEvents.groupingBy { it.ending ?: "途中" }.eachCount()
            .toList()
            .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })

    /**
     * 経路図の枠。経路・イベント・自宅をすべて含み、周囲に `marginM` の余白を取る。
     * ごく短い散歩でも `minSpanM` までは広げる。
     */
    fun frame(marginM: Double, minSpanM: Double): MapFrame? {
        val points = buildList {
            addAll(track)
            addAll(events.map { it.at })
            home?.let { add(it) }
        }
        val first = points.firstOrNull() ?: return null
        var minLat = first.latitude; var maxLat = first.latitude
        var minLon = first.longitude; var maxLon = first.longitude
        for (p in points) {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        val lonScale = Geo.METERS_PER_DEGREE_LAT * cos((minLat + maxLat) / 2 * Math.PI / 180)
        if (lonScale <= 0) return null

        fun expand(lo: Double, hi: Double, perDegree: Double): Pair<Double, Double> {
            val spanM = (hi - lo) * perDegree
            val wantM = max(spanM + 2 * marginM, minSpanM)
            val addDeg = (wantM - spanM) / 2 / perDegree
            return Pair(lo - addDeg, hi + addDeg)
        }
        val (south, north) = expand(minLat, maxLat, Geo.METERS_PER_DEGREE_LAT)
        val (west, east) = expand(minLon, maxLon, lonScale)
        return MapFrame(north, south, west, east, lonScale)
    }
}
