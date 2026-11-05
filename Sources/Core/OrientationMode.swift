import Foundation

/// **音をどの向きを基準に置くか**(利用者が画面で選ぶ・2026-09-18 利用者依頼)。
///
/// これまで頭部固定は `config/parameters.json` の `head_mount.enabled` だけで切り替わり、
/// **実験ビルドでしか使えなかった**(docs/13)。
/// 「音楽スポットのスイッチが ON の時は、アプリ側から選べるように」という依頼で、
/// **製品の設定**として独立させた。
///
/// ## 実験の値とは混ぜない
///
/// `head_mount.enabled` は頭部固定のほかに**有効性パルス・実験用の音色・詳しいログ**も
/// 同時に切り替える。画面の選択からそれらへ到達してはいけない(配布物に実験の値を混ぜない)。
/// そのため、この設定が決めるのは**定位の基準をどこから取るか**だけにしてある。
public enum OrientationMode: String, Codable, CaseIterable, Sendable {
    /// 進む向きを基準にする(配布版の従来どおり)。立ち止まると左右が保持値になる
    case travelDirection
    /// スマホを頭に固定し、その絶対方位を基準にする。**立ち止まっても左右が残る**
    case phoneHeadMounted

    /// この散歩で頭部固定の方位を定位の基準に使うか。
    ///
    /// - Parameter experimentEnabled: `head_mount.enabled`。**実験ビルドは従来どおり常に使う**
    /// - Parameter musicSpotWanted: 音楽スポットを選んだか。
    ///   画面の選択が効くのは**音楽スポットを選んだ時だけ**(2026-09-18 利用者依頼)
    public static func usesHeadMount(mode: OrientationMode,
                                     musicSpotWanted: Bool,
                                     experimentEnabled: Bool) -> Bool {
        if experimentEnabled { return true }
        return musicSpotWanted && mode == .phoneHeadMounted
    }
}
