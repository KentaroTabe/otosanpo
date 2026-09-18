import XCTest
@testable import OtoSanpo

/// 位置から決まる向きの揺れを落とす保持(→ `BearingHold`・docs/08)。
///
/// ## なぜ要るか(2026-09-18)
///
/// 利用者の報告「スポットが小刻みに移動している」。スポットの中心は動いていないので、
/// 原因は自分の位置の推定の揺れ。実測では 0〜5 m で平均 19.4°・最大 82° 動き、
/// 20 m より遠いと 1° 以下だった(約 1 秒間隔の行の差)。
///
/// **段差を作らずに揺れだけ消す**必要がある(以前「離散的」と言われた現象を作り直さない)。
/// 遊び(不感帯)だけでは入力が飛んだ時に出力も飛ぶので、短い時定数の追従と 2 段で作る。
final class BearingHoldTests: XCTestCase {

    private func params(min: Double = 2, max: Double = 10,
                        tau: Double = 0.25) -> BearingHold.Params {
        BearingHold.Params(minDeadbandDeg: min, maxDeadbandDeg: max, timeConstantSec: tau)
    }

    /// 十分な時間を進めて、目標に落ち着いた出力を取る
    private func settled(_ h: inout BearingHold, p: BearingHold.Params) -> Double {
        for _ in 0..<40 { h.output(after: 0.1, p: p) }
        return h.deg ?? .nan
    }

    // MARK: - 遊び(不感帯)

    /// 最初の 1 つはそのまま通る(比べる相手がない)。追従も待たない
    func testFirstSampleIsAdoptedAsIs() {
        var h = BearingHold()
        XCTAssertNil(h.deg)
        h.ingest(210, p: params())
        XCTAssertEqual(h.deg ?? .nan, 210, accuracy: 1e-9)
        XCTAssertEqual(h.target ?? .nan, 210, accuracy: 1e-9)
    }

    /// **不感帯の中の往復は完全に消える。** 何度揺らしても目標は動かない
    func testJitterInsideTheBandIsRejectedCompletely() {
        var h = BearingHold()
        let p = params(min: 5)
        h.ingest(200, p: p)
        for d in [202.0, 198.0, 203.0, 197.0, 201.0, 204.0, 196.0] {
            h.ingest(d, p: p)
            XCTAssertEqual(h.target ?? .nan, 200, accuracy: 1e-9,
                           "±5° の中で揺れている間は目標が動かないこと")
        }
        XCTAssertEqual(settled(&h, p: p), 200, accuracy: 1e-9)
    }

    /// 境界ちょうどは保持側(→ 合議 J2)
    func testExactlyAtTheBandKeepsTheTarget() {
        var h = BearingHold()
        let p = params(min: 5)
        h.ingest(0, p: p)
        h.ingest(5, p: p)
        XCTAssertEqual(h.target ?? .nan, 0, accuracy: 1e-9)
    }

    /// **段差を作らない。** 閾値を超えた時、超えたぶんだけ目標が動く(→ 合議 J3)
    func testTargetMovesOnlyByTheExcess() {
        var h = BearingHold()
        let p = params(min: 5)
        h.ingest(0, p: p)
        h.ingest(4, p: p)
        XCTAssertEqual(h.target ?? .nan, 0, accuracy: 1e-9)
        h.ingest(8, p: p)
        XCTAssertEqual(h.target ?? .nan, 3, accuracy: 1e-9)
    }

    /// 北をまたいでも円で扱う(→ 合議 J4)
    func testWrapsAroundNorth() {
        var h = BearingHold()
        let p = params(min: 5)
        h.ingest(359, p: p)
        h.ingest(1, p: p)
        XCTAssertEqual(h.target ?? .nan, 359, accuracy: 1e-9, "差は 2° なので動かない")
        h.ingest(10, p: p)
        XCTAssertEqual(h.target ?? .nan, 5, accuracy: 1e-9, "11° 動いたので 6° ぶん進む")
    }

    /// **同じ位置を何度取り込んでも、遊びは 1 回ぶんしか進まない**(→ 合議 J11)。
    /// 音は 50 Hz で付け直すので、ここが効かないと遊びが無意味になる
    func testRepeatingTheSameMeasurementDoesNotAdvanceTheTarget() {
        var h = BearingHold()
        let p = params(min: 5)
        h.ingest(0, p: p)
        for _ in 0..<50 { h.ingest(20, p: p) }
        XCTAssertEqual(h.target ?? .nan, 15, accuracy: 1e-9,
                       "20° の測定を 50 回入れても、目標は 15°(= 20 − 5)で止まる")
    }

    /// **不感帯は位置の不確かさから決まる。** 近いほど広く、遠いほど狭い
    func testDeadbandComesFromThePositionUncertainty() {
        XCTAssertEqual(BearingHold.uncertaintyDeg(accuracyM: 3, distanceM: 5), 30.96,
                       accuracy: 0.05)
        XCTAssertEqual(BearingHold.uncertaintyDeg(accuracyM: 3, distanceM: 20), 8.53,
                       accuracy: 0.05)
        XCTAssertEqual(BearingHold.uncertaintyDeg(accuracyM: 3, distanceM: 0.0001), 90,
                       accuracy: 0.1)
    }

