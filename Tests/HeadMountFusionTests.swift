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
///
/// ## 2026-09-10 に変わった要求(旧テストを置き換えた理由)
///
/// 実測で「頭方位 389 件・採用 0 件」になった。原因は検疫が
/// 「course が取れていて差が 40° 以内が**途切れず 5 秒**」を要求していたこと
/// (course は間欠で、条件が続いた最長は 3 秒)。要求を次のように変えた:
///
/// - **初期の信頼は学習の成立が与える。** 成立した時点で採用から始まる
/// - **証拠は「異なる fix の間の経過時間」で数える。** 同じ fix を 50 Hz で
///   50 回読んでも 1 回ぶん
/// - **成立した補正はその散歩の終わりまで固定。** 長い首振りで白紙に戻さない
///
/// 期待値を書き換えたのではなく、判定に使う量と条件が変わっている。
final class HeadMountFusionTests: XCTestCase {

    /// 学習が素直に立つ設定(証拠 5 秒・半減期は長め・R の門は緩め)
    private func learnable(staleSec: Double = 1.0,
                           minConcentration: Double = 0.8,
                           gateDeg: Double = 45) -> HeadMountFusion.Params {
        HeadMountFusion.Params(
            offset: MountOffset.Params(minEvidenceSec: 5, halfLifeSec: 60,
                                       minConcentration: minConcentration,
                                       gateDeg: gateDeg, maxGapSec: 5),
            quarantine: HeadingQuarantine.Params(windowSec: 40, distrustRatio: 0.75,
                                                 distrustSec: 12, regainRatio: 0.7,
                                                 regainSec: 8),
            staleSec: staleSec)
    }

    /// `fixes` 個の fix を 1 秒間隔で流す。1 fix あたり `perFix` 回 `ingest` する
    /// (= 更新頻度の模擬)。戻り値は最後の標本時刻。
    ///
    /// **`heading` と `course` には fix 番号を渡す**(標本番号ではない)。
    /// 標本番号にすると、10 Hz と 50 Hz で「同じ fix の瞬間に見えた方位」が
    /// 変わってしまい、更新頻度の比較が成立しない
    @discardableResult
    private func feed(_ f: inout HeadMountFusion, fixes: Int, from t0: Double,
                      p: HeadMountFusion.Params, perFix: Int = 10,
                      heading: (Int) -> Double, course: (Int) -> Double?) -> Double {
        var t = t0
        for i in 0..<fixes {
            let fixTime = t0 + Double(i)
            let c = course(i)
            let h = heading(i)
            for k in 0..<perFix {
                t = fixTime + Double(k) / Double(perFix)
                f.ingest(headingDeg: h, rawCourseDeg: c,
                         fixTime: c == nil ? nil : fixTime, at: t, p: p)
            }
        }
        return t
    }

    // MARK: - A1 使用可能条件は 3 つの論理積

    /// **学習が成立するまでは、検疫が合っていても使わない。**
    /// これが無いと、取り付けのずれがたまたま小さい時に未補正の方位が音に出る
    func testNotUsableBeforeTheOffsetIsLearned() {
        let p = learnable()
        var f = HeadMountFusion()
        // ずれ 0(heading == course)。検疫の観点では完全に一致しているが、
        // 証拠が 5 秒に満たないので学習は成立しない
        let t = feed(&f, fixes: 3, from: 100, p: p, heading: { _ in 90 }, course: { _ in 90 })
        XCTAssertNil(f.learnedOffsetDeg)
        XCTAssertEqual(f.use(at: t, p: p), .offsetNotLearned)
        XCTAssertNil(f.facingDeg(at: t, p: p), "学習前の方位が定位に流れてはいけない")
    }

