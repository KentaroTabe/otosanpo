import XCTest
@testable import OtoSanpo

/// 経路データのファイルを**名前を問わず読む**ための順序づけ(→ `MapFiles`)。
///
/// なぜ要るか(2026-08-30): 読む名前を `otosanpo-map.json` に固定していたため、
/// `scripts/build_maps.sh` が出す都市名のファイル(`名古屋市.json`)を
/// そのまま置いたテスターの端末で**永久に読まれなかった**。
final class MapFilesTests: XCTestCase {

    private func c(_ name: String, _ minutesAgo: Double, size: Int = 1000) -> MapFiles.Candidate {
        MapFiles.Candidate(name: name,
                           modified: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                           sizeBytes: size)
    }

    /// **今回の不具合そのもの。** 都市名のファイルだけが置かれていても読む対象になる
    func testCityNamedFileIsAccepted() {
        let ordered = MapFiles.order([c("名古屋市.json", 0)])
        XCTAssertEqual(ordered.map(\.name), ["名古屋市.json"])
    }

    /// 正式名は最優先。すでに正しく置けている端末で、他を先に解こうとして遅くしない
    func testPreferredNameWinsEvenWhenOlder() {
        let ordered = MapFiles.order([
            c("名古屋市.json", 0),          // こちらが新しい
            c("otosanpo-map.json", 500),   // でも正式名が勝つ
        ])
        XCTAssertEqual(ordered.first?.name, "otosanpo-map.json")
    }

    /// 正式名が無ければ新しい順。配り直したとき、消し忘れた古い地図に負けない
    func testNewestFirstWithoutPreferredName() {
        let ordered = MapFiles.order([
            c("金沢市.json", 300),
            c("名古屋市.json", 10),
            c("東京都.json", 900),
        ])
        XCTAssertEqual(ordered.map(\.name), ["名古屋市.json", "金沢市.json", "東京都.json"])
    }

    /// 更新時刻が同じでも順が揺れない(実行のたびに読むファイルが変わると再現しない)
    func testTiesAreBrokenByNameSoOrderIsStable() {
        let a = MapFiles.order([c("b.json", 10), c("a.json", 10)])
        let b = MapFiles.order([c("a.json", 10), c("b.json", 10)])
        XCTAssertEqual(a.map(\.name), ["a.json", "b.json"])
        XCTAssertEqual(a.map(\.name), b.map(\.name))
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue(MapFiles.order([]).isEmpty)
    }

    // MARK: - 指紋(前面に戻るたびに解き直さないための印)

    func testFingerprintIsStableForSameFiles() {
        let files = [c("名古屋市.json", 10), c("otosanpo-map.json", 20)]
        XCTAssertEqual(MapFiles.fingerprint(files), MapFiles.fingerprint(files.reversed()))
    }

    func testFingerprintChangesWhenFileIsAdded() {
        let before = MapFiles.fingerprint([c("名古屋市.json", 10)])
        let after = MapFiles.fingerprint([c("名古屋市.json", 10), c("金沢市.json", 5)])
        XCTAssertNotEqual(before, after)
    }

    /// **同じ秒に同名で差し替えられても気づく。** 更新時刻だけ見ていると取りこぼす
    func testFingerprintChangesWhenSizeChangesAtSameTime() {
        let before = MapFiles.fingerprint([c("名古屋市.json", 10, size: 1000)])
        let after = MapFiles.fingerprint([c("名古屋市.json", 10, size: 2000)])
        XCTAssertNotEqual(before, after)
    }

    func testFingerprintOfNothingIsEmpty() {
        XCTAssertEqual(MapFiles.fingerprint([]), "")
    }
}
