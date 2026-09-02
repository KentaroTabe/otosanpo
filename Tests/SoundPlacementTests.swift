import XCTest
@testable import OtoSanpo

final class SoundPlacementTests: XCTestCase {
    private func assertPosition(_ p: SoundPosition, x: Double, y: Double, z: Double,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(p.z, z, accuracy: 0.001, message, file: file, line: line)
    }

    /// 正面は −Z(AVAudioEnvironmentNode の聴取者は −Z を向く)
    func testAheadIsNegativeZ() {
        assertPosition(SoundPlacement.position(relativeBearingDeg: 0), x: 0, y: 0, z: -1)
    }

    func testRightIsPositiveX() {
        assertPosition(SoundPlacement.position(relativeBearingDeg: 90), x: 1, y: 0, z: 0)
    }

    func testLeftIsNegativeX() {
        assertPosition(SoundPlacement.position(relativeBearingDeg: -90), x: -1, y: 0, z: 0)
    }

    /// 3D なら真後ろが正面と区別できる。pan では両方 0 になってしまう
    func testBehindIsDistinguishableInThreeDimensionsButNotInPan() {
        assertPosition(SoundPlacement.position(relativeBearingDeg: 180), x: 0, y: 0, z: 1)
        XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: 180), 0, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: 0), 0, accuracy: 0.001)
    }

    /// 斜めは単位円上に乗る(半径が方向によって変わらない = 距離減衰が方向で揺れない)
    func testDiagonalStaysOnTheUnitCircle() {
        for deg in stride(from: 0.0, to: 360.0, by: 15.0) {
            let p = SoundPlacement.position(relativeBearingDeg: deg)
            let r = (p.x * p.x + p.z * p.z).squareRoot()
            XCTAssertEqual(r, 1.0, accuracy: 0.001, "方位 \(deg)°")
        }
    }

    /// 半径を指定すれば比例して広がる
    func testRadiusScalesTheCircle() {
        let p = SoundPlacement.position(relativeBearingDeg: 90, radiusM: 3)
        assertPosition(p, x: 3, y: 0, z: 0)
    }

    /// pan は真横で最大
    func testPanIsExtremeAtTheSides() {
        XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: 90), 1, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: -90), -1, accuracy: 0.001)
    }

    /// 360° を跨いでも同じ位置になる
    func testWrapsAroundConsistently() {
        assertPosition(SoundPlacement.position(relativeBearingDeg: 450),
                       x: 1, y: 0, z: 0, "450° は 90° と同じ")
        XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: -270),
                       SoundPlacement.pan(relativeBearingDeg: 90), accuracy: 0.001)
    }

    // MARK: - 前半球への畳み(2026-08-31・docs/03「前後からの撤退」)

    /// 前半球はそのまま(何も変えない)
    func testFoldKeepsFrontHemisphereUntouched() {
        for deg in [-90.0, -45, -1, 0, 1, 45, 90] {
            XCTAssertEqual(SoundPlacement.foldToFrontDeg(deg), deg, accuracy: 0.001, "\(deg)°")
        }
    }

    /// 後半球は耳軸を鏡にして前へ映る(左右は保つ)
    func testFoldMirrorsBackHemisphereKeepingSide() {
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(120), 60, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(-120), -60, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(174), 6, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(-174), -6, accuracy: 0.001)
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(180), 0, accuracy: 0.001)
    }

    /// **左右の情報は 1 ビットも失わない**: pan は畳む前後で同値(sin(180−x) = sin(x))
    func testFoldPreservesPanExactly() {
        for deg in stride(from: -180.0, through: 180.0, by: 7.5) {
            XCTAssertEqual(SoundPlacement.pan(relativeBearingDeg: SoundPlacement.foldToFrontDeg(deg)),
                           SoundPlacement.pan(relativeBearingDeg: deg),
                           accuracy: 0.0001, "方位 \(deg)°")
        }
    }

    /// 畳んだ後は必ず前半球に置かれる(z ≤ 0)= HRTF が後ろの色付けをしない
    func testFoldedPositionsAreAlwaysInFront() {
        for deg in stride(from: -180.0, through: 180.0, by: 5.0) {
            let p = SoundPlacement.position(relativeBearingDeg: SoundPlacement.foldToFrontDeg(deg))
            XCTAssertLessThanOrEqual(p.z, 0.001, "方位 \(deg)° が後半球に置かれています")
        }
    }

    /// 360° を跨ぐ入力でも畳みが働く
    func testFoldNormalizesWraparound() {
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(300), -60, accuracy: 0.001, "300° = −60°(前)")
        XCTAssertEqual(SoundPlacement.foldToFrontDeg(-250), 70, accuracy: 0.001, "−250° = 110° → 70°")
    }
}
