import XCTest
@testable import OtoSanpo

final class BranchSuggesterTests: XCTestCase {
    private func lat(_ m: Double) -> Double { 35.0 + m / 111_320.0 }
    private func lon(_ m: Double) -> Double { 139.0 + m / (111_320.0 * cos(35.0 * .pi / 180)) }

    private let route = AppParameters.Route(
        cellSizeM: 50, visitHalfLifeDays: 45, sectorWidthDeg: 60,
        sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
        suggestionMarginOverStraight: 0.05, suggestionMinTravelM: 30,
        mapRadiusM: 5000, mapIndexCellSizeM: 50, snapMaxDistanceM: 25,
        intersectionLookaheadM: 35, branchStraightDeg: 25, branchBackwardDeg: 135,
        crossCostWeight: 0.12, wayClassWeight: 0.08, branchNoveltyRatio: 1.3,
        zoneSizeM: 300, zoneMinRoadM: 400, zoneSampleGrid: 3,
        targetMinDistanceM: 300, targetMinDistanceRatio: 0.4,
        targetReachedM: 150, targetBiasWeight: 0.3)

    /// 十字路。北から来て、東西南へ分かれる
    /// 節点 0 = 交差点、1 = 北(来た道)、2 = 東、3 = 南(直進)、4 = 西
    private func crossroads(eastClass: WayClass = .residential, eastCross: Int = 0) -> WalkGraph {
        let map = WalkMap(
            center: GeoPoint(latitude: lat(0), longitude: lon(0)),
            radiusM: 5000, generated: "2026-08-18",
            nodes: [
                [lat(0), lon(0)],     // 0 交差点
                [lat(100), lon(0)],   // 1 北
                [lat(0), lon(100)],   // 2 東
                [lat(-100), lon(0)],  // 3 南
                [lat(0), lon(-100)],  // 4 西
            ],
            ways: [
                WalkMap.Way(n: [1, 0, 3], cls: .residential, cross: 0),
                WalkMap.Way(n: [0, 2], cls: eastClass, cross: eastCross),
                WalkMap.Way(n: [0, 4], cls: .residential, cross: 0),
            ])
        return WalkGraph(map: map, cellSizeM: 50)
    }

    /// 交差点は分岐 3 方向以上で判定される
    func testIntersectionIsDetectedByBranchCount() {
        let g = crossroads()
        XCTAssertTrue(g.isIntersection(0))
        XCTAssertEqual(g.branches(at: 0).count, 4)
        // 端の節点は行き止まりなので交差点ではない
        XCTAssertFalse(g.isIntersection(2))
    }

