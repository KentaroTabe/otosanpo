import XCTest
@testable import OtoSanpo

/// 頭部固定スマホの device-motion の集計(→ `HeadMotionDigest`)。
///
/// **これは記録専用**(2026-09-10)。次の案件で「方位が回転に応答しているか」を
/// 角速度で検疫したいが、**スマホの角速度をまだ一度も測っていない**ので、
/// まず記録して実測してから設計する。
/// 判定に渡っていないことは `testDigestNeverReachesTheDecision` で固定する。
final class HeadMotionDigestTests: XCTestCase {

    private let down = MotionVector(x: 0, y: 0, z: -1)   // 画面を上にした重力

    private func add(_ d: inout HeadMotionDigest, heading: Double = 0, at t: Double,
                     rotation: MotionVector = .zero, gravity: MotionVector? = nil,
                     magnetic: Int = 2, cap: Double = 1) {
        d.add(headingDeg: heading, sensorTime: t, rotationRate: rotation,
              gravity: gravity ?? down, magneticAccuracy: magnetic, maxIntervalSec: cap)
    }

    /// 方位の変化は先頭と末尾の**円差**。折り返しを跨いでも正しい
    func testHeadingChangeIsCircular() {
        var d = HeadMotionDigest()
        add(&d, heading: 350, at: 0)
        add(&d, heading: 10, at: 0.02)
        XCTAssertEqual(try! XCTUnwrap(d.headingChangeDeg), 20, accuracy: 1e-9,
                       "350° → 10° は +20° であって −340° ではない")
    }

    /// 標本が 1 件では変化を語らない
    func testNoHeadingChangeFromASingleSample() {
        var d = HeadMotionDigest()
        add(&d, heading: 90, at: 0, rotation: MotionVector(x: 1, y: 1, z: 1))
        XCTAssertNil(d.headingChangeDeg)
        XCTAssertEqual(d.count, 1)
    }

    /// **三軸それぞれと鉛直軸の積分**(2026-09-10 の検証で挙がった系列)。
    /// 角速度 (1, 2, 3) rad/s・重力 (0, 0, −1) を 1 秒流すと、
    /// x/y/z = 57.30° / 114.59° / 171.89°、鉛直 = 171.89°
    func testIntegratesEachAxisAndTheVertical() {
        var d = HeadMotionDigest()
        for i in 0...50 {
            add(&d, at: Double(i) * 0.02, rotation: MotionVector(x: 1, y: 2, z: 3),
                gravity: MotionVector(x: 0, y: 0, z: -1))
        }
        XCTAssertEqual(d.integratedDeg.x, 57.2958, accuracy: 0.01)
        XCTAssertEqual(d.integratedDeg.y, 114.5916, accuracy: 0.01)
        XCTAssertEqual(d.integratedDeg.z, 171.8873, accuracy: 0.01)
        XCTAssertEqual(d.integratedVerticalDeg, 171.8873, accuracy: 0.01)
    }

    /// **鉛直軸への射影は取り付けの向きに依らない。**
    /// 縦置き(重力が −y)で y 軸まわりに回るのと、横置き(重力が −x)で x 軸まわりに
    /// 回るのは、どちらも同じ「首を回した」量になる(`rotationRate.z` 決め打ちを避ける理由)
    func testVerticalProjectionIsIndependentOfMountOrientation() {
        let portrait = HeadMotionDigest.verticalRate(rotation: MotionVector(x: 0, y: 2, z: 0),
                                                     gravity: MotionVector(x: 0, y: -1, z: 0))
        let landscape = HeadMotionDigest.verticalRate(rotation: MotionVector(x: 2, y: 0, z: 0),
                                                      gravity: MotionVector(x: -1, y: 0, z: 0))
        XCTAssertEqual(portrait, 2, accuracy: 1e-12)
        XCTAssertEqual(landscape, 2, accuracy: 1e-12)
    }

    /// 重力が 0 ベクトル(センサが値を返していない)なら鉛直成分は 0。0 除算にしない
    func testZeroGravityGivesNoVerticalRate() {
        XCTAssertEqual(HeadMotionDigest.verticalRate(rotation: MotionVector(x: 1, y: 1, z: 1),
                                                     gravity: .zero), 0)
    }

