import XCTest
@testable import OtoSanpo

final class TravelDirectionTests: XCTestCase {
    /// 退避の優先順位そのものを見たいテストが多いため、既定はホールドなし(0 秒)にする
    private let params = AppParameters.Location(
        minSpeedForCourseMPerS: 0.7, maxCourseAccuracyDeg: 45,
        maxFixAgeSec: 10, courseHoldSec: 0, allowCompassFallback: true)

    /// 実機の既定に合わせた設定(ホールド 30 秒・コンパス退避なし)
    private let holdingParams = AppParameters.Location(
        minSpeedForCourseMPerS: 0.7, maxCourseAccuracyDeg: 45,
        maxFixAgeSec: 10, courseHoldSec: 30, allowCompassFallback: false)

    /// 歩行中は端末コンパスではなく移動方向(course)を採用する
    func testWalkingPrefersCourseOverCompass() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.3,
                            compassHeadingDeg: 270, ageSec: 1)
        let r = TravelDirection.resolve(fix, params: params)
        XCTAssertEqual(r, TravelDirectionFix(deg: 90, source: .course))
    }

    /// 立ち止まっている(閾値未満)ときは course を信用せずコンパスへ退避する
    func testStandingStillFallsBackToCompass() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.2,
                            compassHeadingDeg: 270, ageSec: 1)
        let r = TravelDirection.resolve(fix, params: params)
        XCTAssertEqual(r, TravelDirectionFix(deg: 270, source: .compass))
    }

    /// CoreLocation は course / speed が無効なとき負値を返す
    func testNegativeCourseIsInvalid() {
        let fix = MotionFix(courseDeg: -1, courseAccuracyDeg: -1, speedMps: -1,
                            compassHeadingDeg: 180, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(fix, params: params)?.source, .compass)
    }

    /// course の精度が許容を超えたら使わない
    func testPoorCourseAccuracyFallsBack() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 90, speedMps: 1.3,
                            compassHeadingDeg: 270, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(fix, params: params)?.source, .compass)
    }

    /// courseAccuracy が不明(nil / 負値)でも、速度が出ていれば course を使う
    func testUnknownCourseAccuracyStillUsesCourse() {
        let unknown = MotionFix(courseDeg: 90, courseAccuracyDeg: nil, speedMps: 1.3,
                                compassHeadingDeg: 270, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(unknown, params: params)?.source, .course)

        let negative = MotionFix(courseDeg: 90, courseAccuracyDeg: -1, speedMps: 1.3,
                                 compassHeadingDeg: 270, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(negative, params: params)?.source, .course)
    }

    /// 古い位置更新の course は使わない(トンネルや電波不良で止まった値を掴まない)
    func testStaleFixFallsBack() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.3,
                            compassHeadingDeg: 270, ageSec: 30)
        XCTAssertEqual(TravelDirection.resolve(fix, params: params)?.source, .compass)
    }

    /// コンパス退避を無効にすると、course が無効な間は方向なし(= 鳴らさない)
    func testFallbackDisabledYieldsNil() {
        let p = AppParameters.Location(minSpeedForCourseMPerS: 0.7, maxCourseAccuracyDeg: 45,
                                       maxFixAgeSec: 10, courseHoldSec: 0,
                                       allowCompassFallback: false)
        let fix = MotionFix(courseDeg: -1, courseAccuracyDeg: -1, speedMps: -1,
                            compassHeadingDeg: 270, ageSec: 1)
        XCTAssertNil(TravelDirection.resolve(fix, params: p))
    }

    /// course も compass も無ければ nil
    func testNoInputYieldsNil() {
        XCTAssertNil(TravelDirection.resolve(MotionFix(), params: params))
    }

    /// 360 度を跨ぐ値は 0..360 に正規化される
    func testNormalizesOutOfRangeValues() {
        let fix = MotionFix(courseDeg: 370, courseAccuracyDeg: 5, speedMps: 1.3, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(fix, params: params)?.deg ?? -1, 10, accuracy: 0.001)
    }

    // MARK: - course のホールド

    /// course の精度が落ちた区間では、直前まで有効だった向きを使い続ける
    func testHoldsLastGoodCourseWhileCourseIsInvalid() {
        let fix = MotionFix(courseDeg: 123, courseAccuracyDeg: 53, speedMps: 1.2,
                            compassHeadingDeg: 341, ageSec: 0.2)
        let r = TravelDirection.resolve(fix, held: HeldCourse(deg: 125, ageSec: 5),
                                        params: holdingParams)
        XCTAssertEqual(r, TravelDirectionFix(deg: 125, source: .heldCourse))
    }

    /// 保持値が古くなったら使わない(曲がった後も古い向きを指し続けないため)
    func testExpiredHoldIsNotUsed() {
        let fix = MotionFix(courseDeg: -1, courseAccuracyDeg: -1, speedMps: -1, ageSec: 1)
        XCTAssertNil(TravelDirection.resolve(fix, held: HeldCourse(deg: 125, ageSec: 31),
                                             params: holdingParams))
    }

    /// 有効な course があれば保持値より優先する
    func testValidCourseWinsOverHold() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.3, ageSec: 1)
        let r = TravelDirection.resolve(fix, held: HeldCourse(deg: 200, ageSec: 1),
                                        params: holdingParams)
        XCTAssertEqual(r, TravelDirectionFix(deg: 90, source: .course))
    }

    /// 保持値はコンパスより優先する(ポケットの中の端末の向きより確からしい)
    func testHoldWinsOverCompass() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 90, speedMps: 1.3,
                            compassHeadingDeg: 270, ageSec: 1)
        let p = AppParameters.Location(minSpeedForCourseMPerS: 0.7, maxCourseAccuracyDeg: 45,
                                       maxFixAgeSec: 10, courseHoldSec: 30,
                                       allowCompassFallback: true)
        XCTAssertEqual(TravelDirection.resolve(fix, held: HeldCourse(deg: 125, ageSec: 5),
                                               params: p)?.source, .heldCourse)
    }

    // MARK: - 棄却理由

    func testRejectionReasonNamesTheFailingCondition() {
        let slow = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.2, ageSec: 1)
        XCTAssertEqual(TravelDirection.rejectionReason(slow, params: params)?.contains("速度不足"), true)

        let stale = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.3, ageSec: 30)
        XCTAssertEqual(TravelDirection.rejectionReason(stale, params: params)?.contains("古い"), true)

        let inaccurate = MotionFix(courseDeg: 90, courseAccuracyDeg: 90, speedMps: 1.3, ageSec: 1)
        XCTAssertEqual(TravelDirection.rejectionReason(inaccurate, params: params)?.contains("精度不足"), true)
    }

    /// 有効な course には棄却理由が無い
    func testValidCourseHasNoRejectionReason() {
        let fix = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.3, ageSec: 1)
        XCTAssertNil(TravelDirection.rejectionReason(fix, params: params))
    }
}
