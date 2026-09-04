import XCTest
@testable import OtoSanpo

/// **実物の `config/parameters.json` が読めることを確かめる。**
///
/// なぜ要るか(2026-08-29): `map_download` を足したとき、
/// `CodingKeys` を snake_case で書いたせいで**実機の起動時に読み込みが失敗した**。
/// デコーダは `.convertFromSnakeCase` を使うので、JSON の `base_url` は
/// 照合の**前に** `baseUrl` へ変換される。`case baseURL = "base_url"` は永久に一致しない。
///
/// **既存のテストは 1 件もこれを捕まえられなかった。** どれも構造体を手で組んでおり、
/// 設定ファイルと `AppParameters` がずれても緑のままだったため。
/// パラメータを足すたびにこの穴が開くので、実ファイルを読む口をここに置く。
///
/// アプリはフォールバック値を持たない(CLAUDE.md)。読めなければ起動時に止まる。
final class ParametersFileTests: XCTestCase {

    /// リポジトリの `config/parameters.json`。
    /// テストの実行位置に依存しないよう、このファイルの位置から辿る
    private func repositoryParametersURL() -> URL {
        URL(fileURLWithPath: #filePath)          // Tests/ParametersFileTests.swift
            .deletingLastPathComponent()          // Tests/
            .deletingLastPathComponent()          // リポジトリの根
            .appendingPathComponent("config/parameters.json")
    }

    func testRepositoryFileDecodes() throws {
        let url = repositoryParametersURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "設定ファイルが見つかりません: \(url.path)")
        // **失敗したら例外の中身をそのまま出す。** どの鍵で落ちたかが分かる
        _ = try ConfigLoader.load(from: url)
    }

    /// アプリのバンドルに入っている複製も読めること。
    /// リポジトリの版が読めても、資源の複製が漏れていれば実機で落ちる
    func testBundledCopyDecodes() throws {
        guard let url = Bundle.main.url(forResource: "parameters", withExtension: "json") else {
            throw XCTSkip("テストのホストにバンドルされていません")
        }
        _ = try ConfigLoader.load(from: url)
    }

    /// 値が実際に届いていること(鍵の綴りが違っても既定値で通ってしまわないように)
    func testMapDownloadValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertFalse(p.mapDownload.baseUrl.isEmpty, "配信先が空です")
        XCTAssertTrue(p.mapDownload.baseUrl.hasPrefix("https://"), "配信先は https で始まること")
        XCTAssertGreaterThan(p.mapDownload.timeoutSec, 0)
        XCTAssertGreaterThan(p.mapDownload.tileSizeDeg, 0)
    }

    func testShopHistoryValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertEqual(p.shopHistory.passageRadiusM, 30, accuracy: 0.001)
        XCTAssertEqual(p.shopHistory.searchRadiusM, 120, accuracy: 0.001)
        XCTAssertEqual(p.shopHistory.maxHorizontalAccuracyM, 50, accuracy: 0.001)
    }
}