    /// 積分は**符号つき**。左右の回転が打ち消し合う
    func testIntegralsAreSigned() {
        var d = HeadMotionDigest()
        let rate = Double.pi / 2
        // 標本 i が担うのは「i−1 から i まで」の区間。先頭の 1 件は区間を持たない。
        // 右 25 区間 → 左 25 区間になるよう、0...25 と 26...50 で割る
        for i in 0...25 {
            add(&d, at: Double(i) * 0.02, rotation: MotionVector(x: 0, y: 0, z: rate))
        }
        for i in 26...50 {
            add(&d, at: Double(i) * 0.02, rotation: MotionVector(x: 0, y: 0, z: -rate))
        }
        XCTAssertEqual(d.integratedVerticalDeg, 0, accuracy: 1e-9, "行って戻れば 0")
        XCTAssertEqual(d.integratedDeg.z, 0, accuracy: 1e-9)
    }

    /// **配信が止まった後の 1 標本に何十秒も積分させない。**
    /// 背景で間引かれた区間を「その間ずっと回っていた」と数えると、値が壊れる
    func testLongGapIsCappedButRecorded() {
        var d = HeadMotionDigest()
        let spin = MotionVector(x: 0, y: 0, z: Double.pi)   // 180°/s
        add(&d, at: 0, rotation: spin)
        add(&d, at: 60, rotation: spin)
        XCTAssertEqual(d.maxGapSec, 60, accuracy: 1e-9, "間隔そのものは記録に残す")
        XCTAssertEqual(d.integratedVerticalDeg, 180, accuracy: 1e-9,
                       "積分は上限 1 秒ぶんまで(60 秒ぶん積んではいけない)")
    }

    /// 磁場較正は**悪い方**を残す(良い瞬間だけ見て安心しないため)
    func testKeepsTheWorstMagneticAccuracy() {
        var d = HeadMotionDigest()
        add(&d, at: 0, magnetic: 2)
        add(&d, at: 0.02, magnetic: -1)
        add(&d, at: 0.04, magnetic: 2)
        XCTAssertEqual(d.worstMagneticAccuracy, -1)
    }

    /// 区間の最後の**瞬時値**を残す(受け入れ条件 E3。集計だけでは符号の生値が読めない)
    func testKeepsTheLastInstantaneousSample() {
        var d = HeadMotionDigest()
        add(&d, at: 10, rotation: MotionVector(x: 0.1, y: 0.2, z: 0.3),
            gravity: MotionVector(x: 0, y: -1, z: 0))
        add(&d, at: 10.02, rotation: MotionVector(x: -0.4, y: 0.5, z: -0.6),
            gravity: MotionVector(x: -0.1, y: -0.9, z: 0.2))
        XCTAssertEqual(d.lastSensorTime ?? .nan, 10.02, accuracy: 1e-12)
        XCTAssertEqual(d.lastRotationRate, MotionVector(x: -0.4, y: 0.5, z: -0.6))
        XCTAssertEqual(d.lastGravity, MotionVector(x: -0.1, y: -0.9, z: 0.2))
    }

