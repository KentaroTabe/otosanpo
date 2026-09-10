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

    /// head_mount の値が届いていること(docs/13)。
    /// 既定 enabled=false でも、閾値が 0 で届くと実験の時に検疫が意味を失う
    func testHeadMountValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertGreaterThan(p.headMount.updateHz, 0)
        XCTAssertGreaterThan(p.headMount.logIntervalSec, 0)
        XCTAssertGreaterThan(p.headMount.staleSec, 0)
        // ずれの学習(MountOffset)。0 で届くと学習が意味を失う
        XCTAssertGreaterThan(p.headMount.offsetMinSec, 0)
        XCTAssertGreaterThan(p.headMount.offsetHalfLifeSec, 0)
        XCTAssertGreaterThan(p.headMount.offsetMinConcentration, 0)
        XCTAssertLessThanOrEqual(p.headMount.offsetMinConcentration, 1)
        XCTAssertGreaterThan(p.headMount.offsetGateDeg, 0)
        XCTAssertGreaterThan(p.headMount.evidenceMaxGapSec, 0)
        // 検疫(HeadingQuarantine)。割合が 0 だと即座に退避し、1 を超えると永久に退避しない
        XCTAssertGreaterThan(p.headMount.quarantineWindowSec, 0)
        XCTAssertGreaterThan(p.headMount.quarantineDistrustRatio, 0)
        XCTAssertLessThanOrEqual(p.headMount.quarantineDistrustRatio, 1)
        XCTAssertGreaterThan(p.headMount.quarantineDistrustSec, 0)
        XCTAssertGreaterThan(p.headMount.quarantineRegainRatio, 0)
        XCTAssertLessThanOrEqual(p.headMount.quarantineRegainRatio, 1)
        XCTAssertGreaterThan(p.headMount.quarantineRegainSec, 0)
        // 証拠窓より長い遷移条件を置くと、条件が永久に満たされない
        XCTAssertLessThanOrEqual(p.headMount.quarantineDistrustSec,
                                 p.headMount.quarantineWindowSec)
        XCTAssertLessThanOrEqual(p.headMount.quarantineRegainSec,
                                 p.headMount.quarantineWindowSec)
    }

    /// 音楽スポットの音量の値が届いていること(→ MusicSpot.Params.gain)。
    /// **下限が 0 以下だと dB にできず、幅の最小の長さが 0 だと 0 で割る**(2026-09-11)
    func testMusicSpotGainValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        let e = p.experiment
        XCTAssertGreaterThan(e.musicSpotMinGain, 0)
        XCTAssertGreaterThan(e.musicSpotMaxGain, e.musicSpotMinGain)
        XCTAssertLessThanOrEqual(e.musicSpotMaxGain, 1)
        XCTAssertGreaterThan(e.musicSpotReferenceDistanceM, 0)
        XCTAssertGreaterThan(e.musicSpotGainMinSpanM, 0)
    }
}
