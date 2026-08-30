import XCTest
@testable import OtoSanpo

/// 経路データの検分(`WalkMap.integrityIssue`)と、壊れた地図への防御。
///
/// なぜ要るか(2026-08-30): 経路データは**ファイル名を問わず読む**ので、
/// 形だけ合っている別物の JSON が来うる。「存在しない節点を指す道」は
/// `RouteField` の隣接の前計算が生の添字で配列を引くため、
/// **散歩開始の瞬間に落ちる**。TestFlight で配る前に入り口で拒む。
final class WalkMapIntegrityTests: XCTestCase {

    private func healthy() -> WalkMap {
        WalkMap(center: GeoPoint(latitude: 35.0, longitude: 136.0),
                radiusM: 5000,
                generated: "2026-08-30",
                nodes: [[35.0, 136.0], [35.001, 136.0], [35.001, 136.001]],
                ways: [WalkMap.Way(n: [0, 1, 2], cls: .residential, cross: 0)])
    }

    func testHealthyMapPasses() {
        XCTAssertNil(healthy().integrityIssue())
    }

    func testEmptyNodesIsRejected() {
        var m = healthy()
        m.nodes = []
        XCTAssertEqual(m.integrityIssue(), "節点が空")
    }

    func testEmptyWaysIsRejected() {
        var m = healthy()
        m.ways = []
        XCTAssertEqual(m.integrityIssue(), "道が空")
    }

    /// **落ちる形そのもの**: 道が存在しない節点を指している
    func testOutOfRangeWayIndexIsRejected() {
        var m = healthy()
        m.ways = [WalkMap.Way(n: [0, 999], cls: .residential, cross: 0)]
        XCTAssertEqual(m.integrityIssue(), "道 0 が存在しない節点 999 を指している")
    }

    func testNegativeWayIndexIsRejected() {
        var m = healthy()
        m.ways = [WalkMap.Way(n: [-1, 1], cls: .residential, cross: 0)]
        XCTAssertNotNil(m.integrityIssue())
    }

    func testShortNodeEntryIsRejected() {
        var m = healthy()
        m.nodes[1] = [35.001]
        XCTAssertEqual(m.integrityIssue(), "節点 1 に座標が足りない")
    }

    func testNonFiniteCoordinateIsRejected() {
        var m = healthy()
        m.nodes[2] = [Double.nan, 136.001]
        XCTAssertEqual(m.integrityIssue(), "節点 2 の座標が壊れている")
    }

    func testOutOfWorldCoordinateIsRejected() {
        var m = healthy()
        m.nodes[0] = [91.0, 136.0]
        XCTAssertEqual(m.integrityIssue(), "節点 0 の座標が壊れている")
    }

    func testBrokenRadiusIsRejected() {
        var m = healthy()
        m.radiusM = 0
        XCTAssertEqual(m.integrityIssue(), "中心か半径が壊れている")
    }

    // MARK: - RouteField 側の二重の守り

    /// 検分を通らずに来た壊れた地図(タイル結合など)でも、
    /// **RouteField の構築が落ちない**こと。
    /// この守りを外すと、このテストは緑にならず**プロセスごと落ちる**
    /// (生の添字アクセスのため)。それがこのテストの証明力になっている
    func testRouteFieldSurvivesRogueWay() {
        var m = healthy()
        m.ways.append(WalkMap.Way(n: [1, 999], cls: .residential, cross: 0))
        m.ways.append(WalkMap.Way(n: [-5, 0], cls: .footway, cross: 0))
        let graph = WalkGraph(map: m, cellSizeM: 50)
        let field = RouteField(graph: graph,
                               goal: GeoPoint(latitude: 35.0, longitude: 136.0),
                               snapMaxDistanceM: 25,
                               weights: .init(crossCostWeight: 0.12, wayClassWeight: 0.08))
        XCTAssertNotNil(field, "壊れた道は捨て、健全な部分で場が組めること")
        // 健全な道(節点 0-1-2)は生きている
        XCTAssertGreaterThan(field?.reachableNodes ?? 0, 0)
    }
}
