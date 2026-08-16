import Foundation

/// 提案する相対方向。宣言順が評価順(同点なら先勝ち=直進を優先)。
public enum RelativeDirection: CaseIterable, Equatable {
    case straight, left45, right45, left90, right90

    public var offsetDeg: Double {
        switch self {
        case .straight: 0
        case .left45: -45
        case .right45: 45
        case .left90: -90
        case .right90: 90
        }
    }

    /// ステレオパン(-1=左, +1=右)
    public var pan: Float {
        Float(sin(offsetDeg * .pi / 180))
    }
}

public struct Suggestion: Equatable {
    public let direction: RelativeDirection
    public let absoluteBearingDeg: Double
    public let pan: Float
}

/// 「どちらへ曲がると気持ちよさそうか」を決める純粋ロジック。
/// score = novelty - homewardBias * (自宅方向からの角度差 / 180)
///   novelty = 1 / (1 + sectorFamiliarity) ∈ (0, 1]
/// 設計上の決まり:
/// - 最良が「直進」の場合は nil を返す(直進に音は要らない。曲がるときだけ鳴らす)
/// - 最良スコアが suggestionMinScore 未満なら nil(無理に鳴らさない=叱らない・急かさない)
/// - 直進との差が suggestionMarginOverStraight 未満なら nil。
///   このアプリは道の有無を知らないため、僅差で曲がらせると「曲がれない場所での提案」に
///   なりやすい。はっきり差がある時だけ鳴らして外れの回数を減らす(既知の制限は docs/04)
public enum BearingSuggester {
    public static func suggest(position: GeoPoint, headingDeg: Double, home: GeoPoint,
                               grid: VisitGrid, homewardBias: Double,
                               route: AppParameters.Route, now: Date) -> Suggestion? {
        let homeBearing = Geo.bearingDeg(from: position, to: home)
        var best: (dir: RelativeDirection, score: Double)?
        var straightScore = 0.0

        for dir in RelativeDirection.allCases {
            let absBearing = Geo.normalizeDeg(headingDeg + dir.offsetDeg)
            let fam = grid.sectorFamiliarity(from: position, bearingDeg: absBearing,
                                             params: route, now: now)
            let novelty = 1.0 / (1.0 + fam)
            let angleToHome = abs(Geo.angularDiffDeg(absBearing, homeBearing)) / 180.0
            let score = novelty - homewardBias * angleToHome
            if dir == .straight { straightScore = score }
            if best == nil || score > best!.score {
                best = (dir, score)
            }
        }

        guard let b = best, b.dir != .straight,
              b.score >= route.suggestionMinScore,
              b.score - straightScore >= route.suggestionMarginOverStraight else {
            return nil
        }
        let absBearing = Geo.normalizeDeg(headingDeg + b.dir.offsetDeg)
        return Suggestion(direction: b.dir, absoluteBearingDeg: absBearing, pan: b.dir.pan)
    }
}
