import XCTest
@testable import OtoSanpo

/// 音楽スポット(→ `MusicSpot`・docs/08)。連続音で方向が伝わるかを試すための実験の最小形。
///
/// 点の earcon は鳴った瞬間しか手がかりが無い。連続音なら聴きながら向きを直せる、
/// というのが方針 B / C の賭けで、それを 1 回の散歩で確かめるために作った。
final class MusicSpotTests: XCTestCase {

    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    private func params(min: Double = 60, max: Double = 100,
                        steps: Int = 1,
                        reached: Double = 15, step: Double = 30,
                        tolerance: Double = 0.001,
                        blend: Double = 0,
                        pinpointStart: Double = 15, pinpointFull: Double = 5,
                        beam: Double = 60, depth: Double = 12,
                        directivity: Double = 0,
                        rearStart: Double = 90, rearDepth: Double = 0,
                        height: Double = 0,
                        spreadFar: Double = 0, spreadNear: Double = 0) -> MusicSpot.Params {
        MusicSpot.Params(
            minDistanceM: min, maxDistanceM: max, distanceStepCount: steps,
            reachedM: reached,
            bearingStepDeg: step, sameDistanceToleranceM: tolerance,
            referenceDistanceM: 15, gainMinSpanM: 30,
            maxGain: 0.9, minGain: 0.08, routeBlend: blend,
            pinpointStartM: pinpointStart, pinpointFullM: pinpointFull,
            pinpointBeamDeg: beam, pinpointDepthDb: depth,
            directivityDepthDb: directivity,
            rearShelfStartDeg: rearStart, rearShelfDepthDb: rearDepth,
            listenerHeightM: height,
            spreadFarM: spreadFar, spreadNearM: spreadNear)
    }

    /// 音楽を待たせる時だけ、出発の一言に一文を足す(2026-09-10 利用者依頼)。
    /// **三種それぞれに書き写さない** — 音楽を選んでいない散歩では出さないため
    func testGreetingCarriesTheMusicNoteOnlyWhenAsked() {
        let windows = [AppParameters.GreetingWindow(fromHour: 7, toHour: 22,
                                                    message: "さぁ歩き始めましょう")]
        let plain = StartGreeting.message(hour: 10, windows: windows, musicNote: nil)
        XCTAssertEqual(plain, "さぁ歩き始めましょう", "音楽が無ければ一言だけ")

        let withNote = StartGreeting.message(hour: 10, windows: windows,
                                             musicNote: "音楽は後から流れ始めます。")
        XCTAssertEqual(withNote, "さぁ歩き始めましょう\n\n音楽は後から流れ始めます。")

        // 時間帯の一言が無くても、音楽の一文だけは出す(黙って待たせない)
        XCTAssertEqual(StartGreeting.message(hour: 3, windows: windows,
                                             musicNote: "音楽は後から流れ始めます。"),
                       "音楽は後から流れ始めます。")
        XCTAssertNil(StartGreeting.message(hour: 3, windows: windows, musicNote: nil))
    }