    /// **方位の変化は区間の境目をまたいで数える**(2026-09-10 の 2 回目の検証で挙がった系列)。
    ///
    /// 10°/t=0・20°/t=1 のあと畳み、50°/t=2 を 1 件だけ足す。次の区間の変化は
    /// **+30°**(前の区間の最後 20° から)。境目で方位を捨てていた版では nil になり、
    /// 境目を含む積分と期間が食い違っていた
    func testHeadingChangeSpansTheIntervalBoundary() {
        var d = HeadMotionDigest()
        add(&d, heading: 10, at: 0)
        add(&d, heading: 20, at: 1)
        d.rollOver()
        add(&d, heading: 50, at: 2)
        XCTAssertEqual(try! XCTUnwrap(d.headingChangeDeg), 30, accuracy: 1e-9,
                       "前の区間の最後(20°)から数える。積分と同じ期間にそろえる")
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.maxGapSec, 1, accuracy: 1e-9)
    }

    /// 畳んだ後も**時刻は引き継ぐ**(区間をまたぐ間隔を測りたいため)
    func testRollOverKeepsTheClock() {
        var d = HeadMotionDigest()
        add(&d, at: 0)
        d.rollOver()
        XCTAssertEqual(d.count, 0)
        XCTAssertNil(d.lastSensorTime, "瞬時値は区間ごと")
        add(&d, at: 30)
        XCTAssertEqual(d.maxGapSec, 30, accuracy: 1e-9,
                       "区間をまたいだ空白も見えなければ、間引きに気づけない")
    }

    /// **新しい散歩は新しい集計で始める**(2026-09-10 の検証で挙がった系列)。
    ///
    /// 前の散歩の集計を畳んで使い回すと、最初の 1 行に「散歩と散歩の間の何時間」が
    /// 最大間隔として出てしまう。Controller は散歩の開始と終了で作り直す
    /// (その配線は Controller にあるため単体テストでは押さえられない。ここでは
    /// 「作り直せば持ち越さない / 畳むだけなら持ち越す」の違いを固定する)
    func testANewWalkStartsFromAFreshDigest() {
        var walkA = HeadMotionDigest()
        for i in 0...50 {
            add(&walkA, at: Double(i) * 0.02, rotation: MotionVector(x: 1, y: 2, z: 3))
        }
        // 畳むだけ(同じ散歩の次の区間)なら、時計は持ち越される
        var carried = walkA
        carried.rollOver()
        add(&carried, at: 3600)
        XCTAssertGreaterThan(carried.maxGapSec, 3000, "畳むだけなら前の時刻を持ち越す")

        // 新しい散歩: 作り直す
        var walkB = HeadMotionDigest()
        add(&walkB, at: 3600, rotation: MotionVector(x: 1, y: 2, z: 3))
        XCTAssertEqual(walkB.count, 1)
        XCTAssertEqual(walkB.maxGapSec, 0)
        XCTAssertEqual(walkB.integratedDeg, .zero)
        XCTAssertEqual(walkB.integratedVerticalDeg, 0)
    }

    /// **角速度・重力・磁場較正は判定に一切渡っていない**(受け入れ条件 E5)。
    /// 同じ heading / course / fix の列に対して、それらをどう変えても
    /// 学習値・R・検疫の状態・使用可能状態が変わらないこと
    func testDigestNeverReachesTheDecision() {
        let p = HeadMountFusion.Params(
            offset: MountOffset.Params(minEvidenceSec: 5, halfLifeSec: 60,
                                       minConcentration: 0.8, gateDeg: 45, maxGapSec: 5),
            quarantine: HeadingQuarantine.Params(windowSec: 40, distrustRatio: 0.75,
                                                 distrustSec: 12, regainRatio: 0.7,
                                                 regainSec: 8),
            staleSec: 30)

        /// 角速度・重力・磁場較正を変えながら、同じ heading/course/fix 列を流す
        func run(rotation: MotionVector, gravity: MotionVector, magnetic: Int)
            -> (offset: Double?, r: Double, state: HeadingQuarantine.State,
                usable: Bool, digest: HeadMotionDigest) {
            var f = HeadMountFusion()
            var d = HeadMotionDigest()
            var t = 100.0
            for i in 0..<20 {
                for k in 0..<10 {
                    t = 100 + Double(i) + Double(k) * 0.1
                    d.add(headingDeg: 184, sensorTime: t, rotationRate: rotation,
                          gravity: gravity, magneticAccuracy: magnetic, maxIntervalSec: 1)
                    f.ingest(headingDeg: 184, rawCourseDeg: 90, fixTime: 100 + Double(i),
                             at: t, p: p)
                }
            }
            return (f.learnedOffsetDeg, f.concentration, f.quarantineState,
                    f.use(at: t, p: p).isUsable, d)
        }

        let still = run(rotation: .zero, gravity: MotionVector(x: 0, y: 0, z: -1), magnetic: 2)
        let other = run(rotation: MotionVector(x: 3, y: -2, z: 1),
                        gravity: MotionVector(x: -1, y: 0, z: 0), magnetic: -1)
        XCTAssertNotEqual(still.digest, other.digest,
                          "前提: 記録の値は実際に違う(そうでないと検査になっていない)")
        XCTAssertEqual(still.offset ?? .nan, other.offset ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(still.r, other.r, accuracy: 1e-12)
        XCTAssertEqual(still.state, other.state)
        XCTAssertEqual(still.usable, other.usable)
        XCTAssertTrue(still.usable, "前提: 使える状態まで到達している")
    }
}
