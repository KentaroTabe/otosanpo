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
/// - **証拠は fix の時刻で数える。** 同じ fix を 50 Hz で 50 回読んでも 1 回ぶん。
///   course の無い fix を挟んだ区間は含めない。減衰も fix の時刻で測る
/// - **成立した補正はその散歩の終わりまで固定。** 長い首振りで白紙に戻さない
///
/// 期待値を書き換えたのではなく、判定に使う量と条件が変わっている。
/// 系列テストの一部は Codex の検証(2026-09-10)が「入力と期待値」の形で挙げたもの。
final class HeadMountFusionTests: XCTestCase {

    /// 学習が素直に立つ設定(証拠 5 秒・半減期は長め・R の門は緩め)
    private func learnable(staleSec: Double = 1.0,
                           minEvidenceSec: Double = 5,
                           halfLifeSec: Double = 60,
                           minConcentration: Double = 0.8,
                           gateDeg: Double = 45) -> HeadMountFusion.Params {
        HeadMountFusion.Params(
            offset: MountOffset.Params(minEvidenceSec: minEvidenceSec,
                                       halfLifeSec: halfLifeSec,
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
    /// - **`heading` と `course` には fix 番号を渡す**(標本番号ではない)。
    ///   標本番号にすると、10 Hz と 50 Hz で「同じ fix の瞬間に見えた方位」が変わってしまう
    /// - **fix の時刻は course が無くても渡す**(製品と同じ)
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
                f.ingest(headingDeg: h, rawCourseDeg: c, fixTime: fixTime, at: t, p: p)
            }
        }
        return t
    }