    /// **帯の外は選ばない**(下限も上限も散歩時間から決まる・2026-09-09)
    func testRejectsCandidatesOutsideTheBand() {
        let p = params(min: 60, max: 100)
        let tooNear = Geo.destination(from: origin, bearingDeg: 0, distanceM: 40)
        let inBand = Geo.destination(from: origin, bearingDeg: 90, distanceM: 85)
        let tooFar = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)
        let spot = MusicSpot.choose(from: [tooNear, tooFar, inBand], start: origin, p: p)
        XCTAssertEqual(spot?.center.longitude ?? 0, inBand.longitude, accuracy: 1e-9)
        XCTAssertNil(MusicSpot.choose(from: [tooNear, tooFar], start: origin, p: p),
                     "帯の中に候補が無ければ作らない")
    }

    /// **帯の中を何段かに分けて並べる。** 1 つの距離だけだと、道へ寄せた後に
    /// 帯から外れて候補が全滅しうる
    func testCandidatesSpanTheBandWhenAskedForSteps() {
        let p = params(min: 60, max: 100, steps: 3)
        let cs = MusicSpot.candidates(around: origin, p: p)
        XCTAssertEqual(cs.count, 12 * 3, "方位 12 × 距離 3 段")
        let ds = cs.map { Geo.distanceM(origin, $0) }
        XCTAssertEqual(ds.min() ?? 0, 60, accuracy: 1.0)
        XCTAssertEqual(ds.max() ?? 0, 100, accuracy: 1.0)
    }

    /// **同点の許容は設定で効く。**
    ///
    /// 許容より小さい差は同点として先頭を残し、大きい差なら後続へ乗り換える。
    /// これが 0 だと、同点の決まり方が浮動小数の誤差で決まる(2026-09-09 に踏んだ)
    func testTheSameDistanceToleranceDecidesWhoWins() {
        // 誤差 10 m の候補を先頭に、そこから 0.5 mm / 2 mm だけ良い候補を続ける
        let base = Geo.destination(from: origin, bearingDeg: 0, distanceM: 70)
        let slightlyBetter = Geo.destination(from: origin, bearingDeg: 90,
                                             distanceM: 70 + 0.0005)
        let clearlyBetter = Geo.destination(from: origin, bearingDeg: 180, distanceM: 70 + 0.002)

        let p = params(min: 60, max: 100, tolerance: 0.001)
        // 0.5 mm 差は同点 → 先頭が残る
        let tied = MusicSpot.choose(from: [base, slightlyBetter], start: origin, p: p)
        XCTAssertEqual(tied?.center.latitude ?? 0, base.latitude, accuracy: 1e-9)
        // 2 mm 差なら乗り換える
        let better = MusicSpot.choose(from: [base, clearlyBetter], start: origin, p: p)
        XCTAssertEqual(better?.center.latitude ?? 0, clearlyBetter.latitude, accuracy: 1e-9)
        // 許容を広げれば 2 mm 差も同点になる
        let wide = MusicSpot.choose(from: [base, clearlyBetter], start: origin,
                                    p: params(min: 60, max: 100, tolerance: 0.01))
        XCTAssertEqual(wide?.center.latitude ?? 0, base.latitude, accuracy: 1e-9)
    }

    /// 刻みが 0 以下なら候補を作らない。**既定値で埋めない**(設定の誤りに気づけなくなる)
    func testNoCandidatesWhenTheBearingStepIsNotPositive() {
        XCTAssertTrue(MusicSpot.candidates(around: origin, p: params(step: 0)).isEmpty)
        XCTAssertTrue(MusicSpot.candidates(around: origin, p: params(step: -30)).isEmpty)
        XCTAssertNil(MusicSpot.choose(from: [], start: origin, p: params()),
                     "候補が無ければスポットも作らない")
    }

    /// 候補は**方位を刻んで並べる**。同じ出発点なら毎回同じ並びになる(再現できること)
    func testCandidatesAreDeterministicAndAtTheTargetDistance() {
        let p = params()
        let a = MusicSpot.candidates(around: origin, p: p)
        let b = MusicSpot.candidates(around: origin, p: p)
        XCTAssertEqual(a.count, 12, "30° 刻みなら 12 点")
        XCTAssertEqual(a, b, "同じ入力からは同じ候補が出ること")
        for c in a {
            XCTAssertEqual(Geo.distanceM(origin, c), p.targetDistanceM, accuracy: 1.0)
        }
    }

    /// **上限を超える候補は選ばない**(「100 m 以内に 1 つ」という約束)
    func testNeverChoosesBeyondTheLimit() {
        let p = params(min: 60, max: 100)
        let far = Geo.destination(from: origin, bearingDeg: 0, distanceM: 300)
        let near = Geo.destination(from: origin, bearingDeg: 90, distanceM: 85)
        let spot = MusicSpot.choose(from: [far, near], start: origin, p: p)
        XCTAssertEqual(spot?.center.latitude ?? 0, near.latitude, accuracy: 1e-9)
        XCTAssertEqual(spot?.center.longitude ?? 0, near.longitude, accuracy: 1e-9)

        XCTAssertNil(MusicSpot.choose(from: [far], start: origin, p: p),
                     "上限の外しか無ければ作らない")
    }

    /// 狙う距離にいちばん近いものを選ぶ。**同点は候補の並び順で決める**(再現のため)
    func testChoosesTheCandidateClosestToTheTargetDistanceAndBreaksTiesByOrder() {
        let p = params(min: 60, max: 100)
        let first = Geo.destination(from: origin, bearingDeg: 0, distanceM: 70)
        let second = Geo.destination(from: origin, bearingDeg: 90, distanceM: 90)
        let best = Geo.destination(from: origin, bearingDeg: 180, distanceM: 81)
        let spot = MusicSpot.choose(from: [first, second, best], start: origin, p: p)
        XCTAssertEqual(spot?.center.latitude ?? 0, best.latitude, accuracy: 1e-9)

        // 同点は先に並んでいる方(= 方位の小さい方)。
        // **同じ距離で組む。** 「狙い −10 m と +10 m」は同点にならない —
        // `Geo.destination` は平面近似、`distanceM` は haversine で、
        // 往復すると距離がわずかに縮む。その分だけ遠い側が有利になる
        let tieA = Geo.destination(from: origin, bearingDeg: 0, distanceM: 70)
        let tieB = Geo.destination(from: origin, bearingDeg: 90, distanceM: 70)
        XCTAssertEqual(Geo.distanceM(origin, tieA), Geo.distanceM(origin, tieB), accuracy: 1e-6,
                       "前提: この 2 点は同じ距離にある")
        let tie = MusicSpot.choose(from: [tieA, tieB], start: origin, p: p)
        XCTAssertEqual(tie?.center.latitude ?? 0, tieA.latitude, accuracy: 1e-9,
                       "同点なら先に並んでいる方(再現できること)")
        // 並びを逆にすれば逆が選ばれる = 順序で決まっていることの裏取り
        let reversed = MusicSpot.choose(from: [tieB, tieA], start: origin, p: p)
        XCTAssertEqual(reversed?.center.longitude ?? 0, tieB.longitude, accuracy: 1e-9)
    }

    /// **前半球へ畳まない**(2026-09-08 利用者判断)。
    /// 通り過ぎれば後ろにあるのが自然で、畳むと通り過ぎたことが分からなくなる
    func testPlacementIsNotFoldedToTheFrontHemisphere() {
        let p = params()
        // 真北 80 m にスポット。南(180°)を向いていれば、音源は真後ろ
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        let placed = spot.placement(from: origin, referenceBearingDeg: 180,
                                    gainFromDistanceM: 80, p: p)
        XCTAssertEqual(abs(placed.relDeg), 180, accuracy: 1.0,
                       "真後ろは真後ろのまま返る(畳まない)")
        // 参考: earcon の経路なら前へ畳まれる。ここを通らないことが今回の要点
        XCTAssertEqual(abs(SoundPlacement.foldToFrontDeg(placed.relDeg)), 0, accuracy: 1.0)
    }

    /// 右手 90° のスポットは +90°、左手は −90°
    func testPlacementKeepsLeftAndRight() {
        let p = params()
        let right = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 90, distanceM: 80))
        XCTAssertEqual(right.placement(from: origin, referenceBearingDeg: 0,
                                       gainFromDistanceM: 80, p: p).relDeg,
                       90, accuracy: 1.0)
        let left = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 270, distanceM: 80))
        XCTAssertEqual(left.placement(from: origin, referenceBearingDeg: 0,
                                      gainFromDistanceM: 80, p: p).relDeg,
                       -90, accuracy: 1.0)
    }

    // MARK: - 音量(2026-09-11 に要求が変わった)
    //
    // 以前は逆二乗則で、「近いほど急に変わる」ことを検査していた。3 本の散歩(2026-09-10)で
    // 音楽はスポットから 135 m / 95 m / 43 m の所で鳴り始め、遠い側では 10 m 近づいても
    // 1 dB に満たず、「音量の変化が見られない」と言われた。利用者の依頼で、
    // **鳴り始めた地点の距離に応じて 10 m あたりの差を決める**形に変えた。
    // 期待値を緩めたのではなく、検査する性質そのもの(近いほど急 → 起点から一定)が変わっている。

    /// **鳴り始めた距離で最小、スポットの手前で最大。** 聞こえ始めてから着くまでに幅を使い切る
    func testGainSpansFromTheStartDistanceToTheSpot() {
        let p = params()
        XCTAssertEqual(p.gain(atDistanceM: 95, fromDistanceM: 95), p.minGain, accuracy: 1e-9,
                       "鳴り始めた地点では最小")
        XCTAssertEqual(p.gain(atDistanceM: 15, fromDistanceM: 95), p.maxGain, accuracy: 1e-9,
                       "スポットの手前で最大")
        XCTAssertEqual(p.gain(atDistanceM: 5, fromDistanceM: 95), p.maxGain, accuracy: 1e-9,
                       "手前より近くても最大のまま")
        XCTAssertEqual(p.gain(atDistanceM: 200, fromDistanceM: 95), p.minGain, accuracy: 1e-9,
                       "起点より遠ざかっても最小のまま(床)")
    }

    /// **10 m あたりの差は、起点からスポットの手前まで一定**で、起点が遠いほど小さい
    func testDecibelsPer10mDependOnTheStartDistance() {
        let p = params()
        let range = 20 * log10(p.maxGain / p.minGain)   // 約 21 dB
        // 散歩 3 は 43 m で鳴り始めた。最小の長さ(15 + 30 = 45 m)より近いので、
        // 幅は 30 m に広げて割り振る(10 m で 7.0 dB。28 m で割れば 7.5 dB になる所)
        XCTAssertEqual(p.decibelsPer10m(fromDistanceM: 43), range * 10 / 30, accuracy: 1e-9)
        // 散歩 1・2 の鳴り始め(2026-09-10)。どちらも最小の長さより遠い
        for start in [135.0, 95] {
            let expected = range * 10 / (start - 15)
            XCTAssertEqual(p.decibelsPer10m(fromDistanceM: start), expected, accuracy: 1e-9)
            // どこで測っても同じ差(dB で均等)
            for d in stride(from: start, through: 25, by: -10) {
                let far = p.gain(atDistanceM: d, fromDistanceM: start)
                let near = p.gain(atDistanceM: d - 10, fromDistanceM: start)
                XCTAssertEqual(20 * log10(near / far), expected, accuracy: 1e-9,
                               "\(Int(start))m で鳴り始め・\(Int(d))m から 10m 近づく")
            }
        }
        XCTAssertGreaterThan(p.decibelsPer10m(fromDistanceM: 43),
                             p.decibelsPer10m(fromDistanceM: 135),
                             "近くで鳴り始めた散歩ほど 10m の差が大きい")
        // 95 m で鳴り始めた散歩なら 10 m で 2.6 dB(人が気づく 1 dB を大きく超える)
        XCTAssertEqual(p.decibelsPer10m(fromDistanceM: 95), 2.6, accuracy: 0.05)
    }

    /// 起点がスポットのすぐ近くでも、**最小の長さまで広げる**(1 歩で音量が跳ばない)
    func testShortStartDistanceIsWidenedToTheMinimumSpan() {
        let p = params()   // gainMinSpanM = 30
        XCTAssertEqual(p.decibelsPer10m(fromDistanceM: 20),
                       20 * log10(p.maxGain / p.minGain) * 10 / 30, accuracy: 1e-9)
        XCTAssertEqual(p.gain(atDistanceM: 45, fromDistanceM: 20), p.minGain, accuracy: 1e-9,
                       "広げた先(15 + 30 m)で最小")
        XCTAssertTrue(p.gain(atDistanceM: 20, fromDistanceM: 20).isFinite)
    }

    /// 音量は距離に対して**連続**で、近づくほど大きい(段が無い)
    func testGainIsContinuousAndRisesAsYouApproach() {
        let p = params()
        var previous = p.gain(atDistanceM: 300, fromDistanceM: 135)
        for metres in stride(from: 299.0, through: 0.0, by: -1.0) {
            let g = p.gain(atDistanceM: metres, fromDistanceM: 135)
            XCTAssertGreaterThanOrEqual(g, previous - 1e-12, "近づいて小さくなってはいけない")
            XCTAssertLessThan(g / previous, 1.1, "\(Int(metres))m で音量が飛んでいる(1m で 10% 超)")
            previous = g
        }
    }

    /// `placement` は起点を渡した音量を返す
    func testPlacementUsesTheStartDistanceForGain() {
        let p = params()
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 95))
        let atStart = spot.placement(from: origin, referenceBearingDeg: 0,
                                     gainFromDistanceM: 95, p: p)
        XCTAssertEqual(atStart.gain, p.minGain, accuracy: 1e-3, "鳴り始めた地点では最小")
        let closer = spot.placement(from: Geo.destination(from: origin, bearingDeg: 0,
                                                          distanceM: 80),
                                    referenceBearingDeg: 0, gainFromDistanceM: 95, p: p)
        XCTAssertGreaterThan(closer.gain, atStart.gain, "15m 近づけば大きくなる")
    }

    /// **直線の向きと道をたどる向きの間**から鳴らす(2026-09-10 利用者依頼)。
    /// 角度は円周上の量なので、線形に混ぜてはいけない
    func testBlendsTheDirectAndRouteBearings() {
        XCTAssertEqual(MusicSpot.blend(direct: 0, route: 90, weight: 0.5), 45, accuracy: 0.5)
        XCTAssertEqual(MusicSpot.blend(direct: 0, route: 90, weight: 0), 0, accuracy: 1e-9,
                       "0 なら直線だけ")
        XCTAssertEqual(MusicSpot.blend(direct: 0, route: 90, weight: 1), 90, accuracy: 0.5,
                       "1 なら道だけ")
        // 350° と 10° の中間は 0°(平均の 180° ではない)。
        // **0° と 360° は同じ向き**なので、差で見る
        XCTAssertEqual(abs(Geo.angularDiffDeg(MusicSpot.blend(direct: 350, route: 10,
                                                              weight: 0.5), 0)),
                       0, accuracy: 0.5)
        // 道が取れなければ直線のまま
        XCTAssertEqual(MusicSpot.blend(direct: 123, route: nil, weight: 0.5), 123, accuracy: 1e-9)
        // 真反対を等分に混ぜると向きが決まらない。その時は直線を採る
        XCTAssertEqual(MusicSpot.blend(direct: 0, route: 180, weight: 0.5), 0, accuracy: 1e-9)
    }

    /// 混ぜた向きが `placement` の結果に効く
    func testPlacementUsesTheBlendedBearing() {
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        // 直線は北(0°)、道は東(90°)。半々なら北東(45°)から鳴る
        let placed = spot.placement(from: origin, referenceBearingDeg: 0,
                                    routeBearingDeg: 90, gainFromDistanceM: 80,
                                    p: params(blend: 0.5))
        XCTAssertEqual(placed.worldBearingDeg, 45, accuracy: 1.0)
        XCTAssertEqual(placed.relDeg, 45, accuracy: 1.0)
    }

    // MARK: - ピンポイント(2026-09-15 利用者依頼)
    //
    // 「スポットに近づいても最終的にどこにあるか分かりにくい」「5 m 以内でピンポイントに
    // 位置を感じられるように」。2026-09-14 の散歩では、GPS の誤差 14 m・最接近 6 m で、
    // 15 m より内側は音量が 24 秒間まったく変わらず、方位は道の向きの切り替わりで
    // 1 秒に 45〜51° 跳んだ。そこで近くでは (1) 正面に向けた時だけ大きく鳴らし、
    // (2) 道の向きを混ぜない。効果は 15 m から効き始め、5 m 以内で最大になる。

    /// **近さは 15 m から効き始め、5 m 以内で最大**。間は距離に比例する
    func testPinpointWeightRampsFromStartToFull() {
        let p = params()
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 40), 0)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 15), 0, accuracy: 1e-12)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 10), 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 6), 0.9, accuracy: 1e-12,
                       "実測の最接近 6 m でも 9 割効く(5 m で急に切り替えると一度も発動しない)")
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 5), 1, accuracy: 1e-12)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 0), 1)
        var previous = p.pinpointWeight(atDistanceM: 30)
        for d in stride(from: 29.5, through: 0, by: -0.5) {
            let w = p.pinpointWeight(atDistanceM: d)
            XCTAssertGreaterThanOrEqual(w, previous, "近づいて弱まってはいけない(\(d)m)")
            previous = w
        }
    }

    /// 始まりと最大が逆転・一致した設定では、最大の距離を境に 0 / 1 で切り替える
    /// (0 で割らない・既定値で黙って埋めない)
    func testPinpointWeightWithDegenerateSettings() {
        let p = params(pinpointStart: 5, pinpointFull: 5)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 5), 1)
        XCTAssertEqual(p.pinpointWeight(atDistanceM: 5.01), 0)
        XCTAssertTrue(p.pinpointWeight(atDistanceM: 3).isFinite)
        // **逆転**(始まりが最大より近い)も同じ扱い(2026-09-15 の検証で挙がった系列)
        let reversed = params(pinpointStart: 4, pinpointFull: 5)
        XCTAssertEqual(reversed.pinpointWeight(atDistanceM: 5), 1)
        XCTAssertEqual(reversed.pinpointWeight(atDistanceM: 4.5), 1)
        XCTAssertEqual(reversed.pinpointWeight(atDistanceM: 5.01), 0)
        for d in stride(from: 0.0, through: 10, by: 0.25) {
            XCTAssertTrue(reversed.pinpointWeight(atDistanceM: d).isFinite, "\(d)m")
        }
    }

    /// **正面で 0 dB、外れるほど深く、`beam` 以上外れたら一定。左右は対称**
    func testFacingDbDeepensOffAxis() {
        let p = params(beam: 60, depth: 12)
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 0, weight: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 30, weight: 1), -6, accuracy: 1e-12)
        XCTAssertEqual(p.facingDb(relativeBearingDeg: -30, weight: 1), -6, accuracy: 1e-12,
                       "左右で同じ")
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 60, weight: 1), -12, accuracy: 1e-12)
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 120, weight: 1), -12, accuracy: 1e-12)
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 180, weight: 1), -12, accuracy: 1e-12,
                       "真後ろは正面より 12 dB 小さい = 前後が音量で分かる")
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 350, weight: 1), -2, accuracy: 1e-9,
                       "350° は正面から 10° 外れ(折り返しを跨ぐ)")
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 60, weight: 0.5), -6, accuracy: 1e-12,
                       "近さ半分なら深さも半分")
        XCTAssertEqual(p.facingDb(relativeBearingDeg: 180, weight: 0), 0, "遠くでは掛けない")
        XCTAssertEqual(params(depth: 0).facingDb(relativeBearingDeg: 180, weight: 1), 0)
    }

    /// **スポットの近くで首を 1 周振ると、音量の山がスポットの向きにちょうど 1 つだけある**。
    /// これが「ピンポイントに位置を感じられる」の中身(首を振って探す)
    func testHeadScanPeaksAtTheSpot() {
        let p = params()
        // 聴取者から見て北東 45° に 4 m
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 45, distanceM: 4))
        var best = (heading: -1, gain: -1.0)
        var quietest = Double.infinity
        for heading in 0..<360 {
            let placed = spot.placement(from: origin, referenceBearingDeg: Double(heading),
                                        headIsReference: true, gainFromDistanceM: 90, p: p)
            if placed.gain > best.gain { best = (heading, placed.gain) }
            quietest = Swift.min(quietest, placed.gain)
        }
        XCTAssertEqual(Double(best.heading), 45, accuracy: 1, "山はスポットの向き")
        XCTAssertEqual(20 * log10(best.gain / quietest), 12, accuracy: 0.01,
                       "向けた時と外した時で 12 dB 違う")
        // 山は 1 つ: スポットの向きから離れるほど単調に小さくなる(左右どちらへ回っても)
        for side in [1.0, -1.0] {
            var previous = best.gain
            for off in stride(from: 1.0, through: 180, by: 1) {
                let placed = spot.placement(from: origin, referenceBearingDeg: 45 + side * off,
                                            headIsReference: true, gainFromDistanceM: 90, p: p)
                XCTAssertLessThanOrEqual(placed.gain, previous + 1e-12,
                                         "外れる向きへ回して大きくなってはいけない(\(side * off)°)")
                previous = placed.gain
            }
        }
    }

    /// **基準が頭の向きでない時は強調しない**(首を振っても基準が動かず、探せないため)
    func testFacingEmphasisOnlyWhenHeadIsTheReference() {
        let p = params()
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 3))
        let byTravel = spot.placement(from: origin, referenceBearingDeg: 180,
                                      headIsReference: false, gainFromDistanceM: 90, p: p)
        XCTAssertEqual(byTravel.facingDb, 0)
        XCTAssertEqual(byTravel.gain, byTravel.distanceGain, accuracy: 1e-12)
        let byHead = spot.placement(from: origin, referenceBearingDeg: 180,
                                    headIsReference: true, gainFromDistanceM: 90, p: p)
        XCTAssertEqual(byHead.facingDb, -12, accuracy: 1e-9)
        XCTAssertEqual(byHead.gain, byHead.distanceGain * pow(10, -12.0 / 20), accuracy: 1e-12)
        XCTAssertEqual(byHead.pinpointWeight, 1, accuracy: 1e-12)
    }

    /// **遠くでは何も変わらない**(近づく間の体験は 2026-09-11 の形のまま)
    func testNothingChangesBeyondThePinpointStart() {
        let p = params(blend: 0.5)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 40))
        for heading in stride(from: 0.0, to: 360, by: 15) {
            let placed = spot.placement(from: origin, referenceBearingDeg: heading,
                                        headIsReference: true, routeBearingDeg: 90,
                                        gainFromDistanceM: 90, p: p)
            XCTAssertEqual(placed.facingDb, 0)
            XCTAssertEqual(placed.gain, placed.distanceGain, accuracy: 1e-12)
            XCTAssertEqual(placed.worldBearingDeg, MusicSpot.blend(direct: 0, route: 90, weight: 0.5),
                           accuracy: 1e-9, "遠くでは道の向きを混ぜる比もそのまま")
        }
    }

    /// **スポットの近くでは道の向きを混ぜない**(2026-09-14 の散歩で、混ぜた方位が
    /// 道の向きの切り替わりで 1 秒に 45〜51° 跳んだ。直線の方位は滑らかだった)
    func testRouteIsNotBlendedNearTheSpot() {
        let p = params(blend: 0.5)
        func world(at d: Double) -> Double {
            let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: d))
            return spot.placement(from: origin, referenceBearingDeg: 0, routeBearingDeg: 90,
                                  gainFromDistanceM: 90, p: p).worldBearingDeg
        }
        XCTAssertEqual(abs(Geo.angularDiffDeg(world(at: 4), 0)), 0, accuracy: 0.01,
                       "5 m 以内は直線の方位だけ")
        // 10 m では混ぜる比がほぼ半分。**期待値は実際に測った距離から出す** —
        // `Geo.destination`(平面近似)で置いた点を `Geo.distanceM`(haversine)で測ると
        // わずかに短く、近さがちょうど 0.5 にはならない(許容を広げて誤魔化さない)
        let tenM = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 10))
        let measured = Geo.distanceM(origin, tenM.center)
        // 往復の誤差は 10 m で約 1.1 cm(実測 9.989 m)。前提の確認なので数 cm を許す
        XCTAssertEqual(measured, 10, accuracy: 0.05, "前提: ほぼ 10 m に置けている")
        XCTAssertEqual(world(at: 10),
                       MusicSpot.blend(direct: 0, route: 90,
                                       weight: 0.5 * (1 - p.pinpointWeight(atDistanceM: measured))),
                       accuracy: 1e-9, "混ぜる比 = routeBlend × (1 − 近さ)")
        // 近いほど道の向きの切り替わりに振られない。**実測と同じ形**で組む:
        // 直線の方位をはさんで、道の向きが −22° → +74° と 96° 切り替わる
        // (00:19:10 は直線 141° に対し道 119° → 215°。混ぜた方位が 48〜51° 跳んだ)
        func jump(at d: Double) -> Double {
            let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: d))
            let before = spot.placement(from: origin, referenceBearingDeg: 0, routeBearingDeg: -22,
                                        gainFromDistanceM: 90, p: p).worldBearingDeg
            let after = spot.placement(from: origin, referenceBearingDeg: 0, routeBearingDeg: 74,
                                       gainFromDistanceM: 90, p: p).worldBearingDeg
            return abs(Geo.angularDiffDeg(after, before))
        }
        XCTAssertEqual(jump(at: 20), 48, accuracy: 1, "前提: 遠くでは実測どおり約 48° 跳ぶ")
        XCTAssertLessThan(jump(at: 12), 35)
        XCTAssertLessThan(jump(at: 8), 15)
        XCTAssertEqual(jump(at: 5), 0, accuracy: 0.01, "5 m 以内は道の向きが変わっても動かない")
    }

    /// 強調は距離にも角度にも**連続**(段が無い・近づく途中で急に鳴り方が変わらない)
    func testPinpointEmphasisIsContinuous() {
        let p = params()
        var previous = p.facingDb(relativeBearingDeg: 90, weight: p.pinpointWeight(atDistanceM: 20))
        for d in stride(from: 19.9, through: 0, by: -0.1) {
            let db = p.facingDb(relativeBearingDeg: 90, weight: p.pinpointWeight(atDistanceM: d))
            XCTAssertLessThan(abs(db - previous), 0.2, "\(d)m で強調が跳んだ")
            previous = db
        }
        previous = p.facingDb(relativeBearingDeg: -180, weight: 1)
        for deg in stride(from: -179.0, through: 180, by: 1) {
            let db = p.facingDb(relativeBearingDeg: deg, weight: 1)
            XCTAssertLessThan(abs(db - previous), 0.21, "\(deg)° で強調が跳んだ")
            previous = db
        }
    }

    // MARK: - 向きで音量を割り振る(2026-09-18 利用者判断)
    //
    // 「左右のイヤホンの合計音量がほぼ一定なので、左右に偏った時しか分からない」。
    // 合計を一定に保たず、正面を大きく・後ろを小さくする(頭の影と注意の向きに倣う)。

    /// 正面 0・真横で半分・真後ろで最大。**距離によらず掛かる**
    func testDirectivityIsDeepestBehind() {
        let p = params(directivity: 9)
        XCTAssertEqual(p.directivityDb(relativeBearingDeg: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(p.directivityDb(relativeBearingDeg: 90), -4.5, accuracy: 1e-9)
        XCTAssertEqual(p.directivityDb(relativeBearingDeg: 180), -9, accuracy: 1e-9)
        XCTAssertEqual(p.directivityDb(relativeBearingDeg: -90), -4.5, accuracy: 1e-9,
                       "左右で同じ")
        XCTAssertEqual(p.directivityDb(relativeBearingDeg: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(params(directivity: 0).directivityDb(relativeBearingDeg: 180), 0,
                       "0 なら何もしない")
    }

    /// **首を回すと滑らかに変わる。** 段があると「壁」に聞こえる
    func testDirectivityIsSmoothAllTheWayAround() {
        let p = params(directivity: 9)
        var previous = p.directivityDb(relativeBearingDeg: -180)
        for deg in stride(from: -179.0, through: 180, by: 1) {
            let db = p.directivityDb(relativeBearingDeg: deg)
            XCTAssertLessThan(abs(db - previous), 0.2, "\(deg)° で跳んだ")
            previous = db
        }
    }

    /// **正面と背後で、実際に鳴る音量が違うこと。**
    /// これが前回の散歩で足りなかったもの(前後が分からず、左右に振らないと分からなかった)
    func testPlacementIsQuieterBehindThanInFront() {
        let p = params(directivity: 9)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        let front = spot.placement(from: origin, referenceBearingDeg: 0,
                                   gainFromDistanceM: 90, p: p)
        let side = spot.placement(from: origin, referenceBearingDeg: 90,
                                  gainFromDistanceM: 90, p: p)
        let behind = spot.placement(from: origin, referenceBearingDeg: 180,
                                    gainFromDistanceM: 90, p: p)
        XCTAssertEqual(front.distanceGain, behind.distanceGain, accuracy: 1e-12,
                       "距離ぶんの音量は同じ(変えたのは割り振りだけ)")
        XCTAssertGreaterThan(front.gain, side.gain)
        XCTAssertGreaterThan(side.gain, behind.gain)
        XCTAssertEqual(20 * log10(front.gain / behind.gain), 9, accuracy: 0.01,
                       "正面と真後ろで 9 dB 違う")
    }

    // MARK: - 後ろの音を暗くする(2026-09-18 利用者依頼「前後が弱い」)

    /// **正面から真横までは何も変えない。** そこから真後ろへ向けて滑らかに深くなる
    func testRearShelfOnlyDarkensBehind() {
        let p = params(rearStart: 90, rearDepth: 6)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 0), 0)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 60), 0)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 90), 0)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 135), -3, accuracy: 1e-9,
                       "真横と真後ろの中間で半分")
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 180), -6, accuracy: 1e-9)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: -135), -3, accuracy: 1e-9,
                       "左右で同じ")
        // 折り返しを跨いでも同じ扱い(200° は正面から 160° 外れ = −160° と同じ)
        XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: 200),
                       p.rearShelfDb(relativeBearingDeg: -160), accuracy: 1e-12)
        XCTAssertLessThan(p.rearShelfDb(relativeBearingDeg: 200), -5, "後ろ側は深い")
    }

    /// **境目で音色が跳ばない。** 真横をまたぐ所で急に暗くなると「壁」に聞こえる
    func testRearShelfIsContinuous() {
        let p = params(rearStart: 90, rearDepth: 6)
        var previous = p.rearShelfDb(relativeBearingDeg: 0)
        for deg in stride(from: 1.0, through: 180, by: 1) {
            let db = p.rearShelfDb(relativeBearingDeg: deg)
            XCTAssertLessThan(abs(db - previous), 0.15, "\(deg)° で跳んだ")
            XCTAssertLessThanOrEqual(db, previous + 1e-12, "後ろへ回るほど深くなること")
            previous = db
        }
    }

    /// 深さ 0 なら何もしない(切ってある時に余計な処理をしない)
    func testRearShelfIsOffWhenDepthIsZero() {
        let p = params(rearStart: 90, rearDepth: 0)
        for deg in stride(from: -180.0, through: 180, by: 15) {
            XCTAssertEqual(p.rearShelfDb(relativeBearingDeg: deg), 0, "\(deg)°")
        }
    }

    /// 置き方の結果にも入る(画面で切る判断は Controller 側が行う)
    func testPlacementCarriesTheRearShelf() {
        let p = params(rearStart: 90, rearDepth: 6)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        // 北のスポットに背を向ける(南を向く)= 真後ろ
        let behind = spot.placement(from: origin, referenceBearingDeg: 180,
                                    gainFromDistanceM: 90, p: p)
        XCTAssertEqual(behind.rearShelfDb, -6, accuracy: 1e-9)
        let front = spot.placement(from: origin, referenceBearingDeg: 0,
                                   gainFromDistanceM: 90, p: p)
        XCTAssertEqual(front.rearShelfDb, 0)
    }

    /// 着いたら止める(**一度だけ鳴る**という約束)
    func testReachedInsideTheRadius() {
        let p = params(reached: 15)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        XCTAssertFalse(spot.isReached(from: origin, p: p))
        let close = Geo.destination(from: origin, bearingDeg: 0, distanceM: 70)
        XCTAssertTrue(spot.isReached(from: close, p: p))
    }

    // MARK: - 下から鳴る / 広がり(2026-09-18 利用者依頼)

    /// **地面のスポットへ近づくと、音が下から来る**。
    /// 耳の高さ 1.5 m に対し、水平距離から `−atan(h/d)`
    func testElevationDeepensAsYouApproach() {
        let p = params(height: 1.5)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 50), -1.72, accuracy: 0.05)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 10), -8.53, accuracy: 0.05)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 5), -16.70, accuracy: 0.05)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 1.5), -45.0, accuracy: 0.05)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 0), -90.0, accuracy: 0.05,
                       "真上に立ったら真下から鳴る")
    }

    /// **仰角は水平距離だけで決まるので、位置の誤差に強い。**
    /// 同じ 3 m のずれでも、遠い所では方位の方がはるかに大きく振れる
    func testElevationIsRobustToPositionErrorComparedWithBearing() {
        let p = params(height: 1.5)
        // 20 m 先で 3 m ずれた時、仰角は 1° 以内しか動かない
        let near = p.elevationDeg(horizontalDistanceM: 17)
        let far = p.elevationDeg(horizontalDistanceM: 23)
        XCTAssertLessThan(abs(near - far), 1.5, "仰角の振れは 1.5° 未満")
        // 同じ条件の方位は ±8.5° 振れる(atan(3/20))
        let bearingSwing = atan(3.0 / 20.0) * 180 / .pi
        XCTAssertGreaterThan(bearingSwing, 8, "方位はこれだけ振れる(比較)")
    }

    /// 耳の高さ 0 なら仰角を付けない(設定で切れる)
    func testZeroHeightMeansNoElevation() {
        let p = params(height: 0)
        XCTAssertEqual(p.elevationDeg(horizontalDistanceM: 5), 0)
    }

    /// **遠いと広く、近いと一点**。境目で折れない
    func testSpreadNarrowsAsYouApproach() {
        let p = params(spreadFar: 60, spreadNear: 5)
        XCTAssertEqual(p.spread(atDistanceM: 100), 1, accuracy: 1e-9, "遠くでは一番広い")
        XCTAssertEqual(p.spread(atDistanceM: 60), 1, accuracy: 1e-9)
        XCTAssertEqual(p.spread(atDistanceM: 32.5), 0.5, accuracy: 0.01, "中間でちょうど半分")
        XCTAssertEqual(p.spread(atDistanceM: 5), 0, accuracy: 1e-9, "近くでは一点")
        XCTAssertEqual(p.spread(atDistanceM: 1), 0, accuracy: 1e-9)
        // 単調に減ること
        var previous = 1.1
        for d in stride(from: 60.0, through: 5.0, by: -2.5) {
            let s = p.spread(atDistanceM: d)
            XCTAssertLessThanOrEqual(s, previous)
            previous = s
        }
    }

    /// 設定が噛み合っていなければ広がりを使わない(0 のまま)
    func testSpreadIsOffWhenTheRangeIsNotSet() {
        XCTAssertEqual(params(spreadFar: 0, spreadNear: 0).spread(atDistanceM: 30), 0)
        XCTAssertEqual(params(spreadFar: 5, spreadNear: 60).spread(atDistanceM: 30), 0,
                       "遠近が逆なら効かせない")
    }

    /// 置いた結果にも両方が載る
    func testPlacementCarriesElevationAndSpread() {
        let p = params(height: 1.5, spreadFar: 60, spreadNear: 5)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 10))
        let placed = spot.placement(from: origin, referenceBearingDeg: 0,
                                    gainFromDistanceM: 90, p: p)
        XCTAssertEqual(placed.elevationDeg, -8.53, accuracy: 0.1)
        XCTAssertEqual(placed.spread, p.spread(atDistanceM: placed.distanceM), accuracy: 1e-9)
    }

    /// **3D の位置に仰角が載り、距離(= 音量)は変わらない**
    func testPositionCarriesElevationWithoutChangingTheRadius() {
        let flat = SoundPlacement.position(relativeBearingDeg: 90)
        let down = SoundPlacement.position(relativeBearingDeg: 90, elevationDeg: -45)
        XCTAssertEqual((flat.x * flat.x + flat.y * flat.y + flat.z * flat.z).squareRoot(), 1,
                       accuracy: 1e-9)
        XCTAssertEqual((down.x * down.x + down.y * down.y + down.z * down.z).squareRoot(), 1,
                       accuracy: 1e-9, "仰角を付けても半径は 1 のまま(音量が変わらない)")
        XCTAssertLessThan(down.y, 0, "下に置かれること")
        XCTAssertGreaterThan(down.x, 0, "右のまま")
    }

    // MARK: - 置き直す時の選び方(2026-09-18 利用者依頼「特定の箇所に固まらないように」)

    /// **これまでに置いた所の近くは選ばない**(→ 合議 M2)
    func testSpreadChoiceAvoidsPreviousSpots() {
        let p = params(min: 60, max: 100, steps: 1)
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 80)
        let candidates = MusicSpot.candidates(around: origin, p: p)
        // 北を避けると、北の候補は 1 つも選ばれない
        for i in 0..<12 {
            let spot = MusicSpot.chooseSpread(from: candidates, start: origin,
                                              avoiding: [north], minSeparationM: 20,
                                              p: p, pick: { _ in i })
            XCTAssertNotNil(spot)
            XCTAssertGreaterThanOrEqual(Geo.distanceM(spot!.center, north), 20)
        }
    }

    /// ちょうどの距離は許す(→ 合議 M2)。
    ///
    /// **期待値は測った距離から作る。** `destination` で 20 m 先を作っても、
    /// `distanceM` で測り返すと 20 m ちょうどにはならない(平面近似と haversine の往復)
    func testExactlyTheSeparationIsAllowed() {
        let p = params(min: 60, max: 100, steps: 1)
        let spotPoint = Geo.destination(from: origin, bearingDeg: 0, distanceM: 80)
        let away = Geo.destination(from: spotPoint, bearingDeg: 90, distanceM: 20)
        let measured = Geo.distanceM(spotPoint, away)
        XCTAssertEqual(measured, 20, accuracy: 0.05, "前提: ほぼ 20 m(実測 \(measured))")
        XCTAssertNotNil(MusicSpot.chooseSpread(from: [away], start: origin,
                                               avoiding: [spotPoint],
                                               minSeparationM: measured,
                                               p: p, pick: { _ in 0 }),
                        "ちょうどの距離は残ること")
        XCTAssertNil(MusicSpot.chooseSpread(from: [away], start: origin,
                                            avoiding: [spotPoint],
                                            minSeparationM: measured + 0.01,
                                            p: p, pick: { _ in 0 }),
                     "それより近ければ外れること")
    }

    /// **北や先頭に固定的に寄らない**(→ 合議 M4)
    func testSpreadChoiceCanPickAnyEligibleCandidate() {
        let p = params(min: 60, max: 100, steps: 1)
        let candidates = MusicSpot.candidates(around: origin, p: p)
        var seen = Set<String>()
        for i in 0..<12 {
            guard let s = MusicSpot.chooseSpread(from: candidates, start: origin,
                                                 avoiding: [], minSeparationM: 20,
                                                 p: p, pick: { _ in i }) else { continue }
            seen.insert(String(format: "%.4f,%.4f", s.center.latitude, s.center.longitude))
        }
        XCTAssertGreaterThan(seen.count, 4, "選び先が散らばること(得た数 \(seen.count))")
    }

    /// 同じ地点に重なった候補は 1 票にまとめる(道へ寄せると重なる → 合議 M3)
    func testDuplicatePointsCountOnce() {
        let p = params(min: 60, max: 100, steps: 1)
        let a = Geo.destination(from: origin, bearingDeg: 0, distanceM: 80)
        let chosen = MusicSpot.chooseSpread(from: [a, a, a], start: origin,
                                            avoiding: [], minSeparationM: 20,
                                            p: p, pick: { count in
                                                XCTAssertEqual(count, 1, "3 つ渡しても 1 票")
                                                return 0
                                            })
        XCTAssertNotNil(chosen)
    }

    /// **選べなければ nil。条件を黙って緩めない**(→ 合議 M5)
    func testNoEligibleCandidateReturnsNil() {
        let p = params(min: 60, max: 100, steps: 1)
        let candidates = MusicSpot.candidates(around: origin, p: p)
        // 出発点から 1 km を避ける指定なら全部残るが、**全候補を避ければ**何も残らない
        XCTAssertNil(MusicSpot.chooseSpread(from: candidates, start: origin,
                                            avoiding: candidates, minSeparationM: 20,
                                            p: p, pick: { _ in 0 }))
    }

    /// 帯の外は選ばない(既存の `choose` と同じ条件 → 合議 M1)
    func testSpreadChoiceKeepsTheDistanceBand() {
        let p = params(min: 60, max: 100, steps: 1)
        let tooNear = Geo.destination(from: origin, bearingDeg: 0, distanceM: 30)
        let tooFar = Geo.destination(from: origin, bearingDeg: 180, distanceM: 300)
        XCTAssertNil(MusicSpot.chooseSpread(from: [tooNear, tooFar], start: origin,
                                            avoiding: [], minSeparationM: 20,
                                            p: p, pick: { _ in 0 }))
    }

    /// 範囲外の番号を返されても落ちない(挟み込む)
    func testPickIsClamped() {
        let p = params(min: 60, max: 100, steps: 1)
        let candidates = MusicSpot.candidates(around: origin, p: p)
        XCTAssertNotNil(MusicSpot.chooseSpread(from: candidates, start: origin,
                                               avoiding: [], minSeparationM: 20,
                                               p: p, pick: { _ in 9999 }))
        XCTAssertNotNil(MusicSpot.chooseSpread(from: candidates, start: origin,
                                               avoiding: [], minSeparationM: 20,
                                               p: p, pick: { _ in -5 }))
    }
}
