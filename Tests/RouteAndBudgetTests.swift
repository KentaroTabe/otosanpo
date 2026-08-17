import XCTest
@testable import OtoSanpo

final class ReturnBudgetTests: XCTestCase {
    private let budget = AppParameters.Budget(
        walkingSpeedMPerMin: 70, minMovingSpeedMPerS: 0.5, detourFactor: 1.3,
        returnReserveMin: 3, maxReturnWalkMin: 15, softZoneRatio: 0.7)

    func testEstimatedReturnMin() {
        // 700 m * 1.3 / 70 = 13 分
        XCTAssertEqual(ReturnBudget.estimatedReturnMin(distanceM: 700, p: budget), 13, accuracy: 0.01)
    }

    func testAllowedRadiusCappedByMaxReturnWalk() {
        // 残り 60 分でも、帰路は maxReturnWalkMin = 15 分ぶんが天井
        let r = ReturnBudget.allowedRadiusM(remainingMin: 60, p: budget)
        XCTAssertEqual(r, 15 * 70 / 1.3, accuracy: 0.01)
    }

    func testAllowedRadiusShrinksAsTimeRunsOut() {
        let r10 = ReturnBudget.allowedRadiusM(remainingMin: 10, p: budget)
        XCTAssertEqual(r10, 7 * 70 / 1.3, accuracy: 0.01)
        XCTAssertEqual(ReturnBudget.allowedRadiusM(remainingMin: 3, p: budget), 0, accuracy: 0.01)
        XCTAssertEqual(ReturnBudget.allowedRadiusM(remainingMin: 1, p: budget), 0, accuracy: 0.01)
    }

    func testHomewardBiasRampsInSoftZone() {
        // allowed 1000, soft 700
        XCTAssertEqual(ReturnBudget.homewardBias(distanceM: 500, allowedRadiusM: 1000, p: budget), 0)
        XCTAssertEqual(ReturnBudget.homewardBias(distanceM: 700, allowedRadiusM: 1000, p: budget), 0)
        XCTAssertEqual(ReturnBudget.homewardBias(distanceM: 850, allowedRadiusM: 1000, p: budget), 0.5, accuracy: 0.001)
        XCTAssertEqual(ReturnBudget.homewardBias(distanceM: 1000, allowedRadiusM: 1000, p: budget), 1)
        XCTAssertEqual(ReturnBudget.homewardBias(distanceM: 1200, allowedRadiusM: 1000, p: budget), 1)
    }
}

final class VisitGridTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    func testDecayHalfLife() {
        var g = VisitGrid(cellSizeM: 50, halfLifeDays: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        g.recordVisit(at: origin, date: t0)
        let t1 = t0.addingTimeInterval(10 * 86_400)
        XCTAssertEqual(g.familiarity(at: origin, now: t1, excludedFamiliarity: 8), 0.5, accuracy: 0.001)
    }

    func testExcludedCellHasFixedFamiliarity() {
        var g = VisitGrid(cellSizeM: 50, halfLifeDays: 10)
        g.markExcluded(at: origin, date: Date(timeIntervalSince1970: 0))
        // 除外セルは時間が経っても減衰しない
        let later = Date(timeIntervalSince1970: 100 * 86_400)
        XCTAssertEqual(g.familiarity(at: origin, now: later, excludedFamiliarity: 8), 8)
    }

    func testSectorFamiliarityFiltersByBearing() {
        var g = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let route = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeDays: 45, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.05, suggestionMinTravelM: 30)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        let now = Date(timeIntervalSince1970: 0)
        g.recordVisit(at: north, date: now)

        let famNorth = g.sectorFamiliarity(from: origin, bearingDeg: 0, params: route, now: now)
        let famSouth = g.sectorFamiliarity(from: origin, bearingDeg: 180, params: route, now: now)
        XCTAssertGreaterThan(famNorth, 0)
        XCTAssertEqual(famSouth, 0)
    }
}

final class BearingSuggesterTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)
    private let route = AppParameters.Route(
        cellSizeM: 50, visitHalfLifeDays: 45, sectorWidthDeg: 60,
        sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
        suggestionMarginOverStraight: 0.05, suggestionMinTravelM: 30)

    func testAllNovelPrefersStraightAndStaysSilent() {
        // 全方向が未踏なら最良は直進 → 直進に音は出さない設計なので nil
        let grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let home = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)
        let s = BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                         grid: grid, homewardBias: 0,
                                         route: route, now: Date())
        XCTAssertNil(s)
    }

    func testFamiliarAheadWithHomewardBiasSuggestsTurnTowardHome() {
        // 前方(北)は何度も通った道、自宅は東、バイアスあり → 右 90°(東)を提案するはず
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        for _ in 0..<5 {
            grid.recordVisit(at: north, date: now)
        }
        let home = Geo.destination(from: origin, bearingDeg: 90, distanceM: 500)

        let s = BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                         grid: grid, homewardBias: 0.8,
                                         route: route, now: now)
        XCTAssertEqual(s?.direction, .right90)
        XCTAssertEqual(s?.pan ?? 0, 1.0, accuracy: 0.01)
    }

    func testNarrowMarginOverStraightStaysSilent() {
        // 前方をわずかに通っただけ(直進と横のスコア差が小さい)なら鳴らさない。
        // 道の有無を知らないため、僅差で曲がらせると曲がれない場所で鳴ることになる
        var grid = VisitGrid(cellSizeM: 50, halfLifeDays: 45)
        let now = Date(timeIntervalSince1970: 0)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        grid.recordVisit(at: north, date: now)
        let home = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)

        // この配置では 直進 novelty = 1/(1+1) = 0.5、左右は未踏で 1.0 → 差はちょうど 0.5
        let narrow = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeDays: 45, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.6, suggestionMinTravelM: 30)
        XCTAssertNil(BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                              grid: grid, homewardBias: 0,
                                              route: narrow, now: now))

        // 同じ状況でも差の要求を下げれば鳴る(閾値だけの違いであることを確かめる)
        let loose = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeDays: 45, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.4, suggestionMinTravelM: 30)
        XCTAssertNotNil(BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                                 grid: grid, homewardBias: 0,
                                                 route: loose, now: now))
    }
}