    /// 前方の交差点だけを拾う(後ろの交差点は「これから曲がる場所」ではない)
    func testUpcomingIntersectionOnlyLooksForward() {
        let g = crossroads()
        // 交差点の 20 m 北から南へ向かって歩いている
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        XCTAssertNotNil(g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35))
        // 同じ場所から北へ向かっていれば、交差点は背後にある
        XCTAssertNil(g.upcomingIntersection(from: p, bearingDeg: 0, withinM: 35))
    }

    /// 届かない距離の交差点は拾わない
    func testUpcomingIntersectionRespectsRange() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(80), longitude: lon(0))
        XCTAssertNil(g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35))
    }

    /// 来た道(真後ろ)は候補にならない。折り返しの提案が構造的に消える
    func testBackwardBranchIsNeverChosen() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        // 北(来た道)を強く新鮮に、他を馴染ませても北は選ばれない
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        for b in [90.0, 180.0, 270.0] {
            let q = Geo.destination(from: x.point, bearingDeg: b, distanceM: 100)
            for _ in 0..<5 { grid.recordVisit(at: q, date: now) }
        }
        let home = Geo.destination(from: x.point, bearingDeg: 0, distanceM: 500)
        let c = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 1.0, route: route, now: now)
        // 北を向く提案(相対角の大きさが branchBackwardDeg 以上)は出ない
        if let c { XCTAssertLessThan(abs(c.relativeBearingDeg), 135) }
    }

    /// 直進が最良なら鳴らさない
    func testStaysSilentWhenStraightIsBest() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        // 東西を馴染ませ、直進(南)を新鮮に保つ
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        for b in [90.0, 270.0] {
            let q = Geo.destination(from: x.point, bearingDeg: b, distanceM: 100)
            for _ in 0..<5 { grid.recordVisit(at: q, date: now) }
        }
        let home = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 500)
        XCTAssertNil(BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                           position: p, home: home, grid: grid,
                                           homewardBias: 0, route: route, now: now))
    }

    /// 直進が馴染んでいれば、実在する横道を提案する
    func testSuggestsAnExistingSideRoad() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        let south = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 100)
        for _ in 0..<8 { grid.recordVisit(at: south, date: now) }
        let home = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 500)
        let c = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 0, route: route, now: now)
        XCTAssertNotNil(c)
        // 東(相対 -90)か西(相対 +90)のどちらか
        XCTAssertEqual(abs(c?.relativeBearingDeg ?? 0), 90, accuracy: 1.0)
    }

    /// 横断コストが高い道は、同じ新鮮さなら選ばれにくくなる
    func testCrossingCostPushesTheChoiceAway() {
        let now = Date(timeIntervalSince1970: 0)
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        // 直進(南)を馴染ませて、東西のどちらかを選ばせる状況にする
        let center = GeoPoint(latitude: lat(0), longitude: lon(0))
        for _ in 0..<8 {
            grid.recordVisit(at: Geo.destination(from: center, bearingDeg: 180, distanceM: 100),
                             date: now)
        }
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let home = Geo.destination(from: center, bearingDeg: 180, distanceM: 500)

        // 東が幹線で横断コスト 4 なら、西(生活道路)が選ばれる
        let g = crossroads(eastClass: .arterial, eastCross: 4)
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        let c = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 0, route: route, now: now)
        XCTAssertEqual(c?.branch.cls, .residential)
        XCTAssertEqual(c?.relativeBearingDeg ?? 0, 90, accuracy: 1.0)  // 西
    }

    /// 歩き込んで新鮮さが枯れた界隈でも、相対的に良い分岐があれば鳴る。
    /// 絶対値の下限を課していた頃は、交差点接近 824 回に対し提案 0 件だった(2026-08-18 実測)
    func testSuggestsEvenWhenEverythingIsFamiliar() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        // 全方向を歩き込む(絶対値の下限を割る水準)。直進(南)はさらに濃く
        for b in [90.0, 270.0] {
            let q = Geo.destination(from: x.point, bearingDeg: b, distanceM: 100)
            for _ in 0..<5 { grid.recordVisit(at: q, date: now) }
        }
        let south = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 100)
        for _ in 0..<40 { grid.recordVisit(at: south, date: now) }
        let home = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 500)

        let d = BranchSuggester.decide(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 0, route: route, now: now)
        guard case .suggest(let c) = d else {
            return XCTFail("馴染んだ界隈でも相対的に良い分岐は鳴るべき: \(d)")
        }
        // 絶対スコアは低くてよい。直進より良いことが条件
        XCTAssertLessThan(c.score, route.suggestionMinScore)
        XCTAssertEqual(abs(c.relativeBearingDeg), 90, accuracy: 1.0)
    }

    /// 黙った理由が分かる(内訳が取れないと調整できない)
    func testSilenceCarriesItsReason() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        for b in [90.0, 270.0] {
            let q = Geo.destination(from: x.point, bearingDeg: b, distanceM: 100)
            for _ in 0..<5 { grid.recordVisit(at: q, date: now) }
        }
        let home = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 500)
        let d = BranchSuggester.decide(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 0, route: route, now: now)
        guard case .silent(let why, let best) = d else {
            return XCTFail("直進が最良なのに提案した")
        }
        XCTAssertEqual(why, .straightIsBest)
        // 黙った時も最良候補は残す(「惜しかったのか」が分からないと閾値を動かせない)
        XCTAssertEqual(best?.relativeBearingDeg ?? .nan, 0, accuracy: 1)
    }

    // MARK: - 行き先バイアス(広域の向きを局所の選択に効かせる)

    /// 東西どちらも同じ条件なら、行き先のある側を選ぶ。
    /// 交差点ごとの評価だけでは、曲がった先がつまらない場所に出る(2026-08-19 の指摘)
    func testTargetPullsTheChoiceTowardIt() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        // 直進(南)を馴染ませ、東西のどちらかを選ばせる
        let south = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 100)
        for _ in 0..<8 { grid.recordVisit(at: south, date: now) }
        let home = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 500)

        // 行き先が東(90°)にあれば東、西(270°)にあれば西
        let east = Geo.destination(from: p, bearingDeg: 90, distanceM: 800)
        let west = Geo.destination(from: p, bearingDeg: 270, distanceM: 800)
        let toEast = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                            position: p, home: home, grid: grid,
                                            homewardBias: 0, target: east,
                                            route: route, now: now)
        let toWest = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                            position: p, home: home, grid: grid,
                                            homewardBias: 0, target: west,
                                            route: route, now: now)
        // 南へ歩いているので、東は相対 -90(左)、西は相対 +90(右)
        XCTAssertEqual(toEast?.relativeBearingDeg ?? 0, -90, accuracy: 1)
        XCTAssertEqual(toWest?.relativeBearingDeg ?? 0, 90, accuracy: 1)
    }

    /// **帰宅が常に優先**。帰りどきになれば行き先の寄与は消える
    func testTargetIsFoldedAwayAsHomewardBiasRises() {
        let g = crossroads()
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        let x = g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35)!
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        let south = Geo.destination(from: x.point, bearingDeg: 180, distanceM: 100)
        for _ in 0..<8 { grid.recordVisit(at: south, date: now) }

        // 自宅は西、行き先は東。バイアスが最大なら自宅側(西)が勝つ
        let home = Geo.destination(from: x.point, bearingDeg: 270, distanceM: 500)
        let east = Geo.destination(from: p, bearingDeg: 90, distanceM: 800)
        let c = BranchSuggester.choose(intersection: x, travelBearingDeg: 180,
                                       position: p, home: home, grid: grid,
                                       homewardBias: 1.0, target: east,
                                       route: route, now: now)
        XCTAssertEqual(c?.relativeBearingDeg ?? 0, 90, accuracy: 1, "西(自宅側)")
    }

    /// 分岐が 2 方向しかない(道が続いているだけ)場所では交差点として扱わない
    func testStraightThroughNodeIsNotAnIntersection() {
        let map = WalkMap(center: GeoPoint(latitude: lat(0), longitude: lon(0)),
                          radiusM: 5000, generated: "2026-08-18",
                          nodes: [[lat(100), lon(0)], [lat(0), lon(0)], [lat(-100), lon(0)]],
                          ways: [WalkMap.Way(n: [0, 1, 2], cls: .residential, cross: 0)])
        let g = WalkGraph(map: map, cellSizeM: 50)
        XCTAssertFalse(g.isIntersection(1))
        let p = GeoPoint(latitude: lat(20), longitude: lon(0))
        XCTAssertNil(g.upcomingIntersection(from: p, bearingDeg: 180, withinM: 35))
    }
}
