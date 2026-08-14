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
    /// 予備時間 returnReserveMin を差し引き、上限 maxReturnWalkMin でキャップする
    /// (時間無制限でも帰路が 15 分を超えないための天井)。
    public static func allowedRadiusM(remainingMin: Double, p: AppParameters.Budget) -> Double {
        let usable = max(0, min(remainingMin - p.returnReserveMin, p.maxReturnWalkMin))
        return usable * p.walkingSpeedMPerMin / p.detourFactor
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
