import XCTest
@testable import OtoSanpo

/// 行き先の地帯。交差点ごとの局所評価だけでは「曲がった先がつまらない」問題が残るため、
/// 先に広域で向かう先を決める(docs/06 柱 4)。
final class ZoneMapTests: XCTestCase {
    private let p = ZoneMap.Params(zoneSizeM: 300, minRoadM: 400, sampleGrid: 3,
                                   minDistanceM: 300, minDistanceRatio: 0.4,
                                   excludedFamiliarity: 8)

    private func lat(_ m: Double) -> Double { 35.0 + m / Geo.metersPerDegreeLat }
    private func lon(_ m: Double) -> Double {
        137.0 + m / (Geo.metersPerDegreeLat * cos(35.0 * .pi / 180))
    }
    private func at(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(latitude: lat(y), longitude: lon(x))
    }

    /// 東西に離れた 2 か所に、それぞれ折れ線の道を置く。
    /// 東(x≈1000)は道が長く、西(x≈-1000)は短い
    private func twoAreas(eastRoadM: Double = 1000, westRoadM: Double = 1000) -> WalkMap {
        var nodes: [[Double]] = []
        var ways: [WalkMap.Way] = []

        func addRoad(centerX: Double, totalM: Double) {
            // 50 m 刻みの直線。地帯(300m 角)に収まるよう折り返す
            let steps = max(1, Int(totalM / 50))
            var indices: [Int] = []
            for i in 0...steps {
                let x = centerX + Double(i % 4) * 50 - 75
                let y = Double(i / 4) * 10
                nodes.append([lat(y), lon(x)])
                indices.append(nodes.count - 1)
            }
            ways.append(WalkMap.Way(n: indices, cls: .residential, cross: 0))
        }
        addRoad(centerX: 1000, totalM: eastRoadM)
        addRoad(centerX: -1000, totalM: westRoadM)

        return WalkMap(center: at(0, 0), radiusM: 5000, generated: "2026-08-19",
                       nodes: nodes, ways: ways)
    }

    func testZonesAreBuiltWhereRoadsAre() {
        let z = ZoneMap(map: twoAreas(), zoneSizeM: 300)
        XCTAssertGreaterThanOrEqual(z.zones.count, 2)
        // 道の無いところに地帯は生まれない
        for zone in z.zones {
            XCTAssertGreaterThan(zone.roadLengthM, 0)
        }
    }

    /// 両方とも未踏なら、道の多いほうを選ぶ。**道の無い地帯に価値は無い**
    func testPrefersTheAreaWithMoreRoad() {
        let z = ZoneMap(map: twoAreas(eastRoadM: 2000, westRoadM: 500), zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let t = z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 3000,
                               grid: grid, p: p)
        XCTAssertNotNil(t)
        XCTAssertGreaterThan(t?.zone.center.longitude ?? 0, lon(500), "東(道が多い側)を選ぶ")
    }

    /// 歩き込んだ側は選ばれなくなる
    func testAvoidsFamiliarAreas() {
        let z = ZoneMap(map: twoAreas(), zoneSizeM: 300)
        var grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let now = Date(timeIntervalSince1970: 0)
        // 東側を何度も歩いた
        for dx in stride(from: -150.0, through: 150.0, by: 50) {
            for dy in stride(from: 0.0, through: 100.0, by: 50) {
                for _ in 0..<10 { grid.recordVisit(at: at(1000 + dx, dy)) }
            }
        }
        let t = z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 3000,
                               grid: grid, p: p)
        XCTAssertNotNil(t)
        XCTAssertLessThan(t?.zone.center.longitude ?? 0, lon(0), "西(未踏の側)を選ぶ")
    }

    /// 帰ってこられない地帯は行き先にしない(「約束を守る」docs/01)
    func testRespectsTheBudgetRadius() {
        let z = ZoneMap(map: twoAreas(), zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let t = z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 500,
                               grid: grid, p: p)
        XCTAssertNil(t, "どちらの地帯も 1000m 先なので、許容 500m では選べない")
    }

    /// すぐ隣は行き先にならない
    func testIgnoresZonesThatAreTooClose() {
        let z = ZoneMap(map: twoAreas(), zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let near = ZoneMap.Params(zoneSizeM: 300, minRoadM: 400, sampleGrid: 3,
                                  minDistanceM: 1500, minDistanceRatio: 1.0,
                                  excludedFamiliarity: 8)
        XCTAssertNil(z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 3000,
                                    grid: grid, p: near))
    }

    /// **短い散歩でも行き先を選べる。**
    /// 最短距離が固定 300m だけだと、10 分の散歩(許容半径 377m → 数分で 300m を割る)では
    /// 行き先を 1 つも選べなくなる。実測(2026-08-19)では 9 秒しか保たなかった
    func testShortBudgetStillFindsATarget() {
        // 400m 先に地帯を置く。許容半径 500m・最短距離は min(300, 500×0.4)=200m
        var nodes: [[Double]] = []
        var indices: [Int] = []
        for i in 0...20 {
            nodes.append([lat(Double(i / 4) * 10), lon(400 + Double(i % 4) * 50 - 75)])
            indices.append(nodes.count - 1)
        }
        let map = WalkMap(center: at(0, 0), radiusM: 5000, generated: "2026-08-19",
                          nodes: nodes,
                          ways: [WalkMap.Way(n: indices, cls: .residential, cross: 0)])
        let z = ZoneMap(map: map, zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let t = z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 500,
                               grid: grid, p: p)
        XCTAssertNotNil(t, "予算が小さくても、その範囲で行ける地帯は行き先になる")
    }

    func testEffectiveMinDistanceScalesWithTheBudget() {
        // 大きい予算では固定値のまま
        XCTAssertEqual(p.effectiveMinDistanceM(allowedRadiusM: 2000), 300, accuracy: 0.01)
        // 小さい予算では行ける範囲に合わせて縮む
        XCTAssertEqual(p.effectiveMinDistanceM(allowedRadiusM: 500), 200, accuracy: 0.01)
        XCTAssertEqual(p.effectiveMinDistanceM(allowedRadiusM: 250), 100, accuracy: 0.01)
    }

    /// 同じ条件の地帯が並んだら**近いほうを選び、毎回同じ答えになる**。
    /// 未踏の地帯は新鮮さ 1.00 で同点になりやすく、比較を score だけにすると
    /// 選択が辞書の並び順まかせになって実行のたびに変わる
    func testTiesArePickedByDistanceAndAreStable() {
        let z = ZoneMap(map: twoAreas(), zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        // 東(1000m)より西(-1000m)にわずかに近い地点から選ぶ
        let from = at(-100, 0)
        let first = z.chooseTarget(from: from, home: at(0, 0), allowedRadiusM: 3000,
                                   grid: grid, p: p)
        XCTAssertNotNil(first)
        XCTAssertLessThan(first?.zone.center.longitude ?? 0, lon(0), "近い西側を選ぶ")
        for _ in 0..<5 {
            let again = z.chooseTarget(from: from, home: at(0, 0), allowedRadiusM: 3000,
                                       grid: grid, p: p)
            XCTAssertEqual(again?.zone, first?.zone, "同じ入力なら同じ行き先")
        }
    }

    /// 道の少ない地帯は行き先にしない
    func testIgnoresZonesWithTooLittleRoad() {
        let z = ZoneMap(map: twoAreas(eastRoadM: 100, westRoadM: 100), zoneSizeM: 300)
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        XCTAssertNil(z.chooseTarget(from: at(0, 0), home: at(0, 0), allowedRadiusM: 3000,
                                    grid: grid, p: p))
    }
}
