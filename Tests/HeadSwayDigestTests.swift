import XCTest
@testable import OtoSanpo

/// 歩いている間の頭の揺れの要約(→ `HeadSwayDigest`・docs/17 の T6)。
final class HeadSwayDigestTests: XCTestCase {

    func testEmptyDigestHasNoSummary() {
        XCTAssertNil(HeadSwayDigest().summary())
    }

    func testSingleWindowIsEveryPercentile() throws {
        var d = HeadSwayDigest()
        d.add(pitchRangeDeg: 4, yawRangeDeg: 9)
        let s = try XCTUnwrap(d.summary())
        XCTAssertEqual(s.windows, 1)
        XCTAssertEqual(s.pitchMedianDeg, 4)
        XCTAssertEqual(s.pitchP90Deg, 4)
        XCTAssertEqual(s.yawMaxDeg, 9)
    }

    /// 1〜10 の 10 窓: 中央は 5、p90 は 9、最大は 10(最近接順位法)
    func testPercentilesUseNearestRank() throws {
        var d = HeadSwayDigest()
        for v in [7.0, 2, 10, 1, 9, 3, 8, 5, 6, 4] {
            d.add(pitchRangeDeg: v, yawRangeDeg: v * 2)
        }
        let s = try XCTUnwrap(d.summary())
        XCTAssertEqual(s.windows, 10)
        XCTAssertEqual(s.pitchMedianDeg, 5)
        XCTAssertEqual(s.pitchP90Deg, 9)
        XCTAssertEqual(s.pitchMaxDeg, 10)
        XCTAssertEqual(s.yawMedianDeg, 10)
        XCTAssertEqual(s.yawP90Deg, 18)
        XCTAssertEqual(s.yawMaxDeg, 20)
    }

    /// pitch と yaw は別々に並べる(同じ窓の組で並べると分布が歪む)
    func testPitchAndYawAreSortedIndependently() throws {
        var d = HeadSwayDigest()
        d.add(pitchRangeDeg: 1, yawRangeDeg: 30)
        d.add(pitchRangeDeg: 2, yawRangeDeg: 20)
        d.add(pitchRangeDeg: 3, yawRangeDeg: 10)
        let s = try XCTUnwrap(d.summary())
        XCTAssertEqual(s.pitchMedianDeg, 2)
        XCTAssertEqual(s.yawMedianDeg, 20)
    }

    func testResetClearsTheWindows() {
        var d = HeadSwayDigest()
        d.add(pitchRangeDeg: 1, yawRangeDeg: 1)
        d.reset()
        XCTAssertNil(d.summary())
    }
}
