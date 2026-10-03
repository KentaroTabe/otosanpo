import XCTest
@testable import OtoSanpo

/// スポットを移すイベントの日程(→ `SpotMoveSchedule`・docs/08)。
///
/// ## なぜ要るか(2026-09-18 利用者依頼)
///
/// 「ある程度時間が経ったらイベントが発生し、うなずくとスポット位置が変更される。
/// 拒否した場合はイベントまでの長さが倍々に増え、合意して移動したときは長さを同じにする」
final class SpotMoveScheduleTests: XCTestCase {

    private func params(base: Double = 180, delay: Double = 0.5,
                        window: Double = 8) -> SpotMoveSchedule.Params {
        SpotMoveSchedule.Params(baseIntervalSec: base, responseDelaySec: delay,
                                responseWindowSec: window)
    }

    /// **音楽が鳴り始めた時から数える**(待っていた時間は含めない → 合議 E1)
    func testFirstDeadlineIsBaseIntervalAfterTheMusicStarts() {
        var s = SpotMoveSchedule()
        s.start(at: 1000, p: params())
        XCTAssertFalse(s.isDue(at: 1179))
        XCTAssertTrue(s.isDue(at: 1180))
        XCTAssertEqual(s.intervalSec, 180, accuracy: 1e-9)
    }

    /// 始める前は何も起きない
    func testNothingIsDueBeforeStart() {
        let s = SpotMoveSchedule()
        XCTAssertFalse(s.isDue(at: 99999))
        XCTAssertFalse(s.acceptsResponse(at: 99999))
    }

    /// **応答の窓は、鳴り終わってから待って開く**(→ 合議 E3)
    func testTheResponseWindowOpensAfterThePromptFinishes() {
        var s = SpotMoveSchedule()
        let p = params(delay: 0.5, window: 8)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 200, p: p)
        XCTAssertFalse(s.acceptsResponse(at: 200.4), "鳴り終わり直後はまだ受け付けない")
        XCTAssertTrue(s.acceptsResponse(at: 200.5))
        XCTAssertTrue(s.acceptsResponse(at: 208.4))
        XCTAssertFalse(s.acceptsResponse(at: 208.5), "窓が閉じたら受け付けない")
        XCTAssertTrue(s.windowExpired(at: 208.5))
    }

    /// 応答待ちの間は、次のイベントを出さない
    func testNothingIsDueWhileWaitingForAResponse() {
        var s = SpotMoveSchedule()
        let p = params()
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        XCTAssertFalse(s.isDue(at: 1000))
    }

    /// **合意したら間隔はそのまま**(→ 合議 E4)
    func testAcceptingKeepsTheInterval() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.accepted(at: 185)
        XCTAssertEqual(s.intervalSec, 180, accuracy: 1e-9)
        XCTAssertEqual(s.moves, 1)
        XCTAssertFalse(s.isDue(at: 364))
        XCTAssertTrue(s.isDue(at: 365), "移した時刻 + 現在の間隔")
    }

    /// **断ったら倍**(→ 合議 E5)
    func testRefusingDoublesTheInterval() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.refused(at: 188)
        XCTAssertEqual(s.intervalSec, 360, accuracy: 1e-9)
        XCTAssertEqual(s.refusals, 1)
        XCTAssertTrue(s.isDue(at: 548), "応答が決まった時刻 + 新しい間隔")
    }

    /// **拒否 → 拒否 → 移動成功で 360 → 720 → 720**(→ 合議 E6)
    func testDoublingSequence() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.refused(at: 190)
        XCTAssertEqual(s.intervalSec, 360, accuracy: 1e-9)
        s.prompted(promptEndsAt: 550, p: p)
        s.refused(at: 560)
        XCTAssertEqual(s.intervalSec, 720, accuracy: 1e-9)
        s.prompted(promptEndsAt: 1280, p: p)
        s.accepted(at: 1290)
        XCTAssertEqual(s.intervalSec, 720, accuracy: 1e-9, "合意では間隔を変えない")
    }

    /// **中断は断りに数えない**(→ 合議 E10)
    func testPostponeDoesNotCountAsRefusal() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.postpone(at: 182)
        XCTAssertEqual(s.intervalSec, 180, accuracy: 1e-9)
        XCTAssertEqual(s.refusals, 0)
        XCTAssertTrue(s.isDue(at: 362))
    }

    /// 倍々を繰り返しても、短い間隔へ戻らない(→ 合議 E12)
    func testDoublingNeverWrapsAround() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        var t = 180.0
        for _ in 0..<80 {
            s.prompted(promptEndsAt: t, p: p)
            s.refused(at: t + 10)
            t += s.intervalSec
            XCTAssertGreaterThanOrEqual(s.intervalSec, 180)
            XCTAssertTrue(s.intervalSec.isFinite)
        }
    }

    /// 止めたら予約も応答待ちも消える(→ 合議 E11)
    func testStopClearsEverything() {
        var s = SpotMoveSchedule()
        let p = params()
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.stop()
        XCTAssertFalse(s.isDue(at: 10000))
        XCTAssertFalse(s.acceptsResponse(at: 181))
        XCTAssertFalse(s.windowExpired(at: 10000))
    }

    /// 新しい散歩は初期化された状態から始まる(→ 合議 E11)
    func testANewWalkStartsFresh() {
        var s = SpotMoveSchedule()
        let p = params(base: 180)
        s.start(at: 0, p: p)
        s.prompted(promptEndsAt: 180, p: p)
        s.refused(at: 190)
        s = SpotMoveSchedule()
        s.start(at: 5000, p: p)
        XCTAssertEqual(s.intervalSec, 180, accuracy: 1e-9)
        XCTAssertEqual(s.refusals, 0)
        XCTAssertEqual(s.moves, 0)
    }
}
