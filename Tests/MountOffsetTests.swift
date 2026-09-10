import XCTest
@testable import OtoSanpo

/// 取り付けのずれの学習(→ MountOffset・docs/13)。
///
/// なぜ要るか(2026-09-01): 固定値 `offset_deg` の決め忘れで、頭部固定の散歩が
/// 丸ごと検証なしになった(検疫が 84% 退避)。ずれは course との差の定常成分として
/// その散歩のログから正確に推定できた(+94°・残差の中央値 9.2°)ので、
/// 同じ計算を歩きながらその場で行う。
final class MountOffsetTests: XCTestCase {

    private let p = MountOffset.Params(minWeight: 200, halfLifeSec: 300, minConcentration: 0.8)

    /// course に対して一定のずれを持つ標本を 10 Hz で流す
    private func feed(_ m: inout MountOffset, offsetDeg: Double, noiseDeg: [Double],
                      from t0: Double, count: Int, courseDeg: Double = 30) -> Double {
        var t = t0
        for i in 0..<count {
            let noise = noiseDeg[i % noiseDeg.count]
            m.ingest(headingDeg: Geo.normalizeDeg(courseDeg + offsetDeg + noise),
                     courseDeg: courseDeg, at: t, p: p)
            t += 0.1
        }
        return t
    }

    /// **今回の失敗そのもの**: +94° のずれを、雑音(±15°)ごしに学習できる
    func testLearnsTheMountOffsetFromNoisySamples() {
        var m = MountOffset()
        _ = feed(&m, offsetDeg: 94, noiseDeg: [0, 12, -15, 8, -6], from: 0, count: 300)
        let learned = try! XCTUnwrap(m.offsetDeg(p: p))
        XCTAssertEqual(learned, 94, accuracy: 3)
    }

    /// 量が足りないうちは出さない(歩き出し直後に生煮えの補正を使わない)
    func testNotReadyBeforeMinWeight() {
        var m = MountOffset()
        _ = feed(&m, offsetDeg: 94, noiseDeg: [0], from: 0, count: 150)
        XCTAssertNil(m.offsetDeg(p: p), "実効 150 標本では早い(min 200)")
    }

    /// **散らばる差からは学習しない。** ポケットの中(向きが揺れ続ける)や
    /// 磁気の乱れの中では R が立たず、補正は出ない = 頭部基準は使われない
    func testScatteredDiffsNeverQualify() {
        var m = MountOffset()
        // 差が全方位に散る(一様円周)= 定常成分なし
        let scattered = stride(from: -180.0, to: 180.0, by: 24.0).map { $0 }
        _ = feed(&m, offsetDeg: 0, noiseDeg: scattered, from: 0, count: 600)
        XCTAssertNil(m.offsetDeg(p: p), "散らばった差から補正を作ってはいけない")
        XCTAssertLessThan(m.concentration, 0.3)
    }

    /// ±180° の折り返しをまたぐずれも正しく平均できる(素朴な算術平均では 0 に潰れる)
    func testWraparoundOffset() {
        var m = MountOffset()
        _ = feed(&m, offsetDeg: 178, noiseDeg: [0, 6, -6], from: 0, count: 300)
        let learned = try! XCTUnwrap(m.offsetDeg(p: p))
        // 178 ± 6 の平均。normalizeDeg は 0..360 なので 178 近辺で返る
        XCTAssertEqual(learned, 178, accuracy: 3)
    }

    /// course が無い標本は平均を汚さない(立ち止まり・ホールド切れの間)
    func testNilCourseIsIgnored() {
        var m = MountOffset()
        let t = feed(&m, offsetDeg: 94, noiseDeg: [0], from: 0, count: 250)
        var t2 = t
        for _ in 0..<500 {
            m.ingest(headingDeg: 300, courseDeg: nil, at: t2, p: p)
            t2 += 0.1
        }
        XCTAssertEqual(try! XCTUnwrap(m.offsetDeg(p: p)), 94, accuracy: 3)
    }

