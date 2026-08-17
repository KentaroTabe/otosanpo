import XCTest
@testable import OtoSanpo

final class GaitMetricsTests: XCTestCase {
    /// 緯度 1 度 ≒ 111.32 km。南北に動かせば距離が読みやすい
    private func north(_ meters: Double) -> GeoPoint {
        GeoPoint(latitude: 35.0 + meters / 111_320.0, longitude: 139.0)
    }

    /// 経路長は位置更新の差分の総和。往復すれば直線距離より長くなる
    func testPathLengthSumsSegments() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(100), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(50), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        XCTAssertEqual(m.pathLengthM, 150, accuracy: 1.0)
    }

    /// 立ち止まっているサンプルは平均速度に入れない
    func testStoppedSamplesAreExcludedFromAverage() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.5, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(10), speedMps: 0.1, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(20), speedMps: 1.5, minMovingSpeedMps: 0.5, minSegmentM: 10)
        // 1.5 m/s の 2 件だけが平均に入る = 90 m/min
        XCTAssertEqual(m.averageMovingSpeedMPerMin ?? 0, 90, accuracy: 0.1)
    }

    /// 速度が無効(nil)でも経路長は積む
    func testMissingSpeedStillAccumulatesPath() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: nil, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(80), speedMps: nil, minMovingSpeedMps: 0.5, minSegmentM: 10)
        XCTAssertEqual(m.pathLengthM, 80, accuracy: 1.0)
        XCTAssertNil(m.averageMovingSpeedMPerMin)
    }

    /// 迂回率 = 実経路長 / 直線距離
    func testDetourFactorIsPathOverStraightLine() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(60), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(130), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        XCTAssertEqual(m.detourFactor(straightLineM: 100) ?? 0, 1.3, accuracy: 0.02)
    }

    /// 直線距離が 0(自宅で開始してすぐ到着)なら迂回率は求まらない
    func testDetourFactorIsNilWithoutStraightLineDistance() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(10), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        XCTAssertNil(m.detourFactor(straightLineM: 0))
    }

    /// GPS の揺れ(水平精度の範囲内の往復)は経路長に積まない。
    /// 1 秒ごとの更新をそのまま足すと、歩行 1.2 m に対して揺れ 3〜5 m が累積して迂回率が過大になる
    func testJitterBelowMinSegmentIsNotAccumulated() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 0.0, minMovingSpeedMps: 0.5, minSegmentM: 10)
        for _ in 0..<20 {
            m.add(north(4), speedMps: 0.0, minMovingSpeedMps: 0.5, minSegmentM: 10)
            m.add(north(-4), speedMps: 0.0, minMovingSpeedMps: 0.5, minSegmentM: 10)
        }
        XCTAssertEqual(m.pathLengthM, 0, accuracy: 0.001)
    }

    /// 基準点は動かさないので、揺れの後に本当に進めばその分は拾える
    func testRealMovementAfterJitterIsStillCounted() {
        var m = GaitMetrics()
        m.add(north(0), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)
        m.add(north(3), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)   // 揺れ
        m.add(north(6), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)   // 揺れ
        m.add(north(30), speedMps: 1.4, minMovingSpeedMps: 0.5, minSegmentM: 10)  // 実移動
        XCTAssertEqual(m.pathLengthM, 30, accuracy: 1.0)
    }

    /// 1 件も入っていなければ何も出さない(0 を返して係数を壊さない)
    func testEmptyMetricsYieldNil() {
        let m = GaitMetrics()
        XCTAssertNil(m.averageMovingSpeedMPerMin)
        XCTAssertNil(m.detourFactor(straightLineM: 100))
        XCTAssertEqual(m.pathLengthM, 0)
    }
}