    /// 下限と上限で挟む。**近距離で凍結させない**ための上限が効くこと
    func testDeadbandIsClamped() {
        let p = params(min: 2, max: 10)
        XCTAssertEqual(BearingHold.deadbandDeg(uncertaintyDeg: 0, p: p), 2, accuracy: 1e-9)
        XCTAssertEqual(BearingHold.deadbandDeg(uncertaintyDeg: 6, p: p), 6, accuracy: 1e-9)
        XCTAssertEqual(BearingHold.deadbandDeg(uncertaintyDeg: 70, p: p), 10, accuracy: 1e-9)
    }

    // MARK: - 追従

    /// **目標が動いた瞬間に出力は飛ばない**(→ 合議 J5)
    func testOutputDoesNotJumpWhenTheTargetMoves() {
        var h = BearingHold()
        let p = params(min: 5, tau: 0.25)
        h.ingest(0, p: p)
        h.ingest(90, p: p)
        XCTAssertEqual(h.target ?? .nan, 85, accuracy: 1e-9)
        let step = h.output(after: 0.02, p: p) ?? .nan
        XCTAssertGreaterThan(step, 0)
        XCTAssertLessThan(step, 20, "1 コマで目標へ飛ばないこと")
        XCTAssertEqual(settled(&h, p: p), 85, accuracy: 0.01, "時間が経てば目標に着く")
    }

    /// **同じ経過時間なら、更新の回数によらず同じ出力になる**(→ 合議 J6)
    func testOutputDependsOnElapsedTimeNotOnUpdateCount() {
        let p = params(min: 5, tau: 0.25)
        var sparse = BearingHold(), dense = BearingHold()
        sparse.ingest(0, p: p); dense.ingest(0, p: p)
        sparse.ingest(100, p: p); dense.ingest(100, p: p)
        for _ in 0..<5 { sparse.output(after: 0.1, p: p) }      // 0.5 秒を 5 回で
        for _ in 0..<50 { dense.output(after: 0.01, p: p) }     // 0.5 秒を 50 回で
        XCTAssertEqual(sparse.deg ?? .nan, dense.deg ?? .nan, accuracy: 0.6,
                       "刻み方で追従の速さが変わらないこと")
    }

    /// **通り過ぎる場面に間に合う。** 180° 変わって 1.5 秒後には 11° 以内(→ 合議 J8)
    func testCatchesUpFastEnoughToFollowAPass() {
        var h = BearingHold()
        let p = params(min: 2, max: 10, tau: 0.25)
        h.ingest(0, p: p)
        h.ingest(180, p: p)
        for _ in 0..<15 { h.output(after: 0.1, p: p) }
        let err = abs(Geo.angularDiffDeg(h.deg ?? .nan, 180))
        XCTAssertLessThanOrEqual(err, 11, "1.5 秒で 11° 以内へ寄ること(実測 \(err)°)")
    }

    /// 最短の回転方向へ寄る(北をまたいで遠回りしない)
    func testFollowsTheShortWayAround() {
        var h = BearingHold()
        let p = params(min: 2, tau: 0.25)
        h.ingest(350, p: p)
        h.ingest(30, p: p)
        let first = h.output(after: 0.05, p: p) ?? .nan
        XCTAssertTrue(first > 350 || first < 30, "350° → 30° は +側から寄ること(得た値 \(first))")
        XCTAssertEqual(settled(&h, p: p), 28, accuracy: 0.05)
    }

    // MARK: - 壊れた入力・作り直し

    /// 壊れた入力で状態を壊さない(→ 合議 J11)
    func testNonFiniteInputIsIgnored() {
        var h = BearingHold()
        let p = params()
        h.ingest(200, p: p)
        h.ingest(.nan, p: p)
        h.ingest(.infinity, p: p)
        XCTAssertEqual(h.target ?? .nan, 200, accuracy: 1e-9)
    }

    /// 取り込む前に出力を求めても落ちない
    func testOutputBeforeAnyMeasurementIsNil() {
        var h = BearingHold()
        XCTAssertNil(h.output(after: 0.1, p: params()))
    }

    /// 置き直したら捨てる(→ 合議 J12)
    func testResetForgetsEverything() {
        var h = BearingHold()
        let p = params()
        h.ingest(200, p: p)
        h.reset()
        XCTAssertNil(h.deg)
        XCTAssertNil(h.target)
        h.ingest(20, p: p)
        XCTAssertEqual(h.deg ?? .nan, 20, accuracy: 1e-9)
    }

    /// 時定数 0 なら追従は止まる(設定で切れる)。目標は動き続ける
    func testZeroTimeConstantHoldsTheOutput() {
        var h = BearingHold()
        let p = params(min: 5, tau: 0)
        h.ingest(0, p: p)
        h.ingest(90, p: p)
        XCTAssertEqual(h.output(after: 1, p: p) ?? .nan, 0, accuracy: 1e-9)
    }
}
