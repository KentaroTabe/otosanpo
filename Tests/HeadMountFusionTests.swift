import XCTest
@testable import OtoSanpo

/// 頭部固定スマホの方位を「使ってよいか」の判断(→ `HeadMountFusion`・docs/13)。
///
/// ## なぜこのテストが要るか(2026-09-08)
///
/// 学習(`MountOffset`)と検疫(`HeadingQuarantine`)はそれぞれ単体テストを持っていたが、
/// **両者を突き合わせる判断は Controller に散っていて、どこもテストしていなかった。**
/// その結果 3 つの穴が空いたまま実機テストへ出ようとしていた:
///
/// 1. 学習が成立していなくても、検疫さえ通れば未補正の方位が音に出る
/// 2. 学習が外れて方位が 90° 以上飛んでも、検疫が退避するまで採用のまま
/// 3. 更新が止まっても最後の値が残り続ける(鮮度の判定がどこにも無い)
///
/// 3 はとくに、**画面を消して頭にスマホを載せる**今回の構成に直結する。
/// 音が最後の頭の向きに凍りついたまま戻らず、画面が見えないので気づけない。
final class HeadMountFusionTests: XCTestCase {

    /// 学習が素直に立つ設定(標本 20 件・半減期は長め・R の門は緩め)
    private func learnable(staleSec: Double = 1.0) -> HeadMountFusion.Params {
        HeadMountFusion.Params(
            offset: MountOffset.Params(minWeight: 20, halfLifeSec: 60, minConcentration: 0.8),
            quarantine: HeadingQuarantine.Params(distrustDeg: 40, distrustSec: 5, regainSec: 5),
            staleSec: staleSec)
    }

    /// 10 Hz で `count` 件を流す。戻り値は最後の時刻
    @discardableResult
    private func feed(_ f: inout HeadMountFusion, count: Int, from t0: Double,
                      p: HeadMountFusion.Params,
                      heading: (Int) -> Double, course: (Int) -> Double?) -> Double {
        var t = t0
        for i in 0..<count {
            t = t0 + Double(i) * 0.1
            f.ingest(headingDeg: heading(i), rawCourseDeg: course(i), at: t, p: p)
        }
        return t
    }

    // MARK: - B1 使用可能条件は 3 つの論理積

    /// **学習が成立するまでは、検疫が合っていても使わない。**
    /// これが無いと、取り付けのずれがたまたま小さい時に未補正の方位が音に出る
    func testNotUsableBeforeTheOffsetIsLearned() {
        let p = learnable()
        var f = HeadMountFusion()
        // ずれ 0(heading == course)。検疫の観点では完全に一致しているが、
        // 標本が 20 件に満たないので学習は成立しない
        let t = feed(&f, count: 10, from: 100, p: p, heading: { _ in 90 }, course: { _ in 90 })
        XCTAssertNil(f.learnedOffsetDeg)
        XCTAssertEqual(f.use(at: t, p: p), .offsetNotLearned)
        XCTAssertNil(f.facingDeg(at: t, p: p), "学習前の方位が定位に流れてはいけない")
    }

    /// 学習が成立し、検疫の実績が `regain_sec` ぶん続いて初めて使える
    func testUsableOnlyAfterBothLearningAndQuarantineAgree() {
        let p = learnable()
        var f = HeadMountFusion()
        // ずれ +94°(実測値と同じ形)。course は東(90°)、heading は 184°
        let t = feed(&f, count: 400, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.learnedOffsetDeg ?? 0, 94, accuracy: 0.5)
        XCTAssertEqual(f.use(at: t, p: p), .use)
        XCTAssertEqual(f.facingDeg(at: t, p: p) ?? 0, 90, accuracy: 0.5,
                       "補正後の方位 = course と一致するはず")
    }

    // MARK: - B2 学習が外れたら即座に退避し、検疫の実績も捨てる