    /// 1 つの fix を 1 回だけ流す(細かい系列を組むとき用)
    private func step(_ f: inout HeadMountFusion, fixTime: Double, heading: Double,
                      course: Double?, p: HeadMountFusion.Params) {
        f.ingest(headingDeg: heading, rawCourseDeg: course, fixTime: fixTime, at: fixTime, p: p)
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

    /// **成立した瞬間、検疫の窓は白紙**(受け入れ条件 D1・2026-09-10 の検証で挙がった系列)。
    ///
    /// `minEvidenceSec = 2` で一定差の fix を t=0,1,2 に流す。t=2 で成立した直後は
    /// 採用・門内 0 秒・門外 0 秒。成立させた標本を門内として数えていた版では 1 秒になった
    func testQuarantineStartsEmptyAtTheMomentOfLearning() {
        let p = learnable(staleSec: 30, minEvidenceSec: 2, halfLifeSec: .infinity)
        var f = HeadMountFusion()
        step(&f, fixTime: 0, heading: 184, course: 90, p: p)
        step(&f, fixTime: 1, heading: 184, course: 90, p: p)
        XCTAssertNil(f.learnedOffsetDeg, "前提: まだ成立していない")
        step(&f, fixTime: 2, heading: 184, course: 90, p: p)
        XCTAssertNotNil(f.learnedOffsetDeg, "前提: この fix で成立する")
        XCTAssertEqual(f.quarantineState, .trusted)
        XCTAssertEqual(f.insideEvidenceSec, 0, "成立させた標本を門内として数えない")
        XCTAssertEqual(f.outsideEvidenceSec, 0)
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

    // MARK: - B 同じ fix を重複して数えない・更新頻度に依らない

    /// **更新頻度と、新しい fix を最初に見る位相に依らず、結果が同じ**(受け入れ条件 B4)。
    ///
    /// 実機では fix の到着は GPS 側の都合でばらつき、頭方位のコールバックは一定の格子で来る。
    /// 新しい fix を最初に見る時刻は、10 Hz なら最大 0.1 秒・50 Hz なら 0.02 秒遅れ、
    /// **その遅れは fix ごとに違う**。減衰をコールバック時刻で測っていた版では、
    /// この違いで R・学習値・成立時刻が変わった(2026-09-10 の検証で指摘)。
    /// 学習 → 退避 → 復帰を 1 本で起こし、**全 fix の検疫状態の列**まで一致させる
    func testResultIsIndependentOfUpdateRateAndPhase() {
        // 半減期を有限にする。**減衰の測り方が位相に依ると、ここで差が出る**
        let p = learnable(staleSec: 30, halfLifeSec: 10)
        /// fix の到着時刻(1 秒おき + 0〜0.29 秒のばらつき)。
        /// 1 行で書くと型推論が時間切れになるので、式を分けて型を明示する
        let fixTimes: [Double] = (0..<60).map { (i: Int) -> Double in
            let jitter = Double((i * 37) % 30) / 100.0
            return 1000.0 + Double(i) + jitter
        }
        /// 学習 → 磁気が変わる(門の外)→ 戻る、を起こす方位(fix 番号で決まる)
        func heading(_ i: Int) -> Double {
            switch i {
            case ..<10: return 184 + Double(i % 3)
            case ..<30: return 304
            default: return 184
            }
        }
        func run(hz: Double) -> (states: [HeadingQuarantine.State], learnedAt: Int?,
                                 offset: Double?, r: Double) {
            var f = HeadMountFusion()
            var states: [HeadingQuarantine.State] = []
            var learnedAt: Int?
            var i = 0
            // コールバックの格子(hz の倍数の時刻)
            var t = (fixTimes[0] * hz).rounded(.up) / hz
            let end = fixTimes[fixTimes.count - 1] + 1
            while t < end {
                // この時刻に見えている最新の fix へ進む。進む前に直前の fix の結果を記録する
                while i + 1 < fixTimes.count, fixTimes[i + 1] <= t {
                    if learnedAt == nil, f.learnedOffsetDeg != nil { learnedAt = i }
                    states.append(f.quarantineState)
                    i += 1
                }
                f.ingest(headingDeg: heading(i), rawCourseDeg: 90, fixTime: fixTimes[i],
                         at: t, p: p)
                t += 1 / hz
            }
            if learnedAt == nil, f.learnedOffsetDeg != nil { learnedAt = i }
            states.append(f.quarantineState)
            return (states, learnedAt, f.learnedOffsetDeg, f.concentration)
        }
        let slow = run(hz: 10)
        let fast = run(hz: 50)
        XCTAssertEqual(slow.states.count, fixTimes.count, "前提: fix を 1 つも取りこぼしていない")
        XCTAssertNotNil(slow.learnedAt, "前提: 学習が成立する")
        XCTAssertTrue(slow.states.contains(.distrusted), "前提: 退避まで起きる系列になっている")
        XCTAssertEqual(slow.states.last, .trusted, "前提: 復帰まで起きる")
        XCTAssertEqual(slow.learnedAt, fast.learnedAt, "成立した fix が同じ")
        XCTAssertEqual(slow.offset ?? .nan, fast.offset ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(slow.r, fast.r, accuracy: 1e-12)
        XCTAssertEqual(slow.states, fast.states, "検疫の状態が fix ごとにすべて一致する")
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

    /// **course の無い fix を挟んだ区間は証拠にしない**(受け入れ条件 D6)。
    ///
    /// これは旧版と要求が逆になった箇所でもある。旧版は course が 1 標本でも欠けると
    /// 実績の窓をゼロに戻していた(→ 採用 0%)。いまは欠落で捨てないが、
    /// **欠落していた時間を証拠に数えることもしない**。
    /// 1 秒おきに course が消える系列で、有効な fix 5 個 × 1 秒 = 5 秒ちょうどで成立する。
    /// 無効な fix の時刻を捨てていた版では 2 秒ずつ数え、t=6 で早く成立していた
    func testShortCourseGapsCountOnlyTheObservedInterval() {
        let p = learnable(staleSec: 30, halfLifeSec: .infinity)
        var f = HeadMountFusion()
        var learnedAt: Int?
        for i in 0..<20 {
            step(&f, fixTime: 100 + Double(i), heading: 184,
                 course: i % 2 == 0 ? 90 : nil, p: p)
            if learnedAt == nil, f.learnedOffsetDeg != nil { learnedAt = i }
        }
        XCTAssertEqual(learnedAt, 10,
                       "有効 fix の区間 1 秒 × 5 回で成立する(course の無い 1 秒は数えない)")
        XCTAssertEqual(f.use(at: 119, p: p), .use, "欠落を挟んでも採用のまま")
    }

    /// **欠落の時間を門外の証拠にも数えない**(2026-09-10 の検証で挙がった系列)。
    ///
    /// 採用中に門外 8 秒 → course の無い新しい fix 3 秒 → 門外の有効 fix 1 件。
    /// 門外の証拠は **9 秒**で、`distrust_sec = 12` に届かず採用を維持する。
    /// 欠落を数えていた版では 12 秒になり、ここで退避していた
    func testNoCourseGapDoesNotInflateOutsideEvidence() {
        let p = learnable(staleSec: 30, halfLifeSec: .infinity)
        var f = HeadMountFusion()
        // t=0..5 で学習が成立(証拠 5 秒)。成立させた標本は検疫に入らない
        for i in 0...5 { step(&f, fixTime: Double(i), heading: 184, course: 90, p: p) }
        XCTAssertEqual(f.quarantineState, .trusted, "前提: 学習が成立して採用")
        // 門外(磁気が 120° 変わった)を 8 秒
        for i in 6...13 { step(&f, fixTime: Double(i), heading: 304, course: 90, p: p) }
        XCTAssertEqual(f.outsideEvidenceSec, 8, accuracy: 1e-9)
        // 立ち止まる: course の無い新しい fix が 3 秒
        for i in 14...16 { step(&f, fixTime: Double(i), heading: 304, course: nil, p: p) }
        // 門外の有効 fix を 1 件
        step(&f, fixTime: 17, heading: 304, course: 90, p: p)
        XCTAssertEqual(f.outsideEvidenceSec, 9, accuracy: 1e-9,
                       "course の無かった 3 秒を門外に数えない")
        XCTAssertEqual(f.insideEvidenceSec, 0, accuracy: 1e-9)
        XCTAssertEqual(f.quarantineState, .trusted, "門外 9 秒は distrust_sec = 12 に届かない")
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

        // 立ち止まって首を左右に大きく振る。fix は来るが course は無効(nil)
        t = feed(&f, fixes: 20, from: t + 0.1, p: p,
                 heading: { i in Double(184 + 80 * sin(Double(i) * 0.3)) },
                 course: { _ in nil })

        XCTAssertEqual(f.learnedOffsetDeg ?? .nan, offsetBefore ?? .nan, accuracy: 1e-9,
                       "止まっている間に学習値が動いてはいけない")
        XCTAssertEqual(f.concentration, concentrationBefore, accuracy: 1e-9,
                       "止まっている間に R が下がってはいけない")
        XCTAssertEqual(f.quarantineState, stateBefore,
                       "止まっている間に検疫の状態が変わってはいけない")
        // **証拠については要求を D6 に合わせた**(2026-09-10 の 2 回目の検証で指摘)。
        // 以前は「course が無い間は証拠も増減しない」と書いていたが、D6 は
        // 「上限を超えた欠落では未確定の証拠を捨てる」。20 秒の停止は上限 5 秒を超える。
        // 上限以内の停止で証拠を保つことは testLongCourseGapClearsEvidenceWithoutWaitingForCourse
        XCTAssertEqual(f.insideEvidenceSec, 0, accuracy: 1e-9,
                       "上限を超えて止まったら、未確定の証拠は捨てる(状態は変えない)")
        XCTAssertEqual(f.outsideEvidenceSec, 0, accuracy: 1e-9)
        XCTAssertEqual(f.use(at: t, p: p), .use, "首を回しても使えるまま(だから試験ができる)")
    }

    /// **course の途切れが上限を超えたら、有効な course の復帰を待たずに証拠を捨てる**
    /// (受け入れ条件 D6・2026-09-10 の 2 回目の検証で挙がった系列)。
    ///
    /// 学習後に門外 8 秒 → 最後の有効 course が t=13 → course の無い新しい fix を t=14〜19。
    /// 上限 5 秒なので、t=18 までは証拠を保ち、t=19 で門内 0・門外 0。状態は採用のまま。
    /// 有効な course が戻るまで待っていた版では、長い停止の間ずっと古い証拠が残っていた
    func testLongCourseGapClearsEvidenceWithoutWaitingForCourse() {
        let p = learnable(staleSec: 30, halfLifeSec: .infinity)
        var f = HeadMountFusion()
        for i in 0...5 { step(&f, fixTime: Double(i), heading: 184, course: 90, p: p) }
        for i in 6...13 { step(&f, fixTime: Double(i), heading: 304, course: 90, p: p) }
        XCTAssertEqual(f.outsideEvidenceSec, 8, accuracy: 1e-9, "前提: 門外 8 秒")
        for i in 14...18 { step(&f, fixTime: Double(i), heading: 304, course: nil, p: p) }
        XCTAssertEqual(f.outsideEvidenceSec, 8, accuracy: 1e-9, "上限(5 秒)以内の欠落では証拠を保つ")
        step(&f, fixTime: 19, heading: 304, course: nil, p: p)
        XCTAssertEqual(f.insideEvidenceSec, 0, accuracy: 1e-9)
        XCTAssertEqual(f.outsideEvidenceSec, 0, accuracy: 1e-9,
                       "上限を超えた時点で捨てる(有効な course の復帰を待たない)")
        XCTAssertEqual(f.quarantineState, .trusted, "欠落だけでは状態を変えない")
    }

    /// **位置更新そのものが止まっても、上限を超えたら証拠を捨てる**
    /// (受け入れ条件 D6・2026-09-10 の 3 回目の検証で挙がった系列)。
    ///
    /// 学習後に門外 8 秒(最後の有効 fix が t=13)→ 位置更新が止まり、同じ fix(13)を
    /// 読み続けながらコールバック時刻だけが 14〜19 と進む。t=18 までは門外 8 秒を保ち、
    /// t=19 で門内 0・門外 0。状態は採用のまま、学習値と R は全期間変わらない。
    /// fix の時刻だけで期限を測っていた版では、全部「同じ fix の読み直し」になり、
    /// t=19 でも門外 8 秒が残っていた
    func testEvidenceExpiresWhenLocationUpdatesStop() {
        let p = learnable(staleSec: 30, halfLifeSec: .infinity)
        var f = HeadMountFusion()
        for i in 0...5 { step(&f, fixTime: Double(i), heading: 184, course: 90, p: p) }
        for i in 6...13 { step(&f, fixTime: Double(i), heading: 304, course: 90, p: p) }
        let learned = try! XCTUnwrap(f.learnedOffsetDeg)
        let r = f.concentration
        XCTAssertEqual(f.outsideEvidenceSec, 8, accuracy: 1e-9, "前提: 門外 8 秒")
        for at in 14...18 {
            f.ingest(headingDeg: 304, rawCourseDeg: nil, fixTime: 13, at: Double(at), p: p)
            XCTAssertEqual(f.outsideEvidenceSec, 8, accuracy: 1e-9, "t=\(at): 上限以内は保つ")
            XCTAssertEqual(f.quarantineState, .trusted)
        }
        f.ingest(headingDeg: 304, rawCourseDeg: nil, fixTime: 13, at: 19, p: p)
        XCTAssertEqual(f.insideEvidenceSec, 0, accuracy: 1e-9)
        XCTAssertEqual(f.outsideEvidenceSec, 0, accuracy: 1e-9,
                       "fix が来なくても、上限を超えたら捨てる")
        XCTAssertEqual(f.quarantineState, .trusted, "期限切れだけでは状態を変えない")
        XCTAssertEqual(f.learnedOffsetDeg ?? .nan, learned, accuracy: 1e-12)
        XCTAssertEqual(f.concentration, r, accuracy: 1e-12)
        XCTAssertEqual(f.currentObservationLabel, "重複", "同じ fix の読み直しであることは変わらない")
    }

    /// **ログに「今回の観測が新規か重複か」と「最後の新 fix の分類」を別々に出せる**
    /// (受け入れ条件 E2・2026-09-10 の 2 回目の検証で挙がった系列)
    func testLogDistinguishesNewAndDuplicateObservations() {
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        XCTAssertEqual(f.currentObservationLabel, "fix無")
        step(&f, fixTime: 100, heading: 184, course: 90, p: p)
        XCTAssertEqual(f.currentObservationLabel, "新規")
        XCTAssertEqual(f.lastNewFixLabel, "始点")
        step(&f, fixTime: 100, heading: 184, course: 90, p: p)   // 同じ fix の読み直し
        XCTAssertEqual(f.currentObservationLabel, "重複")
        XCTAssertEqual(f.lastNewFixLabel, "始点", "読み直しでは最後の新 fix の分類は変わらない")
        step(&f, fixTime: 101, heading: 184, course: 90, p: p)
        XCTAssertEqual(f.currentObservationLabel, "新規")
        XCTAssertEqual(f.lastNewFixLabel, "学習")
    }

    // MARK: - A4 渡してよい course の定義

    /// **保持 course は「いま有効な生の course」ではない。**
    ///
    /// Controller はこの規則で course を選ぶ(`TravelDirection.courseObservation`)。
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

    /// **fix の時刻の無い course は証拠にならない。**
    /// 識別子の無い course を渡すと、重複排除ができないまま証拠が積まれる
    func testObservationWithoutAFixTimeIsNeverEvidence() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: false)
        let noTime = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 1.0,
                               compassHeadingDeg: 200, ageSec: 1, fixTime: nil)
        let obs = TravelDirection.courseObservation(noTime, params: loc)
        XCTAssertEqual(obs.courseDeg ?? .nan, 90, accuracy: 1e-9, "前提: 角度そのものは取れる")
        XCTAssertNil(obs.fixTime)
        let p = learnable(staleSec: 30)
        var f = HeadMountFusion()
        for i in 0..<100 {
            f.ingest(headingDeg: 184, rawCourseDeg: obs.courseDeg, fixTime: obs.fixTime,
                     at: Double(i) * 0.1, p: p)
        }
        XCTAssertNil(f.learnedOffsetDeg, "識別子の無い course から学習してはいけない")
    }

    /// 立ち止まった fix でも**時刻は観測に入る**(course だけが nil)。
    /// 時刻を捨てると、course の無い区間まで次の証拠に入ってしまう
    func testAStoppedFixStillCarriesItsTime() {
        let loc = AppParameters.Location(minSpeedForCourseMPerS: 0.7,
                                         maxCourseAccuracyDeg: 70,
                                         maxFixAgeSec: 10,
                                         courseHoldSec: 15,
                                         allowCompassFallback: false)
        let stopped = MotionFix(courseDeg: 90, courseAccuracyDeg: 10, speedMps: 0.1,
                                compassHeadingDeg: 200, ageSec: 1, fixTime: 1234)
        let obs = TravelDirection.courseObservation(stopped, params: loc)
        XCTAssertNil(obs.courseDeg)
        XCTAssertEqual(obs.fixTime ?? .nan, 1234, accuracy: 1e-9)
    }

    /// **製品と同じ course 抽出を通した系列で、停止が学習と検疫を壊さないこと。**
    ///
    /// 直接 nil を渡すテストだけでは配線の欠陥を捕まえられない
    /// (**問題はまさに nil が渡ってこなかったこと**だった。2026-09-08 の検証で指摘)。
    /// ここでは fix 列を `TravelDirection.courseObservation` に通し、
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
            let obs = TravelDirection.courseObservation(walking, params: loc)
            XCTAssertNotNil(obs.courseDeg, "前提: 歩いている fix からは生の course が取れる")
            for k in 0..<10 {
                t = 100 + Double(i) + Double(k) * 0.1
                f.ingest(headingDeg: 184, rawCourseDeg: obs.courseDeg, fixTime: obs.fixTime,
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
                                    fixTime: 120 + Double(i))
            let obs = TravelDirection.courseObservation(stopped, params: loc)
            XCTAssertNil(obs.courseDeg, "止まったら製品の規則では生の course は出ない")
            for k in 0..<10 {
                t = 120 + Double(i) + Double(k) * 0.1
                f.ingest(headingDeg: Double(184 + 80 * sin(t * 3)),
                         rawCourseDeg: obs.courseDeg, fixTime: obs.fixTime, at: t, p: p)
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
        XCTAssertNil(TravelDirection.courseObservation(stopped, params: loc).courseDeg,
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
