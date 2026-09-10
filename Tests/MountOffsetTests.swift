import XCTest
@testable import OtoSanpo

/// 取り付けのずれの学習(→ MountOffset・docs/13)。
///
/// なぜ要るか(2026-09-01): 固定値 `offset_deg` の決め忘れで、頭部固定の散歩が
/// 丸ごと検証なしになった(検疫が 84% 退避)。ずれは course との差の定常成分として
/// その散歩のログから正確に推定できた(+94°・残差の中央値 9.2°)ので、
/// 同じ計算を歩きながらその場で行う。
///
/// ## 2026-09-10 に要求が変わった(旧テストを置き換えた理由)
///
/// 旧版は「`ingest` が呼ばれた回数」で証拠を数え、`gateReopenSec` で学習を白紙に戻していた。
/// 実測(`field-log-20260910-143041-3.tsv`)で 2 つの欠陥が出た:
///
/// - 頭方位は 50 Hz、GPS の fix は約 1 Hz。**同じ fix が 50 回、独立した証拠として
///   数えられていた**。`max_fix_age_sec` が 10 秒なので、古い fix 1 個で学習条件の半分を作れる
/// - 長い首振りで門が閉じ続けると「付け直し」と誤認して学習が白紙に戻り、
///   1 回の散歩で 2 回起きた(そのたびに検疫の実績も捨てられる)
///
/// そこで要求を変えた: **証拠は「fix の間の経過時間」で数え、
/// 一度成立した値は散歩の終わりまで固定する。** 期待値だけを書き換えたのではなく、
/// 数える対象そのものが変わっている。
final class MountOffsetTests: XCTestCase {

    /// 証拠 20 秒・門なし。fix は 1 秒間隔なので 21 個で成立する。
    ///
    /// **半減期を実質無限にしてある。** 証拠の数え方を検査する回で減衰が混ざると、
    /// 「4 秒のはずが 3.986 秒」のようなずれが出て、何を測っているのか分からなくなる。
    /// 減衰そのものは `testEvidenceDecaysWithTheHalfLife` で別に見る
    private let p = MountOffset.Params(minEvidenceSec: 20, halfLifeSec: .infinity,
                                       minConcentration: 0.8, maxGapSec: 5)

    /// 門つきの設定
    private func gated(_ gateDeg: Double) -> MountOffset.Params {
        MountOffset.Params(minEvidenceSec: 20, halfLifeSec: .infinity, minConcentration: 0.8,
                           gateDeg: gateDeg, maxGapSec: 5)
    }

    /// course に対して一定のずれを持つ標本を、**1 秒ごとの新しい fix** で流す。
    /// - Parameter perFix: 1 つの fix につき何回 `ingest` を呼ぶか(更新頻度の模擬)
    private func feed(_ m: inout MountOffset, p gp: MountOffset.Params,
                      offsetDeg: Double, noiseDeg: [Double] = [0],
                      from t0: Double, fixes: Int, courseDeg: Double = 30,
                      perFix: Int = 1) {
        for i in 0..<fixes {
            let noise = noiseDeg[i % noiseDeg.count]
            let heading = Geo.normalizeDeg(courseDeg + offsetDeg + noise)
            for _ in 0..<perFix {
                m.ingest(headingDeg: heading, courseDeg: courseDeg,
                         fixTime: t0 + Double(i), p: gp)
            }
        }
    }

    /// **最初の失敗そのもの**: +94° のずれを、雑音(±15°)ごしに学習できる
    func testLearnsTheMountOffsetFromNoisySamples() {
        var m = MountOffset()
        feed(&m, p: p, offsetDeg: 94, noiseDeg: [0, 12, -15, 8, -6], from: 0, fixes: 40)
        let learned = try! XCTUnwrap(m.offsetDeg)
        XCTAssertEqual(learned, 94, accuracy: 3)
        XCTAssertGreaterThan(m.concentration, 0.9)
    }

    /// 証拠時間が足りないうちは学習を成立させない
    func testDoesNotLearnBeforeEnoughEvidence() {
        var m = MountOffset()
        // 最初の fix は「区間の始点」にしかならないので、20 秒ぶんには 21 個要る
        feed(&m, p: p, offsetDeg: 94, from: 0, fixes: 15)
        XCTAssertNil(m.offsetDeg, "証拠 14 秒では早い(min 20 秒)")
        XCTAssertEqual(m.evidence, 14, accuracy: 0.01)
    }

