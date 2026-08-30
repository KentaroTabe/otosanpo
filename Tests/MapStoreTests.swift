import XCTest
@testable import OtoSanpo

/// **Documents に置かれたファイルを実際に読む経路**を確かめる。
///
/// `MapFilesTests` は並べ替えだけを見ている。今回の不具合は
/// 「都市名のファイルが読まれない」という**読み込みの入り口**にあったので、
/// 本当にファイルを置いて読めることまで確かめないと再発を止められない。
///
/// Documents に既に `.json` がある端末では飛ばす(手で入れた地図を壊さないため)。
final class MapStoreTests: XCTestCase {

    private var documents: URL!
    private var written: [URL] = []

    override func setUpWithError() throws {
        documents = try XCTUnwrap(MapStore.documentsURL())
        if !MapStore.candidates().isEmpty {
            throw XCTSkip("Documents に既に .json があるため飛ばします(実機の地図を壊さない)")
        }
        written = []
    }

    override func tearDownWithError() throws {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
    }

    /// 最小の経路データ。2 点を 1 本の道で結んだだけ
    private func sampleMap() -> WalkMap {
        WalkMap(center: GeoPoint(latitude: 35.17, longitude: 136.90),
                radiusM: 5000,
                generated: "2026-08-30",
                nodes: [[35.17, 136.90], [35.171, 136.90]],
                ways: [WalkMap.Way(n: [0, 1], cls: .residential, cross: 0)])
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = documents.appendingPathComponent(name)
        try data.write(to: url)
        written.append(url)
        return url
    }

    // MARK: -

    /// **今回の不具合そのもの。**
    /// `scripts/build_maps.sh` が出す都市名のファイルを、改名せずに読める
    func testCityNamedFileIsLoaded() throws {
        try write("名古屋市.json", try JSONEncoder().encode(sampleMap()))

        guard case .loaded(let map, let name) = MapStore.loadMap() else {
            return XCTFail("都市名のファイルが読まれませんでした: \(MapStore.loadMap())")
        }
        XCTAssertEqual(name, "名古屋市.json")
        XCTAssertEqual(map.generated, "2026-08-30")
    }

    /// 正式名も従来どおり読める(互換を壊していない)
    func testPreferredNameStillLoads() throws {
        try write(MapFiles.preferredName, try JSONEncoder().encode(sampleMap()))

        guard case .loaded(_, let name) = MapStore.loadMap() else {
            return XCTFail("正式名のファイルが読まれませんでした")
        }
        XCTAssertEqual(name, MapFiles.preferredName)
    }

    /// 何も置いていなければ「未読込」。**読めなかったのとは区別する**
    func testNoFileIsReportedAsNoFile() {
        XCTAssertEqual(MapStore.loadMap().mapFailure, .noFile)
    }

    /// 置いてあるのに解けない場合は、**ファイル名つきで理由が返る**。
    /// 「未読込」に潰すと、入れ忘れたのか読めないのかが切り分けられない
    func testUndecodableFileIsReportedWithItsName() throws {
        try write("こわれた.json", Data("{ これは経路データではない }".utf8))

        XCTAssertEqual(MapStore.loadMap().mapFailure, .undecodable(["こわれた.json"]))
    }

    /// 解けないものが混ざっていても、**解けるものがあればそれを使う**
    func testDecodableFileWinsOverBrokenOne() throws {
        try write("こわれた.json", Data("{}".utf8))
        try write("金沢市.json", try JSONEncoder().encode(sampleMap()))

        guard case .loaded(_, let name) = MapStore.loadMap() else {
            return XCTFail("解ける地図があるのに読まれませんでした")
        }
        XCTAssertEqual(name, "金沢市.json")
    }

    /// 下位ディレクトリ(`map-tiles/`)は見ない。タイルは別系統で読む
    func testSubdirectoriesAreIgnored() throws {
        let dir = documents.appendingPathComponent("map-tiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        written.append(dir)
        try JSONEncoder().encode(sampleMap()).write(to: dir.appendingPathComponent("t0_0.json"))

        XCTAssertTrue(MapStore.candidates().isEmpty, "下位のタイルを候補に入れてはいけません")
    }

    /// 指紋はファイルを置くと変わる(前面に戻ったときに読み直す判定に使う)
    func testFingerprintChangesWhenFileAppears() throws {
        let before = MapStore.fingerprint()
        try write("名古屋市.json", try JSONEncoder().encode(sampleMap()))
        XCTAssertNotEqual(MapStore.fingerprint(), before)
    }
}

private extension MapStore.Outcome {
    /// 失敗の中身だけ取り出す(テストの読みやすさのため)
    var mapFailure: MapFiles.Failure? {
        if case .failed(let f) = self { return f }
        return nil
    }
}
