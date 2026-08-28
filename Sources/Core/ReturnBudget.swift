import Foundation

/// 帰宅予算モデル(ゴムひもモデル)。
/// 「どの瞬間に帰路へ入っても、帰宅時間が約束の範囲に収まる」ことを保証するための純粋計算。
///
/// 距離の測り方は 2 通りあり、**経路長が取れるならそちらを使う**(2026-08-19)。
/// 直線 × 迂回率は推測でしかなく、実測の迂回率は 1.09〜1.70 に散らばっていた。
/// 固定係数では安全側にも危険側にも外れる。経路データがあれば推測は要らない。
public enum ReturnBudget {
    /// 帰宅推定の材料。どちらで測ったかをログに出せるよう、値と一緒に持ち回る
    public enum Distance: Equatable {
        /// 経路グラフで測った実際に歩く距離 [m]。迂回率を掛けない
        case route(Double)
        /// 経路長が直線距離に対して大きすぎたので、上限で頭を押さえた値 [m]。
        /// スナップの誤りを疑っている状態(→ `distance(routeM:straightM:p:)`)
        case cappedRoute(Double)
        /// 直線距離 [m]。経路データが無い / 圏外のときの代替。迂回率を掛ける
        case straight(Double)

        /// 帰路の見積もりに使う「歩く距離」[m]
        public func walkingM(p: AppParameters.Budget) -> Double {
            switch self {
            case .route(let m), .cappedRoute(let m): m
            case .straight(let m): m * p.detourFactor
            }
        }

        public var label: String {
            switch self {
            case .route: "経路"
            case .cappedRoute: "経路(上限)"
            case .straight: "直線"
            }
        }

        public var rawM: Double {
            switch self {
            case .route(let m), .cappedRoute(let m), .straight(let m): m
            }
        }
    }

    /// 見積もりに使う距離を選ぶ。経路長が取れないときは直線距離に落ちる。
    ///
    /// **経路長は稀に大きく跳ねる。** スナップが幹線の反対側や別の道に乗ると、
    /// 実際には歩かない迂回路の長さが返る。2026-08-27 の実測では 42 秒間だけ
    /// 直線の 2.5〜3.06 倍を示し、**その最初の 1 サンプルで帰宅プロンプトが撃たれた**
    /// (30 分の設定に対し 4 分 20 秒で「帰りどき」。推定 24.3 分に対し実測 9.9 分)。
    ///
    /// 跳ねていない間の比は 中央 1.42 / 95% 1.68 で、跳ね(2.5 以上)との間が空いている。
    /// **直線距離の倍数で頭を押さえれば、跳ねだけを削れる。**
    ///
    /// 捨てて直線 × 迂回率に戻すのではなく上限で抑えるのは、川や線路の向こうのように
    /// **本当に大回りが要る場所**があるため。捨てるとそこで過小評価になり、
    /// 帰りが間に合わなくなる。上限で抑えれば迂回率よりは大きい値が残る。
    public static func distance(routeM: Double?, straightM: Double,
                                p: AppParameters.Budget) -> Distance {
        guard let routeM else { return .straight(straightM) }
        let cap = straightM * p.routeStraightMaxRatio
        return routeM <= cap ? .route(routeM) : .cappedRoute(cap)
    }

    /// 推定した帰宅所要時間 [min]。速度は実測から渡す(設定値は初期値に格下げ)
    public static func estimatedReturnMin(_ d: Distance, speedMPerMin: Double,
                                          p: AppParameters.Budget) -> Double {
        guard speedMPerMin > 0 else { return .infinity }
        return d.walkingM(p: p) / speedMPerMin
    }

    /// 直線距離だけが分かる場合の帰宅所要時間 [min](経路データが無いとき)
    public static func estimatedReturnMin(distanceM: Double, p: AppParameters.Budget) -> Double {
        estimatedReturnMin(.straight(distanceM), speedMPerMin: p.walkingSpeedMPerMin, p: p)
    }

    /// 残り時間 remainingMin から逆算した「自宅からの許容半径」[m]。
    /// 予備時間 returnReserveMin だけを差し引く。
    /// かつてあった帰宅時間の天井(max_return_walk_min)は 2026-08-17 に廃止した。
    /// 天井があると予算が飽和し、延長しても許容半径が伸びず条件が抜けなくなる(docs/03)
    ///
    /// 半径は直線距離の尺度なので、経路長が取れる場合でも迂回率で割って直線へ戻す。
    public static func allowedRadiusM(remainingMin: Double, speedMPerMin: Double,
                                      p: AppParameters.Budget) -> Double {
        max(0, remainingMin - p.returnReserveMin) * speedMPerMin / p.detourFactor
    }

    public static func allowedRadiusM(remainingMin: Double, p: AppParameters.Budget) -> Double {
        allowedRadiusM(remainingMin: remainingMin, speedMPerMin: p.walkingSpeedMPerMin, p: p)
    }

    /// 「今帰り始めれば設定時間ちょうどに着く」瞬間が来たか。
    /// 帰宅プロンプトはこの条件で発火する(2026-08-18 実装。docs/03「帰宅プロンプトの発火条件」)。
    /// sessionEnd で鳴らす方式では、鳴った時点からさらに帰路の時間がかかり、
    /// 設定 30 分の散歩が最大 45 分の外出になっていた。実測でも利用者は
    /// タイマーの 6 分前に「帰るべきタイミングが過ぎている」と感じて手動発火した。
    public static func shouldPromptReturn(remainingMin: Double, distance: Distance,
                                          speedMPerMin: Double,
                                          p: AppParameters.Budget) -> Bool {
        remainingMin <= estimatedReturnMin(distance, speedMPerMin: speedMPerMin, p: p)
            + p.returnReserveMin
    }

    public static func shouldPromptReturn(remainingMin: Double, distanceM: Double,
                                          p: AppParameters.Budget) -> Bool {
        shouldPromptReturn(remainingMin: remainingMin, distance: .straight(distanceM),
                           speedMPerMin: p.walkingSpeedMPerMin, p: p)
    }

    /// 提案を自宅方向へ寄せるバイアス [0..1]。
    /// 許容半径の softZoneRatio 倍までは 0(自由)、許容半径で 1(強く帰宅方向)。
    public static func homewardBias(distanceM: Double, allowedRadiusM: Double,
                                    p: AppParameters.Budget) -> Double {
        guard allowedRadiusM > 0 else { return 1 }
        let soft = allowedRadiusM * p.softZoneRatio
        if distanceM <= soft { return 0 }
        if allowedRadiusM <= soft { return 1 }
        return min(1, (distanceM - soft) / (allowedRadiusM - soft))
    }
}
