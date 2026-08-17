import Foundation

/// 実際に曲がれる道の中から 1 本を選ぶ。
///
/// `BearingSuggester`(グリッドのみ)との違い:
/// - 候補が **±45° / ±90° の推測ではなく、その交差点に実在する道**になる
/// - 通行可否が保証される(地図に無い方向は候補に入らない)
/// - 横断コストと道の種別をスコアに入れられる
/// - **来た道を除外できる**(折り返しの提案が構造的に消える)
///
/// 実測で出ていた「曲がり角の 10 m 手前で鳴る」「私有地を突っ切る」「折り返しを指す」は、
/// いずれもこの候補の作り方が原因だった(docs/04)。
public enum BranchSuggester {
    public struct Choice: Equatable {
        public let branch: Branch
        /// 進行方向に対する相対角 [deg]。音の定位に使う
        public let relativeBearingDeg: Double
        public let score: Double

        public init(branch: Branch, relativeBearingDeg: Double, score: Double) {
            self.branch = branch
            self.relativeBearingDeg = relativeBearingDeg
            self.score = score
        }
    }

    /// 交差点の分岐から 1 本選ぶ。鳴らす価値が無ければ nil。
    ///
    /// - Parameters:
    ///   - intersection: 前方の交差点
    ///   - travelBearingDeg: いまの進行方位
    ///   - position: 現在地(新鮮さの評価に使う)
    ///   - home: 自宅(帰宅バイアスに使う)
    ///   - grid: 通過履歴
    ///   - homewardBias: 0..1
    public static func choose(intersection: UpcomingIntersection,
                              travelBearingDeg: Double,
                              position: GeoPoint, home: GeoPoint,
                              grid: VisitGrid, homewardBias: Double,
                              route: AppParameters.Route, now: Date) -> Choice? {
        let homeBearing = Geo.bearingDeg(from: position, to: home)
        var straightScore: Double?
        var best: Choice?

        for b in intersection.branches {
            let rel = Geo.angularDiffDeg(b.bearingDeg, travelBearingDeg)
            // 来た道(ほぼ真後ろ)は候補にしない。折り返しは困惑とストレスの元(docs/04)
            if abs(rel) >= route.branchBackwardDeg { continue }

            let fam = grid.sectorFamiliarity(from: intersection.point, bearingDeg: b.bearingDeg,
                                             params: route, now: now)
            let novelty = 1.0 / (1.0 + fam)
            let angleToHome = abs(Geo.angularDiffDeg(b.bearingDeg, homeBearing)) / 180.0
            // 横断コストと道の種別は、どちらも「その道へ入る負担」として引く
            let crossPenalty = Double(b.crossCost) * route.crossCostWeight
            let classPenalty = Double(b.cls.preferenceRank) * route.wayClassWeight
            let score = novelty - homewardBias * angleToHome - crossPenalty - classPenalty

            // 直進に相当する分岐(進行方向にいちばん近い道)を基準にする
            if abs(rel) <= route.branchStraightDeg {
                if straightScore == nil || score > straightScore! { straightScore = score }
            }
            if best == nil || score > best!.score {
                best = Choice(branch: b, relativeBearingDeg: rel, score: score)
            }
        }

        guard let b = best else { return nil }
        // 直進が最良なら鳴らさない(直進に音は要らない)
        guard abs(b.relativeBearingDeg) > route.branchStraightDeg else { return nil }
        guard b.score >= route.suggestionMinScore else { return nil }
        // 直進との差がはっきりしている時だけ鳴らす
        if let s = straightScore, b.score - s < route.suggestionMarginOverStraight { return nil }
        return b
    }
}
