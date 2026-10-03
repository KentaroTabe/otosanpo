import XCTest
@testable import OtoSanpo

/// 大きな向きの変化に裏取りを要求する関所(→ `BearingFlipGate`・docs/05)。
///
/// 2026-09-08 の散歩で、帰路のビーコンが **1.5 秒で 180° 往復**していた。
/// 歩行では起こりえないので、「大きな変化は数秒続いた時だけ受け入れる」で落とす。
final class BearingFlipGateTests: XCTestCase {

    private func params(enter: Double = 90, exit: Double = 45, cluster: Double = 40,
                        confirm: Double = 3, minSamples: Int = 3,
                        maxGap: Double = 5) -> BearingFlipGate.Params {
        BearingFlipGate.Params(enterDeg: enter, exitDeg: exit, clusterDeg: cluster,
                               confirmSec: confirm, minSamples: minSamples,
                               maxGapSec: maxGap)
    }

    /// 最初の 1 件はそのまま通す(比べる相手が無い)
    func testFirstSampleIsAdopted() {
        var g = BearingFlipGate()
        XCTAssertEqual(g.ingest(100, at: 0, p: params()), 100, accuracy: 1e-9)
        XCTAssertEqual(g.current, 100)
    }

    /// **小さい変化は遅らせない。** 普通に曲がる時の追従を鈍らせてはいけない
    func testSmallChangesPassThroughImmediately() {
        var g = BearingFlipGate()
        let p = params()
        g.ingest(0, at: 0, p: p)
        XCTAssertEqual(g.ingest(30, at: 1, p: p), 30, accuracy: 1e-9)
        XCTAssertEqual(g.ingest(75, at: 2, p: p), 75, accuracy: 1e-9)
        XCTAssertEqual(g.confirms, 0, "小さい変化は確定の勘定に入らない")
    }

    /// **1.5 秒で往復する反転は素通りしない**(これが直したい症状そのもの)
    func testShortRoundTripIsRejected() {
        var g = BearingFlipGate()
        let p = params()
        g.ingest(0, at: 0, p: p)
        // 176° 跳ぶ。まだ出さない
        XCTAssertEqual(g.ingest(176, at: 1, p: p), 0, accuracy: 1e-9)
        XCTAssertEqual(g.ingest(178, at: 2, p: p), 0, accuracy: 1e-9)
        // 1.5 秒で元へ戻った → 往復だったので捨てる
        XCTAssertEqual(g.ingest(2, at: 2.5, p: p), 2, accuracy: 1e-9)
        XCTAssertEqual(g.cancels, 1)
        XCTAssertEqual(g.confirms, 0, "往復は確定させない")
    }

    /// **本当に向きが変わったなら、裏が取れた時点で切り替える**
    func testSustainedChangeIsConfirmed() {
        var g = BearingFlipGate()
        let p = params(confirm: 3, minSamples: 3)
        g.ingest(0, at: 0, p: p)
        XCTAssertEqual(g.ingest(180, at: 1, p: p), 0, accuracy: 1e-9, "1 件目は保留")
        XCTAssertEqual(g.ingest(178, at: 2, p: p), 0, accuracy: 1e-9, "まだ 3 秒経っていない")
        XCTAssertEqual(g.ingest(182, at: 3, p: p), 0, accuracy: 1e-9, "3 件目・ちょうど 3 秒前から")
        XCTAssertEqual(g.ingest(181, at: 4, p: p), 181, accuracy: 1e-9, "確定")
        XCTAssertEqual(g.confirms, 1)
    }

