import XCTest
@testable import OtoSanpo

final class ReturnBudgetTests: XCTestCase {
    private let budget = AppParameters.Budget(
        walkingSpeedMPerMin: 70, minMovingSpeedMPerS: 0.5, pathSegmentMinM: 10,
        maxAccuracyForMetricsM: 20, detourFactor: 1.3, routeStraightMaxRatio: 2.0,
        returnReserveMin: 3, softZoneRatio: 0.7,
        speedEwmaWeight: 0.4, speedMinSamples: 60,
        speedMinMPerMin: 45, speedMaxMPerMin: 90)

    func testEstimatedReturnMin() {
        // 700 m * 1.3 / 70 = 13 分
        XCTAssertEqual(ReturnBudget.estimatedReturnMin(distanceM: 700, p: budget), 13, accuracy: 0.01)
    }

    func testAllowedRadiusGrowsWithRemainingTime() {
        // 天井(max_return_walk_min)は廃止した。残り時間に応じて許容半径は伸び続ける。
        // 天井があると予算が飽和し、延長しても条件が抜けなくなる(docs/03)
        let r = ReturnBudget.allowedRadiusM(remainingMin: 60, p: budget)
        XCTAssertEqual(r, 57 * 70 / 1.3, accuracy: 0.01)
    }

    func testShouldPromptReturnAtTheTurnaroundMoment() {
        // 帰宅推定 = 700 × 1.3 / 70 = 13 分。予備 3 分 → 残り 16 分ちょうどで発火
        XCTAssertFalse(ReturnBudget.shouldPromptReturn(remainingMin: 17, distanceM: 700, p: budget))
        XCTAssertTrue(ReturnBudget.shouldPromptReturn(remainingMin: 16, distanceM: 700, p: budget))
        XCTAssertTrue(ReturnBudget.shouldPromptReturn(remainingMin: 10, distanceM: 700, p: budget))
    }

    func testShouldPromptNearHomeOnlyWhenTimeIsAlmostUp() {
        // 自宅の目の前に居れば、残りが予備時間を切るまで鳴らない
        XCTAssertFalse(ReturnBudget.shouldPromptReturn(remainingMin: 5, distanceM: 10, p: budget))
        XCTAssertTrue(ReturnBudget.shouldPromptReturn(remainingMin: 3, distanceM: 10, p: budget))
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

    /// **減衰の時計は日数ではなく歩いた総距離**(2026-08-20 決定)。
    /// 歩かなかった期間に新鮮さが戻るのはおかしい
    func testDecayFollowsDistanceWalked() {
        var g = VisitGrid(cellSizeM: 50, halfLifeM: 10_000)
        g.recordVisit(at: origin)
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 1.0, accuracy: 0.001)
        // 半減期ぶん(10 km)歩けば半分
        g.advance(byM: 10_000)
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 0.5, accuracy: 0.001)
        // さらに 10 km でその半分
        g.advance(byM: 10_000)
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 0.25, accuracy: 0.001)
    }

    /// **歩かなければ減らない。** 時計を進めなければ何も変わらない
    func testDoesNotDecayWithoutWalking() {
        var g = VisitGrid(cellSizeM: 50, halfLifeM: 10_000)
        g.recordVisit(at: origin)
        g.advance(byM: 0)
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 1.0, accuracy: 0.001)
    }

    /// 通うほど積み上がり、間に歩いた分だけ目減りする
    func testRepeatedVisitsAccumulateOnTopOfDecay() {
        var g = VisitGrid(cellSizeM: 50, halfLifeM: 10_000)
        g.recordVisit(at: origin)
        g.advance(byM: 10_000)
        g.recordVisit(at: origin)
        // 1.0 が 0.5 に減ってから +1
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 1.5, accuracy: 0.001)
    }

    func testExcludedCellHasFixedFamiliarity() {
        var g = VisitGrid(cellSizeM: 50, halfLifeM: 10_000)
        g.markExcluded(at: origin)
        // 除外セルはどれだけ歩いても減衰しない
        g.advance(byM: 100_000)
        XCTAssertEqual(g.familiarity(at: origin, excludedFamiliarity: 8), 8)
    }

    func testSectorFamiliarityFiltersByBearing() {
        var g = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let route = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeM: 20_000, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.05, suggestionMinTravelM: 30,
            mapRadiusM: 5000, mapIndexCellSizeM: 50, snapMaxDistanceM: 25, nodeArrivalToleranceM: 8,
            intersectionLookaheadM: 35, branchStraightDeg: 25, branchBackwardDeg: 135,
            crossCostWeight: 0.12, wayClassWeight: 0.08, branchNoveltyRatio: 1.3,
            zoneSizeM: 300, zoneMinRoadM: 400, zoneSampleGrid: 3,
            targetMinDistanceM: 300, targetMinDistanceRatio: 0.4,
            targetReachedM: 150, targetBiasWeight: 0.3)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        g.recordVisit(at: north)

        let famNorth = g.sectorFamiliarity(from: origin, bearingDeg: 0, params: route)
        let famSouth = g.sectorFamiliarity(from: origin, bearingDeg: 180, params: route)
        XCTAssertGreaterThan(famNorth, 0)
        XCTAssertEqual(famSouth, 0)
    }
}

