import XCTest
@testable import OtoSanpo

final class HeadingFusionTests: XCTestCase {
    /// 実機は 50 Hz。時定数を数十秒にしたいので alpha は小さい
    private let p = HeadingFusion.Params(baselineAlpha: 0.0005, maxOffsetDeg: 90, minSamples: 250)
    /// 基準線の追従を見るテスト用に、速く動く設定も用意する
    private let fast = HeadingFusion.Params(baselineAlpha: 0.05, maxOffsetDeg: 90, minSamples: 10)

    /// 基準線が育つまでは何も返さない(進行方位をそのまま使わせる)
    func testReturnsNilUntilBaselineIsEstablished() {
        var f = HeadingFusion()
        // minSamples = 10 なので、10 件与えた後の 11 件目から返る
        for _ in 0..<10 {
            XCTAssertNil(f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast))
        }
        XCTAssertNotNil(f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast))
    }

    /// 顔が進行方向を向き続けているなら、推定した向き = 進行方位
    func testFacingEqualsTravelWhenHeadIsSteady() {
        var f = HeadingFusion()
        var last: Double?
        for _ in 0..<400 {
            last = f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast)
        }
        XCTAssertEqual(last ?? -1, 90, accuracy: 1.0)
    }

    /// 首を右に 40° 振った瞬間は、推定した向きも進行方位から 40° 右にずれる。
    /// これが「音が世界に固定されて聞こえる」ための本体
    func testHeadTurnShiftsFacingBearing() {
        var f = HeadingFusion()
        for _ in 0..<400 { _ = f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast) }
        let facing = f.ingest(headYawDeg: 70, travelBearingDeg: 90, p: fast)
        XCTAssertEqual(facing ?? -1, 130, accuracy: 2.0)
    }

    /// 体ごと曲がった場合(yaw も進行方位も同じだけ回る)は、相対角は 0 のまま。
    /// 角を曲がっただけで音が横へ飛ばないことの確認
    func testTurningTheWholeBodyDoesNotChangeOffset() {
        var f = HeadingFusion()
        for _ in 0..<400 { _ = f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast) }
        let facing = f.ingest(headYawDeg: 120, travelBearingDeg: 180, p: fast)
        XCTAssertEqual(facing ?? -1, 180, accuracy: 2.0)
    }

    /// ±180° を跨いでも基準線が壊れない(単位ベクトルで平均しているため)
    func testBaselineSurvivesWrapAround() {
        var f = HeadingFusion()
        // yaw − travel が 179° と −179° を行き来する状況
        for i in 0..<400 {
            _ = f.ingest(headYawDeg: i.isMultiple(of: 2) ? 179 : -179,
                         travelBearingDeg: 0, p: fast)
        }
        let baseline = f.baselineDeg ?? 0
        XCTAssertEqual(abs(baseline), 180, accuracy: 3.0)
    }

    /// 上限を超える差は丸める(基準が狂ったまま真後ろを指し続けないため)
    func testOffsetIsClampedToMaximum() {
        var f = HeadingFusion()
        for _ in 0..<400 { _ = f.ingest(headYawDeg: 0, travelBearingDeg: 0, p: fast) }
        let facing = f.ingest(headYawDeg: 170, travelBearingDeg: 0, p: fast)
        XCTAssertEqual(facing ?? -1, 90, accuracy: 2.0)
    }

    /// 首を振り続けても基準線がそちらへ流れる(それ以上区別できないため)。
    /// 時定数の遅さで、瞬間的な首振りとは区別される
    func testBaselineSlowlyFollowsSustainedTurn() {
        var f = HeadingFusion()
        for _ in 0..<400 { _ = f.ingest(headYawDeg: 0, travelBearingDeg: 0, p: fast) }
        var facing: Double?
        for _ in 0..<400 { facing = f.ingest(headYawDeg: 60, travelBearingDeg: 0, p: fast) }
        XCTAssertEqual(facing ?? -1, 0, accuracy: 3.0)
    }

    /// 実機の設定(alpha 0.0005)では、1 秒の首振りは基準線にほとんど吸収されない
    func testRealParamsDoNotAbsorbAShortTurn() {
        var f = HeadingFusion()
        for _ in 0..<300 { _ = f.ingest(headYawDeg: 0, travelBearingDeg: 0, p: p) }
        var facing: Double?
        for _ in 0..<50 { facing = f.ingest(headYawDeg: 45, travelBearingDeg: 0, p: p) }
        XCTAssertEqual(facing ?? -1, 45, accuracy: 2.0)
    }

    /// reset 後は基準線を作り直す
    func testResetClearsBaseline() {
        var f = HeadingFusion()
        for _ in 0..<400 { _ = f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast) }
        XCTAssertTrue(f.isReady)
        f.reset()
        XCTAssertFalse(f.isReady)
        XCTAssertNil(f.baselineDeg)
        XCTAssertNil(f.ingest(headYawDeg: 30, travelBearingDeg: 90, p: fast))
    }
}
