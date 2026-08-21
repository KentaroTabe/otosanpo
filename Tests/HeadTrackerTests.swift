import XCTest
@testable import OtoSanpo

/// 角速度から頭の向きを推定する系統(HeadTracker)。
/// 姿勢(yaw)の系統は 2026-08-19 に散歩 1 回を潰した(左右が壊れた)ので、
/// **こちらは机上で確かめられる形にしてから動作へ入れる**(docs/08)。
final class HeadTrackerTests: XCTestCase {
    private let p = HeadTracker.Params(halfLifeSec: 4, maxOffsetDeg: 90,
                                       deadbandDegPerSec: 3, sign: 1, maxGapSec: 0.5)

    /// 一定の角速度で回した分だけ首が向く(減衰の効かない短い時間で見る)
    func testIntegratesRotationIntoAnOffset() {
        var t = HeadTracker()
        var time = 0.0
        t.ingest(yawRateDegPerSec: 0, time: time, p: p)   // 最初の 1 件は基準を置くだけ
        for _ in 0..<10 {
            time += 0.02
            t.ingest(yawRateDegPerSec: 90, time: time, p: p)
        }
        // 0.2 秒 × 90°/s = 18°。半減期 4 秒の減衰は 0.2 秒では 3% 程度
        XCTAssertEqual(t.offsetDeg, 18, accuracy: 1.0)
    }

    /// **絶対基準を持たないので、放っておけば 0 へ戻る。**
    /// これがドリフト対策。代償として、横を向いたままだと正面と区別できなくなる
    func testDecaysBackToZeroWhenTheHeadStops() {
        var t = HeadTracker()
        var time = 0.0
        t.ingest(yawRateDegPerSec: 0, time: time, p: p)
        for _ in 0..<10 {
            time += 0.02
            t.ingest(yawRateDegPerSec: 90, time: time, p: p)
        }
        let turned = t.offsetDeg
        for _ in 0..<200 {   // 4 秒静止 = 半減期 1 つぶん
            time += 0.02
            t.ingest(yawRateDegPerSec: 0, time: time, p: p)
        }
        XCTAssertEqual(t.offsetDeg, turned / 2, accuracy: turned * 0.1)
    }

    /// ジャイロの偏りを積み上げない(不感帯)
    func testIgnoresDriftBelowTheDeadband() {
        var t = HeadTracker()
        var time = 0.0
        t.ingest(yawRateDegPerSec: 0, time: time, p: p)
        for _ in 0..<500 {   // 10 秒ぶん、2°/s の偏りを与える
            time += 0.02
            t.ingest(yawRateDegPerSec: 2, time: time, p: p)
        }
        XCTAssertEqual(t.offsetDeg, 0, accuracy: 0.001)
    }

    /// 上限を超えない(首は 90° 以上は回らない)
    func testClampsToTheMaximumOffset() {
        var t = HeadTracker()
        var time = 0.0
        t.ingest(yawRateDegPerSec: 0, time: time, p: p)
        for _ in 0..<100 {
            time += 0.02
            t.ingest(yawRateDegPerSec: 500, time: time, p: p)
        }
        XCTAssertLessThanOrEqual(abs(t.offsetDeg), p.maxOffsetDeg)
    }

    /// 符号を反転すると向きも反転する(机上テストで決める値)
    func testSignFlipsTheDirection() {
        let flipped = HeadTracker.Params(halfLifeSec: 4, maxOffsetDeg: 90,
                                         deadbandDegPerSec: 3, sign: -1, maxGapSec: 0.5)
        var a = HeadTracker(), b = HeadTracker()
        var time = 0.0
        a.ingest(yawRateDegPerSec: 0, time: time, p: p)
        b.ingest(yawRateDegPerSec: 0, time: time, p: flipped)
        for _ in 0..<10 {
            time += 0.02
            a.ingest(yawRateDegPerSec: 90, time: time, p: p)
            b.ingest(yawRateDegPerSec: 90, time: time, p: flipped)
        }
        XCTAssertEqual(a.offsetDeg, -b.offsetDeg, accuracy: 0.001)
    }

    /// **間が空いたら積分しない。** 外していた間の回転は分からない
    func testSkipsGapsThatAreTooLong() {
        var t = HeadTracker()
        t.ingest(yawRateDegPerSec: 0, time: 0, p: p)
        t.ingest(yawRateDegPerSec: 90, time: 5, p: p)
        XCTAssertEqual(t.offsetDeg, 0, accuracy: 0.001)
        // 間隔が戻れば再開する
        t.ingest(yawRateDegPerSec: 90, time: 5.02, p: p)
        XCTAssertGreaterThan(t.offsetDeg, 0)
    }

    /// 減衰なしの積分は別に持つ(ジャイロが旋回を追えているかの検証用)
    func testKeepsAnUndecayedRotationForVerification() {
        var t = HeadTracker()
        var time = 0.0
        t.ingest(yawRateDegPerSec: 0, time: time, p: p)
        for _ in 0..<100 {   // 2 秒 × 45°/s = 90°
            time += 0.02
            t.ingest(yawRateDegPerSec: 45, time: time, p: p)
        }
        XCTAssertEqual(t.rotationDeg, 90, accuracy: 1.0)
        // 減衰つきの推定は同じだけ回っても小さくなる(2 秒 = 半減期の半分)
        XCTAssertLessThan(t.offsetDeg, t.rotationDeg)
        // 読み出したら 0 に戻る(ログに区間ごとの回転を出すため)
        XCTAssertEqual(t.takeRotation(), t.rotationDeg + 90, accuracy: 1.0)
        XCTAssertEqual(t.rotationDeg, 0)
    }
}
