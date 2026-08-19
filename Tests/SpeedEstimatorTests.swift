import XCTest
@testable import OtoSanpo

/// 歩行速度の実測化。固定係数では帰宅時刻を約束できない(実測は 62〜94 m/min に散らばる)
final class SpeedEstimatorTests: XCTestCase {
    private let limits = SpeedEstimator.Limits(ewmaWeight: 0.4, minSamples: 60,
                                               minMPerMin: 45, maxMPerMin: 90)

    func testFirstWalkSetsTheEstimateDirectly() {
        var e = SpeedEstimator()
        XCTAssertNil(e.mPerMin)
        e.record(sessionAverageMPerMin: 70, movingSamples: 200, limits: limits)
        XCTAssertEqual(e.mPerMin ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(e.walks, 1)
    }

    func testLaterWalksMoveTheEstimatePartway() {
        var e = SpeedEstimator()
        e.record(sessionAverageMPerMin: 70, movingSamples: 200, limits: limits)
        e.record(sessionAverageMPerMin: 80, movingSamples: 200, limits: limits)
        // 70 * 0.6 + 80 * 0.4 = 74
        XCTAssertEqual(e.mPerMin ?? 0, 74, accuracy: 0.01)
    }

    /// サンプルが少ない回(すぐ引き返した等)は推定を動かさない
    func testShortWalksAreIgnored() {
        var e = SpeedEstimator()
        e.record(sessionAverageMPerMin: 70, movingSamples: 200, limits: limits)
        e.record(sessionAverageMPerMin: 30, movingSamples: 10, limits: limits)
        XCTAssertEqual(e.mPerMin ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(e.walks, 1)
    }

    /// 走った回でも上限で丸める。**楽観的な帰宅推定は帰りを間に合わなくする**
    func testRunningIsClampedToTheUpperBound() {
        var e = SpeedEstimator()
        e.record(sessionAverageMPerMin: 140, movingSamples: 200, limits: limits)
        XCTAssertEqual(e.mPerMin ?? 0, 90, accuracy: 0.01)
    }

    func testVerySlowWalkIsClampedToTheLowerBound() {
        var e = SpeedEstimator()
        e.record(sessionAverageMPerMin: 20, movingSamples: 200, limits: limits)
        XCTAssertEqual(e.mPerMin ?? 0, 45, accuracy: 0.01)
    }

    // MARK: - いま使う速度

    func testUsesTheConfiguredValueUntilAnythingIsMeasured() {
        let e = SpeedEstimator()
        XCTAssertEqual(e.effectiveMPerMin(sessionAverageMPerMin: nil, movingSamples: 0,
                                          fallback: 70, limits: limits), 70, accuracy: 0.01)
    }

    func testPrefersTheCurrentWalkOverHistory() {
        var e = SpeedEstimator()
        e.record(sessionAverageMPerMin: 60, movingSamples: 200, limits: limits)
        // 今日は速い(80)。今日の実測を使う
        XCTAssertEqual(e.effectiveMPerMin(sessionAverageMPerMin: 80, movingSamples: 200,
                                          fallback: 70, limits: limits), 80, accuracy: 0.01)
        // まだサンプルが少なければ過去の推定
        XCTAssertEqual(e.effectiveMPerMin(sessionAverageMPerMin: 80, movingSamples: 5,
                                          fallback: 70, limits: limits), 60, accuracy: 0.01)
    }

    func testCurrentWalkIsAlsoClamped() {
        let e = SpeedEstimator()
        XCTAssertEqual(e.effectiveMPerMin(sessionAverageMPerMin: 140, movingSamples: 200,
                                          fallback: 70, limits: limits), 90, accuracy: 0.01)
    }
}

/// 帰宅推定の距離。経路長が取れるなら迂回率を掛けない
final class ReturnDistanceTests: XCTestCase {
    private let budget = AppParameters.Budget(
        walkingSpeedMPerMin: 70, minMovingSpeedMPerS: 0.5, pathSegmentMinM: 10,
        maxAccuracyForMetricsM: 20, detourFactor: 1.3,
        returnReserveMin: 3, softZoneRatio: 0.7,
        speedEwmaWeight: 0.4, speedMinSamples: 60,
        speedMinMPerMin: 45, speedMaxMPerMin: 90)

    func testRouteDistanceIsUsedAsIs() {
        // 経路長 700m は既に「歩く距離」なので迂回率を掛けない
        XCTAssertEqual(ReturnBudget.estimatedReturnMin(.route(700), speedMPerMin: 70, p: budget),
                       10, accuracy: 0.01)
    }

    func testStraightDistanceGetsTheDetourFactor() {
        XCTAssertEqual(ReturnBudget.estimatedReturnMin(.straight(700), speedMPerMin: 70, p: budget),
                       13, accuracy: 0.01)
    }

    /// 遅く歩く日は帰宅推定が伸びる = 早めに帰り始める
    func testSlowerSpeedMeansLongerEstimate() {
        let fast = ReturnBudget.estimatedReturnMin(.route(700), speedMPerMin: 90, p: budget)
        let slow = ReturnBudget.estimatedReturnMin(.route(700), speedMPerMin: 50, p: budget)
        XCTAssertLessThan(fast, slow)
        XCTAssertEqual(slow, 14, accuracy: 0.01)
    }

    func testPromptFiresOnTheRouteLength() {
        // 経路 700m・70m/min → 帰宅 10 分。予備 3 分で残り 13 分ちょうどに発火
        XCTAssertFalse(ReturnBudget.shouldPromptReturn(remainingMin: 14, distance: .route(700),
                                                       speedMPerMin: 70, p: budget))
        XCTAssertTrue(ReturnBudget.shouldPromptReturn(remainingMin: 13, distance: .route(700),
                                                      speedMPerMin: 70, p: budget))
    }

    /// 曲がりくねった経路では、直線の推測より早く帰り始める
    func testWindingRouteFiresEarlierThanTheStraightLineGuess() {
        // 直線 300m だが実際の経路は 600m(迂回率 2.0 相当)
        let byRoute = ReturnBudget.estimatedReturnMin(.route(600), speedMPerMin: 70, p: budget)
        let byStraight = ReturnBudget.estimatedReturnMin(.straight(300), speedMPerMin: 70, p: budget)
        XCTAssertGreaterThan(byRoute, byStraight)
    }
}
