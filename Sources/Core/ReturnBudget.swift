import Foundation

/// 帰宅予算モデル(ゴムひもモデル)。
/// 「どの瞬間に帰路へ入っても、帰宅時間が約束の範囲に収まる」ことを保証するための純粋計算。
public enum ReturnBudget {
    /// 直線距離 distanceM から推定した帰宅所要時間 [min]。
    /// 実経路は直線より長いため detourFactor を掛ける。
    public static func estimatedReturnMin(distanceM: Double, p: AppParameters.Budget) -> Double {
        (distanceM * p.detourFactor) / p.walkingSpeedMPerMin
    }

    /// 残り時間 remainingMin から逆算した「自宅からの許容半径」[m]。
    /// 予備時間 returnReserveMin だけを差し引く。
    /// かつてあった帰宅時間の天井(max_return_walk_min)は 2026-08-17 に廃止した。
    /// 天井があると予算が飽和し、延長しても許容半径が伸びず条件が抜けなくなる(docs/03)
    public static func allowedRadiusM(remainingMin: Double, p: AppParameters.Budget) -> Double {
        max(0, remainingMin - p.returnReserveMin) * p.walkingSpeedMPerMin / p.detourFactor
    }

    /// 「今帰り始めれば設定時間ちょうどに着く」瞬間が来たか。
    /// 帰宅プロンプトはこの条件で発火する(2026-08-18 実装。docs/03「帰宅プロンプトの発火条件」)。
    /// sessionEnd で鳴らす方式では、鳴った時点からさらに帰路の時間がかかり、
    /// 設定 30 分の散歩が最大 45 分の外出になっていた。実測でも利用者は
    /// タイマーの 6 分前に「帰るべきタイミングが過ぎている」と感じて手動発火した。
    public static func shouldPromptReturn(remainingMin: Double, distanceM: Double,
                                          p: AppParameters.Budget) -> Bool {
        remainingMin <= estimatedReturnMin(distanceM: distanceM, p: p) + p.returnReserveMin
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
