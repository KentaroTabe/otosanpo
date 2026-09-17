import XCTest
@testable import OtoSanpo

/// 画面で選ぶ設定の保存(→ Services の SettingStore)。
///
/// **外へ位置を送る設定の既定は「送らない」側**であることを、ここで固定する
/// (2026-09-17 利用者判断)。既定が逆になっていると、テスターが何も操作しないまま
/// 現在地が外へ出てしまう。
final class SettingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "otosanpo.tests.settings"

    override func setUp() {
        super.setUp()
        // **本物の設定を汚さない。** 実行ごとに白紙から始める
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// **何も選んでいなければ、店は調べない**(現在地を外へ送らない側)
    func testShopSearchIsOffUntilChosen() {
        XCTAssertFalse(SettingStore.loadShopSearchEnabled(from: defaults))
    }

    func testShopSearchChoiceSurvives() {
        SettingStore.saveShopSearchEnabled(true, to: defaults)
        XCTAssertTrue(SettingStore.loadShopSearchEnabled(from: defaults))
        SettingStore.saveShopSearchEnabled(false, to: defaults)
        XCTAssertFalse(SettingStore.loadShopSearchEnabled(from: defaults))
    }

    /// 案内音は**未設定と「元の音を選んだ」を区別する**。
    /// 区別できないと、実験ビルドで元の音を選んでも次の起動で倍音に戻ってしまう
    func testGuidanceToneIsUnsetUntilChosen() {
        XCTAssertNil(SettingStore.loadGuidanceToneExperimental(from: defaults))
    }

    func testGuidanceToneChoiceSurvivesIncludingTheOriginalSound() {
        SettingStore.saveGuidanceToneExperimental(false, to: defaults)
        XCTAssertEqual(SettingStore.loadGuidanceToneExperimental(from: defaults), false,
                       "「元の音」を選んだことが、未設定と混ざってはいけない")
        SettingStore.saveGuidanceToneExperimental(true, to: defaults)
        XCTAssertEqual(SettingStore.loadGuidanceToneExperimental(from: defaults), true)
    }
}