    /// **学習が成立した時点で使える**(受け入れ条件 A2)。
    /// 旧版はここから更に「course と 5 秒連続一致」を要求し、実測で一度も成立しなかった
    func testUsableAsSoonAsTheOffsetIsLearned() {
        let p = learnable()
        var f = HeadMountFusion()
        // ずれ +94°(実測値と同じ形)。course は東(90°)、heading は 184°
        let t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.learnedOffsetDeg ?? 0, 94, accuracy: 0.5)
        XCTAssertEqual(f.quarantineState, .trusted)
        XCTAssertEqual(f.use(at: t, p: p), .use)
        XCTAssertEqual(f.facingDeg(at: t, p: p) ?? 0, 90, accuracy: 0.5,
                       "補正後の方位 = course と一致するはず")
    }

    /// 学習が成立する**前**に差が散らばれば、成立しないまま(使えないまま)
    func testScatteredDiffNeverLearns() {
        let p = learnable(minConcentration: 0.9)
        var f = HeadMountFusion()
        let t = feed(&f, fixes: 60, from: 100, p: p,
                     heading: { i in i % 2 == 0 ? 0 : 180 }, course: { _ in 90 })
        XCTAssertNil(f.learnedOffsetDeg, "R が門を割るので学習は成立しない")
        XCTAssertEqual(f.use(at: t, p: p), .offsetNotLearned)
        XCTAssertEqual(f.quarantineState, .unverified)
    }

    /// **成立した補正は失われない**(受け入れ条件 C1)。
    /// 旧版は R が落ちると学習が外れ、そのたびに検疫の実績も捨てていた。
    /// 実測の散歩で 2 回起き、そのつど「補正待ち」へ落ちて音が進行方位に戻っていた
    func testLearnedOffsetIsNeverLost() {
        let p = learnable(staleSec: 30, minConcentration: 0.9)
        var f = HeadMountFusion()
        var t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        let learned = try! XCTUnwrap(f.learnedOffsetDeg)
        let r = f.concentration
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: いったん使える状態にする")

        // 首を大きく振り回しながら歩く。旧版ならここで学習が外れていた
        t = feed(&f, fixes: 60, from: t + 0.1, p: p,
                 heading: { i in Double(184 + 170 * sin(Double(i) * 0.3)) },
                 course: { _ in 90 })
        XCTAssertEqual(try! XCTUnwrap(f.learnedOffsetDeg), learned, accuracy: 1e-9,
                       "首を回しただけで学習値が動いてはいけない")
        XCTAssertEqual(f.concentration, r, accuracy: 1e-9, "成立後は R も動かない")
    }

    // MARK: - B 同じ fix を重複して数えない

    /// **更新頻度を変えても、学習も検疫も同じ結果になる**(受け入れ条件 B4)
    func testResultIsIndependentOfUpdateRate() {
        let p = learnable(staleSec: 30)
        var slow = HeadMountFusion()
        var fast = HeadMountFusion()
        let heading: (Int) -> Double = { i in 184 + 10 * sin(Double(i) * 0.1) }
        feed(&slow, fixes: 30, from: 100, p: p, perFix: 10,
             heading: heading, course: { _ in 90 })
        feed(&fast, fixes: 30, from: 100, p: p, perFix: 50,
             heading: heading, course: { _ in 90 })
        XCTAssertEqual(try! XCTUnwrap(slow.learnedOffsetDeg),
                       try! XCTUnwrap(fast.learnedOffsetDeg), accuracy: 0.001)
        XCTAssertEqual(slow.concentration, fast.concentration, accuracy: 0.001)
        XCTAssertEqual(slow.quarantineState, fast.quarantineState)
        XCTAssertEqual(slow.insideEvidenceSec, fast.insideEvidenceSec, accuracy: 0.001)
    }

    /// **1 個の fix を読み直し続けても学習は成立しない**(受け入れ条件 B2)。
    /// `max_fix_age_sec` は 10 秒あるので、古い fix 1 個で学習時間の半分を作れていた
    func testOneStaleFixCannotLearnOnItsOwn() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        for i in 0..<500 {
            f.ingest(headingDeg: 184, rawCourseDeg: 90, fixTime: 1000,
                     at: 1000 + Double(i) * 0.02, p: p)
        }
        XCTAssertNil(f.learnedOffsetDeg, "fix 1 個で 5 秒ぶんの証拠を作ってはいけない")
    }

    // MARK: - D 検疫は割合で見る

    /// 一時的に横を向いても退避しない(受け入れ条件 D2)
    func testBriefSidewaysLookKeepsUsable() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        var t = feed(&f, fixes: 20, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use)
        // 6 秒だけ 90° 横を向く(門の外)
        t = feed(&f, fixes: 6, from: t + 0.1, p: p,
                 heading: { _ in 274 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use, "6 秒の横向きで退避してはいけない")
    }

    /// 門の外が支配的な状態が続けば退避し、定位に方位を流さない
    func testSustainedOutsideDistrusts() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        var t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use)
        // 磁気バイアスが 120° 変わった(門 45° の外)。20 秒続く
        t = feed(&f, fixes: 20, from: t + 0.1, p: p,
                 heading: { _ in 304 }, course: { _ in 90 })
        XCTAssertEqual(f.quarantineState, .distrusted)
        XCTAssertEqual(f.use(at: t, p: p), .quarantined(.distrusted))
        XCTAssertNil(f.facingDeg(at: t, p: p), "退避中の方位が定位に流れてはいけない")
    }

    // MARK: - A3 立ち止まっても学習と検疫が壊れない

    /// **立ち止まって首を回しても、学習の値も R も検疫の状態も動かない。**
    ///
    /// これが実機テストの核心。以前の配線では「止まる直前の course」が
    /// 固定値として残り続け、それと回っている heading を突き合わせていたため、
    /// R が落ちて 5 秒で退避に落ちていた。**試験が自分の前提を壊していた。**
    func testStandingStillAndTurningTheHeadChangesNothing() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        var t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: 歩いて使える状態にする")

        let offsetBefore = f.learnedOffsetDeg
        let concentrationBefore = f.concentration
        let stateBefore = f.quarantineState
        let insideBefore = f.insideEvidenceSec

        // 立ち止まって首を左右に大きく振る。course は無効(nil)
        t = feed(&f, fixes: 20, from: t + 0.1, p: p,
                 heading: { i in Double(184 + 80 * sin(Double(i) * 0.3)) },
                 course: { _ in nil })

        XCTAssertEqual(f.learnedOffsetDeg ?? .nan, offsetBefore ?? .nan, accuracy: 1e-9,
                       "止まっている間に学習値が動いてはいけない")
        XCTAssertEqual(f.concentration, concentrationBefore, accuracy: 1e-9,
                       "止まっている間に R が下がってはいけない")
        XCTAssertEqual(f.quarantineState, stateBefore,
                       "止まっている間に検疫の状態が変わってはいけない")
        XCTAssertEqual(f.insideEvidenceSec, insideBefore, accuracy: 1e-9,
                       "course が無い間は証拠も増減しない")
        XCTAssertEqual(f.use(at: t, p: p), .use, "首を回しても使えるまま(だから試験ができる)")
    }

    /// **短い course の欠落では証拠を捨てない**(受け入れ条件 D6)。
    ///
    /// これは旧版と要求が逆になった箇所。旧版は 1 標本でも course が欠けると
    /// 実績の窓をゼロに戻していた。course は本質的に間欠(実測で 37%)なので、
    /// その規則では条件が永久に満たされない — 実際に採用 0% になった
    func testShortCourseGapsDoNotDiscardEvidence() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        // 1 秒おきに course が消える系列でも、学習は素直に立つ
        let t = feed(&f, fixes: 30, from: 100, p: p,
                     heading: { _ in 184 }, course: { i in i % 2 == 0 ? 90 : nil })
        XCTAssertNotNil(f.learnedOffsetDeg, "course が半分欠けていても学習は成立する")
        XCTAssertEqual(f.use(at: t, p: p), .use)
    }

    // MARK: - A4 渡してよい course の定義

    /// **保持 course は「いま有効な生の course」ではない。**
    ///
    /// Controller はこの規則で course を選ぶ(`rawCourseFix` → `TravelDirection.rawCourseFix`)。
    /// 立ち止まった fix に対して `held` を渡さずに解けば nil になる、が担保
    func testAStoppedFixYieldsNoRawCourse() {
        let params = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                            maxCourseAccuracyDeg: 70,
                                            maxFixAgeSec: 10,
                                            courseHoldSec: 15,
                                            allowCompassFallback: false)
        let stopped = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.1,
                                compassHeadingDeg: 200, ageSec: 1, fixTime: 1000)
        XCTAssertNil(TravelDirection.resolve(stopped, held: nil, params: params),
                     "止まっている fix から生の course は取れない")
        // 保持値を渡せば「保持 course」として解けてしまう。だから学習・検疫へは渡さない
        let held = HeldCourse(deg: 90, ageSec: 2)
        XCTAssertEqual(TravelDirection.resolve(stopped, held: held, params: params)?.source,
                       .heldCourse)
    }

    /// **fix の時刻が無ければ生 course として渡さない。**
    /// 識別子の無い course を渡すと、重複排除ができないまま証拠が積まれる
    func testRawCourseFixRequiresAFixTime() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: false)
        let noTime = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.0,
                               compassHeadingDeg: 200, ageSec: 1, fixTime: nil)
        XCTAssertEqual(TravelDirection.rawCourse(noTime, params: loc) ?? .nan, 90,
                       accuracy: 1e-9, "前提: 角度そのものは取れる")
        XCTAssertNil(TravelDirection.rawCourseFix(noTime, params: loc),
                     "fix の時刻が無ければ学習・検疫へは渡さない")
    }

    /// **製品と同じ course 抽出を通した系列で、停止が学習と検疫を壊さないこと。**
    ///
    /// 直接 nil を渡すテストだけでは配線の欠陥を捕まえられない
    /// (**問題はまさに nil が渡ってこなかったこと**だった。2026-09-08 の検証で指摘)。
    /// ここでは fix 列を `TravelDirection.rawCourseFix` に通し、
    /// **保持 course もコンパスも混ざらない**ことまで含めて確かめる
    func testStoppedFixesNeverReachTheFusionThroughTheProductRule() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: false)
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()

        var t = 100.0
        // 歩いている fix を 1 秒ごとに更新しながら 10 Hz で読む
        for i in 0..<20 {
            let walking = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.0,
                                    compassHeadingDeg: 200, ageSec: 1,
                                    fixTime: 100 + Double(i))
            let fix = TravelDirection.rawCourseFix(walking, params: loc)
            XCTAssertNotNil(fix, "前提: 歩いている fix からは生の course が取れる")
            for k in 0..<10 {
                t = 100 + Double(i) + Double(k) * 0.1
                f.ingest(headingDeg: 184, rawCourseDeg: fix?.deg, fixTime: fix?.fixTime,
                         at: t, p: p)
            }
        }
        XCTAssertEqual(f.use(at: t, p: p), .use, "前提: 歩いて使える状態にする")
        let offsetBefore = f.learnedOffsetDeg
        let concentrationBefore = f.concentration
        let stateBefore = f.quarantineState

        // 立ち止まった fix。**保持 course もコンパスも持っている**が、生の course は無い
        for i in 0..<20 {
            let stopped = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.1,
                                    compassHeadingDeg: 200, ageSec: 1,
                                    fixTime: 200 + Double(i))
            XCTAssertNil(TravelDirection.rawCourseFix(stopped, params: loc),
                         "止まったら製品の規則では生の course は出ない")
            let fix = TravelDirection.rawCourseFix(stopped, params: loc)
            for k in 0..<10 {
                t = 200 + Double(i) + Double(k) * 0.1
                f.ingest(headingDeg: Double(184 + 80 * sin(t * 3)),
                         rawCourseDeg: fix?.deg, fixTime: fix?.fixTime, at: t, p: p)
            }
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
                                compassHeadingDeg: 200, ageSec: 1, fixTime: 1000)
        XCTAssertEqual(TravelDirection.resolve(stopped, held: nil, params: loc)?.source, .compass,
                       "前提: この設定なら resolve はコンパスへ退避する")
        XCTAssertNil(TravelDirection.rawCourseFix(stopped, params: loc),
                     "それでも学習・検疫へは渡さない")
    }

    // MARK: - 鮮度は読み出し時に効く

    /// **新しい標本が来なくても、時間が経てば使用不能になる。**
    ///
    /// 更新が止まった場合、受信側の処理では捕まえられない(呼ばれないのだから)。
    /// 画面を消して頭に載せる構成では、これが
    /// 「音が最後の頭の向きに凍りついたまま戻らない」という形で出る
    func testStalenessAppliesAtReadTimeWithoutNewSamples() {
        let p = learnable(staleSec: 1.0)
        var f = HeadMountFusion()
        let t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
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

    /// **鮮度切れは「読み出しの回数」に依らず、同じ判定を返す。**
    ///
    /// 状態の遷移ログと有効性パルスは、この判定を時計仕掛けで読んで動く。
    /// 何度読んでも同じ答えが返らないと、遷移が二重に記録される
    func testStalenessIsStableAcrossRepeatedReads() {
        let p = learnable(staleSec: 1.0)
        var f = HeadMountFusion()
        let t = feed(&f, fixes: 10, from: 100, p: p,
                     heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.use(at: t + 1.1, p: p), .stale)
        XCTAssertEqual(f.use(at: t + 1.1, p: p), .stale, "読み出しは判定を変えない")
        XCTAssertEqual(f.use(at: t + 1.2, p: p), .stale)
        // 受信が再開すれば、同じ標本 1 件で使用可能へ戻る(検疫の状態は保たれているため)
        f.ingest(headingDeg: 184, rawCourseDeg: 90, fixTime: 130, at: t + 1.3, p: p)
        XCTAssertEqual(f.use(at: t + 1.3, p: p), .use,
                       "受信が戻れば即座に使える(改めて待たせない)")
    }

    /// 補正後の方位は「生 − 学習値」。**学習前は生のまま**(ログに出すため)
    func testCorrectedHeadingSubtractsTheLearnedOffset() {
        let p = learnable()
        var f = HeadMountFusion()
        feed(&f, fixes: 2, from: 100, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.rawHeadingDeg ?? 0, 184, accuracy: 1e-9)
        XCTAssertEqual(f.correctedHeadingDeg ?? 0, 184, accuracy: 1e-9, "学習前は補正しない")

        feed(&f, fixes: 20, from: 200, p: p, heading: { _ in 184 }, course: { _ in 90 })
        XCTAssertEqual(f.correctedHeadingDeg ?? 0, 90, accuracy: 0.5, "学習後はずれを引く")
    }
}
