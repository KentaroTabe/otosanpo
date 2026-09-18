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

    /// ピンポイントの値が届いていること(→ MusicSpot.Params.pinpointWeight / facingDb・2026-09-15)
    func testMusicSpotPinpointValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        let e = p.experiment
        XCTAssertGreaterThan(e.musicSpotPinpointFullM, 0)
        XCTAssertGreaterThan(e.musicSpotPinpointStartM, e.musicSpotPinpointFullM,
                             "始まりが最大より遠くないと、少しずつ効かせられない")
        XCTAssertGreaterThan(e.musicSpotPinpointBeamDeg, 0)
        XCTAssertGreaterThan(e.musicSpotPinpointDepthDb, 0)
        // **音量はピンポイントの範囲に入るまで上がり続ける**(2026-09-14 の散歩で、
        // 15 m より内側は 24 秒間音量が変わらず「最終的にどこにあるか分からない」と言われた)
        XCTAssertLessThanOrEqual(e.musicSpotReferenceDistanceM, e.musicSpotPinpointFullM)
    }

    /// 位置の取り方が届いていること(2026-09-18 利用者判断で「案内向けの最高精度」にした)
    func testLocationAccuracyChoiceArrives() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertTrue(p.location.useBestForNavigation,
                      "利用者判断で有効にした(電力より精度を採る)。戻す時はここも直す")
    }

    /// 後ろの音を暗くする値が届いていること(→ MusicSpot.Params.rearShelfDb・2026-09-18)
    func testMusicSpotRearShelfValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        let e = p.experiment
        XCTAssertGreaterThan(e.musicSpotRearShelfDepthDb, 0, "0 だと何も変わらない")
        XCTAssertLessThan(e.musicSpotRearShelfDepthDb, 12,
                          "深く削ると HRTF が前後に使う高域まで失われる(合議)")
        XCTAssertGreaterThanOrEqual(e.musicSpotRearShelfStartDeg, 0)
        XCTAssertLessThan(e.musicSpotRearShelfStartDeg, 180)
        XCTAssertGreaterThan(e.musicSpotRearShelfHz, 1_000,
                             "耳介の手がかりが載る帯域より上から落とす")
    }

    /// 向きによる音量の割り振りが届いていること(2026-09-18 利用者判断)。
    /// **深すぎると距離が分からなくなる** — 音量は距離も表しているため
    func testMusicSpotDirectivityArrives() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        let e = p.experiment
        XCTAssertGreaterThan(e.musicSpotDirectivityDepthDb, 0, "0 だと前後で音量が変わらない")
        let range = 20 * log10(e.musicSpotMaxGain / e.musicSpotMinGain)
        XCTAssertLessThan(e.musicSpotDirectivityDepthDb, range / 2,
                          "距離の幅(\(String(format: "%.0f", range)) dB)の半分を超えると、"
                          + "向きが距離を食いつぶす")
    }

    /// **スポットの向きの遊び**(2026-09-18)。揺れを落とすが、凍結はさせない
    func testMusicSpotBearingHoldValuesArrive() throws {
        let e = try ConfigLoader.load(from: repositoryParametersURL()).experiment
        let hold = e.musicSpotBearingHold
        XCTAssertGreaterThan(hold.minDeadbandDeg, 0, "0 だと揺れが素通りする")
        XCTAssertGreaterThan(hold.maxDeadbandDeg, hold.minDeadbandDeg)
        XCTAssertLessThanOrEqual(hold.maxDeadbandDeg, 20,
                                 "上限が大きいと、通り過ぎても向きが前のままになる")
        XCTAssertGreaterThan(hold.timeConstantSec, 0, "0 だと追従が止まる")
        XCTAssertLessThan(hold.timeConstantSec, 1,
                          "1 秒を超えると、通り過ぎる場面に間に合わない")
    }

    /// **近づくと下から・一点から鳴る**(2026-09-18 利用者依頼)
    func testMusicSpotElevationAndSpreadValuesArrive() throws {
        let e = try ConfigLoader.load(from: repositoryParametersURL()).experiment
        XCTAssertGreaterThan(e.musicSpotListenerHeightM, 0, "0 だと仰角が付かない")
        XCTAssertLessThan(e.musicSpotListenerHeightM, 3, "耳の高さとして現実的な範囲")
        XCTAssertGreaterThan(e.musicSpotSpreadFarM, e.musicSpotSpreadNearM,
                             "遠近が逆だと広がりが効かない")
        XCTAssertGreaterThan(e.musicSpotSpreadMax, 0)
        XCTAssertLessThanOrEqual(e.musicSpotSpreadMax, 1)
        // 一点に締まる距離は、ピンポイントで首を振って探す範囲と噛み合っていること
        let spot = e.musicSpot(durationMin: 30)
        XCTAssertLessThanOrEqual(spot.spreadNearM, spot.pinpointStartM,
                                 "首を振って探し始める距離までには、音が締まっていること")
    }

    /// **スポットを移す提案**(2026-09-18 利用者依頼)
    func testMusicSpotMoveValuesArrive() throws {
        let e = try ConfigLoader.load(from: repositoryParametersURL()).experiment
        let m = e.musicSpotMove
        XCTAssertGreaterThan(m.baseIntervalSec, 0)
        XCTAssertGreaterThan(m.responseWindowSec, 0, "0 だと返事を受け取れない")
        XCTAssertGreaterThanOrEqual(m.responseDelaySec, 0)
        XCTAssertGreaterThan(e.musicSpotMoveMinSeparationM, 0,
                             "0 だと同じ所が選ばれうる(固まらないための距離)")
        XCTAssertGreaterThan(e.musicSpotMoveFadeSec, 0, "0 だと移る時に音が飛ぶ")
    }

    /// **移す提案の音は、時間到来と別の音**(どちらへの返事か分からなくなるため)
    func testSpotMoveToneDiffersFromTheReturnPrompt() throws {
        let a = try ConfigLoader.load(from: repositoryParametersURL()).audio
        XCTAssertNotEqual(a.tones.spotMove, a.tones.timeUpPrompt)
        XCTAssertGreaterThan(a.tones.spotMove.durationSec, 0)
    }

    /// 音楽スポットでは検疫の判断を無視する(2026-09-18 利用者判断)。
    /// **基準が切り替わること自体が、連続音では壊れた体験になる**
    func testMusicIgnoresQuarantineIsOn() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertTrue(p.headMount.musicIgnoresQuarantine)
    }

    /// **設定から Core への受け渡し**で、音楽スポットの値が取り違えられていないこと
    /// (2026-09-15 の検証で挙がった系列)。
    ///
    /// **今の設定値(5 m・60°・12 dB など)を期待値に書き写さない。** 実機の結果で値を
    /// 調整するたびにテストを書き換えることになり、「期待値を合わせる」癖がつく。
    /// かといって設定値どうしを比べるだけだと、2 つの項目が偶然同じ値の時に取り違えを
    /// 見逃す。そこで**全項目に互いに異なる値を差し込んで**から受け渡しを確かめる
    /// (検査したいのは配線であって、値の良し悪しではない)
    func testMusicSpotParamsCarryEachConfigValueToItsOwnField() throws {
        var e = try ConfigLoader.load(from: repositoryParametersURL()).experiment
        // 互いに重ならない値(テストの入力)
        e.musicSpotMinDistancePerMin = 1.1
        e.musicSpotMaxDistancePerMin = 2.3
        e.musicSpotDistanceSteps = 7
        e.musicSpotReachedM = 13.1
        e.musicSpotBearingStepDeg = 17.3
        e.musicSpotSameDistanceToleranceM = 0.0019
        e.musicSpotReferenceDistanceM = 3.7
        e.musicSpotGainMinSpanM = 29.3
        e.musicSpotMaxGain = 0.83
        e.musicSpotMinGain = 0.071
        e.musicSpotRouteBlend = 0.37
        e.musicSpotPinpointStartM = 19.1
        e.musicSpotPinpointFullM = 4.3
        e.musicSpotPinpointBeamDeg = 53.9
        e.musicSpotPinpointDepthDb = 11.3
        e.musicSpotDirectivityDepthDb = 8.3
        e.musicSpotRearShelfStartDeg = 71.7
        e.musicSpotRearShelfDepthDb = 4.9
        let sp = e.musicSpot(durationMin: 20)
        XCTAssertEqual(sp.minDistanceM, 1.1 * 20, accuracy: 1e-9)
        XCTAssertEqual(sp.maxDistanceM, 2.3 * 20, accuracy: 1e-9)
        XCTAssertEqual(sp.distanceStepCount, 7)
        XCTAssertEqual(sp.reachedM, 13.1)
        XCTAssertEqual(sp.bearingStepDeg, 17.3)
        XCTAssertEqual(sp.sameDistanceToleranceM, 0.0019)
        XCTAssertEqual(sp.referenceDistanceM, 3.7)
        XCTAssertEqual(sp.gainMinSpanM, 29.3)
        XCTAssertEqual(sp.maxGain, 0.83)
        XCTAssertEqual(sp.minGain, 0.071)
        XCTAssertEqual(sp.routeBlend, 0.37)
        XCTAssertEqual(sp.pinpointStartM, 19.1)
        XCTAssertEqual(sp.pinpointFullM, 4.3)
        XCTAssertEqual(sp.pinpointBeamDeg, 53.9)
        XCTAssertEqual(sp.pinpointDepthDb, 11.3)
        XCTAssertEqual(sp.directivityDepthDb, 8.3)
        XCTAssertEqual(sp.rearShelfStartDeg, 71.7)
        XCTAssertEqual(sp.rearShelfDepthDb, 4.9)
    }

    func testShopHistoryValuesArrive() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        XCTAssertEqual(p.shopHistory.passageRadiusM, 30, accuracy: 0.001)
        XCTAssertEqual(p.shopHistory.searchRadiusM, 300, accuracy: 0.001)
        XCTAssertEqual(p.shopHistory.maxHorizontalAccuracyM, 50, accuracy: 0.001)
    }
}