    /// **学習が失われたら、検疫の 5 秒を待たずに使用不能になる。**
    /// 補正値が消えると方位が学習値ぶん(実測 94°)一瞬で飛ぶため
    func testLosingTheLearnedOffsetStopsUseImmediately() {
        // 半減期を短くして、古い実績が速やかに薄れるようにする(挙動の検査なので値は自由)
        let p = HeadMountFusion.Params(
            offset: MountOffset.Params(minWeight: 20, halfLifeSec: 2, minConcentration: 0.9),
            quarantine: HeadingQuarantine.Params(distrustDeg: 40, distrustSec: 5, regainSec: 5),
            staleSec: 1.0)
        var f = HeadMountFusion()
        var t = feed(&f, count: 300, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: いったん使える状態にする")
        XCTAssertEqual(f.quarantineState, .trusted)

        // ずれが定数でなくなる(ポケットの中で揺れる・磁気が乱れる)。R が門を割る
        t = feed(&f, count: 200, from: t + 0.1, p: p,
                 heading: { i in i % 2 == 0 ? 0 : 180 }, course: { _ in 90 })
        XCTAssertNil(f.learnedOffsetDeg, "R が落ちたので学習は成立しないはず")
        XCTAssertEqual(f.use(at: t, p: p), .offsetNotLearned)
        XCTAssertEqual(f.quarantineState, .unverified,
                       "学習が外れたら検疫の実績も捨てる(別の量に対する実績になるため)")
    }

    // MARK: - B3 鮮度は読み出し時に効く

    /// **新しい標本が来なくても、時間が経てば使用不能になる。**
    ///
    /// 更新が止まった場合、受信側の処理では捕まえられない(呼ばれないのだから)。
    /// 画面を消して頭に載せる構成では、これが
    /// 「音が最後の頭の向きに凍りついたまま戻らない」という形で出る
    func testStalenessAppliesAtReadTimeWithoutNewSamples() {
        let p = learnable(staleSec: 1.0)
        var f = HeadMountFusion()
        let t = feed(&f, count: 400, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use)

        XCTAssertEqual(f.use(at: t + 0.9, p: p), .use, "上限の内側では使える")
        XCTAssertEqual(f.use(at: t + 1.5, p: p), .stale, "上限を超えたら古いと判定する")
        XCTAssertNil(f.facingDeg(at: t + 1.5, p: p), "古い方位が定位に流れてはいけない")
        XCTAssertEqual(f.use(at: t + 3600, p: p), .stale, "何時間経っても復活しない")
    }

    /// 1 標本も来ていない状態は「標本なし」。**検疫や学習の話をする前に区別する**
    func testNoSampleIsDistinguishedFromTheOtherReasons() {
        let p = learnable()
        let f = HeadMountFusion()
        XCTAssertEqual(f.use(at: 100, p: p), .noSample)
        XCTAssertNil(f.correctedHeadingDeg)
        XCTAssertNil(f.rawHeadingDeg)
    }

    // MARK: - A3 立ち止まっても学習と検疫が壊れない

    /// **立ち止まって首を回しても、学習の値も R も検疫の状態も動かない。**
    ///
    /// これが今回の実機テストの核心。以前の配線では「止まる直前の course」が
    /// 固定値として残り続け、それと回っている heading を突き合わせていたため、
    /// R が落ちて 5 秒で退避に落ちていた。**試験が自分の前提を壊していた。**
    ///
    /// 既存の `MountOffset` の「course が nil なら無視する」テストだけでは、
    /// この配線の欠陥は捕まえられない(nil が渡ってこなかったのが問題だったため)。
    /// **いったん有効な course を受けた後で nil に落ちる系列**で検査する
    func testStandingStillAndTurningTheHeadChangesNothing() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        var t = feed(&f, count: 400, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: 歩いて使える状態にする")

        let offsetBefore = f.learnedOffsetDeg
        let concentrationBefore = f.concentration
        let stateBefore = f.quarantineState

        // 立ち止まって首を左右に大きく振る。course は無効(nil)
        t = feed(&f, count: 200, from: t + 0.1, p: p,
                 heading: { i in Double(184 + 80 * sin(Double(i) * 0.3)) },
                 course: { _ in nil })

        XCTAssertEqual(f.learnedOffsetDeg ?? .nan, offsetBefore ?? .nan, accuracy: 1e-9,
                       "止まっている間に学習値が動いてはいけない")
        XCTAssertEqual(f.concentration, concentrationBefore, accuracy: 1e-9,
                       "止まっている間に R が下がってはいけない")
        XCTAssertEqual(f.quarantineState, stateBefore,
                       "止まっている間に検疫の状態が変わってはいけない")
        XCTAssertEqual(f.use(at: t, p: p), .use, "首を回しても使えるまま(だから試験ができる)")
    }

    /// 立ち止まりのあと歩き出しても、**中断を挟んだ実績を継ぎ足さない**
    /// (`HeadingQuarantine` の約束。ここでは Fusion 経由でも保たれることを見る)
    func testEvidenceWindowsAreNotStitchedAcrossAStop() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        // 標本 20 件(= 2 秒)で学習が立ち、その時点で検疫は白紙に戻る。
        // そこから regain_sec(5 秒)が要るので、5 秒で切れば実績は 3 秒ぶんしかない
        var t = feed(&f, count: 50, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertNotNil(f.learnedOffsetDeg, "前提: 学習は立っている")
        XCTAssertEqual(f.use(at: t, p: p), .quarantined(.unverified),
                       "前提: 検疫の実績はまだ 5 秒に足りない")

        // 立ち止まる(course が無い)。ここで実績の窓は捨てられる
        t = feed(&f, count: 50, from: t + 0.1, p: p, heading: { _ in 184 }, course: { _ in nil })
        // 再開後 3 秒だけでは、止まる前の 3 秒と足して 6 秒あっても採用にならない
        t = feed(&f, count: 30, from: t + 0.1, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .quarantined(.unverified),
                       "中断を挟んだ 3 秒 + 3 秒を 6 秒の実績として繋いではいけない")
    }

    // MARK: - A4 渡してよい course の定義

    /// **保持 course は「いま有効な生の course」ではない。**
    ///
    /// Controller はこの規則で course を選ぶ(`rawCourseBearing` →`TravelDirection.rawCourse`)。
    /// 立ち止まった fix に対して `held` を渡さずに解けば nil になる、が担保
    func testAStoppedFixYieldsNoRawCourse() {
        let params = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                            maxCourseAccuracyDeg: 70,
                                            maxFixAgeSec: 10,
                                            courseHoldSec: 15,
                                            allowCompassFallback: false)
        let stopped = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.1,
                                compassHeadingDeg: 200, ageSec: 1)
        XCTAssertNil(TravelDirection.resolve(stopped, held: nil, params: params),
                     "止まっている fix から生の course は取れない")
        // 保持値を渡せば「保持 course」として解けてしまう。だから学習・検疫へは渡さない
        let held = HeldCourse(deg: 90, ageSec: 2)
        XCTAssertEqual(TravelDirection.resolve(stopped, held: held, params: params)?.source,
                       .heldCourse)
    }

    /// **A3 の本体: 製品と同じ course 抽出を通した系列で、停止が学習と検疫を壊さないこと。**
    ///
    /// 前のテストは Fusion へ直接 nil を渡しており、「nil が渡ってくる」ことを前提にしていた。
    /// **問題はまさに nil が渡ってこなかったことだった**ので、それでは配線の欠陥を捕まえられない
    /// (2026-09-08 の検証で指摘)。ここでは fix 列を `TravelDirection.rawCourse` に通し、
    /// **保持 course もコンパスも混ざらない**ことまで含めて確かめる
    func testStoppedFixesNeverReachTheFusionThroughTheProductRule() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: false)
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()

        // 歩いている fix。course 90°・速度 1.0 m/s
        let walking = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.0,
                                compassHeadingDeg: 200, ageSec: 1)
        XCTAssertEqual(TravelDirection.rawCourse(walking, params: loc) ?? .nan, 90, accuracy: 1e-9,
                       "前提: 歩いている fix からは生の course が取れる")

        var t = 100.0
        for _ in 0..<400 {
            f.ingest(headingDeg: 184, rawCourseDeg: TravelDirection.rawCourse(walking, params: loc),
                     at: t, p: p)
            t += 0.1
        }
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: 歩いて使える状態にする")
        let offsetBefore = f.learnedOffsetDeg
        let concentrationBefore = f.concentration
        let stateBefore = f.quarantineState

        // 立ち止まった fix。**保持 course もコンパスも持っている**が、生の course は無い
        let stopped = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.1,
                                compassHeadingDeg: 200, ageSec: 1)
        XCTAssertNil(TravelDirection.rawCourse(stopped, params: loc),
                     "止まったら製品の規則では生の course は出ない")

        // その状態で首を大きく振る
        for i in 0..<200 {
            f.ingest(headingDeg: Double(184 + 80 * sin(Double(i) * 0.3)),
                     rawCourseDeg: TravelDirection.rawCourse(stopped, params: loc),
                     at: t, p: p)
            t += 0.1
        }

        XCTAssertEqual(f.learnedOffsetDeg ?? .nan, offsetBefore ?? .nan, accuracy: 1e-9,
                       "停止後も学習値は不変であること")
        XCTAssertEqual(f.concentration, concentrationBefore, accuracy: 1e-9,
                       "停止後も R は不変であること")
        XCTAssertEqual(f.quarantineState, stateBefore, "停止後も検疫の状態は不変であること")
        XCTAssertEqual(f.use(at: t, p: p), .use)
    }

    /// コンパス退避を許す設定でも、**学習・検疫へは生の course しか渡らない**
    func testCompassFallbackNeverReachesTheFusion() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: true)
        let stopped = MotionFix(courseDeg: -1, courseAccuracyDeg: -1, speedMps: 0.0,
                                compassHeadingDeg: 200, ageSec: 1)
        XCTAssertEqual(TravelDirection.resolve(stopped, held: nil, params: loc)?.source, .compass,
                       "前提: この設定なら resolve はコンパスへ退避する")
        XCTAssertNil(TravelDirection.rawCourse(stopped, params: loc),
                     "それでも学習・検疫へは渡さない")
    }

    // MARK: - 補正後の方位

    /// **鮮度切れは「読み出しの回数」に依らず、同じ判定を返す。**
    ///
    /// 状態の遷移ログと有効性パルスは、この判定を時計仕掛けで読んで動く。
    /// 何度読んでも同じ答えが返らないと、遷移が二重に記録される
    func testStalenessIsStableAcrossRepeatedReads() {
        let p = learnable(staleSec: 1.0)
        var f = HeadMountFusion()
        let t = feed(&f, count: 400, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t + 1.1, p: p), .stale)
        XCTAssertEqual(f.use(at: t + 1.1, p: p), .stale, "読み出しは判定を変えない")
        XCTAssertEqual(f.use(at: t + 1.2, p: p), .stale)
        // 受信が再開すれば、同じ標本 1 件で使用可能へ戻る(検疫の状態は保たれているため)
        f.ingest(headingDeg: 184, rawCourseDeg: 90, at: t + 1.3, p: p)
        XCTAssertEqual(f.use(at: t + 1.3, p: p), .use,
                       "受信が戻れば即座に使える(改めて 5 秒待たせない)")
    }

    /// 補正後の方位は「生 − 学習値」。**学習前は生のまま**(ログに出すため)
    func testCorrectedHeadingSubtractsTheLearnedOffset() {
        let p = learnable()
        var f = HeadMountFusion()
        _ = feed(&f, count: 5, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.rawHeadingDeg ?? 0, 184, accuracy: 1e-9)
        XCTAssertEqual(f.correctedHeadingDeg ?? 0, 184, accuracy: 1e-9, "学習前は補正しない")

        _ = feed(&f, count: 400, from: 200, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.correctedHeadingDeg ?? 0, 90, accuracy: 0.5, "学習後はずれを引く")
    }
}
