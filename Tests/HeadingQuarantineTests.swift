import XCTest
@testable import OtoSanpo

/// 頭部固定スマホの方位の検疫(→ docs/13)。
/// 端末コンパスが帰路で左右を反転させた実測(docs/04・2026-08-16)があるので、
/// **「磁気を信じてよいのはいつか」を決めるこの門が、頭部固定の安全装置になる。**
final class HeadingQuarantineTests: XCTestCase {

    private let p = HeadingQuarantine.Params(distrustDeg: 40, distrustSec: 5, regainSec: 5)

    /// 合致した(または乱れた)方位を dur 秒ぶん 1 Hz で流す
    private func feed(_ q: inout HeadingQuarantine, headingDeg: Double, courseDeg: Double?,
                      from t0: Double, seconds: Double) -> Double {
        var t = t0
        while t <= t0 + seconds {
            q.assess(headingDeg: headingDeg, courseDeg: courseDeg, at: t, p: p)
            t += 1
        }
        return t
    }

    /// **初期は使わない。** 屋内の乱れた磁気で歩き出しても、最初の音が反転しない
    func testStartsUnusable() {
        let q = HeadingQuarantine()
        XCTAssertEqual(q.state, .unverified)
        XCTAssertFalse(q.isUsable)
    }

    /// course と合う実績が regainSec 続いたら採用
    func testTrustEarnedByAgreement() {
        var q = HeadingQuarantine()
        q.assess(headingDeg: 90, courseDeg: 92, at: 0, p: p)
        q.assess(headingDeg: 91, courseDeg: 90, at: 4, p: p)
        XCTAssertFalse(q.isUsable, "実績 4 秒では早い(regain_sec = 5)")
        q.assess(headingDeg: 90, courseDeg: 89, at: 5, p: p)
        XCTAssertTrue(q.isUsable)
        XCTAssertEqual(q.state, .trusted)
    }

    /// 採用後、乱れが distrustSec 続いたら退避
    func testDistrustAfterSustainedDisagreement() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 0, seconds: 6)
        XCTAssertTrue(q.isUsable)
        q.assess(headingDeg: 200, courseDeg: 90, at: 10, p: p)
        q.assess(headingDeg: 200, courseDeg: 90, at: 14, p: p)
        XCTAssertTrue(q.isUsable, "乱れ 4 秒では落とさない(distrust_sec = 5)")
        q.assess(headingDeg: 200, courseDeg: 90, at: 15, p: p)
        XCTAssertEqual(q.state, .distrusted)
        XCTAssertFalse(q.isUsable)
    }

    /// 一瞬の乱れ(振り向きなど)では退避しない。窓は合致で捨てられる
    func testBriefDisagreementIsForgiven() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 0, seconds: 6)
        // 3 秒乱れ → 1 秒合致 → 3 秒乱れ。連続 5 秒に達しない
        _ = feed(&q, headingDeg: 200, courseDeg: 90, from: 10, seconds: 3)
        q.assess(headingDeg: 90, courseDeg: 90, at: 14, p: p)
        _ = feed(&q, headingDeg: 200, courseDeg: 90, from: 15, seconds: 3)
        XCTAssertTrue(q.isUsable, "乱れの窓が継ぎ足されている(合致でリセットされるべき)")
    }

    /// 退避からの復帰も同じ形(内側が regainSec 続いたら)
    func testRegainAfterDistrust() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 0, seconds: 6)
        _ = feed(&q, headingDeg: 200, courseDeg: 90, from: 10, seconds: 6)
        XCTAssertEqual(q.state, .distrusted)
        _ = feed(&q, headingDeg: 88, courseDeg: 90, from: 20, seconds: 6)
        XCTAssertEqual(q.state, .trusted)
    }

    /// 立ち止まっている間(course なし)は直前の状態を引き継ぐ
    func testStateHeldWhileStopped() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 0, seconds: 6)
        XCTAssertTrue(q.assess(headingDeg: 300, courseDeg: nil, at: 20, p: p),
                      "採用のまま保つ(首を回しても、突き合わせる相手が無い間は落とさない)")
        var fresh = HeadingQuarantine()
        XCTAssertFalse(fresh.assess(headingDeg: 90, courseDeg: nil, at: 0, p: p),
                       "未検証のまま保つ(立ち止まったままでは信頼を得られない)")
    }

    /// course が無い区間を挟んだ実績は継ぎ足さない
    func testAgreementWindowNotBridgedAcrossStop() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 0, seconds: 3)
        q.assess(headingDeg: 90, courseDeg: nil, at: 4, p: p)   // 立ち止まる
        _ = feed(&q, headingDeg: 90, courseDeg: 90, from: 5, seconds: 3)
        XCTAssertFalse(q.isUsable, "3 秒 + 3 秒を 6 秒の実績として繋いではいけない")
    }

    /// 方位の折り返し(350° と 10°)は差 20° として扱う
    func testAngleWraparound() {
        var q = HeadingQuarantine()
        _ = feed(&q, headingDeg: 350, courseDeg: 10, from: 0, seconds: 6)
        XCTAssertTrue(q.isUsable, "350° と 10° の差は 20°(360° 近くの折り返しを跨いで合致)")
    }
}
