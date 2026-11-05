package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.sin

/** 提案する相対方向。宣言順が評価順(同点なら先勝ち = 直進を優先) */
enum class RelativeDirection(val offsetDeg: Double, val label: String) {
    STRAIGHT(0.0, "直進"),
    LEFT45(-45.0, "左ななめ前"),
    RIGHT45(45.0, "右ななめ前"),
    LEFT90(-90.0, "左"),
    RIGHT90(90.0, "右");

    /** ステレオパン(−1 = 左, +1 = 右) */
    val pan: Double get() = sin(offsetDeg * Math.PI / 180)
}

data class Suggestion(
    val direction: RelativeDirection,
    val absoluteBearingDeg: Double,
    val pan: Double,
)

/**
 * 「どちらへ曲がると気持ちよさそうか」を、**経路データ無しで**決める純粋ロジック。
 *
 * `BranchSuggester`(実在する分岐から選ぶ)が使えないときの代替。
 * Android では地図ファイルを入れていない人がこちらに落ちるので、**実際に使われる経路**。
 *
 * 設計上の決まり:
 * - 最良が「直進」なら鳴らさない(直進に音は要らない)
 * - 最良スコアが下限未満なら鳴らさない(無理に鳴らさない = 叱らない・急かさない)
 * - 直進との差が小さいときも鳴らさない。道の有無を知らないので、僅差で曲がらせると
 *   「曲がれない場所での提案」になりやすい
 */
object BearingSuggester {
    fun suggest(position: GeoPoint, headingDeg: Double, home: GeoPoint,
                grid: VisitGrid, homewardBias: Double,
                route: AppParameters.Route): Suggestion? {
        val homeBearing = Geo.bearingDeg(position, home)
        var bestDir: RelativeDirection? = null
        var bestScore = Double.NEGATIVE_INFINITY
        var straightScore = 0.0

        for (dir in RelativeDirection.entries) {
            val absBearing = Geo.normalizeDeg(headingDeg + dir.offsetDeg)
            val fam = grid.sectorFamiliarity(position, absBearing, route)
            val novelty = 1.0 / (1.0 + fam)
            val angleToHome = abs(Geo.angularDiffDeg(absBearing, homeBearing)) / 180.0
            val score = novelty - homewardBias * angleToHome
            if (dir == RelativeDirection.STRAIGHT) straightScore = score
            if (bestDir == null || score > bestScore) {
                bestDir = dir
                bestScore = score
            }
        }

        val dir = bestDir ?: return null
        if (dir == RelativeDirection.STRAIGHT) return null
        if (bestScore < route.suggestionMinScore) return null
        if (bestScore - straightScore < route.suggestionMarginOverStraight) return null
        val absBearing = Geo.normalizeDeg(headingDeg + dir.offsetDeg)
        return Suggestion(dir, absBearing, dir.pan)
    }
}