    /// **時間が足りていても、標本が足りなければ確定しない**
    func testMinimumSamplesAreRequired() {
        var g = BearingFlipGate()
        let p = params(confirm: 3, minSamples: 3)
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)
        // 2 件目が 10 秒後。時間は足りるが、間が空いているので群は作り直される
        XCTAssertEqual(g.ingest(180, at: 11, p: p), 0, accuracy: 1e-9)
        XCTAssertEqual(g.confirms, 0)
    }

    /// **標本が途切れたら保留を捨てる。** 測位が止まった前後を「続いた」と見ない
    func testGapDropsThePending() {
        var g = BearingFlipGate()
        let p = params(confirm: 3, minSamples: 2, maxGap: 5)
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)
        g.ingest(180, at: 20, p: p)      // 19 秒空いた → 群を作り直す
        XCTAssertEqual(g.ingest(180, at: 21, p: p), 0, accuracy: 1e-9, "作り直した群はまだ 1 秒")
        XCTAssertEqual(g.confirms, 0)
    }

    /// **同じ fix を 2 度読んでも 1 件**(定期発火と位置更新の両方から引かれるため)
    func testTheSameFixIsCountedOnce() {
        var g = BearingFlipGate()
        let p = params(confirm: 3, minSamples: 3)
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)
        g.ingest(180, at: 1, p: p)       // 同じ時刻。数えない
        g.ingest(180, at: 1, p: p)
        XCTAssertEqual(g.ingest(180, at: 4, p: p), 0, accuracy: 1e-9,
                       "固有の標本は 2 件しかないので確定しない")
        XCTAssertEqual(g.confirms, 0)
    }

    /// 保留中に候補がばらつけば、群を作り直す(**確定は遠のく**)
    func testScatteredCandidatesRestartTheCluster() {
        var g = BearingFlipGate()
        let p = params(cluster: 40, confirm: 3, minSamples: 2)
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)
        g.ingest(260, at: 2, p: p)       // 群から 80° 外れた → 作り直し
        XCTAssertEqual(g.ingest(262, at: 3, p: p), 0, accuracy: 1e-9,
                       "作り直した群はまだ 1 秒しか経っていない")
        XCTAssertEqual(g.confirms, 0)
        XCTAssertGreaterThan(g.drops, 0)
    }

    /// 入口と出口で閾値が違う(Schmitt)。**出口のほうが狭い**
    func testExitThresholdIsNarrowerThanEntry() {
        var g = BearingFlipGate()
        let p = params(enter: 90, exit: 45)
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)       // 保留に入る
        // 60° は enter(90°)より小さいが exit(45°)より大きい → まだ戻ったとはみなさない
        XCTAssertEqual(g.ingest(60, at: 2, p: p), 0, accuracy: 1e-9)
        XCTAssertEqual(g.cancels, 0)
        // 40° まで戻れば「戻った」
        XCTAssertEqual(g.ingest(40, at: 3, p: p), 40, accuracy: 1e-9)
        XCTAssertEqual(g.cancels, 1)
    }

    /// 0° をまたぐ差を円周で測る(359° と 1° は 2° 差)
    func testWrapAroundIsMeasuredOnTheCircle() {
        var g = BearingFlipGate()
        let p = params()
        g.ingest(359, at: 0, p: p)
        XCTAssertEqual(g.ingest(1, at: 1, p: p), 1, accuracy: 1e-9, "2° 差なので素通り")
        XCTAssertEqual(g.confirms, 0)
    }

    /// `reset` で全部捨てる(帰路の開始・自宅の変更・経路の場の作り直し)
    func testResetClearsEverything() {
        var g = BearingFlipGate()
        let p = params()
        g.ingest(0, at: 0, p: p)
        g.ingest(180, at: 1, p: p)
        g.reset()
        XCTAssertNil(g.current)
        XCTAssertEqual(g.ingest(180, at: 2, p: p), 180, accuracy: 1e-9,
                       "作り直した後の 1 件目はそのまま通る")
    }

    /// **時間を巻き戻されても壊れない**(同じ fix の二度読みと同じ扱い)
    func testOlderSampleIsIgnored() {
        var g = BearingFlipGate()
        let p = params()
        g.ingest(0, at: 10, p: p)
        XCTAssertEqual(g.ingest(90, at: 5, p: p), 0, accuracy: 1e-9)
    }
}
