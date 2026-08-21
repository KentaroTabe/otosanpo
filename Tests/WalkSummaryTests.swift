import XCTest
@testable import OtoSanpo

/// 散歩の記録(経路・イベント番号・経路図の枠)。
/// 番号は利用者が「n 回目のイベント」と呼ぶ単位なので、振り方がずれると
/// フィードバックと記録が食い違う。
final class WalkSummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let origin = GeoPoint(latitude: 35.0, longitude: 139.0)

    private func point(northM: Double = 0, eastM: Double = 0) -> GeoPoint {
        let lonScale = Geo.metersPerDegreeLat * cos(origin.latitude * .pi / 180)
        return GeoPoint(latitude: origin.latitude + northM / Geo.metersPerDegreeLat,
                        longitude: origin.longitude + eastM / lonScale)
    }

    // MARK: - 経路

    func testDropsJitterBelowTheMinimumSegment() {
        var s = WalkSummary(startedAt: start, home: origin)
        s.add(origin, minSegmentM: 10, maxPoints: 100)
        s.add(point(northM: 3), minSegmentM: 10, maxPoints: 100)
        s.add(point(northM: 6), minSegmentM: 10, maxPoints: 100)
        // 揺れの範囲では点を増やさない。基準点は動かないので、真の移動は次に拾われる
        XCTAssertEqual(s.track.count, 1)
        s.add(point(northM: 12), minSegmentM: 10, maxPoints: 100)
        XCTAssertEqual(s.track.count, 2)
    }

    func testThinsInsteadOfGrowingWithoutBound() {
        var s = WalkSummary(startedAt: start, home: origin)
        let totalM = 399.0 * 12
        for i in 0..<400 {
            s.add(point(northM: Double(i) * 12), minSegmentM: 10, maxPoints: 20)
        }
        XCTAssertLessThanOrEqual(s.track.count, 20)
        // 間引いても図の形は保たれる: 出発点が残り、順序が入れ替わらず、
        // 歩いた範囲をほぼ覆う(末尾は間引きの刻み 1 つぶんだけ手前になりうる)
        XCTAssertEqual(s.track.first, origin)
        XCTAssertEqual(s.track.map(\.latitude), s.track.map(\.latitude).sorted())
        let span = Geo.distanceM(s.track.first ?? origin, s.track.last ?? origin)
        XCTAssertGreaterThan(span, totalM * 0.9)
    }

    // MARK: - イベント

    func testNumbersGuidanceEventsFromOne() {
        var s = WalkSummary(startedAt: start, home: origin)
        XCTAssertEqual(s.startGuidance(at: point(northM: 30), bearingDeg: 90,
                                       onReturn: false, now: start), 1)
        s.finishGuidance(ending: TurnGuidance.Ending.turned.rawValue)
        XCTAssertEqual(s.startGuidance(at: point(northM: 60), bearingDeg: 0,
                                       onReturn: false, now: start.addingTimeInterval(120)), 2)
        // 帰路の誘導も同じ番号列で続ける(利用者は通しで数える)
        s.addMark(.returnStart, at: point(northM: 60), onReturn: true, now: start)
        XCTAssertEqual(s.startGuidance(at: point(northM: 20), bearingDeg: 180,
                                       onReturn: true, now: start.addingTimeInterval(300)), 3)
        XCTAssertEqual(s.guidanceEvents.map(\.number), [1, 2, 3])
        XCTAssertEqual(s.guidanceEvents.map(\.onReturn), [false, false, true])
        XCTAssertEqual(s.events.count, 4)
    }

    func testWritesTheEndingIntoTheOpenGuidanceOnly() {
        var s = WalkSummary(startedAt: start, home: origin)
        s.startGuidance(at: point(northM: 30), bearingDeg: 90, onReturn: false, now: start)
        s.finishGuidance(ending: "曲がり終えた")
        s.startGuidance(at: point(northM: 90), bearingDeg: 90, onReturn: false, now: start)
        s.finishGuidance(ending: "従わなかった")
        XCTAssertEqual(s.guidanceEvents.map(\.ending), ["曲がり終えた", "従わなかった"])
        // 開いている誘導が無ければ何も書き換えない
        s.finishGuidance(ending: "角から離れた")
        XCTAssertEqual(s.guidanceEvents.map(\.ending), ["曲がり終えた", "従わなかった"])
    }

    func testCountsEndingsInAStableOrder() {
        var s = WalkSummary(startedAt: start, home: origin)
        for (i, ending) in ["従わなかった", "曲がり終えた", "曲がり終えた"].enumerated() {
            s.startGuidance(at: point(northM: Double(i) * 40), bearingDeg: 0,
                            onReturn: false, now: start)
            s.finishGuidance(ending: ending)
        }
        // 鳴っている最中の 1 件は「途中」に数える
        s.startGuidance(at: point(northM: 200), bearingDeg: 0, onReturn: false, now: start)
        XCTAssertEqual(s.endingCounts().map(\.ending), ["曲がり終えた", "従わなかった", "途中"])
        XCTAssertEqual(s.endingCounts().map(\.count), [2, 1, 1])
    }

    func testDurationAndDistanceComeFromFinish() {
        var s = WalkSummary(startedAt: start, home: origin)
        XCTAssertEqual(s.durationSec, 0)
        s.finish(at: start.addingTimeInterval(1_800), pathLengthM: 2_450)
        XCTAssertEqual(s.durationSec, 1_800)
        XCTAssertEqual(s.pathLengthM, 2_450)
    }

    // MARK: - 経路図の枠

    func testFrameContainsEverythingWithMargin() {
        var s = WalkSummary(startedAt: start, home: origin)
        s.add(origin, minSegmentM: 10, maxPoints: 100)
        s.add(point(northM: 200, eastM: 300), minSegmentM: 10, maxPoints: 100)
        s.startGuidance(at: point(northM: -50, eastM: -60), bearingDeg: 45,
                        onReturn: false, now: start)
        guard let f = s.frame(marginM: 40, minSpanM: 150) else {
            return XCTFail("枠を作れなかった")
        }
        // 余白ぶんだけ外側に広がる(端の印が枠に貼り付かない)
        XCTAssertEqual(f.widthM, 360 + 80, accuracy: 1.0)
        XCTAssertEqual(f.heightM, 250 + 80, accuracy: 1.0)
        for p in [origin, point(northM: 200, eastM: 300), point(northM: -50, eastM: -60)] {
            let xy = f.point(p)
            XCTAssertTrue((0...f.widthM).contains(xy.x), "x=\(xy.x)")
            XCTAssertTrue((0...f.heightM).contains(xy.y), "y=\(xy.y)")
        }
    }

    func testFrameWidensASingleStandingPointToTheMinimumSpan() {
        var s = WalkSummary(startedAt: start, home: nil)
        s.add(origin, minSegmentM: 10, maxPoints: 100)
        guard let f = s.frame(marginM: 40, minSpanM: 150) else {
            return XCTFail("枠を作れなかった")
        }
        XCTAssertEqual(f.widthM, 150, accuracy: 1.0)
        XCTAssertEqual(f.heightM, 150, accuracy: 1.0)
    }

    func testFrameIsNorthUp() {
        var s = WalkSummary(startedAt: start, home: origin)
        s.add(origin, minSegmentM: 10, maxPoints: 100)
        s.add(point(northM: 100, eastM: 100), minSegmentM: 10, maxPoints: 100)
        guard let f = s.frame(marginM: 40, minSpanM: 150) else {
            return XCTFail("枠を作れなかった")
        }
        // 北にある点ほど y が小さい(上に描かれる)。東にある点ほど x が大きい
        XCTAssertLessThan(f.point(point(northM: 100)).y, f.point(origin).y)
        XCTAssertGreaterThan(f.point(point(eastM: 100)).x, f.point(origin).x)
    }

    func testFrameIsNilWithoutAnyPoint() {
        let s = WalkSummary(startedAt: start, home: nil)
        XCTAssertNil(s.frame(marginM: 40, minSpanM: 150))
    }

    // MARK: - 保存

    func testSurvivesEncodingRoundTrip() throws {
        var s = WalkSummary(startedAt: start, home: origin)
        s.add(origin, minSegmentM: 10, maxPoints: 100)
        s.add(point(northM: 40), minSegmentM: 10, maxPoints: 100)
        s.startGuidance(at: point(northM: 30), bearingDeg: 90, onReturn: false, now: start)
        s.finishGuidance(ending: "曲がり終えた")
        s.finish(at: start.addingTimeInterval(600), pathLengthM: 800)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WalkSummary.self, from: data), s)
    }
}
