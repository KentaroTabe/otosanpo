import XCTest
@testable import OtoSanpo

/// 音楽スポット(→ `MusicSpot`・docs/08)。連続音で方向が伝わるかを試すための実験の最小形。
///
/// 点の earcon は鳴った瞬間しか手がかりが無い。連続音なら聴きながら向きを直せる、
/// というのが方針 B / C の賭けで、それを 1 回の散歩で確かめるために作った。
final class MusicSpotTests: XCTestCase {

    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    private func params(target: Double = 80, max: Double = 100,
                        reached: Double = 15, step: Double = 30) -> MusicSpot.Params {
        MusicSpot.Params(
            maxDistanceM: max, targetDistanceM: target, reachedM: reached,
            bearingStepDeg: step,
            gainNear: 0.9, gainFar: 0.25, nearDistanceM: 15, farDistanceM: 100)
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
        let p = params(target: 80, max: 100)
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
        let p = params(target: 80, max: 100)
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
