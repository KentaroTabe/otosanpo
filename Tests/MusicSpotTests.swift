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
                        tolerance: Double = 0.001) -> MusicSpot.Params {
        MusicSpot.Params(
            minDistanceM: min, maxDistanceM: max, distanceStepCount: steps,
            reachedM: reached,
            bearingStepDeg: step, sameDistanceToleranceM: tolerance,
            gainNear: 0.9, gainFar: 0.25, nearDistanceM: 15, farDistanceM: 100)
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
        let placed = spot.placement(from: origin, referenceBearingDeg: 180, p: p)
        XCTAssertEqual(abs(placed.relDeg), 180, accuracy: 1.0,
                       "真後ろは真後ろのまま返る(畳まない)")
        // 参考: earcon の経路なら前へ畳まれる。ここを通らないことが今回の要点
        XCTAssertEqual(abs(SoundPlacement.foldToFrontDeg(placed.relDeg)), 0, accuracy: 1.0)
    }

    /// 右手 90° のスポットは +90°、左手は −90°
    func testPlacementKeepsLeftAndRight() {
        let p = params()
        let right = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 90, distanceM: 80))
        XCTAssertEqual(right.placement(from: origin, referenceBearingDeg: 0, p: p).relDeg,
                       90, accuracy: 1.0)
        let left = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 270, distanceM: 80))
        XCTAssertEqual(left.placement(from: origin, referenceBearingDeg: 0, p: p).relDeg,
                       -90, accuracy: 1.0)
    }

    /// 近づくほど大きくなる。**距離が音量で伝わる**(ビーコンと同じ形)
    func testGainRisesAsYouApproach() {
        let p = params()
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 100))
        let far = spot.placement(from: origin, referenceBearingDeg: 0, p: p)
        let mid = spot.placement(from: Geo.destination(from: origin, bearingDeg: 0, distanceM: 50),
                                 referenceBearingDeg: 0, p: p)
        let near = spot.placement(from: Geo.destination(from: origin, bearingDeg: 0, distanceM: 90),
                                  referenceBearingDeg: 0, p: p)
        XCTAssertLessThan(far.gain, mid.gain)
        XCTAssertLessThan(mid.gain, near.gain)
        XCTAssertLessThanOrEqual(near.gain, p.gainNear)
        XCTAssertGreaterThanOrEqual(far.gain, p.gainFar)
    }

    /// 着いたら止める(**一度だけ鳴る**という約束)
    func testReachedInsideTheRadius() {
        let p = params(reached: 15)
        let spot = MusicSpot(center: Geo.destination(from: origin, bearingDeg: 0, distanceM: 80))
        XCTAssertFalse(spot.isReached(from: origin, p: p))
        let close = Geo.destination(from: origin, bearingDeg: 0, distanceM: 70)
        XCTAssertTrue(spot.isReached(from: close, p: p))
    }
}
