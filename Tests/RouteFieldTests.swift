import XCTest
@testable import OtoSanpo

/// 自宅を終点とする経路の場。帰宅推定を「直線 × 迂回率」の推測から
/// 「実際に歩く距離」へ置き換えるための土台(docs/06 柱 3)。
final class RouteFieldTests: XCTestCase {
    private let weights = RouteField.Weights(crossCostWeight: 0.12, wayClassWeight: 0.08)

    private func lat(_ m: Double) -> Double { 35.0 + m / Geo.metersPerDegreeLat }
    private func lon(_ m: Double) -> Double {
        137.0 + m / (Geo.metersPerDegreeLat * cos(35.0 * .pi / 180))
    }
    private func at(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(latitude: lat(y), longitude: lon(x))
    }

    /// コの字の道。自宅(0,0)から東へ 100m、そこから北へ 100m、そこから西へ 100m。
    /// 終点(0,100)は自宅の真北 100m にあるが、**歩けば 300m** かかる
    private func uShape() -> WalkGraph {
        let nodes: [[Double]] = [
            [lat(0), lon(0)],      // 0: 自宅
            [lat(0), lon(100)],    // 1
            [lat(100), lon(100)],  // 2
            [lat(100), lon(0)],    // 3: 直線では自宅の真北 100m
        ]
        let map = WalkMap(center: at(50, 50), radiusM: 5000, generated: "2026-08-19",
                          nodes: nodes,
                          ways: [WalkMap.Way(n: [0, 1, 2, 3], cls: .residential, cross: 0)])
        return WalkGraph(map: map, cellSizeM: 50)
    }

    func testPathLengthFollowsTheRoadNotTheStraightLine() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertNotNil(f)
        let end = at(0, 100)
        // 直線なら 100m。経路なら 300m
        XCTAssertEqual(Geo.distanceM(end, at(0, 0)), 100, accuracy: 2)
        XCTAssertEqual(f?.pathLengthM(from: end, graph: g) ?? -1, 300, accuracy: 3)
    }

    func testAllNodesAreReachable() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertEqual(f?.reachableNodes, 4)
    }

    func testDistanceIncludesTheWalkToTheNearestNode() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        // 道の途中(東へ 50m)に居れば 50m
        XCTAssertEqual(f?.pathLengthM(from: at(50, 0), graph: g) ?? -1, 50, accuracy: 3)
    }

    func testReturnsNilOffTheMap() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertNil(f?.pathLengthM(from: at(0, 500), graph: g))
    }

    // MARK: - 次に曲がる地点

    func testNextTurnFindsTheCornerOnTheRoute() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        // (0,100) から自宅へ帰るには、まず東へ 100m 進んで角(100,100)で南へ曲がる
        let turn = f?.nextTurn(from: at(0, 100), graph: g,
                               straightWithinDeg: 25, maxLookM: 200)
        XCTAssertEqual(turn?.corner.latitude ?? 0, lat(100), accuracy: 0.0001)
        XCTAssertEqual(turn?.corner.longitude ?? 0, lon(100), accuracy: 0.0001)
        // 角から踏み出す向きは南(180°)
        XCTAssertEqual(turn?.branchBearingDeg ?? 0, 180, accuracy: 2)
        XCTAssertEqual(turn?.distanceM ?? 0, 100, accuracy: 3)
    }

    /// 探索範囲内に曲がる場所が無ければ黙る(まだ誘導を始めない)
    func testNextTurnIsNilWhenTheCornerIsTooFar() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertNil(f?.nextTurn(from: at(0, 100), graph: g,
                                 straightWithinDeg: 25, maxLookM: 35))
    }

    /// 経路が真っ直ぐなら曲がる場所は無い
    func testNextTurnIsNilOnAStraightRoute() {
        let nodes: [[Double]] = [[lat(0), lon(0)], [lat(0), lon(100)], [lat(0), lon(200)]]
        let map = WalkMap(center: at(100, 0), radiusM: 5000, generated: "2026-08-19",
                          nodes: nodes,
                          ways: [WalkMap.Way(n: [0, 1, 2], cls: .residential, cross: 0)])
        let g = WalkGraph(map: map, cellSizeM: 50)
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertNil(f?.nextTurn(from: at(200, 0), graph: g,
                                 straightWithinDeg: 25, maxLookM: 300))
    }

    // MARK: - いま進むべき向き(ビーコンが指す方位)

    /// **自宅の直線方向ではなく、道に沿った向きを指す。**
    /// コの字の道では、自宅は真南でも進むべきは西(角を回ってから南)
    func testNextBearingFollowsTheRoadNotTheStraightLine() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        let end = at(0, 100)
        // 自宅は真南(180°)にある
        XCTAssertEqual(Geo.bearingDeg(from: end, to: at(0, 0)), 180, accuracy: 2)
        // だが進むべきは東(角 (100,100) へ向かう)
        XCTAssertEqual(f?.nextBearingDeg(from: end, graph: g) ?? -1, 90, accuracy: 3)
    }

    /// 節点の手前ではその節点へ向かう。角を曲がる前に曲がった先を指さない
    func testPointsAtTheNextNodeWhileApproachingIt() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        // 角 (100,100) の 30m 手前(西側)
        let p = at(70, 100)
        XCTAssertEqual(f?.nextBearingDeg(from: p, graph: g) ?? -1, 90, accuracy: 3)
    }

    func testReturnsNilOffTheMapForBearing() {
        let g = uShape()
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        XCTAssertNil(f?.nextBearingDeg(from: at(0, 500), graph: g))
    }

    // MARK: - 経路の選び方

    /// 同じ距離なら、横断コストの低い道を選ぶ。
    /// 分岐提案と同じ価値観を経路にも効かせる(好みを一箇所に保つ)
    func testPrefersTheCheaperRoadWhenLengthsAreEqual() {
        // 自宅(0,0) と目的地(100,100) を、北回りと南回りの 2 本で結ぶ。長さは同じ
        let nodes: [[Double]] = [
            [lat(0), lon(0)],       // 0: 自宅
            [lat(100), lon(0)],     // 1: 北回りの折れ点
            [lat(0), lon(100)],     // 2: 南回りの折れ点
            [lat(100), lon(100)],   // 3: 出発地
        ]
        let map = WalkMap(center: at(50, 50), radiusM: 5000, generated: "2026-08-19",
                          nodes: nodes,
                          ways: [
                            // 北回り: 横断コスト 3
                            WalkMap.Way(n: [0, 1, 3], cls: .residential, cross: 3),
                            // 南回り: 横断コスト 0
                            WalkMap.Way(n: [0, 2, 3], cls: .residential, cross: 0),
                          ])
        let g = WalkGraph(map: map, cellSizeM: 50)
        let f = RouteField(graph: g, goal: at(0, 0), snapMaxDistanceM: 25, weights: weights)
        // 南回り(2 を通る)を選ぶ = 最初の角は (0,100)
        let turn = f?.nextTurn(from: at(100, 100), graph: g,
                               straightWithinDeg: 25, maxLookM: 300)
        XCTAssertEqual(turn?.corner.longitude ?? 0, lon(100), accuracy: 0.0001)
        XCTAssertEqual(turn?.corner.latitude ?? 0, lat(0), accuracy: 0.0001)
        // 実距離は重みを掛けない 200m のまま(時間の見積もりに使うため)
        XCTAssertEqual(f?.pathLengthM(from: at(100, 100), graph: g) ?? -1, 200, accuracy: 3)
    }
}
