import XCTest
@testable import OtoSanpo

/// 音の向きの基準を画面から選べるようにした(2026-09-18 利用者依頼)。
///
/// **ここで押さえるのは 2 つ**:
/// - 画面の選択が効くのは**音楽スポットを選んだ時だけ**
/// - 画面の選択から**実験の値(有効性パルス・実験音色)へ到達しない**
///   (配布物に実験の値を混ぜないという決まりを、迂回しない)
final class OrientationModeTests: XCTestCase {

    /// **既定は進む向き。** 何も選んでいない人の鳴り方が変わらないこと
    func testDefaultIsTravelDirection() {
        XCTAssertFalse(OrientationMode.usesHeadMount(mode: .travelDirection,
                                                     musicSpotWanted: true,
                                                     experimentEnabled: false))
    }

    /// 頭の向きを選んでも、**音楽スポットを選んでいなければ効かない**
    func testHeadMountNeedsTheMusicSpot() {
        XCTAssertFalse(OrientationMode.usesHeadMount(mode: .phoneHeadMounted,
                                                     musicSpotWanted: false,
                                                     experimentEnabled: false))
        XCTAssertTrue(OrientationMode.usesHeadMount(mode: .phoneHeadMounted,
                                                    musicSpotWanted: true,
                                                    experimentEnabled: false))
    }

    /// **実験ビルドは従来どおり。** 設定と音楽スポットの選択によらず頭部固定を使う
    /// (同じビルドで装着あり / なしを比べる運用を壊さない・docs/13)
    func testExperimentBuildAlwaysUsesHeadMount() {
        for mode in OrientationMode.allCases {
            for wanted in [true, false] {
                XCTAssertTrue(OrientationMode.usesHeadMount(mode: mode,
                                                            musicSpotWanted: wanted,
                                                            experimentEnabled: true),
                              "\(mode) / 音楽スポット=\(wanted)")
            }
        }
    }

    /// **画面の選択は、実験の値への入口にならない。**
    ///
    /// 有効性パルス・実験用の音色は `head_mount.enabled`(設定ファイル)だけで決まる。
    /// ここでは「画面で頭部固定を選んでも、その旗は立たない」ことを型の上で固定する
    func testTheProductSwitchDoesNotTurnOnExperimentSounds() throws {
        let p = try ConfigLoader.load(from: repositoryParametersURL())
        // 配布の設定は実験 off(番人は ToneDirectionalityTests にもある)
        XCTAssertFalse(p.headMount.enabled)
        // 画面で頭部固定を選んだ状態を作る
        let uses = OrientationMode.usesHeadMount(mode: .phoneHeadMounted,
                                                 musicSpotWanted: true,
                                                 experimentEnabled: p.headMount.enabled)
        XCTAssertTrue(uses, "定位の基準としては使う")
        XCTAssertFalse(p.headMount.enabled,
                       "実験の値(パルス・実験音色)を決める旗は立たないままであること")
        // 実験用の音色は「実験が有効な時」しか載らない(Core の判断)
        let shipped = p.audio.tones
        XCTAssertEqual(p.experiment.tones(from: shipped, active: p.headMount.enabled), shipped)
    }

    private func repositoryParametersURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config/parameters.json")
    }
}
