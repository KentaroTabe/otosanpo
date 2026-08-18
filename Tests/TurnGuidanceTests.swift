import XCTest
@testable import OtoSanpo

/// 曲がり角の誘導。2026-08-18 の実測で出た 3 つの欠陥
/// (間隔で距離を表す / 頂点が角の奥 / 曲がり終えると逆側へ流れる)への対処を固定する。
final class TurnGuidanceTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)
    /// 北 35 m 先の角。そこで東(90°)へ曲がる想定
    private var corner: GeoPoint { Geo.destination(from: origin, bearingDeg: 0, distanceM: 35) }
    private let branchDeg = 90.0

    private let p = TurnGuidance.Params(
        startDistanceM: 35, peakBeforeM: 10, intervalSec: 1.2,
        gainFar: 0.3, gainNear: 1.0, endDistanceM: 45, leftBehindM: 12,
        turnedWithinDeg: 25, closingTones: 3)

    private func guidance(at d: Double = 35) -> TurnGuidance {
        TurnGuidance(corner: corner, branchBearingDeg: branchDeg, distanceM: d)
    }

    /// 角までの距離 [m] の地点(角の南側、つまり手前)
    private func approach(_ d: Double) -> GeoPoint {
        Geo.destination(from: corner, bearingDeg: 180, distanceM: d)
    }

    private func play(_ g: inout TurnGuidance, at point: GeoPoint,
                      travel: Double?) -> TurnGuidance.Step? {
        if case .play(let s) = g.next(position: point, travelBearingDeg: travel, p: p) { return s }
        return nil
    }

    // MARK: - 距離は音量で、間隔は固定で

    func testIntervalIsConstantAndGainRisesTowardTheCorner() {
        var g = guidance(at: 40)
        // 起点(35 m)より遠い間は gainFar のまま
        guard let far = play(&g, at: approach(40), travel: 0) else { return XCTFail("鳴らない") }
        XCTAssertEqual(far.gain, 0.3, accuracy: 0.001, "起点より遠ければ gainFar")

        var gains: [Double] = []
        for d in stride(from: 35.0, through: 12.0, by: -1.0) {
            guard let s = play(&g, at: approach(d), travel: 0) else {
                return XCTFail("接近中に鳴り止んだ(角まで \(d)m)")
            }
            XCTAssertEqual(s.intervalSec, 1.2, "間隔は距離によらず固定")
            gains.append(s.gain)
        }
        for (a, b) in zip(gains, gains.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "近づくほど音量は上がる(下がらない)")
        }
        XCTAssertGreaterThan(gains.last!, gains.first!, "接近の間に音量は実際に上がる")
    }

    func testGainPeaksBeforeTheCornerAndHolds() {
        var g = guidance()
        // 頂点(10 m 手前)までの接近
        for d in stride(from: 35.0, through: 10.0, by: -1.0) {
            _ = play(&g, at: approach(d), travel: 0)
        }
        guard let atPeak = play(&g, at: approach(10), travel: 0) else {
            return XCTFail("頂点で鳴り止んだ")
        }
        XCTAssertEqual(atPeak.gain, 1.0, accuracy: 0.001, "10 m 手前で最大に達する")
        // さらに角へ寄っても最大のまま(頂点は角の奥ではない)
        guard let atCorner = play(&g, at: approach(2), travel: 0) else {
            return XCTFail("角の直前で鳴り止んだ")
        }
        XCTAssertEqual(atCorner.gain, 1.0, accuracy: 0.001)
    }

    // MARK: - 向きのブレンドは片道

    func testPointsAtCornerWhenFarAndAtBranchWhenNear() {
        var g = guidance()
        guard let far = play(&g, at: approach(35), travel: 0) else { return XCTFail("鳴らない") }
        XCTAssertEqual(far.targetBearingDeg, 0, accuracy: 1, "遠いうちは角そのもの(北)を指す")

        for d in stride(from: 34.0, through: 10.0, by: -1.0) {
            _ = play(&g, at: approach(d), travel: 0)
        }
        guard let near = play(&g, at: approach(9), travel: 0) else { return XCTFail("鳴らない") }
        XCTAssertEqual(near.targetBearingDeg, branchDeg, accuracy: 1, "頂点では曲がる先を指し切る")
    }

    /// 2026-08-18 の実測: 右に曲がり終えた直後、音が左へ流れた(+56° → −33°)。
    /// 距離だけで補間すると、通過後に「背後になった角」へ引き戻されるため
    func testDoesNotSwingBackToTheCornerAfterPassingIt() {
        var g = guidance()
        for d in stride(from: 35.0, through: 4.0, by: -1.0) {
            _ = play(&g, at: approach(d), travel: 0)
        }
        // 角を東へ抜けた地点(角は西 = 背後側にある)。進行方位はまだ曲がりきっていない 45°
        let past = Geo.destination(from: corner, bearingDeg: 90, distanceM: 8)
        guard let s = play(&g, at: past, travel: 45) else { return XCTFail("鳴らない") }
        XCTAssertEqual(s.targetBearingDeg, branchDeg, accuracy: 1,
                       "通過後も曲がる先を指し続ける(角へ戻さない)")
    }

    // MARK: - 終端

    func testClosingTonesFadeOutAfterTheTurnIsComplete() {
        var g = guidance()
        for d in stride(from: 35.0, through: 4.0, by: -1.0) {
            _ = play(&g, at: approach(d), travel: 0)
        }
        // 進行方位が曲がる先に揃った = 曲がり終えた
        let past = Geo.destination(from: corner, bearingDeg: 90, distanceM: 6)
        var closing: [Double] = []
        for _ in 0..<3 {
            guard let s = play(&g, at: past, travel: branchDeg) else {
                return XCTFail("終端の音が足りない")
            }
            XCTAssertTrue(s.isClosing)
            XCTAssertEqual(s.targetBearingDeg, branchDeg, accuracy: 1, "終端は正面(曲がった先)")
            closing.append(s.gain)
        }
        for (a, b) in zip(closing, closing.dropFirst()) {
            XCTAssertLessThan(b, a, "終端は 1 音ごとに小さくなる")
        }
        XCTAssertLessThan(closing[0], 1.0, "終端の 1 音目から頂点より小さい")
        XCTAssertEqual(g.next(position: past, travelBearingDeg: branchDeg, p: p),
                       .finished(.turned), "終端を鳴らし切ったら終わる")
    }

    func testDoesNotFinishAsTurnedBeforeReachingTheCorner() {
        var g = guidance()
        // 角に寄る前に、たまたま進行方位が曲がる先に一致しても終端に入らない
        guard let s = play(&g, at: approach(30), travel: branchDeg) else {
            return XCTFail("鳴らない")
        }
        XCTAssertFalse(s.isClosing)
    }

    // MARK: - 曲がらなかった場合

    /// 実測(2026-08-18)では、角に近づかないまま 33m → 43m と離れる間ずっと鳴り続けた
    func testFinishesWhenLeavingWithoutApproaching() {
        var g = guidance(at: 33)
        _ = play(&g, at: approach(33), travel: 180)
        // 最接近 33 m から 12 m 以上離れた
        XCTAssertEqual(g.next(position: approach(46), travelBearingDeg: 180, p: p),
                       .finished(.leftBehind))
    }

    func testFinishesWhenTooFarFromTheCorner() {
        var g = guidance()
        XCTAssertEqual(g.next(position: approach(50), travelBearingDeg: 0, p: p),
                       .finished(.leftBehind))
    }

    func testTracksClosestApproach() {
        var g = guidance()
        _ = play(&g, at: approach(30), travel: 0)
        _ = play(&g, at: approach(12), travel: 0)
        _ = play(&g, at: approach(20), travel: 0)
        XCTAssertEqual(g.closestM, 12, accuracy: 0.5)
    }
}