final class BearingSuggesterTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)
    private let route = AppParameters.Route(
        cellSizeM: 50, visitHalfLifeM: 20_000, sectorWidthDeg: 60,
        sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
        suggestionMarginOverStraight: 0.05, suggestionMinTravelM: 30,
        mapRadiusM: 5000, mapIndexCellSizeM: 50, snapMaxDistanceM: 25, nodeArrivalToleranceM: 8,
        intersectionLookaheadM: 35, branchStraightDeg: 25, branchBackwardDeg: 135,
        crossCostWeight: 0.12, wayClassWeight: 0.08, branchNoveltyRatio: 1.3,
        zoneSizeM: 300, zoneMinRoadM: 400, zoneSampleGrid: 3,
        targetMinDistanceM: 300, targetMinDistanceRatio: 0.4,
        targetReachedM: 150, targetBiasWeight: 0.3)

    func testAllNovelPrefersStraightAndStaysSilent() {
        // 全方向が未踏なら最良は直進 → 直進に音は出さない設計なので nil
        let grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let home = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)
        let s = BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                         grid: grid, homewardBias: 0,
                                         route: route)
        XCTAssertNil(s)
    }

    func testFamiliarAheadWithHomewardBiasSuggestsTurnTowardHome() {
        // 前方(北)は何度も通った道、自宅は東、バイアスあり → 右 90°(東)を提案するはず
        var grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        for _ in 0..<5 {
            grid.recordVisit(at: north)
        }
        let home = Geo.destination(from: origin, bearingDeg: 90, distanceM: 500)

        let s = BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                         grid: grid, homewardBias: 0.8,
                                         route: route)
        XCTAssertEqual(s?.direction, .right90)
        XCTAssertEqual(s?.pan ?? 0, 1.0, accuracy: 0.01)
    }

    func testNarrowMarginOverStraightStaysSilent() {
        // 前方をわずかに通っただけ(直進と横のスコア差が小さい)なら鳴らさない。
        // 道の有無を知らないため、僅差で曲がらせると曲がれない場所で鳴ることになる
        var grid = VisitGrid(cellSizeM: 50, halfLifeM: 20_000)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        grid.recordVisit(at: north)
        let home = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)

        // この配置では 直進 novelty = 1/(1+1) = 0.5、左右は未踏で 1.0 → 差はちょうど 0.5
        let narrow = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeM: 20_000, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.6, suggestionMinTravelM: 30,
            mapRadiusM: 5000, mapIndexCellSizeM: 50, snapMaxDistanceM: 25, nodeArrivalToleranceM: 8,
            intersectionLookaheadM: 35, branchStraightDeg: 25, branchBackwardDeg: 135,
            crossCostWeight: 0.12, wayClassWeight: 0.08, branchNoveltyRatio: 1.3,
            zoneSizeM: 300, zoneMinRoadM: 400, zoneSampleGrid: 3,
            targetMinDistanceM: 300, targetMinDistanceRatio: 0.4,
            targetReachedM: 150, targetBiasWeight: 0.3)
        XCTAssertNil(BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                              grid: grid, homewardBias: 0,
                                              route: narrow))

        // 同じ状況でも差の要求を下げれば鳴る(閾値だけの違いであることを確かめる)
        let loose = AppParameters.Route(
            cellSizeM: 50, visitHalfLifeM: 20_000, sectorWidthDeg: 60,
            sectorRadiusM: 250, suggestionMinScore: 0.15, excludedFamiliarity: 8,
            suggestionMarginOverStraight: 0.4, suggestionMinTravelM: 30,
            mapRadiusM: 5000, mapIndexCellSizeM: 50, snapMaxDistanceM: 25, nodeArrivalToleranceM: 8,
            intersectionLookaheadM: 35, branchStraightDeg: 25, branchBackwardDeg: 135,
            crossCostWeight: 0.12, wayClassWeight: 0.08, branchNoveltyRatio: 1.3,
            zoneSizeM: 300, zoneMinRoadM: 400, zoneSampleGrid: 3,
            targetMinDistanceM: 300, targetMinDistanceRatio: 0.4,
            targetReachedM: 150, targetBiasWeight: 0.3)
        XCTAssertNotNil(BearingSuggester.suggest(position: origin, headingDeg: 0, home: home,
                                                 grid: grid, homewardBias: 0,
                                                 route: loose))
    }
}
