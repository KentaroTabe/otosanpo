import XCTest
@testable import OtoSanpo

/// 左右の音量差を利用者が合わせた値で決める(→ `EarBalance`・docs/08)。
///
/// ## なぜ要るか(2026-09-18)
///
/// 「左右のイヤホンから聞こえる音量の合計値がほぼ一定な影響で、左右に偏った時のみ
/// はっきり分かる」という報告。汎用 HRTF の左右差は平均的な頭のもので、
/// **その人にとって 90° に聞こえる保証は無い**。真横での差だけ本人に合わせてもらう。
final class EarBalanceTests: XCTestCase {

    private let six = EarBalance(rightDb: 6, leftDb: 6)

    /// **正面と真後ろでは左右が等しい**(→ 合議 C3)
    func testFrontAndBackAreEqual() {
        for deg in [0.0, 180.0, -180.0, 360.0] {
            let g = six.gains(relativeBearingDeg: deg)
            XCTAssertEqual(g.left, g.right, accuracy: 1e-9, "\(deg)° で左右が等しいこと")
        }
    }

    /// 真横では、合わせた値そのものになる(→ 合議 C3)
    func testAtNinetyDegreesTheSavedDifferenceIsUsed() {
        let cal = EarBalance(rightDb: 6, leftDb: 10)
        XCTAssertEqual(cal.differenceDb(relativeBearingDeg: 90), 6, accuracy: 1e-9)
        XCTAssertEqual(cal.differenceDb(relativeBearingDeg: -90), -10, accuracy: 1e-9)
        let r = cal.gains(relativeBearingDeg: 90)
        XCTAssertEqual(20 * log10(r.right / r.left), 6, accuracy: 1e-9)
        let l = cal.gains(relativeBearingDeg: -90)
        XCTAssertEqual(20 * log10(l.left / l.right), 10, accuracy: 1e-9)
    }

    /// **間は |sin θ| で補間する**(→ 合議 C4)
    func testInterpolatesBySine() {
        XCTAssertEqual(six.differenceDb(relativeBearingDeg: 30), 3, accuracy: 1e-9)
        XCTAssertEqual(six.differenceDb(relativeBearingDeg: 150), 3, accuracy: 1e-9)
        XCTAssertEqual(six.differenceDb(relativeBearingDeg: -30), -3, accuracy: 1e-9)
    }

    /// **左² + 右² = 1**(電力の係数。聞こえる大きさの保証ではない → 合議 C5)
    func testPowerSumIsOne() {
        let cal = EarBalance(rightDb: 18, leftDb: 3)
        for deg in stride(from: -180.0, through: 180.0, by: 7.5) {
            let g = cal.gains(relativeBearingDeg: deg)
            XCTAssertEqual(g.left * g.left + g.right * g.right, 1, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(g.left, 0)
            XCTAssertGreaterThanOrEqual(g.right, 0)
            XCTAssertTrue(g.left.isFinite && g.right.isFinite)
        }
    }

    /// 0°・±90°・±180° をまたいでも連続(→ 合議 C6)
    func testIsContinuousAcrossTheCardinalAngles() {
        let cal = EarBalance(rightDb: 12, leftDb: 8)
        for center in [0.0, 90.0, -90.0, 180.0] {
            let a = cal.gains(relativeBearingDeg: center - 0.05)
            let b = cal.gains(relativeBearingDeg: center + 0.05)
            XCTAssertEqual(a.left, b.left, accuracy: 0.01, "\(center)° の前後で跳ばないこと")
            XCTAssertEqual(a.right, b.right, accuracy: 0.01)
        }
    }

    /// 左右で違う値を入れたら、左右で違う結果になる(鏡写しにしていないこと)
    func testLeftAndRightAreIndependent() {
        let cal = EarBalance(rightDb: 3, leftDb: 15)
        XCTAssertEqual(abs(cal.differenceDb(relativeBearingDeg: 45)), 3 * sin(45 * .pi / 180),
                       accuracy: 1e-9)
        XCTAssertEqual(abs(cal.differenceDb(relativeBearingDeg: -45)), 15 * sin(45 * .pi / 180),
                       accuracy: 1e-9)
    }

    /// 差が 0 なら、どの向きでも左右が等しい(校正前と同じ聞こえ方)
    func testZeroCalibrationIsFlat() {
        let flat = EarBalance(rightDb: 0, leftDb: 0)
        for deg in [0.0, 45.0, 90.0, -90.0, 135.0] {
            let g = flat.gains(relativeBearingDeg: deg)
            XCTAssertEqual(g.left, g.right, accuracy: 1e-9)
        }
    }

    // MARK: - つまみ(等電力パン)への写像

    /// 中央は 0、右いっぱいは +1 へ近づく。**単調**であること
    func testPanIsMonotonicAndCentred() {
        XCTAssertEqual(EarBalance.pan(differenceDb: 0), 0, accuracy: 1e-9)
        var previous = -2.0
        for db in stride(from: 0.0, through: 24.0, by: 1.0) {
            let p = EarBalance.pan(differenceDb: db)
            XCTAssertGreaterThan(p, previous, "差が大きいほど右へ寄ること(\(db) dB)")
            XCTAssertLessThanOrEqual(p, 1)
            previous = p
        }
    }

    /// 向きから作ったパンも、正面で中央・右で正・左で負
    func testPanFollowsTheBearing() {
        XCTAssertEqual(six.pan(relativeBearingDeg: 0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(six.pan(relativeBearingDeg: 90), 0)
        XCTAssertLessThan(six.pan(relativeBearingDeg: -90), 0)
        XCTAssertEqual(six.pan(relativeBearingDeg: 180), 0, accuracy: 1e-9)
    }

    // MARK: - 妥当性

    /// 範囲の外・非有限は「校正済み」と認めない(→ 合議 C8)
    func testValidity() {
        XCTAssertTrue(EarBalance(rightDb: 0, leftDb: 24).isValid)
        XCTAssertFalse(EarBalance(rightDb: -1, leftDb: 6).isValid)
        XCTAssertFalse(EarBalance(rightDb: 25, leftDb: 6).isValid)
        XCTAssertFalse(EarBalance(rightDb: .nan, leftDb: 6).isValid)
        XCTAssertFalse(EarBalance(rightDb: 6, leftDb: .infinity).isValid)
    }

    /// 壊れた向きを渡しても落ちない
    func testNonFiniteBearingIsSafe() {
        XCTAssertEqual(six.differenceDb(relativeBearingDeg: .nan), 0, accuracy: 1e-9)
        let g = six.gains(relativeBearingDeg: .infinity)
        XCTAssertEqual(g.left, g.right, accuracy: 1e-9)
    }

    /// 保存して読み直せる
    func testSurvivesEncodingRoundTrip() throws {
        let cal = EarBalance(rightDb: 7.5, leftDb: 11.25)
        let data = try JSONEncoder().encode(cal)
        XCTAssertEqual(try JSONDecoder().decode(EarBalance.self, from: data), cal)
    }
}
