import XCTest
@testable import OtoSanpo

/// 頭部固定スマホの方位の検疫(→ docs/13)。
/// 端末コンパスが帰路で左右を反転させた実測(docs/04・2026-08-16)があるので、
/// **「磁気を信じてよいのはいつか」を決めるこの門が、頭部固定の安全装置になる。**
///
/// ## 2026-09-10 に要求が変わった(旧テストを置き換えた理由)
///
/// 旧版は「course が取れていて、かつ差が 40° 以内が**途切れず 5 秒**続いたら採用」だった。
/// 実測(`field-log-20260910-143041-3.tsv`)でこの条件が成立しないことが分かった:
///
/// - course は間欠(この散歩で 37%)。1 標本でも欠けると窓がゼロに戻る
/// - 条件が続いた最長は **3 秒**。頭方位 389 件のうち採用は **0 件**
/// - しかも頭部固定では、頭が進行方向から 40° 外れるのは正常(店先を見る・角を覗く)
///
/// **初期の信頼は検疫が与えるのをやめた。** 取り付け補正の成立(証拠時間 + R)が与え、
/// 検疫は退避と復帰だけを担う。判定は `MountOffset` が返す門の内外の分類を、
/// **異なる fix の証拠時間で重み付けした割合**で見る。
/// 期待値を書き換えたのではなく、判定に使う量そのものが変わっている。
final class HeadingQuarantineTests: XCTestCase {

    /// 窓 40 秒・門外 75% かつ 12 秒で退避・門内 70% かつ 8 秒で復帰
    private let p = HeadingQuarantine.Params(windowSec: 40, distrustRatio: 0.75,
                                             distrustSec: 12, regainRatio: 0.7,
                                             regainSec: 8)

    private func sample(_ kind: MountOffset.Sample.Kind, _ sec: Double = 1)
        -> MountOffset.Sample {
        MountOffset.Sample(kind: kind, evidenceSec: sec)
    }

    /// 同じ分類を n 秒ぶん流す(1 秒 = 1 標本)
    private func feed(_ q: inout HeadingQuarantine,
                      _ kind: MountOffset.Sample.Kind, seconds: Int) {
        for _ in 0..<seconds { q.assess(sample(kind), p: p) }
    }

    /// **学習前は使わない。** 屋内の乱れた磁気で歩き出しても、最初の音が反転しない
    func testStartsUnusable() {
        var q = HeadingQuarantine()
        XCTAssertEqual(q.state, .unverified)
        XCTAssertFalse(q.isUsable)
        // 学習前は門内が何秒来ても採用にならない(証拠も数えない)
        feed(&q, .inside, seconds: 100)
        XCTAssertEqual(q.state, .unverified)
        XCTAssertEqual(q.evidenceSec, 0)
    }

    /// **学習が成立したら採用から始まる**(受け入れ条件 A2/D1)。
    /// 旧版はここで「course と 5 秒連続一致」を追加要求し、実測で一度も成立しなかった
    func testTrustedAsSoonAsTheOffsetIsLearned() {
        var q = HeadingQuarantine()
        q.markLearned()
        XCTAssertEqual(q.state, .trusted)
        XCTAssertTrue(q.isUsable)
        XCTAssertEqual(q.evidenceSec, 0, "成立の時点で証拠は白紙から始まる")
    }

    /// 門外が割合と証拠時間の両方を満たしたら退避
    func testDistrustWhenOutsideDominates() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .outside, seconds: 11)
        XCTAssertTrue(q.isUsable, "門外 11 秒では落とさない(distrust_sec = 12)")
        q.assess(sample(.outside), p: p)
        XCTAssertEqual(q.state, .distrusted)
        XCTAssertFalse(q.isUsable)
        XCTAssertEqual(q.evidenceSec, 0, "遷移で証拠窓を白紙化する")
    }

    /// **一時的に横を向いても退避しない**(受け入れ条件 D2)。
    /// 旧版は「連続 5 秒」だったので、店先を 5 秒見ただけで落ちていた
    func testBriefSidewaysLookDoesNotDistrust() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .inside, seconds: 20)
        feed(&q, .outside, seconds: 6)     // 6 秒だけ横を向く
        XCTAssertTrue(q.isUsable, "門外 6 秒 / 全 26 秒 = 23% では退避しない")
        feed(&q, .inside, seconds: 10)
        XCTAssertTrue(q.isUsable)
    }

    /// course が無い間・同じ fix の読み直しでは、証拠も状態も動かない
    func testNoCourseAndDuplicateFixChangeNothing() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .inside, seconds: 10)
        let before = q.evidenceSec
        feed(&q, .noCourse, seconds: 50)
        feed(&q, .duplicateFix, seconds: 50)
        XCTAssertEqual(q.evidenceSec, before, accuracy: 0.001)
        XCTAssertTrue(q.isUsable, "立ち止まって首を回しても採用のまま")
    }

    /// **間隔が空きすぎたら未確定の証拠だけ捨て、状態は変えない**(受け入れ条件 D6)
    func testLongGapClearsEvidenceButKeepsState() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .outside, seconds: 8)     // 退避まであと 4 秒
        q.assess(sample(.gapTooLong, 0), p: p)
        XCTAssertEqual(q.evidenceSec, 0, "間隔を跨いだ証拠を継ぎ足さない")
        XCTAssertTrue(q.isUsable, "間隔が空いただけで状態を変えてはいけない")
        feed(&q, .outside, seconds: 8)
        XCTAssertTrue(q.isUsable, "捨てた後は 8 秒では足りない(distrust_sec = 12)")
    }

    /// 退避中も、間隔が空いただけでは復帰しない
    func testLongGapDoesNotRegain() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .outside, seconds: 12)
        XCTAssertEqual(q.state, .distrusted)
        q.assess(sample(.gapTooLong, 0), p: p)
        feed(&q, .noCourse, seconds: 100)
        XCTAssertEqual(q.state, .distrusted)
    }

    /// 退避からの復帰(門内割合 + 証拠時間)
    func testRegainAfterDistrust() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .outside, seconds: 12)
        XCTAssertEqual(q.state, .distrusted)
        feed(&q, .inside, seconds: 7)
        XCTAssertEqual(q.state, .distrusted, "門内 7 秒では早い(regain_sec = 8)")
        q.assess(sample(.inside), p: p)
        XCTAssertEqual(q.state, .trusted)
    }

    /// **窓は有限。** 前半の大量の門内が、後半の磁気バイアス変化を覆い隠さない
    func testOldEvidenceFallsOutOfTheWindow() {
        var q = HeadingQuarantine()
        q.markLearned()
        feed(&q, .inside, seconds: 200)          // 長く正常に歩く
        XCTAssertEqual(q.evidenceSec, 40, accuracy: 0.001, "窓は 40 秒ぶんしか持たない")
        feed(&q, .outside, seconds: 35)          // ここで磁気が変わる
        XCTAssertEqual(q.state, .distrusted,
                       "前半 200 秒の門内が残っていると、ここで落ちない")
    }

    /// 証拠 0 秒の標本は窓に入れない(0 除算と、時間の無い証拠を防ぐ)
    func testZeroEvidenceSamplesAreIgnored() {
        var q = HeadingQuarantine()
        q.markLearned()
        for _ in 0..<100 { q.assess(sample(.outside, 0), p: p) }
        XCTAssertEqual(q.evidenceSec, 0)
        XCTAssertTrue(q.isUsable)
    }
}
