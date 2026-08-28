import XCTest
@testable import OtoSanpo

final class MapTilesTests: XCTestCase {

    private let size = 0.05

    // MARK: - 番号

    func testTileIdIsFloorOfCoordinate() {
        let id = MapTiles.id(of: GeoPoint(latitude: 35.18510, longitude: 136.89984), sizeDeg: size)
        XCTAssertEqual(id, MapTiles.TileID(y: 703, x: 2737))
    }

    /// タイルの中心はそのタイルに属する(番号 → 中心 → 番号 が往復する)
    func testCenterRoundTripsToTheSameTile() {
        let id = MapTiles.TileID(y: 703, x: 2737)
        let c = MapTiles.center(of: id, sizeDeg: size)
        XCTAssertEqual(MapTiles.id(of: c, sizeDeg: size), id)
        XCTAssertTrue(MapTiles.contains(id, c, sizeDeg: size))
    }

    func testFileNameRoundTrips() {
        let id = MapTiles.TileID(y: 703, x: 2737)
        XCTAssertEqual(MapTiles.fileName(id), "t703_2737.json")
        XCTAssertEqual(MapTiles.id(fromFileName: "t703_2737.json"), id)
        XCTAssertNil(MapTiles.id(fromFileName: "otosanpo-map.json"))
        XCTAssertNil(MapTiles.id(fromFileName: "meta.json"))
    }

    // MARK: - 取得範囲

    /// タイルの中心に立つと、5 km 圏は 3×3 で覆える(0.05° ≈ 緯度 5.6 km)
    func testCoveringFromTheMiddleOfATileIsThreeByThree() {
        let c = MapTiles.center(of: MapTiles.TileID(y: 703, x: 2737), sizeDeg: size)
        let ids = MapTiles.covering(center: c, radiusM: 5000, sizeDeg: size)
        XCTAssertEqual(ids.count, 9)
        XCTAssertTrue(ids.contains(MapTiles.TileID(y: 703, x: 2737)))
    }

    /// 覆いは円との交差で選ぶ。四隅のタイルが円に届かない配置では 9 枚より減る
    func testCoveringDropsCornersOutsideTheDisk() {
        let c = MapTiles.center(of: MapTiles.TileID(y: 703, x: 2737), sizeDeg: size)
        let ids = MapTiles.covering(center: c, radiusM: 2800, sizeDeg: size)
        // 半径 2.8 km: 上下左右には届くが、対角(約 3.6 km)には届かない
        XCTAssertEqual(ids.count, 5)
    }

    /// 立ち位置のタイルは必ず入る
    func testCoveringAlwaysIncludesTheTileUnderfoot() {
        let p = GeoPoint(latitude: 35.19999, longitude: 136.94999)  // タイルの隅
        let ids = MapTiles.covering(center: p, radiusM: 100, sizeDeg: size)
        XCTAssertTrue(MapTiles.cover(ids, p, sizeDeg: size))
    }

    /// 圏内判定は**矩形の集合**で行う。外接円で判定すると、離れた 2 都市を取った端末で
    /// 間の空白まで「覆っている」ことになる
    func testCoverIsExactNotACircumscribedDisk() {
        let ids = [MapTiles.TileID(y: 700, x: 2700), MapTiles.TileID(y: 700, x: 2710)]
        let between = MapTiles.center(of: MapTiles.TileID(y: 700, x: 2705), sizeDeg: size)
        XCTAssertFalse(MapTiles.cover(ids, between, sizeDeg: size))
    }

    // MARK: - 結合

    private func tileMap(ways: [[[Double]]], generated: String = "2026-08-28") -> WalkMap {
        var nodes: [[Double]] = []
        var mapWays: [WalkMap.Way] = []
        for coords in ways {
            var indices: [Int] = []
            for c in coords {
                nodes.append(c)
                indices.append(nodes.count - 1)
            }
            mapWays.append(WalkMap.Way(n: indices, cls: .residential, cross: 0))
        }
        return WalkMap(center: GeoPoint(latitude: 35, longitude: 137), radiusM: 4000,
                       generated: generated, nodes: nodes, ways: mapWays)
    }

    /// **タイルの境目でグラフが切れないこと。** 境目の節点は両側のタイルに
    /// 同じ座標で入っているので、結合時に 1 つへ畳まれて道が繋がる。
    /// これが壊れると、帰路の経路の場がタイルの縁で止まる
    func testAssembleJoinsRoadsAcrossTheTileBorder() throws {
        let border: [Double] = [35.2000000, 136.9000000]
        let tileA = tileMap(ways: [[[35.1990000, 136.9000000], border]])
        let tileB = tileMap(ways: [[border, [35.2010000, 136.9000000]]])

        let merged = try XCTUnwrap(MapTiles.assemble([tileA, tileB]))
        XCTAssertEqual(merged.nodes.count, 3, "境目の節点が畳まれて 4 → 3 になる")

        // 片側の端から反対側の端まで、経路の場が届く = グラフとして繋がっている
        let graph = WalkGraph(map: merged, cellSizeM: 50)
        let field = try XCTUnwrap(RouteField(
            graph: graph, goal: GeoPoint(latitude: 35.2010000, longitude: 136.9000000),
            snapMaxDistanceM: 25,
            weights: RouteField.Weights(crossCostWeight: 0.12, wayClassWeight: 0.08)))
        let m = field.pathLengthM(from: GeoPoint(latitude: 35.1990000, longitude: 136.9000000),
                                  graph: graph)
        XCTAssertNotNil(m)
        // 約 222 m(緯度 0.002°)
        XCTAssertEqual(try XCTUnwrap(m), 222, accuracy: 30)
    }

    func testAssembleKeepsTheNewestGeneratedDate() throws {
        let old = tileMap(ways: [[[35.1, 136.9], [35.1, 136.91]]], generated: "2026-08-20")
        let new = tileMap(ways: [[[35.2, 136.9], [35.2, 136.91]]], generated: "2026-08-28")
        let merged = try XCTUnwrap(MapTiles.assemble([old, new]))
        XCTAssertEqual(merged.generated, "2026-08-28")
    }

    func testAssembleOfNothingIsNil() {
        XCTAssertNil(MapTiles.assemble([]))
    }

    // MARK: - どの地図で歩くか

    /// 決め方の表。**タイルが勝つのは「タイルは覆い、手動は覆わない」時だけ**
    func testSourceChoiceTable() {
        typealias Row = (Bool, Bool, Bool, Bool, MapSource)
        let rows: [Row] = [
            // hasManual, manualCovers, hasTiles, tilesCover
            (false, false, false, false, .none),
            (true,  true,  false, false, .manual),
            (true,  false, false, false, .manual),   // 覆っていなくても手動しか無ければ手動
            (false, false, true,  true,  .tiles),
            (false, false, true,  false, .tiles),
            (true,  true,  true,  true,  .manual),   // 両方覆う → 人が置いたものを勝たせる
            (true,  false, true,  true,  .tiles),    // 旅行先: 古い都市ファイルは覆わない
            (true,  false, true,  false, .manual),   // 位置不明はここに落ちる(covers=false)
            (true,  true,  true,  false, .manual),
        ]
        for (hasManual, manualCovers, hasTiles, tilesCover, want) in rows {
            XCTAssertEqual(
                MapSource.choose(hasManual: hasManual, manualCovers: manualCovers,
                                 hasTiles: hasTiles, tilesCover: tilesCover),
                want,
                "hasManual=\(hasManual) manualCovers=\(manualCovers)"
                + " hasTiles=\(hasTiles) tilesCover=\(tilesCover)")
        }
    }
}
