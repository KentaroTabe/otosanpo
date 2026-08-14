import XCTest
@testable import OtoSanpo

final class TravelDirectionTests: XCTestCase {
    private let params = AppParameters.Location(
        minSpeedForCourseMPerS: 0.7, maxCourseAccuracyDeg: 45,
        maxFixAgeSec: 10, allowCompassFallback: true)

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
                                       maxFixAgeSec: 10, allowCompassFallback: false)
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
}
