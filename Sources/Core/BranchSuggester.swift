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
        /// この分岐の新鮮さ(penalty を引く前)。直進との比較は score ではなくこちらで行う
        public let novelty: Double

        public init(branch: Branch, relativeBearingDeg: Double, score: Double, novelty: Double) {
            self.branch = branch
            self.relativeBearingDeg = relativeBearingDeg
            self.score = score
            self.novelty = novelty
        }
    }

    /// 分岐を選ばなかった理由。「鳴らない」の内訳が分からないと調整できない
    public enum Silence: String, Equatable {
        case noCandidates = "候補なし"
        case straightIsBest = "直進が最良"
        case marginTooSmall = "直進との差が小さい"
    }

    public enum Decision: Equatable {
        case suggest(Choice)
        /// 黙った理由と、そのとき最良だった候補(候補なしの場合だけ nil)。
        /// **「惜しかったのか、遠く及ばなかったのか」が分からないと閾値を動かせない。**
        /// 実測(2026-08-18)では、最良スコアの分布を見て初めて絶対下限が高すぎると分かった
        case silent(Silence, best: Choice?)

        /// そのとき最良だった候補(鳴らした場合はそれ自身)
        public var best: Choice? {
            switch self {
            case .suggest(let c): c
            case .silent(_, let b): b
            }
        }
    }

    /// 交差点の分岐から 1 本選ぶ。鳴らす価値が無ければ理由つきで黙る。
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
                              target: GeoPoint? = nil, graph: WalkGraph? = nil,
                              route: AppParameters.Route) -> Choice? {
        if case .suggest(let c) = decide(intersection: intersection,
                                         travelBearingDeg: travelBearingDeg,
                                         position: position, home: home, grid: grid,
                                         homewardBias: homewardBias, target: target,
                                         graph: graph, route: route) {
            return c
        }
        return nil
    }

    /// - Parameters:
    ///   - target: 向かっている地帯(ZoneMap が選ぶ)。
    ///     局所の選択に広域の向きを与える。帰宅バイアスが立つにつれ効き目は畳まれる
    ///   - graph: 与えると**新鮮さをその道に沿って測る**。無ければ扇形で代用する
    public static func decide(intersection: UpcomingIntersection,
                              travelBearingDeg: Double,
                              position: GeoPoint, home: GeoPoint,
                              grid: VisitGrid, homewardBias: Double,
                              target: GeoPoint? = nil, graph: WalkGraph? = nil,
                              route: AppParameters.Route) -> Decision {
        let homeBearing = Geo.bearingDeg(from: position, to: home)
        let targetBearing = target.map { Geo.bearingDeg(from: position, to: $0) }
        // 行き先の寄与は帰宅バイアスの裏返し。**帰宅が常に優先**なので、
        // 帰りどきが近づくほど行き先は畳まれて消える
        let targetWeight = route.targetBiasWeight * (1 - homewardBias)
        var straightNovelty: Double?
        var best: Choice?

        for b in intersection.branches {
            let rel = Geo.angularDiffDeg(b.bearingDeg, travelBearingDeg)
            // 来た道(ほぼ真後ろ)は候補にしない。折り返しは困惑とストレスの元(docs/04)
            if abs(rel) >= route.branchBackwardDeg { continue }

            // **その道に沿って測る。** 扇形だと、そこから行けない別の道や
            // 道でない場所まで混ざる(docs/04)
            let samples = graph?.samplesAlong(branch: b, from: intersection.nodeIndex,
                                              withinM: route.sectorRadiusM,
                                              stepM: route.cellSizeM) ?? []
            let fam = samples.isEmpty
                ? grid.sectorFamiliarity(from: intersection.point, bearingDeg: b.bearingDeg,
                                         params: route)
                : grid.averageFamiliarity(at: samples,
                                          excludedFamiliarity: route.excludedFamiliarity)
            let novelty = 1.0 / (1.0 + fam)
            let angleToHome = abs(Geo.angularDiffDeg(b.bearingDeg, homeBearing)) / 180.0
            // 横断コストと道の種別は、どちらも「その道へ入る負担」として引く
            let crossPenalty = Double(b.crossCost) * route.crossCostWeight
            let classPenalty = Double(b.cls.preferenceRank) * route.wayClassWeight
            // 行き先から逸れる方向を引く(帰宅バイアスと同じ形。向く先が違うだけ)
            let targetPenalty = targetBearing.map {
                targetWeight * abs(Geo.angularDiffDeg(b.bearingDeg, $0)) / 180.0
            } ?? 0
            let score = novelty - homewardBias * angleToHome - crossPenalty - classPenalty
                - targetPenalty

            // 直進に相当する分岐(進行方向にいちばん近い道)を基準にする
            if abs(rel) <= route.branchStraightDeg {
                if straightNovelty == nil || novelty > straightNovelty! { straightNovelty = novelty }
            }
            if best == nil || score > best!.score {
                best = Choice(branch: b, relativeBearingDeg: rel, score: score, novelty: novelty)
            }
        }

        guard let b = best else { return .silent(.noCandidates, best: nil) }
        // 直進が最良なら鳴らさない(直進に音は要らない)
        guard abs(b.relativeBearingDeg) > route.branchStraightDeg else {
            return .silent(.straightIsBest, best: b)
        }
        // **絶対値の下限は課さない**(`suggestion_min_score` はグリッドのみの経路で使う)。
        // 分岐選択は「ここにある道のうちどれが良いか」という相対比較であり、
        // 絶対的な新鮮さの下限を課すと、歩き込んだ界隈では一切鳴らなくなる。
        // 実測(2026-08-18): 交差点接近 824 回に対し提案 0 件。最良スコアの中央値は
        // -0.17 で、閾値 0.15 に遠く届いていなかった(docs/04)
        //
        // 直進との比較は**絶対差ではなく比**で見る。新鮮さ 1/(1+馴染み度) は
        // 馴染むほど 0 に圧縮されるので、絶対差では歩き込んだ地点ほど黙ってしまう。
        // 比なら「直進より何割新鮮か」を尺度によらず判定できる
        if let s = straightNovelty, s > 0, b.novelty < s * route.branchNoveltyRatio {
            return .silent(.marginTooSmall, best: b)
        }
        return .suggest(b)
    }
}
