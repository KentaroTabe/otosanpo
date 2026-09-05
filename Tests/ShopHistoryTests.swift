import XCTest
@testable import OtoSanpo

final class ShopHistoryTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    private func shop(_ id: String, bearing: Double = 0, distanceM: Double = 10) -> Shop {
        let p = Geo.destination(from: origin, bearingDeg: bearing, distanceM: distanceM)
        return Shop(shopID: id, name: "店 \(id)", latitude: p.latitude, longitude: p.longitude,
                    category: "cafe")
    }

    func testFirstPassageCreatesSeparatedShopAndHistory() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let now = Date(timeIntervalSince1970: 1_000)
        let s = shop("a")

        let updates = history.recordPassages(near: origin, candidates: [s],
                                             session: &session, at: now, radiusM: 30)

        XCTAssertEqual(updates, [
            ShopPassageUpdate(shopID: "a", isFirstPassage: true,
                              passedAt: now, distanceM: Geo.distanceM(origin, s.location))
        ])
        XCTAssertEqual(history.shopsByID["a"], s)
        XCTAssertEqual(history.historiesByShopID["a"],
                       ShopPassageHistory(shopID: "a", firstPassedAt: now,
                                          lastPassedAt: now, passCount: 1))
    }

    func testRepeatPassageInDifferentSessionIncrementsCount() {
        var history = ShopHistory()
        var firstSession = ShopPassageSession()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        let s = shop("a")

        history.recordPassages(near: origin, candidates: [s],
                               session: &firstSession, at: first, radiusM: 30)
        var secondSession = ShopPassageSession()
        let updates = history.recordPassages(near: origin, candidates: [s],
                                             session: &secondSession, at: second, radiusM: 30)

        XCTAssertEqual(updates.map(\.isFirstPassage), [false])
        XCTAssertEqual(history.historiesByShopID["a"]?.firstPassedAt, first)
        XCTAssertEqual(history.historiesByShopID["a"]?.lastPassedAt, second)
        XCTAssertEqual(history.historiesByShopID["a"]?.passCount, 2)
    }

    func testSameShopInSameWalkCountsOnlyOnce() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let s = shop("a")

        let first = history.recordPassages(near: origin, candidates: [s],
                                           session: &session, at: Date(), radiusM: 30)
        let duplicate = history.recordPassages(near: origin, candidates: [s],
                                               session: &session, at: Date(), radiusM: 30)

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(history.historiesByShopID["a"]?.passCount, 1)
    }

    func testPassageRadiusUsesThirtyMetersThreshold() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let inside = shop("inside", distanceM: 29)
        let outside = shop("outside", distanceM: 31)

        let updates = history.recordPassages(near: origin, candidates: [outside, inside],
                                             session: &session, at: Date(), radiusM: 30)

        XCTAssertEqual(updates.map(\.shopID), ["inside"])
        XCTAssertNil(history.historiesByShopID["outside"])
    }

    func testRoutePassageUsesDistanceToWalkPolyline() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        let route = [origin, north]
        let nearRoute = shop("near-route", bearing: 90, distanceM: 20)
        let farRoute = shop("far-route", bearing: 90, distanceM: 40)

        let updates = history.recordPassages(along: route,
                                             candidates: [farRoute, nearRoute],
                                             session: &session,
                                             at: Date(),
                                             radiusM: 30)

        XCTAssertEqual(updates.map(\.shopID), ["near-route"])
        XCTAssertEqual(history.historiesByShopID["near-route"]?.passCount, 1)
        XCTAssertNil(history.historiesByShopID["far-route"])
    }

    func testPoorHorizontalAccuracyDoesNotRecordPassage() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let s = shop("a", distanceM: 10)

        let poor = history.recordPassages(near: origin,
                                          horizontalAccuracyM: 80,
                                          candidates: [s],
                                          session: &session,
                                          at: Date(),
                                          radiusM: 30,
                                          maxHorizontalAccuracyM: 50)
        let invalid = history.recordPassages(near: origin,
                                             horizontalAccuracyM: -1,
                                             candidates: [s],
                                             session: &session,
                                             at: Date(),
                                             radiusM: 30,
                                             maxHorizontalAccuracyM: 50)

        XCTAssertTrue(poor.isEmpty)
        XCTAssertTrue(invalid.isEmpty)
        XCTAssertNil(history.historiesByShopID["a"])
    }

    func testRoutePassageUsesNearestRouteTime() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let north = Geo.destination(from: origin, bearingDeg: 0, distanceM: 100)
        let route = [
            TimedGeoPoint(point: origin, date: Date(timeIntervalSince1970: 1_000)),
            TimedGeoPoint(point: north, date: Date(timeIntervalSince1970: 1_100))
        ]
        let halfway = Geo.destination(from: origin, bearingDeg: 0, distanceM: 50)
        let nearHalfway = Shop(shopID: "mid", name: "中間", latitude: halfway.latitude,
                               longitude: halfway.longitude, category: "cafe")

        let updates = history.recordPassages(along: route,
                                             candidates: [nearHalfway],
                                             session: &session,
                                             fallbackDate: Date(timeIntervalSince1970: 2_000),
                                             radiusM: 30)

        XCTAssertEqual(updates.first?.passedAt.timeIntervalSince1970 ?? 0,
                       1_050,
                       accuracy: 0.01)
        XCTAssertEqual(history.historiesByShopID["mid"]?.firstPassedAt.timeIntervalSince1970 ?? 0,
                       1_050,
                       accuracy: 0.01)
    }

    func testRoutePassageIgnoresPoorAccuracyPoints() {
        var history = ShopHistory()
        var session = ShopPassageSession()
        let poorPoint = Geo.destination(from: origin, bearingDeg: 90, distanceM: 100)
        let shopNearPoorPoint = Shop(shopID: "poor", name: "精度不良点の店",
                                     latitude: poorPoint.latitude,
                                     longitude: poorPoint.longitude,
                                     category: "cafe")
        let route = [
            TimedGeoPoint(point: origin, date: Date(timeIntervalSince1970: 1_000),
                          horizontalAccuracyM: 10),
            TimedGeoPoint(point: poorPoint, date: Date(timeIntervalSince1970: 1_100),
                          horizontalAccuracyM: 80)
        ]

        let updates = history.recordPassages(along: route,
                                             candidates: [shopNearPoorPoint],
                                             session: &session,
                                             fallbackDate: Date(timeIntervalSince1970: 2_000),
                                             radiusM: 30,
                                             maxHorizontalAccuracyM: 50)

        XCTAssertTrue(updates.isEmpty)
        XCTAssertNil(history.historiesByShopID["poor"])
    }
}
