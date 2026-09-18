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

    /// **既定は進む向き**(2026-09-18)。選んでいない人の鳴り方は変わらない
    func testOrientationModeIsTravelDirectionUntilChosen() {
        XCTAssertEqual(SettingStore.loadOrientationMode(from: defaults), .travelDirection)
        SettingStore.saveOrientationMode(.phoneHeadMounted, to: defaults)
        XCTAssertEqual(SettingStore.loadOrientationMode(from: defaults), .phoneHeadMounted)
        SettingStore.saveOrientationMode(.travelDirection, to: defaults)
        XCTAssertEqual(SettingStore.loadOrientationMode(from: defaults), .travelDirection)
    }

    /// 壊れた値が入っていても落ちない(既定へ戻す)
    func testUnknownOrientationModeFallsBack() {
        defaults.set("何か別のもの", forKey: "orientation_mode")
        XCTAssertEqual(SettingStore.loadOrientationMode(from: defaults), .travelDirection)
    }

    /// **後ろの音を暗くするのは既定で ON**(前後が分からないという感想への手当て)
    func testRearDarkeningIsOnByDefaultAndSurvives() {
        XCTAssertTrue(SettingStore.loadRearDarkening(from: defaults))
        SettingStore.saveRearDarkening(false, to: defaults)
        XCTAssertFalse(SettingStore.loadRearDarkening(from: defaults),
                       "「暗くしない」を選んだことが、未設定と混ざってはいけない")
    }

    func testGuidanceToneChoiceSurvivesIncludingTheOriginalSound() {
        SettingStore.saveGuidanceToneExperimental(false, to: defaults)
        XCTAssertEqual(SettingStore.loadGuidanceToneExperimental(from: defaults), false,
                       "「元の音」を選んだことが、未設定と混ざってはいけない")
        SettingStore.saveGuidanceToneExperimental(true, to: defaults)
        XCTAssertEqual(SettingStore.loadGuidanceToneExperimental(from: defaults), true)
    }

    // MARK: - 左右の音量差(2026-09-18)

    /// **未校正は nil。** その時は従来の HRTF の経路で鳴らす(→ 合議 C9)
    func testEarBalanceIsNilUntilCalibrated() {
        XCTAssertNil(SettingStore.loadEarBalance(from: defaults))
    }

    /// 合わせた値が残る(→ 合議 C2)
    func testEarBalanceSurvives() {
        XCTAssertTrue(SettingStore.saveEarBalance(EarBalance(rightDb: 7, leftDb: 11),
                                                  to: defaults))
        XCTAssertEqual(SettingStore.loadEarBalance(from: defaults),
                       EarBalance(rightDb: 7, leftDb: 11))
    }

    /// **範囲外は保存しない**(端に張り付いた値を成功として残さない → 合議 C8)
    func testOutOfRangeCalibrationIsNotSaved() {
        XCTAssertFalse(SettingStore.saveEarBalance(EarBalance(rightDb: 99, leftDb: 6),
                                                   to: defaults))
        XCTAssertNil(SettingStore.loadEarBalance(from: defaults))
        XCTAssertFalse(SettingStore.saveEarBalance(EarBalance(rightDb: .nan, leftDb: 6),
                                                   to: defaults))
        XCTAssertNil(SettingStore.loadEarBalance(from: defaults))
    }

    /// 壊れた中身が入っていても、校正済みとして扱わない
    func testBrokenStoredCalibrationIsIgnored() {
        defaults.set(Data("これは JSON ではない".utf8), forKey: "ear_balance")
        XCTAssertNil(SettingStore.loadEarBalance(from: defaults))
    }

    /// 消したら未校正へ戻る(汎用の聞こえ方へ)
    func testClearingReturnsToUncalibrated() {
        SettingStore.saveEarBalance(EarBalance(rightDb: 6, leftDb: 6), to: defaults)
        SettingStore.clearEarBalance(from: defaults)
        XCTAssertNil(SettingStore.loadEarBalance(from: defaults))
    }
}