    /// 半減期でゆっくり追従する(付け直しで 94° → 60° に変わったら、いずれ移る)
    func testAdaptsSlowlyToRemount() {
        var m = MountOffset()
        let t = feed(&m, offsetDeg: 94, noiseDeg: [0], from: 0, count: 300)
        // 半減期(300 秒)を大きく超える量の新しいずれを流す
        _ = feed(&m, offsetDeg: 60, noiseDeg: [0], from: t + 600, count: 3000)
        let learned = try! XCTUnwrap(m.offsetDeg(p: p))
        XCTAssertEqual(learned, 60, accuracy: 5, "新しい取り付きへ追従していない")
    }

    // MARK: - 門(2026-09-09)

    /// 門つきの設定。`gateReopenSec` は付け直しから戻るための逃げ道
    private func gated(gateDeg: Double, reopenSec: Double) -> MountOffset.Params {
        MountOffset.Params(minWeight: 200, halfLifeSec: 300, minConcentration: 0.8,
                           gateDeg: gateDeg, gateReopenSec: reopenSec)
    }

    private func feed(_ m: inout MountOffset, p gp: MountOffset.Params,
                      offsetDeg: Double, from t0: Double, count: Int,
                      courseDeg: Double = 30) -> Double {
        var t = t0
        for _ in 0..<count {
            m.ingest(headingDeg: Geo.normalizeDeg(courseDeg + offsetDeg),
                     courseDeg: courseDeg, at: t, p: gp)
            t += 0.1
        }
        return t
    }

    /// **首を回している間の標本で推定を汚さない。**
    ///
    /// 門が無いと、R(差の一定さ)が落ちて学習が外れる。すると頭方位が信用されず、
    /// 「音が追従するか確かめようと首を回すほど追従しなくなる」循環になる
    /// (2026-09-09 の実測: 採用 7%・R 0.77)
    func testGateKeepsTheEstimateWhileTheHeadTurns() {
        let gp = gated(gateDeg: 45, reopenSec: 20)
        var m = MountOffset()
        var t = feed(&m, p: gp, offsetDeg: 94, from: 0, count: 300)
        let before = try! XCTUnwrap(m.offsetDeg(p: gp))
        let rBefore = m.concentration

        // 首を 90° 回した状態の標本を混ぜる(ずれではなく首の向き)
        t = feed(&m, p: gp, offsetDeg: 94 + 90, from: t, count: 100)
        XCTAssertEqual(m.offsetDeg(p: gp) ?? .nan, before, accuracy: 1,
                       "首の向きの標本で推定が動いてはいけない")
        XCTAssertEqual(m.concentration, rBefore, accuracy: 1e-9, "R が落ちてはいけない")
    }

    /// **門だけでは付け直しから戻れない。** 閉じ続けたら学び直す
    func testGateReopensAfterASustainedMismatch() {
        let gp = gated(gateDeg: 45, reopenSec: 20)
        var m = MountOffset()
        var t = feed(&m, p: gp, offsetDeg: 94, from: 0, count: 300)
        XCTAssertEqual(m.offsetDeg(p: gp) ?? .nan, 94, accuracy: 1)

        // 付け直してずれが 90° 跳ぶ。門は閉じるが、20 秒を超えたら学び直す
        t = feed(&m, p: gp, offsetDeg: 7, from: t, count: 600)
        XCTAssertEqual(m.offsetDeg(p: gp) ?? .nan, 7, accuracy: 2,
                       "閉じ続けたら学び直して新しいずれへ移ること")
    }

    /// 学び直しを切れば、門は閉じたまま(= 2026-09-09 に踏んだ失敗そのもの)
    func testWithoutReopenTheGateNeverRecovers() {
        let gp = gated(gateDeg: 45, reopenSec: 0)
        var m = MountOffset()
        var t = feed(&m, p: gp, offsetDeg: 94, from: 0, count: 300)
        t = feed(&m, p: gp, offsetDeg: 7, from: t, count: 600)
        XCTAssertEqual(m.offsetDeg(p: gp) ?? .nan, 94, accuracy: 2,
                       "逃げ道が無いと古いずれに固執する")
    }
}
