import XCTest
@testable import OtoSanpo

/// 頭部固定スマホの device-motion の集計(→ `HeadMotionDigest`)。
///
/// **これは記録専用**(2026-09-10)。次の案件で「方位が回転に応答しているか」を
/// 角速度で検疫したいが、**スマホの角速度をまだ一度も測っていない**ので、
/// まず記録して実測してから設計する。
/// 判定に渡っていないことは `testDigestNeverReachesTheDecision` で固定する。
final class HeadMotionDigestTests: XCTestCase {

    /// 方位の変化は先頭と末尾の**円差**。折り返しを跨いでも正しい
    func testHeadingChangeIsCircular() {
        var d = HeadMotionDigest()
        d.add(headingDeg: 350, sensorTime: 0, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        d.add(headingDeg: 10, sensorTime: 0.02, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        XCTAssertEqual(try! XCTUnwrap(d.headingChangeDeg), 20, accuracy: 1e-9,
                       "350° → 10° は +20° であって −340° ではない")
    }

    /// 標本が 1 件では変化を語らない
    func testNoHeadingChangeFromASingleSample() {
        var d = HeadMotionDigest()
        d.add(headingDeg: 90, sensorTime: 0, absRateRadPerSec: 1,
              verticalRateRadPerSec: 1, magneticAccuracy: 2, maxIntervalSec: 1)
        XCTAssertNil(d.headingChangeDeg)
        XCTAssertEqual(d.count, 1)
    }

    /// 角速度の積分。90°/s で 1 秒回れば 90°
    func testIntegratesRotation() {
        var d = HeadMotionDigest()
        let rate = Double.pi / 2   // 90°/s
        for i in 0...50 {
            d.add(headingDeg: 0, sensorTime: Double(i) * 0.02, absRateRadPerSec: rate,
                  verticalRateRadPerSec: rate, magneticAccuracy: 2, maxIntervalSec: 1)
        }
        XCTAssertEqual(d.integratedVerticalDeg, 90, accuracy: 0.5)
        XCTAssertEqual(d.integratedAbsDeg, 90, accuracy: 0.5)
    }

    /// 鉛直積分は**符号つき**。左右の回転が打ち消し合う
    func testVerticalIntegralIsSigned() {
        var d = HeadMotionDigest()
        let rate = Double.pi / 2
        // 標本 i が担うのは「i−1 から i まで」の区間。先頭の 1 件は区間を持たない。
        // 右 25 区間 → 左 25 区間になるよう、0...25 と 26...50 で割る
        for i in 0...25 {
            d.add(headingDeg: 0, sensorTime: Double(i) * 0.02, absRateRadPerSec: rate,
                  verticalRateRadPerSec: rate, magneticAccuracy: 2, maxIntervalSec: 1)
        }
        for i in 26...50 {
            d.add(headingDeg: 0, sensorTime: Double(i) * 0.02, absRateRadPerSec: rate,
                  verticalRateRadPerSec: -rate, magneticAccuracy: 2, maxIntervalSec: 1)
        }
        XCTAssertEqual(d.integratedVerticalDeg, 0, accuracy: 1e-9, "行って戻れば 0")
        XCTAssertEqual(d.integratedAbsDeg, 90, accuracy: 1e-9, "総量は打ち消し合わない")
    }

    /// **配信が止まった後の 1 標本に何十秒も積分させない。**
    /// 背景で間引かれた区間を「その間ずっと回っていた」と数えると、値が壊れる
    func testLongGapIsCappedButRecorded() {
        var d = HeadMotionDigest()
        let rate = Double.pi   // 180°/s
        d.add(headingDeg: 0, sensorTime: 0, absRateRadPerSec: rate,
              verticalRateRadPerSec: rate, magneticAccuracy: 2, maxIntervalSec: 1)
        d.add(headingDeg: 0, sensorTime: 60, absRateRadPerSec: rate,
              verticalRateRadPerSec: rate, magneticAccuracy: 2, maxIntervalSec: 1)
        XCTAssertEqual(d.maxGapSec, 60, accuracy: 1e-9, "間隔そのものは記録に残す")
        XCTAssertEqual(d.integratedVerticalDeg, 180, accuracy: 1e-9,
                       "積分は上限 1 秒ぶんまで(60 秒ぶん積んではいけない)")
    }

    /// 磁場較正は**悪い方**を残す(良い瞬間だけ見て安心しないため)
    func testKeepsTheWorstMagneticAccuracy() {
        var d = HeadMotionDigest()
        d.add(headingDeg: 0, sensorTime: 0, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        d.add(headingDeg: 0, sensorTime: 0.02, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: -1, maxIntervalSec: 1)
        d.add(headingDeg: 0, sensorTime: 0.04, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        XCTAssertEqual(d.worstMagneticAccuracy, -1)
    }

    /// 畳んだ後も**時刻は引き継ぐ**(区間をまたぐ間隔を測りたいため)
    func testRollOverKeepsTheClock() {
        var d = HeadMotionDigest()
        d.add(headingDeg: 0, sensorTime: 0, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        d.rollOver()
        XCTAssertEqual(d.count, 0)
        XCTAssertEqual(d.integratedAbsDeg, 0)
        d.add(headingDeg: 0, sensorTime: 30, absRateRadPerSec: 0,
              verticalRateRadPerSec: 0, magneticAccuracy: 2, maxIntervalSec: 1)
        XCTAssertEqual(d.maxGapSec, 30, accuracy: 1e-9,
                       "区間をまたいだ空白も見えなければ、間引きに気づけない")
    }

    /// **角速度は判定に一切渡っていない**(受け入れ条件 E5)。
    /// 同じ heading / course / fix の列に対して、gyro をどう変えても
    /// 学習値・R・検疫の状態・使用可能状態が変わらないこと
    func testDigestNeverReachesTheDecision() {
        let p = HeadMountFusion.Params(
            offset: MountOffset.Params(minEvidenceSec: 5, halfLifeSec: 60,
                                       minConcentration: 0.8, gateDeg: 45, maxGapSec: 5),
            quarantine: HeadingQuarantine.Params(windowSec: 40, distrustRatio: 0.75,
                                                 distrustSec: 12, regainRatio: 0.7,
                                                 regainSec: 8),
            staleSec: 30)

        /// gyro の値を変えながら、同じ heading/course/fix 列を流す
        func run(rate: Double) -> (offset: Double?, r: Double, state: HeadingQuarantine.State,
                                   usable: Bool, digest: Double) {
            var f = HeadMountFusion()
            var d = HeadMotionDigest()
            var t = 100.0
            for i in 0..<20 {
                for k in 0..<10 {
                    t = 100 + Double(i) + Double(k) * 0.1
                    d.add(headingDeg: 184, sensorTime: t, absRateRadPerSec: rate,
                          verticalRateRadPerSec: rate, magneticAccuracy: 2, maxIntervalSec: 1)
                    f.ingest(headingDeg: 184, rawCourseDeg: 90, fixTime: 100 + Double(i),
                             at: t, p: p)
                }
            }
            return (f.learnedOffsetDeg, f.concentration, f.quarantineState,
                    f.use(at: t, p: p).isUsable, d.integratedVerticalDeg)
        }

        let still = run(rate: 0)
        let spinning = run(rate: 3)
        XCTAssertNotEqual(still.digest, spinning.digest, accuracy: 1e-9,
                          "前提: gyro の値は実際に違う(そうでないと検査になっていない)")
        XCTAssertEqual(still.offset ?? .nan, spinning.offset ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(still.r, spinning.r, accuracy: 1e-12)
        XCTAssertEqual(still.state, spinning.state)
        XCTAssertEqual(still.usable, spinning.usable)
        XCTAssertTrue(still.usable, "前提: 使える状態まで到達している")
    }
}
