import XCTest
@testable import OtoSanpo

final class MapCatalogTests: XCTestCase {

    private func entry(_ name: String, _ lat: Double, _ lon: Double,
                       radiusM: Double = 20000) -> MapCatalog.Entry {
        MapCatalog.Entry(name: name, file: "\(name).json", bytes: 1_000_000,
                         radiusM: radiusM, center: GeoPoint(latitude: lat, longitude: lon),
                         generated: "2026-08-28")
    }

    private let nagoya = GeoPoint(latitude: 35.18510, longitude: 136.89984)
    private let kanazawa = GeoPoint(latitude: 36.56163, longitude: 136.65688)

    func testSortsByDistanceFromHere() {
        let list = [entry("金沢市", 36.56163, 136.65688),
                    entry("名古屋市", 35.18510, 136.89984),
                    entry("東京都", 35.67686, 139.76389)]
        let sorted = MapCatalog.sorted(list, near: nagoya)
        // 名古屋から見て 金沢 約 155 km < 東京 約 265 km
        XCTAssertEqual(sorted.map(\.name), ["名古屋市", "金沢市", "東京都"])
    }

    /// **位置が取れないことは普通に起きる**(屋内・起動直後)。その時は元の順のまま
    func testKeepsOrderWithoutPosition() {
        let list = [entry("金沢市", 36.56163, 136.65688),
                    entry("名古屋市", 35.18510, 136.89984)]
        XCTAssertEqual(MapCatalog.sorted(list, near: nil).map(\.name), ["金沢市", "名古屋市"])
    }

    func testCoversWithinRadius() {
        let e = entry("名古屋市", 35.18510, 136.89984, radiusM: 15000)
        XCTAssertTrue(MapCatalog.covers(e, nagoya))
        // 金沢は 150 km 以上離れている
        XCTAssertFalse(MapCatalog.covers(e, kanazawa))
    }

    /// 覆う地図のうち、中心が最も近いものを選ぶ
    func testBestPicksTheNearestCoveringMap() {
        let list = [entry("東京都", 35.67686, 139.76389, radiusM: 15000),
                    entry("八王子市", 35.66636, 139.31637, radiusM: 20000),
                    entry("さいたま市", 35.86161, 139.64557, radiusM: 15000)]
        // 多摩市は八王子の 20km 圏には入るが、東京都の 15km 圏には入らない
        let tama = GeoPoint(latitude: 35.63725, longitude: 139.44611)
        XCTAssertEqual(MapCatalog.best(list, for: tama)?.name, "八王子市")
    }

    /// **覆う地図が 1 つも無い地域がある。** 呼び出し側が空を扱えること
    func testBestIsNilWhereNothingCovers() {
        let list = [entry("名古屋市", 35.18510, 136.89984, radiusM: 15000)]
        XCTAssertNil(MapCatalog.best(list, for: kanazawa))
    }

    /// 配信先に置く JSON をそのまま読めること。**鍵名は snake_case**
    func testDecodesThePublishedFormat() throws {
        let json = """
        {
          "generated": "2026-08-28",
          "cities": [
            {
              "name": "金沢市",
              "file": "金沢市.json",
              "bytes": 10231257,
              "radius_m": 20000,
              "center": { "latitude": 36.56163, "longitude": 136.65688 },
              "generated": "2026-08-28"
            }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(MapCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.cities.count, 1)
        XCTAssertEqual(catalog.cities[0].name, "金沢市")
        XCTAssertEqual(catalog.cities[0].radiusM, 20000)
        XCTAssertEqual(catalog.cities[0].bytes, 10231257)
    }
}
