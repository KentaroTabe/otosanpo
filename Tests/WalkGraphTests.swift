import XCTest
@testable import OtoSanpo

final class WalkGraphTests: XCTestCase {
    /// 緯度 1 度 ≒ 111.32 km。南北・東西に並べた格子状の道を組む
    private func lat(_ meters: Double) -> Double { 35.0 + meters / 111_320.0 }
    private func lon(_ meters: Double) -> Double {
        139.0 + meters / (111_320.0 * cos(35.0 * .pi / 180))
    }

    /// 東西に走る道(y = 0)と、南北に走る道(x = 100)が交わる小さな地図
    private func crossMap() -> WalkMap {
        let nodes: [[Double]] = [
            [lat(0), lon(0)],       // 0
            [lat(0), lon(200)],     // 1
            [lat(-100), lon(100)],  // 2
            [lat(100), lon(100)],   // 3
        ]
        return WalkMap(
            center: GeoPoint(latitude: lat(0), longitude: lon(100)),
            radiusM: 5000, generated: "2026-08-18",
            nodes: nodes,
            ways: [
                WalkMap.Way(n: [0, 1], cls: .residential, cross: 0),
                WalkMap.Way(n: [2, 3], cls: .footway, cross: 0),
            ])
    }

    /// 道の脇の点は、最も近い道の上に落ちる
    func testSnapsToNearestWay() {
        let g = WalkGraph(map: crossMap(), cellSizeM: 50)
        // 東西の道の 10 m 北
        let p = GeoPoint(latitude: lat(10), longitude: lon(50))
        let s = g.snap(p, maxDistanceM: 30)
        XCTAssertEqual(s?.wayIndex, 0)
        XCTAssertEqual(s?.distanceM ?? -1, 10, accuracy: 1.5)
    }

    /// 南北の道に近い点はそちらへ落ちる
    func testSnapsToTheOtherWayWhenCloser() {
        let g = WalkGraph(map: crossMap(), cellSizeM: 50)
        let p = GeoPoint(latitude: lat(50), longitude: lon(95))
        XCTAssertEqual(g.snap(p, maxDistanceM: 30)?.wayIndex, 1)
    }

    /// 上限を超えて離れていれば乗せない(地図に無い場所を無理に道へ寄せない)
    func testDoesNotSnapBeyondMaxDistance() {
        let g = WalkGraph(map: crossMap(), cellSizeM: 50)
        let p = GeoPoint(latitude: lat(200), longitude: lon(400))
        XCTAssertNil(g.snap(p, maxDistanceM: 30))
    }

    /// 線分の向きが返る(進行方向と突き合わせて道に沿っているか見るため)
    func testReportsSegmentBearing() {
        let g = WalkGraph(map: crossMap(), cellSizeM: 50)
        // 東西の道は西→東なので方位 90°
        let east = g.snap(GeoPoint(latitude: lat(5), longitude: lon(50)), maxDistanceM: 30)
        XCTAssertEqual(east?.bearingDeg ?? -1, 90, accuracy: 1.0)
        // 南北の道は南→北なので方位 0°
        let north = g.snap(GeoPoint(latitude: lat(50), longitude: lon(98)), maxDistanceM: 30)
        XCTAssertEqual(north?.bearingDeg ?? -1, 0, accuracy: 1.0)
    }

    /// セルより長い線分も索引から漏れない(端点だけ登録すると中間で取りこぼす)
    func testLongSegmentIsIndexedAlongItsLength() {
        let map = WalkMap(
            center: GeoPoint(latitude: lat(0), longitude: lon(500)),
            radiusM: 5000, generated: "2026-08-18",
            nodes: [[lat(0), lon(0)], [lat(0), lon(1000)]],
            ways: [WalkMap.Way(n: [0, 1], cls: .residential, cross: 0)])
        // セル 20 m に対して線分は 1000 m。中間点で引けることを確かめる
        let g = WalkGraph(map: map, cellSizeM: 20)
        let mid = GeoPoint(latitude: lat(5), longitude: lon(500))
        XCTAssertNotNil(g.snap(mid, maxDistanceM: 30))
    }

    /// 節点が 2 つ未満の way は索引に入らない
    func testDegenerateWayIsSkipped() {
        let map = WalkMap(center: GeoPoint(latitude: lat(0), longitude: lon(0)),
                          radiusM: 5000, generated: "2026-08-18",
                          nodes: [[lat(0), lon(0)]],
                          ways: [WalkMap.Way(n: [0], cls: .footway, cross: 0)])
        let g = WalkGraph(map: map, cellSizeM: 50)
        XCTAssertEqual(g.indexedSegmentCount, 0)
        XCTAssertNil(g.snap(GeoPoint(latitude: lat(0), longitude: lon(0)), maxDistanceM: 30))
    }

    /// 圏内・圏外の判定
    func testCoversOnlyWithinRadius() {
        let m = crossMap()
        XCTAssertTrue(m.covers(m.center))
        let far = Geo.destination(from: m.center, bearingDeg: 0, distanceM: 6000)
        XCTAssertFalse(m.covers(far))
    }

    /// 経路図の下地。枠に入る線分だけを返す(枠の外の道で図が埋まらないこと)
    func testRoadSegmentsAreClippedToTheFrame() {
        let g = WalkGraph(map: crossMap(), cellSizeM: 50)
        var s = WalkSummary(startedAt: Date(timeIntervalSince1970: 0),
                            home: GeoPoint(latitude: lat(0), longitude: lon(100)))
        s.add(GeoPoint(latitude: lat(0), longitude: lon(100)), minSegmentM: 10, maxPoints: 100)
        guard let frame = s.frame(marginM: 10, minSpanM: 60) else {
            return XCTFail("枠を作れなかった")
        }
        // 交差点の周り 60 m 四方には、どちらの道も 1 線分ずつ掛かる
        XCTAssertEqual(g.roadSegments(in: frame).count, 2)

        // 遠く離れた枠には 1 本も入らない
        let far = MapFrame(northLat: lat(5000), southLat: lat(4900),
                           westLon: lon(4900), eastLon: lon(5000),
                           metersPerDegreeLon: 111_320.0 * cos(35.0 * .pi / 180))
        XCTAssertTrue(g.roadSegments(in: far).isEmpty)
    }

    /// 保存形式を往復できる(生成側と読み込み側で形が食い違わないこと)
    func testJSONRoundTrip() throws {
        let original = crossMap()
        let data = try JSONEncoder().encode(original)
        // 圧縮した鍵名で書かれていること
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"radius_m\""))
        XCTAssertTrue(text.contains("\"class\""))
        let restored = try JSONDecoder().decode(WalkMap.self, from: data)
        XCTAssertEqual(restored, original)
    }
}
