package dev.otosanpo.core

import kotlin.math.max
import kotlin.math.min

/**
 * 帰宅予算モデル(ゴムひもモデル)。
 * 「どの瞬間に帰路へ入っても、帰宅時間が約束の範囲に収まる」ことを保証する純粋計算。
 *
 * 距離の測り方は 2 通りあり、**経路長が取れるならそちらを使う**(2026-08-19)。
 * 直線 × 迂回率は推測でしかなく、実測の迂回率は 1.09〜1.70 に散らばっていた。
 */
object ReturnBudget {
    /** 帰宅推定の材料。どちらで測ったかをログに出せるよう、値と一緒に持ち回る */
    sealed interface Distance {
        /** 経路グラフで測った実際に歩く距離 [m]。迂回率を掛けない */
        data class Route(val meters: Double) : Distance

        /**
         * 経路長が直線距離に対して大きすぎたので、上限で頭を押さえた値 [m]。
         * スナップの誤りを疑っている状態(→ [ReturnBudget.distance])
         */
        data class CappedRoute(val meters: Double) : Distance

        /** 直線距離 [m]。経路データが無い / 圏外のときの代替。迂回率を掛ける */
        data class Straight(val meters: Double) : Distance

        /** 帰路の見積もりに使う「歩く距離」[m] */
        fun walkingM(p: AppParameters.Budget): Double = when (this) {
            is Route -> meters
            is CappedRoute -> meters
            is Straight -> meters * p.detourFactor
        }

        val label: String get() = when (this) {
            is Route -> "経路"
            is CappedRoute -> "経路(上限)"
            is Straight -> "直線"
        }

        val rawM: Double get() = when (this) {
            is Route -> meters
            is CappedRoute -> meters
            is Straight -> meters
        }
    }

    /**
     * 見積もりに使う距離を選ぶ。経路長が取れないときは直線距離に落ちる。
     *
     * **経路長は稀に大きく跳ねる。** スナップが幹線の反対側や別の道に乗ると、
     * 実際には歩かない迂回路の長さが返る。2026-08-27 の iOS 実測では 42 秒間だけ
     * 直線の 2.5〜3.06 倍を示し、**その最初の 1 サンプルで帰宅プロンプトが撃たれた**
     * (30 分の設定に対し 4 分 20 秒で「帰りどき」。推定 24.3 分に対し実測 9.9 分)。
     *
     * 跳ねていない間の比は 中央 1.42 / 95% 1.68 で、跳ねとの間が空いている。
     * **直線距離の倍数で頭を押さえれば、跳ねだけを削れる。**
     *
     * 捨てて直線 × 迂回率に戻すのではなく上限で抑えるのは、川や線路の向こうのように
     * **本当に大回りが要る場所**があるため。捨てるとそこで過小評価になり、
     * 帰りが間に合わなくなる。
     */
    fun distance(routeM: Double?, straightM: Double, p: AppParameters.Budget): Distance {
        if (routeM == null) return Distance.Straight(straightM)
        val cap = straightM * p.routeStraightMaxRatio
        return if (routeM <= cap) Distance.Route(routeM) else Distance.CappedRoute(cap)
    }

    /** 推定した帰宅所要時間 [min]。速度は実測から渡す(設定値は初期値に格下げ) */
    fun estimatedReturnMin(d: Distance, speedMPerMin: Double, p: AppParameters.Budget): Double {
        if (speedMPerMin <= 0) return Double.POSITIVE_INFINITY
        return d.walkingM(p) / speedMPerMin
    }

    /**
     * 残り時間から逆算した「自宅からの許容半径」[m]。予備時間だけを差し引く。
     * 半径は直線距離の尺度なので、迂回率で割って直線へ戻す。
     */
    fun allowedRadiusM(remainingMin: Double, speedMPerMin: Double,
                       p: AppParameters.Budget): Double =
        max(0.0, remainingMin - p.returnReserveMin) * speedMPerMin / p.detourFactor

    /**
     * 「今帰り始めれば設定時間ちょうどに着く」瞬間が来たか。
     * 帰宅プロンプトはこの条件で発火する。設定時刻で鳴らす方式では、
     * 鳴った時点からさらに帰路の時間がかかり、30 分の散歩が 45 分の外出になっていた。
     */
    fun shouldPromptReturn(remainingMin: Double, distance: Distance, speedMPerMin: Double,
                           p: AppParameters.Budget): Boolean =
        remainingMin <= estimatedReturnMin(distance, speedMPerMin, p) + p.returnReserveMin

    /**
     * 提案を自宅方向へ寄せるバイアス [0..1]。
     * 許容半径の softZoneRatio 倍までは 0(自由)、許容半径で 1(強く帰宅方向)。
     */
    fun homewardBias(distanceM: Double, allowedRadiusM: Double,
                     p: AppParameters.Budget): Double {
        if (allowedRadiusM <= 0) return 1.0
        val soft = allowedRadiusM * p.softZoneRatio
        if (distanceM <= soft) return 0.0
        if (allowedRadiusM <= soft) return 1.0
        return min(1.0, (distanceM - soft) / (allowedRadiusM - soft))
    }
}
