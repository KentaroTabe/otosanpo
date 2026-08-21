import XCTest
@testable import OtoSanpo

final class HeadGestureDetectorTests: XCTestCase {
    private let params = AppParameters.Gesture(
        nodPitchThresholdDeg: 10, shakeYawThresholdDeg: 12,
        minReversals: 2, windowSec: 1.6, refractorySec: 1.0,
        diagnosticsIntervalSec: 0.5, diagnosticsReportRatio: 0.7)

    private func feed(pitches: [Double] = [], yaws: [Double] = [],
                      detector: inout HeadGestureDetector) -> HeadGesture? {
        let n = max(pitches.count, yaws.count)
        var result: HeadGesture?
        for i in 0..<n {
            let s = HeadSample(time: Double(i) * 0.2,
                               pitchDeg: i < pitches.count ? pitches[i] : 0,
                               yawDeg: i < yaws.count ? yaws[i] : 0)
            if let g = detector.ingest(s) { result = g }
        }
        return result
    }

    func testNodDetected() {
        var d = HeadGestureDetector(params: params)
        XCTAssertEqual(feed(pitches: [0, 14, -14, 14], detector: &d), .nod)
    }

    func testShakeDetected() {
        var d = HeadGestureDetector(params: params)
        XCTAssertEqual(feed(yaws: [0, 16, -16, 16], detector: &d), .shake)
    }

    func testSmallNoiseIgnored() {
        var d = HeadGestureDetector(params: params)
        XCTAssertNil(feed(pitches: [0, 5, -5, 5, -5], detector: &d))
    }

    func testMonotonicYawTurnIgnored() {
        // 歩行中に体ごと右へ曲がる(yaw が単調変化)場合は首振りと誤検出しない
        var d = HeadGestureDetector(params: params)
        XCTAssertNil(feed(yaws: [0, 20, 40, 60, 80], detector: &d))
    }

    func testJitterAcrossYawBoundaryIgnored() {
        // 正面が ±180° 付近にあるとき、実際の動きは ±数度でも生値は 176 → -179 と飛ぶ。
        // 折り返しを解かないと巨大な偏差として首振りに化ける。
        var d = HeadGestureDetector(params: params)
        XCTAssertNil(feed(yaws: [176, -179, 178, -177, 179], detector: &d))
    }

    func testShakeAcrossYawBoundaryDetected() {
        // 正面 180° を中心に ±16° 振った(164 ↔ 196)。生値は 164 ↔ -164 に折り返す
        var d = HeadGestureDetector(params: params)
        XCTAssertEqual(feed(yaws: [164, -164, 164, -164, 164], detector: &d), .shake)
    }

    func testUnwrapDegRemovesBoundaryJumps() {
        let out = HeadGestureDetector.unwrapDeg([176, -179, 178, -177, 179])
        XCTAssertEqual(out, [176, 181, 178, 183, 179])
    }
}

final class WalkMachineTests: XCTestCase {
    private let session = AppParameters.Session(
        defaultDurationMin: 30, minDurationMin: 10, maxDurationMin: 90,
        extensionRatio: 0.33, maxExtensions: 2,
        rePromptIntervalSec: 60, arrivalRadiusM: 40)

    func testStartFromIdle() {
        let (s, e) = WalkMachine.reduce(state: .idle, event: .start,
                                        extensionsUsed: 0, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .wandering)
        XCTAssertTrue(e.contains(.startSuggestionLoop))
    }

    func testTimeUpPrompts() {
        let (s, e) = WalkMachine.reduce(state: .wandering, event: .timeUp,
                                        extensionsUsed: 0, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .promptingReturn)
        XCTAssertTrue(e.contains(.play(.timeUpPrompt)))
        XCTAssertTrue(e.contains(.stopSuggestionLoop))
    }

    func testNodStartsReturnPhase() {
        let (s, e) = WalkMachine.reduce(state: .promptingReturn, event: .nod,
                                        extensionsUsed: 0, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .returning)
        XCTAssertTrue(e.contains(.startReturnPhase))
    }

    func testShakeExtendsUntilLimit() {
        let (s, e) = WalkMachine.reduce(state: .promptingReturn, event: .shake,
                                        extensionsUsed: 1, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .wandering)
        // 延長は設定時間 × extension_ratio(30 分 × 0.33 ≒ 10 分)
        XCTAssertTrue(e.contains(.extendSession(minutes: 30 * 0.33)))
    }

    func testShakeAtLimitOnlyReprompts() {
        let (s, e) = WalkMachine.reduce(state: .promptingReturn, event: .shake,
                                        extensionsUsed: 2, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .promptingReturn)
        XCTAssertFalse(e.contains(.extendSession(minutes: 30 * 0.33)))
        XCTAssertTrue(e.contains(.play(.timeUpPrompt)))
    }

    func testReachedHomeArrives() {
        let (s, e) = WalkMachine.reduce(state: .returning, event: .reachedHome,
                                        extensionsUsed: 0, plannedDurationMin: 30, params: session)
        XCTAssertEqual(s, .arrived)
        XCTAssertTrue(e.contains(.play(.arrival)))
        XCTAssertTrue(e.contains(.endSession))
    }

    func testStopFromAnywhere() {
        for state: WalkState in [.wandering, .promptingReturn, .returning, .arrived] {
            let (s, e) = WalkMachine.reduce(state: state, event: .stop,
                                            extensionsUsed: 0, plannedDurationMin: 30, params: session)
            XCTAssertEqual(s, .idle)
            XCTAssertTrue(e.contains(.endSession))
        }
    }

    /// **帰路の案内は帰路の音で鳴らす**(2026-08-21 の利用者判断)。
    /// 帰る区間で誘導とビーコンの音色が混ざると落ち着かない
    func testGuidanceUsesTheReturnToneOnlyWhileReturning() {
        XCTAssertEqual(WalkMachine.guidanceEarcon(for: .returning), .homeBeacon)
        for state: WalkState in [.idle, .wandering, .promptingReturn, .arrived] {
            XCTAssertEqual(WalkMachine.guidanceEarcon(for: state), .suggestion)
        }
    }
}

/// 帰路の確認音をいつまで繰り返すか。
/// 実測(2026-08-19)では確認音が誘導とビーコンを 60 秒せき止め、
/// **帰路の最初の 64 秒間、方向の手がかりが 1 つも鳴っていなかった**
final class ReturnAckTests: XCTestCase {
    func testStopsAsSoonAsGuidanceStarts() {
        // 案内が始まれば「同意が伝わった」ことは伝わっている。上限を待たない
        XCTAssertFalse(ReturnAck.shouldRepeat(directionStarted: true, elapsedSec: 1,
                                              durationSec: 60))
    }

    func testKeepsGoingWhileNoDirectionIsAvailable() {
        // 進行方向が取れない・地図が無いなど、案内を出せない状況では確認音だけが頼り
        XCTAssertTrue(ReturnAck.shouldRepeat(directionStarted: false, elapsedSec: 1,
                                             durationSec: 60))
        XCTAssertTrue(ReturnAck.shouldRepeat(directionStarted: false, elapsedSec: 59,
                                             durationSec: 60))
    }

    func testStopsAtTheUpperBound() {
        XCTAssertFalse(ReturnAck.shouldRepeat(directionStarted: false, elapsedSec: 60,
                                              durationSec: 60))
    }
}