    /// 証拠は半減期で薄れる。**古い区間の実績が永久に残らない**
    func testEvidenceDecaysWithTheHalfLife() {
        let decaying = MountOffset.Params(minEvidenceSec: 20, halfLifeSec: 10,
                                          minConcentration: 0.8, maxGapSec: 5)
        var m = MountOffset()
        feed(&m, p: decaying, offsetDeg: 94, from: 0, fixes: 6)   // 5 区間ぶん積む
        // 積みながら薄れるので生の 5 秒より小さい。**そこが減衰の効いている証拠**
        let fresh = m.evidence
        XCTAssertLessThan(fresh, 5)
        XCTAssertGreaterThan(fresh, 4)
        // 5 秒あけて 1 個。半減期 10 秒なので、それまでの証拠は約 0.71 倍になる
        m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 10, p: decaying)
        XCTAssertEqual(m.evidence, fresh * pow(0.5, 0.5) + 5, accuracy: 0.01)
    }

    /// 差が散らばっていれば(ポケットの中など)学習しない
    func testDoesNotLearnWhenDiffIsScattered() {
        var m = MountOffset()
        feed(&m, p: p, offsetDeg: 0, noiseDeg: [0, 90, 180, 270], from: 0, fixes: 40)
        XCTAssertNil(m.offsetDeg, "散らばった差から補正を作ってはいけない")
        XCTAssertLessThan(m.concentration, 0.5)
    }

    /// fix がまだ無い間は何も進まない
    func testIgnoresSamplesWithoutAnyFix() {
        var m = MountOffset()
        for i in 0..<100 {
            let s = m.ingest(headingDeg: Double(i) * 3.6, courseDeg: 30, fixTime: nil, p: p)
            XCTAssertEqual(s.kind, .noFix, "fix の時刻の無い course は証拠にしない")
        }
        XCTAssertEqual(m.evidence, 0)
        XCTAssertNil(m.offsetDeg)
    }

    // MARK: - 2026-09-10 に加えた要求

    /// **同じ fix を何度読んでも証拠は増えない**(受け入れ条件 B2)。
    /// 50 Hz で回していても、1 Hz の fix は 1 Hz ぶんの証拠しか持たない
    func testSameFixCountsOnce() {
        var m = MountOffset()
        // fix は 1 個だけ。それを 10 秒間 50 Hz で読み直す
        for _ in 0..<500 {
            m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 1000, p: p)
        }
        XCTAssertEqual(m.evidence, 0, "同じ fix の読み直しは証拠にならない")
        XCTAssertNil(m.offsetDeg, "fix 1 個で 20 秒ぶんの学習が成立してはいけない")
    }

    /// 最初の有効な fix は**区間の始点**になるだけ。証拠は持たない
    func testTheFirstValidFixOnlyStartsTheInterval() {
        var m = MountOffset()
        let first = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 0, p: p)
        XCTAssertEqual(first.kind, .firstFix)
        XCTAssertEqual(first.evidenceSec, 0)
        XCTAssertEqual(first.label, "始点", "「同fix」と記録しない(ログで重複と見分けがつかなくなる)")
        let second = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 1, p: p)
        XCTAssertEqual(second.kind, .learning)
        XCTAssertEqual(second.evidenceSec, 1, accuracy: 1e-9)
    }

    /// **course の無い fix を挟んだ区間は証拠にしない**(受け入れ条件 D6・2026-09-10 の検証で指摘)。
    ///
    /// 有効 t=0 → course 無効の新しい fix t=1 → 有効 t=2。
    /// 最後の証拠は **1 秒**(t=1〜2)であって、2 秒(t=0〜2)ではない。
    /// 無効な fix の時刻を捨てていた版では 2 秒になり、学習・退避・復帰が早まっていた
    func testNoCourseFixIsNotCountedAsEvidence() {
        var m = MountOffset()
        m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 0, p: p)
        let gap = m.ingest(headingDeg: 124, courseDeg: nil, fixTime: 1, p: p)
        XCTAssertEqual(gap.kind, .noCourse)
        XCTAssertEqual(gap.evidenceSec, 0)
        let last = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 2, p: p)
        XCTAssertEqual(last.evidenceSec, 1.0, accuracy: 1e-9,
                       "course の無かった t=0〜1 を証拠に入れてはいけない")
        XCTAssertEqual(m.evidence, 1.0, accuracy: 1e-9)
    }

    /// **更新頻度を変えても結果が同じ**(受け入れ条件 B4)。
    /// 同じ fix 列に対して 10 Hz と 50 Hz で流し、学習値・R・証拠を比べる
    func testResultIsIndependentOfUpdateRate() {
        let decaying = MountOffset.Params(minEvidenceSec: 20, halfLifeSec: 30,
                                          minConcentration: 0.8, maxGapSec: 5)
        var slow = MountOffset()
        var fast = MountOffset()
        feed(&slow, p: decaying, offsetDeg: 94, noiseDeg: [0, 12, -15, 8, -6],
             from: 0, fixes: 40, perFix: 10)
        feed(&fast, p: decaying, offsetDeg: 94, noiseDeg: [0, 12, -15, 8, -6],
             from: 0, fixes: 40, perFix: 50)
        XCTAssertEqual(try! XCTUnwrap(slow.offsetDeg), try! XCTUnwrap(fast.offsetDeg),
                       accuracy: 1e-9, "10 Hz と 50 Hz で学習値が変わってはいけない")
        XCTAssertEqual(slow.concentration, fast.concentration, accuracy: 1e-9)
        XCTAssertEqual(slow.evidence, fast.evidence, accuracy: 1e-9)
    }

    /// course が長く途切れた後の fix は証拠に足さない(受け入れ条件 B3)。
    /// 立ち止まりや受信の途切れを「その間ずっと合っていた」と数えない
    func testLongGapIsNotCountedAsEvidence() {
        var m = MountOffset()
        // 1 秒間隔の fix を 5 個 → 4 秒ぶん
        for i in 0..<5 {
            m.ingest(headingDeg: 124, courseDeg: 30, fixTime: Double(i), p: p)
        }
        XCTAssertEqual(m.evidence, 4, accuracy: 0.01)
        // 60 秒あけた次の fix。上限 5 秒を超えるので加算しない
        let far = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 64, p: p)
        XCTAssertEqual(far.kind, .gapTooLong)
        XCTAssertEqual(m.evidence, 4, accuracy: 0.01, "60 秒の空白を証拠にしてはいけない")
        // その次は 1 秒後なので普通に積む
        m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 65, p: p)
        XCTAssertEqual(m.evidence, 5, accuracy: 0.01)
    }

    /// 立ち止まって course の無い fix が続いた後も、上限を超えていれば証拠にしない。
    /// **上限を超えた時点で、course の無い fix のうちに知らせる**(D6。有効な course の
    /// 復帰を待つと、長い停止の間ずっと古い証拠が検疫の窓に残る — 2 回目の検証で指摘)
    func testLongRunOfNoCourseFixesIsAGap() {
        var m = MountOffset()
        for i in 0..<5 {
            m.ingest(headingDeg: 124, courseDeg: 30, fixTime: Double(i), p: p)
        }
        // 立ち止まる: fix は 1 秒ごとに来るが course が無い(10 秒)
        var kinds: [MountOffset.Sample.Kind] = []
        for i in 5..<15 {
            kinds.append(m.ingest(headingDeg: 124, courseDeg: nil, fixTime: Double(i), p: p).kind)
        }
        XCTAssertTrue(kinds[0..<5].allSatisfy { $0 == .noCourse },
                      "最後の有効 course(t=4)から 5 秒以内は区間の始点を進めるだけ")
        XCTAssertEqual(kinds[5], .gapTooLong,
                       "t=10 で途切れが 6 秒(上限 5 秒)。この時点で知らせる")
        let resumed = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 15, p: p)
        XCTAssertEqual(resumed.kind, .gapTooLong,
                       "course が 11 秒途切れた(上限 5 秒)。fix が来続けていても証拠にしない")
        XCTAssertEqual(m.evidence, 4, accuracy: 0.01)
    }

    /// **成立した値は散歩の終わりまで固定**(受け入れ条件 C1/C2)。
    /// 長い首振り(門の外の標本)が続いても、値も R も学習済み状態も変わらない
    func testFrozenAfterLearning() {
        let gp = gated(45)
        var m = MountOffset()
        feed(&m, p: gp, offsetDeg: 94, from: 0, fixes: 40)
        let learned = try! XCTUnwrap(m.offsetDeg)
        let r = m.concentration
        XCTAssertEqual(learned, 94, accuracy: 1)
        // 90° 横を向いたまま 60 秒歩く(旧版は gate_reopen で白紙に戻していた)
        feed(&m, p: gp, offsetDeg: 94 + 90, from: 40, fixes: 60)
        XCTAssertEqual(try! XCTUnwrap(m.offsetDeg), learned, accuracy: 1e-9,
                       "首を回しただけで学習が動いてはいけない")
        XCTAssertEqual(m.concentration, r, accuracy: 1e-9)
    }

    /// 学習中の標本は `.learning`、成立後は**門の内外を分類して返す**(受け入れ条件 D3)。
    /// 検疫はこの結果を数えるので、差の計算は 1 か所にしかない
    func testClassifiesInsideAndOutsideAfterLearning() {
        let gp = gated(45)
        var m = MountOffset()
        feed(&m, p: gp, offsetDeg: 94, from: 0, fixes: 40)
        XCTAssertNotNil(m.offsetDeg)
        // 学習値どおりの標本 → 門内(fix は 1 秒刻みで続ける)
        let inside = m.ingest(headingDeg: Geo.normalizeDeg(30 + 94), courseDeg: 30,
                              fixTime: 40, p: gp)
        XCTAssertEqual(inside.kind, .inside)
        XCTAssertEqual(inside.evidenceSec, 1, accuracy: 0.01)
        // 90° 外れた標本 → 門外
        let outside = m.ingest(headingDeg: Geo.normalizeDeg(30 + 94 + 90), courseDeg: 30,
                               fixTime: 41, p: gp)
        XCTAssertEqual(outside.kind, .outside)
        XCTAssertEqual(outside.evidenceSec, 1, accuracy: 0.01)
        // 同じ fix の読み直し → 証拠なし
        let dup = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 41, p: gp)
        XCTAssertEqual(dup.kind, .duplicateFix)
        XCTAssertEqual(dup.evidenceSec, 0)
        // 間隔超過 → 証拠なし
        let far = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 200, p: gp)
        XCTAssertEqual(far.kind, .gapTooLong)
        XCTAssertEqual(far.evidenceSec, 0)
    }

    /// **学習を成立させた標本も `.learning`**(固定値に対する分類ではない)。
    /// これを `.inside` として返していた版では、成立直後の検疫の窓が白紙にならなかった
    func testTheSampleThatCompletesLearningIsLearning() {
        let short = MountOffset.Params(minEvidenceSec: 2, halfLifeSec: .infinity,
                                       minConcentration: 0.8, gateDeg: 45, maxGapSec: 5)
        var m = MountOffset()
        m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 0, p: short)
        m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 1, p: short)
        XCTAssertNil(m.offsetDeg)
        let completing = m.ingest(headingDeg: 124, courseDeg: 30, fixTime: 2, p: short)
        XCTAssertNotNil(m.offsetDeg, "前提: この標本で成立する")
        XCTAssertEqual(completing.kind, .learning)
    }

    /// **門は学習中には効かない**(2026-09-10 に要求が変わった箇所)。
    ///
    /// 旧版は「証拠が貯まったら推定から離れた標本を捨てる」を学習中にも掛けていた。
    /// 量だけを条件にしていて質(R)を見ていなかったため、差が散らばっている間の
    /// **無意味な円平均を中心に門が閉じ、通った側だけで R が 1 に近づいた**。
    /// このテストを書いたときに実際に 270° を学習した。学習値を凍結する以上、
    /// この誤りは取り返しがつかない
    func testGateDoesNotFabricateAnEstimateFromScatteredSamples() {
        let gp = gated(45)
        var m = MountOffset()
        // 差が 270° と 90° を往復する(= 意味のあるずれが無い)
        for i in 0..<200 {
            let heading = Geo.normalizeDeg(30 + (i % 2 == 0 ? 270 : 90))
            m.ingest(headingDeg: heading, courseDeg: 30, fixTime: Double(i), p: gp)
        }
        XCTAssertNil(m.offsetDeg,
                     "散らばった差から学習値を作ってはいけない(門が片側だけ通すと作れてしまう)")
        XCTAssertLessThan(m.concentration, 0.5, "R が自作自演で上がっていないこと")
    }

    /// 折り返し(350° と 10°)を跨いだ円平均が正しい
    func testCircularMeanAcrossWraparound() {
        var m = MountOffset()
        feed(&m, p: p, offsetDeg: 0, noiseDeg: [-10, 10], from: 0, fixes: 40, courseDeg: 0)
        // 0° と 360° は同じ角度。**素の引き算で比べない**
        XCTAssertEqual(abs(Geo.angularDiffDeg(try! XCTUnwrap(m.offsetDeg), 0)), 0, accuracy: 1,
                       "±10° の平均は 0° であって 180° ではない")
    }
}
