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
}
