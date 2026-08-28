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
        maxAccuracyForMetricsM: 20, detourFactor: 1.3, routeStraightMaxRatio: 2.0,
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

    // MARK: - 経路長の跳ねを直線距離で抑える(2026-08-27 の実測)

    /// ふつうの遠回りはそのまま通す。実測の比は中央 1.42 / 95% 1.68
    func testOrdinaryDetourPassesThrough() {
        XCTAssertEqual(ReturnBudget.distance(routeM: 760, straightM: 450, p: budget),
                       .route(760))
    }

    /// **跳ねた経路長は上限で頭を押さえる。**
    /// 実測値: 直線 543m に対し経路 1587m(2.92 倍)が 42 秒間だけ出た
    func testSpikedRouteIsCapped() {
        XCTAssertEqual(ReturnBudget.distance(routeM: 1587, straightM: 543, p: budget),
                       .cappedRoute(1086))
    }

    /// この修正が効くことの本体。**同じ場面で帰宅プロンプトが撃たれなくなる。**
    /// 実測: 残り 26 分・65m/min・予備 3 分のところへ経路 1587m が出て発火した
    func testSpikeNoLongerFiresThePrompt() {
        let spiked = ReturnBudget.distance(routeM: 1587, straightM: 543, p: budget)
        XCTAssertFalse(ReturnBudget.shouldPromptReturn(remainingMin: 26, distance: spiked,
                                                       speedMPerMin: 65, p: budget))
        // 抑えなければ発火していた(この回に実際に起きたこと)
        XCTAssertTrue(ReturnBudget.shouldPromptReturn(remainingMin: 26, distance: .route(1587),
                                                      speedMPerMin: 65, p: budget))
    }

    /// 抑えた後でも、直線 × 迂回率より大きい値が残る。
    /// 川や線路の向こうで本当に大回りが要る場所を、過小評価にしないため
    func testCappedEstimateStaysAboveTheStraightLineGuess() {
        let capped = ReturnBudget.estimatedReturnMin(
            ReturnBudget.distance(routeM: 1587, straightM: 543, p: budget),
            speedMPerMin: 65, p: budget)
        let byStraight = ReturnBudget.estimatedReturnMin(.straight(543), speedMPerMin: 65, p: budget)
        XCTAssertGreaterThan(capped, byStraight)
    }

    /// 経路データが無ければ直線距離に落ちる(圏外・地図未読込)
    func testFallsBackToStraightWithoutRouteData() {
        XCTAssertEqual(ReturnBudget.distance(routeM: nil, straightM: 543, p: budget),
                       .straight(543))
    }

    /// 上限ちょうどは通す(境界)
    func testExactlyAtTheCapIsStillTrusted() {
        XCTAssertEqual(ReturnBudget.distance(routeM: 1086, straightM: 543, p: budget),
                       .route(1086))
    }

    /// 曲がりくねった経路では、直線の推測より早く帰り始める
    func testWindingRouteFiresEarlierThanTheStraightLineGuess() {
        // 直線 300m だが実際の経路は 600m(迂回率 2.0 相当)
        let byRoute = ReturnBudget.estimatedReturnMin(.route(600), speedMPerMin: 70, p: budget)
        let byStraight = ReturnBudget.estimatedReturnMin(.straight(300), speedMPerMin: 70, p: budget)
        XCTAssertGreaterThan(byRoute, byStraight)
    }
}
