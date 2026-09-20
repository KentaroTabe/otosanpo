import XCTest
@testable import OtoSanpo

/// 「その人にとって真横に聞こえる角度」で音の置き方を合わせる(→ `EarAngleMap`・docs/08)。
///
/// ## なぜ要るか(2026-09-18 利用者依頼)
///
/// 「音を左後ろから正面を経由して右後ろまでのいずれかで流せる 1 本のつまみを用意し、
/// それを元に校正する」。真右に聞こえた所でつまみを止めてもらい、その角度を覚える。
final class EarAngleMapTests: XCTestCase {

    /// **合わせた角度が 90° なら何もしない**(校正前と同じ聞こえ方)
    func testNinetyMeansIdentity() {
        let m = EarAngleMap.identity
        for deg in stride(from: -180.0, through: 180.0, by: 15.0) {
            XCTAssertEqual(m.rendered(intendedDeg: deg), deg, accuracy: 1e-6,
                           "\(deg)° が動かないこと")
        }
    }

    /// **正面と真後ろは動かさない**(どんな校正でも)
    func testFrontAndBackAreFixed() {
        let m = EarAngleMap(rightAnchorDeg: 130, leftAnchorDeg: 55)
        XCTAssertEqual(m.rendered(intendedDeg: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(abs(m.rendered(intendedDeg: 180)), 180, accuracy: 1e-6)
        XCTAssertEqual(abs(m.rendered(intendedDeg: -180)), 180, accuracy: 1e-6)
    }

    /// **真横は、合わせた所へ置かれる**
    func testNinetyGoesToTheAnchor() {
        let m = EarAngleMap(rightAnchorDeg: 120, leftAnchorDeg: 70)
        XCTAssertEqual(m.rendered(intendedDeg: 90), 120, accuracy: 0.01)
        XCTAssertEqual(m.rendered(intendedDeg: -90), -70, accuracy: 0.01)
    }

    /// **間の角度も一緒に開く**(真横だけずらすのではない)。
    /// 内側は一定の比(合わせた角度 / 90)で開き、外側は残りを詰める
    func testIntermediateAnglesOpenTogether() {
        let m = EarAngleMap(rightAnchorDeg: 120, leftAnchorDeg: 120)
        XCTAssertEqual(m.rendered(intendedDeg: 45), 60, accuracy: 0.01)
        XCTAssertEqual(m.rendered(intendedDeg: 30), 40, accuracy: 0.01)
        XCTAssertEqual(m.rendered(intendedDeg: 135), 150, accuracy: 0.01,
                       "真横より外側は詰まる(180° は動かないため)")
    }

    /// **正面のすぐ横で傾きが暴れない。**
    /// 冪で作ると 0.05° の入力が 3.9° になった(首のわずかな動きが大きな移動に化ける)
    func testSlopeNearTheFrontIsBounded() {
        let m = EarAngleMap(rightAnchorDeg: 130, leftAnchorDeg: 60)
        XCTAssertEqual(m.rendered(intendedDeg: 0.05), 0.05 * 130 / 90, accuracy: 1e-6)
        XCTAssertLessThan(m.rendered(intendedDeg: 1), 2, "1° の入力が 2° を超えないこと")
    }

    /// 左右は別々(耳は左右対称ではない)
    func testLeftAndRightAreIndependent() {
        let m = EarAngleMap(rightAnchorDeg: 130, leftAnchorDeg: 60)
        XCTAssertEqual(m.rendered(intendedDeg: 90), 130, accuracy: 0.01)
        XCTAssertEqual(m.rendered(intendedDeg: -90), -60, accuracy: 0.01)
    }

    /// **単調**であること(順番が入れ替わらない)
    func testIsMonotonic() {
        let m = EarAngleMap(rightAnchorDeg: 140, leftAnchorDeg: 35)
        var previous = -181.0
        for deg in stride(from: -179.0, through: 179.0, by: 1.0) {
            let v = m.rendered(intendedDeg: deg)
            XCTAssertGreaterThan(v, previous, "\(deg)° で順番が入れ替わった")
            previous = v
        }
    }

    /// 0° と ±180° の近くで折れない(連続)
    func testIsContinuous() {
        let m = EarAngleMap(rightAnchorDeg: 130, leftAnchorDeg: 60)
        for center in [0.0, 90.0, -90.0, 179.0] {
            let a = m.rendered(intendedDeg: center - 0.05)
            let b = m.rendered(intendedDeg: center + 0.05)
            XCTAssertEqual(a, b, accuracy: 0.5, "\(center)° の前後で跳ばないこと")
        }
    }

    /// 360° をまたいだ入力も同じ結果になる
    func testWrapsAround() {
        let m = EarAngleMap(rightAnchorDeg: 120, leftAnchorDeg: 120)
        XCTAssertEqual(m.rendered(intendedDeg: 450), m.rendered(intendedDeg: 90), accuracy: 1e-6)
        XCTAssertEqual(m.rendered(intendedDeg: -270), m.rendered(intendedDeg: 90), accuracy: 1e-6)
    }

    /// 範囲の外・非有限は「校正済み」と認めない
    func testValidity() {
        XCTAssertTrue(EarAngleMap(rightAnchorDeg: 20, leftAnchorDeg: 160).isValid)
        XCTAssertFalse(EarAngleMap(rightAnchorDeg: 10, leftAnchorDeg: 90).isValid)
        XCTAssertFalse(EarAngleMap(rightAnchorDeg: 170, leftAnchorDeg: 90).isValid)
        XCTAssertFalse(EarAngleMap(rightAnchorDeg: .nan, leftAnchorDeg: 90).isValid)
    }

    /// 壊れた入力でも落ちない
    func testNonFiniteInputIsSafe() {
        let m = EarAngleMap(rightAnchorDeg: 120, leftAnchorDeg: 70)
        XCTAssertEqual(m.rendered(intendedDeg: .nan), 0, accuracy: 1e-9)
    }

    /// 保存して読み直せる
    func testSurvivesEncodingRoundTrip() throws {
        let m = EarAngleMap(rightAnchorDeg: 112.5, leftAnchorDeg: 78.5)
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(EarAngleMap.self, from: data), m)
    }
}
