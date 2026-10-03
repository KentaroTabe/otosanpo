import XCTest
@testable import OtoSanpo

/// 取り付けのずれを**直近の証拠だけ**から作り直す滑り窓(→ `OffsetWindow`・docs/13)。
///
/// ## なぜこの型が要るか(2026-09-18)
///
/// `MountOffset` は成立した値を凍結する(長い首振りで学習が消える事故を 2 回踏んだ末の設計)。
/// しかし**スマホは頭の後ろに固定するので、装着は必ず「散歩を開始」の後**になり、
/// 「最初に成立した値」は構造的に装着前の値になりうる。実測で 106° 外れたまま 10 分続いた。
///
/// 減衰つきの平均では急に忘れられないため、**窓**で測る。
final class OffsetWindowTests: XCTestCase {

    private func params(evidenceSec: Double = 10,
                        minConcentration: Double = 0.8) -> OffsetWindow.Params {
        OffsetWindow.Params(evidenceSec: evidenceSec, minConcentration: minConcentration)
    }

    /// 満ちるまで値を出さない(**一時的に横を向いただけで乗り換えないため**)
    func testDoesNotEstimateBeforeTheWindowIsFull() {
        let p = params()
        var w = OffsetWindow()
        for _ in 0..<9 { w.add(diffDeg: 40, evidenceSec: 1, p: p) }
        XCTAssertFalse(w.isFull)
        XCTAssertNil(w.estimateDeg(p: p))
        XCTAssertEqual(w.evidence, 9, accuracy: 1e-9)

        w.add(diffDeg: 40, evidenceSec: 1, p: p)
        XCTAssertTrue(w.isFull)
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, 40, accuracy: 1e-9)
    }

    /// **窓の長さは超えない。** 端の 1 件は部分的に削る
    /// (丸ごと捨てると窓の長さが鋸歯状に揺れ、R と平均が更新間隔に依存する)
    func testTrimsPartiallyToKeepTheWindowLength() {
        let p = params(evidenceSec: 10)
        var w = OffsetWindow()
        for _ in 0..<4 { w.add(diffDeg: 0, evidenceSec: 3, p: p) }
        XCTAssertEqual(w.evidence, 10, accuracy: 1e-9, "12 秒入れても窓は 10 秒")
        // 古い 0° が 1 秒だけ残り、新しい 90° が 9 秒。平均は 90° 寄りになる
        for _ in 0..<3 { w.add(diffDeg: 90, evidenceSec: 3, p: p) }
        XCTAssertEqual(w.evidence, 10, accuracy: 1e-9)
        let expected = atan2(9.0, 1.0) * 180 / .pi
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, expected, accuracy: 1e-9)
    }

    /// 古い証拠は窓から出ていく。**入れ替われば新しいずれだけが残る**
    func testOldEvidenceLeavesTheWindow() {
        let p = params(evidenceSec: 10)
        var w = OffsetWindow()
        for _ in 0..<10 { w.add(diffDeg: 347, evidenceSec: 1, p: p) }
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, 347, accuracy: 1e-9)
        for _ in 0..<10 { w.add(diffDeg: 95, evidenceSec: 1, p: p) }
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, 95, accuracy: 1e-9,
                       "装着後の証拠だけで満ちたら、新しいずれそのものを出すこと")
    }

    /// **散らばっていれば値を出さない**(R の門)
    func testScatteredEvidenceGivesNoEstimate() {
        let p = params(evidenceSec: 8, minConcentration: 0.8)
        var w = OffsetWindow()
        for d in [0.0, 90.0, 180.0, 270.0, 0.0, 90.0, 180.0, 270.0] {
            w.add(diffDeg: d, evidenceSec: 1, p: p)
        }
        XCTAssertTrue(w.isFull)
        XCTAssertLessThan(w.concentration, 0.8)
        XCTAssertNil(w.estimateDeg(p: p), "R が門を越えなければ値を出さない")
    }

    /// **「変わり目をまたいだ窓は成立しない」とは言えない**(2026-09-18 の合議で指摘)。
    /// 0° と 60° が等量なら円平均 30°・R ≈ 0.866 で門を越える。
    /// この限界を固定しておく — 乗り換え後に残差が残るのはこれが理由
    func testAMixedWindowCanStillEstablish() {
        let p = params(evidenceSec: 10, minConcentration: 0.8)
        var w = OffsetWindow()
        for _ in 0..<5 { w.add(diffDeg: 0, evidenceSec: 1, p: p) }
        for _ in 0..<5 { w.add(diffDeg: 60, evidenceSec: 1, p: p) }
        XCTAssertEqual(w.concentration, cos(30 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, 30, accuracy: 1e-9,
                       "混ざった窓は 2 つのずれの中間を出す")
    }

    /// 北をまたいでも円平均になる(数直線の平均にしない)。
    /// **比べ方も円で行う** — 0° は 360° と同じ角度で、丸め次第でどちらにも出る
    func testMeanIsCircular() {
        let p = params(evidenceSec: 4)
        var w = OffsetWindow()
        for d in [350.0, 10.0, 350.0, 10.0] { w.add(diffDeg: d, evidenceSec: 1, p: p) }
        let mean = w.estimateDeg(p: p) ?? .nan
        XCTAssertEqual(abs(Geo.angularDiffDeg(mean, 0)), 0, accuracy: 1e-9)
    }

    /// 乗り換えた直後は空にする(**同じ証拠で 2 回乗り換えない**)
    func testClearEmptiesTheWindow() {
        let p = params(evidenceSec: 5)
        var w = OffsetWindow()
        for _ in 0..<5 { w.add(diffDeg: 100, evidenceSec: 1, p: p) }
        XCTAssertNotNil(w.estimateDeg(p: p))
        w.clear()
        XCTAssertEqual(w.evidence, 0)
        XCTAssertFalse(w.isFull)
        XCTAssertNil(w.estimateDeg(p: p))
        XCTAssertNil(w.meanDeg)
        XCTAssertEqual(w.concentration, 0)
    }

    /// 設定が 0 なら何も積まないし、値も出さない(見直しを止められる)
    func testZeroWindowIsDisabled() {
        let p = params(evidenceSec: 0)
        var w = OffsetWindow()
        for _ in 0..<10 { w.add(diffDeg: 100, evidenceSec: 1, p: p) }
        XCTAssertEqual(w.evidence, 0)
        XCTAssertNil(w.estimateDeg(p: p))
    }

    /// 証拠 0 の標本(course が無い・同じ fix の読み直し)は窓を動かさない
    func testSamplesWithoutEvidenceAreIgnored() {
        let p = params(evidenceSec: 5)
        var w = OffsetWindow()
        for _ in 0..<100 { w.add(diffDeg: 100, evidenceSec: 0, p: p) }
        XCTAssertEqual(w.evidence, 0)
        XCTAssertNil(w.estimateDeg(p: p))
    }

    /// 非有限の値は取り込まない(壊れた入力で窓が死なないこと)
    func testNonFiniteInputIsIgnored() {
        let p = params(evidenceSec: 5)
        var w = OffsetWindow()
        w.add(diffDeg: .nan, evidenceSec: 1, p: p)
        w.add(diffDeg: .infinity, evidenceSec: 1, p: p)
        XCTAssertEqual(w.evidence, 0)
        for _ in 0..<5 { w.add(diffDeg: 100, evidenceSec: 1, p: p) }
        XCTAssertEqual(w.estimateDeg(p: p) ?? .nan, 100, accuracy: 1e-9)
    }

    /// **刻み方に依らない。** 同じ証拠時間を細かく入れても粗く入れても同じ値になる
    func testResultDoesNotDependOnTheSampleSize() {
        let p = params(evidenceSec: 10)
        var coarse = OffsetWindow()
        for _ in 0..<5 { coarse.add(diffDeg: 95, evidenceSec: 2, p: p) }
        var fine = OffsetWindow()
        for _ in 0..<50 { fine.add(diffDeg: 95, evidenceSec: 0.2, p: p) }
        XCTAssertEqual(coarse.evidence, fine.evidence, accuracy: 1e-9)
        XCTAssertEqual(coarse.estimateDeg(p: p) ?? .nan,
                       fine.estimateDeg(p: p) ?? .nan, accuracy: 1e-9)
    }
}
