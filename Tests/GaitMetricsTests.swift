import XCTest
@testable import OtoSanpo

final class GaitMetricsTests: XCTestCase {
    private let limits = GaitMetrics.Limits(
        minMovingSpeedMps: 0.5, minSegmentM: 10, maxAccuracyM: 20)

    /// 緯度 1 度 ≒ 111.32 km。南北に動かせば距離が読みやすい
    private func north(_ meters: Double) -> GeoPoint {
        GeoPoint(latitude: 35.0 + meters / 111_320.0, longitude: 139.0)
    }

    /// 経路長は位置更新の差分の総和。往復すれば直線距離より長くなる
    func testPathLengthSumsSegments() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(100), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(50), speedMps: 1.4, accuracyM: 4, limits: limits)
        XCTAssertEqual(m.pathLengthM, 150, accuracy: 1.0)
    }

    /// 立ち止まっているサンプルは平均速度に入れない
    func testStoppedSamplesAreExcludedFromAverage() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.5, accuracyM: 4, limits: limits)
        m.add(north(10), speedMps: 0.1, accuracyM: 4, limits: limits)
        m.add(north(20), speedMps: 1.5, accuracyM: 4, limits: limits)
        // 1.5 m/s の 2 件だけが平均に入る = 90 m/min
        XCTAssertEqual(m.averageMovingSpeedMPerMin ?? 0, 90, accuracy: 0.1)
    }

    /// 速度が無効(nil)でも経路長は積む
    func testMissingSpeedStillAccumulatesPath() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: nil, accuracyM: 4, limits: limits)
        m.add(north(80), speedMps: nil, accuracyM: 4, limits: limits)
        XCTAssertEqual(m.pathLengthM, 80, accuracy: 1.0)
        XCTAssertNil(m.averageMovingSpeedMPerMin)
    }

    /// 迂回率 = 実経路長 / 直線距離
    func testDetourFactorIsPathOverStraightLine() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(60), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(130), speedMps: 1.4, accuracyM: 4, limits: limits)
        XCTAssertEqual(m.detourFactor(straightLineM: 100) ?? 0, 1.3, accuracy: 0.02)
    }

    /// 直線距離が 0(自宅で開始してすぐ到着)なら迂回率は求まらない
    func testDetourFactorIsNilWithoutStraightLineDistance() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(10), speedMps: 1.4, accuracyM: 4, limits: limits)
        XCTAssertNil(m.detourFactor(straightLineM: 0))
    }

    /// GPS の揺れ(水平精度の範囲内の往復)は経路長に積まない。
    /// 1 秒ごとの更新をそのまま足すと、歩行 1.2 m に対して揺れ 3〜5 m が累積して迂回率が過大になる
    func testJitterBelowMinSegmentIsNotAccumulated() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 0.0, accuracyM: 4, limits: limits)
        for _ in 0..<20 {
            m.add(north(4), speedMps: 0.0, accuracyM: 4, limits: limits)
            m.add(north(-4), speedMps: 0.0, accuracyM: 4, limits: limits)
        }
        XCTAssertEqual(m.pathLengthM, 0, accuracy: 0.001)
    }

    /// 基準点は動かさないので、揺れの後に本当に進めばその分は拾える
    func testRealMovementAfterJitterIsStillCounted() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(3), speedMps: 1.4, accuracyM: 4, limits: limits)   // 揺れ
        m.add(north(6), speedMps: 1.4, accuracyM: 4, limits: limits)   // 揺れ
        m.add(north(30), speedMps: 1.4, accuracyM: 4, limits: limits)  // 実移動
        XCTAssertEqual(m.pathLengthM, 30, accuracy: 1.0)
    }

    /// 水平精度が悪い fix は経路長も速度も使わない。
    /// 段階 8 の実測で水平精度 69 m の区間が位置を飛ばし、迂回率が 1.67 と過大に出た
    func testPoorAccuracyFixIsRejectedEntirely() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: 4, limits: limits)
        m.add(north(200), speedMps: 3.6, accuracyM: 69, limits: limits)  // 飛んだ fix
        m.add(north(30), speedMps: 1.4, accuracyM: 4, limits: limits)
        XCTAssertEqual(m.pathLengthM, 30, accuracy: 1.0)
        XCTAssertEqual(m.rejectedSamples, 1)
        // 3.6 m/s(歩行ではありえない)は平均にも最高速度にも入らない
        XCTAssertEqual(m.maxSpeedMps, 1.4, accuracy: 0.001)
    }

    /// 精度が負値(CoreLocation の「無効」)の fix も捨てる
    func testNegativeAccuracyIsRejected() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: -1, limits: limits)
        XCTAssertEqual(m.rejectedSamples, 1)
        XCTAssertEqual(m.pathLengthM, 0)
    }

    /// 精度が不明(nil)なら判定材料が無いので通す
    func testUnknownAccuracyIsAccepted() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, accuracyM: nil, limits: limits)
        m.add(north(40), speedMps: 1.4, accuracyM: nil, limits: limits)
        XCTAssertEqual(m.pathLengthM, 40, accuracy: 1.0)
        XCTAssertEqual(m.rejectedSamples, 0)
    }

    /// 1 件も入っていなければ何も出さない(0 を返して係数を壊さない)
    func testEmptyMetricsYieldNil() {
        let m = GaitMetrics()
        XCTAssertNil(m.averageMovingSpeedMPerMin)
        XCTAssertNil(m.detourFactor(straightLineM: 100))
        XCTAssertEqual(m.pathLengthM, 0)
    }
}
