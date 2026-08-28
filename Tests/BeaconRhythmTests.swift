import XCTest
@testable import OtoSanpo

/// 帰路ビーコンを歩調に同期させ、距離は音量で表す(2026-08-16 の要望・2026-08-19 の確認)。
/// 間隔が歩調に取られるため、距離の表し方が間隔から音量へ移る。
final class BeaconRhythmTests: XCTestCase {
    private let p = BeaconRhythm.Params(
        stepsPerTone: 4, minIntervalSec: 1.0, maxIntervalSec: 4.0,
        fallbackIntervalSec: 2.0, gainFar: 0.45, gainNear: 1.0,
        nearDistanceM: 60, farDistanceM: 600)

    // MARK: - 間隔は歩調に同期する

    func testIntervalFollowsCadence() {
        // 2 歩/秒で 4 歩に 1 回 → 2 秒
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: 2.0, p: p), 2.0, accuracy: 0.01)
        // ゆっくり歩けば間隔も伸びる
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: 1.5, p: p),
                       4.0 / 1.5, accuracy: 0.01)
    }

    func testFasterWalkingMeansShorterInterval() {
        let slow = BeaconRhythm.intervalSec(cadenceStepsPerSec: 1.4, p: p)
        let fast = BeaconRhythm.intervalSec(cadenceStepsPerSec: 2.4, p: p)
        XCTAssertLessThan(fast, slow)
    }

    /// 走ったり立ち止まりかけたりしても暴れない
    func testIntervalIsClamped() {
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: 8.0, p: p), 1.0, accuracy: 0.01)
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: 0.5, p: p), 4.0, accuracy: 0.01)
    }

    /// 歩調が取れないとき(立ち止まっている・非対応端末)は既定の間隔
    func testFallbackWhenCadenceIsUnavailable() {
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: nil, p: p), 2.0, accuracy: 0.01)
        XCTAssertEqual(BeaconRhythm.intervalSec(cadenceStepsPerSec: 0, p: p), 2.0, accuracy: 0.01)
    }

    // MARK: - 距離は音量で表す

    func testGainRisesAsHomeGetsCloser() {
        XCTAssertEqual(BeaconRhythm.gain(distanceM: 600, p: p), 0.45, accuracy: 0.001)
        XCTAssertEqual(BeaconRhythm.gain(distanceM: 60, p: p), 1.0, accuracy: 0.001)
        // 中間は単調に上がる
        let far = BeaconRhythm.gain(distanceM: 400, p: p)
        let mid = BeaconRhythm.gain(distanceM: 300, p: p)
        let near = BeaconRhythm.gain(distanceM: 150, p: p)
        XCTAssertLessThan(far, mid)
        XCTAssertLessThan(mid, near)
    }

    func testGainIsClampedOutsideTheRange() {
        XCTAssertEqual(BeaconRhythm.gain(distanceM: 5000, p: p), 0.45, accuracy: 0.001)
        XCTAssertEqual(BeaconRhythm.gain(distanceM: 5, p: p), 1.0, accuracy: 0.001)
    }

    /// 音量は距離だけで決まり、歩調とは独立。2 つの手がかりが混ざらない
    func testGainDoesNotDependOnCadence() {
        let g = BeaconRhythm.gain(distanceM: 300, p: p)
        for cadence in [1.0, 2.0, 3.0] {
            _ = BeaconRhythm.intervalSec(cadenceStepsPerSec: cadence, p: p)
            XCTAssertEqual(BeaconRhythm.gain(distanceM: 300, p: p), g, accuracy: 0.001)
        }
    }
}
