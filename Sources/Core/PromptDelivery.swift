import Foundation

/// 時間到来のプロンプトを「いま鳴らす」か「付け直しまで保留する」かの判断。
///
/// 保留してよいのは**着けていた人が外した場合だけ**。
/// AirPods を持っていない人には「付け直す」という契機が来ないので、保留すると
/// 鳴らし直しの機会が永遠に訪れず、時間到来がどこにも出ないまま散歩が終わる。
/// 60 秒ごとの鳴らし直しも同じ経路を通るため、まとめて消える。
///
/// 2026-08-26 に発見。判定に使っているのは `CMHeadphoneMotionManager` の接続で、
/// これは**モーション対応の AirPods にしか反応しない**。有線イヤホンや
/// スピーカーで聴いている人は、装着していても「未接続」として扱われる。
public enum PromptDelivery {
    /// - Parameters:
    ///   - connected: いまモーション対応のヘッドフォンが繋がっているか
    ///   - hasEverConnected: この散歩で一度でも繋がったか
    /// - Returns: 保留するなら true(鳴らさずに持ち越す)
    public static func shouldHold(connected: Bool, hasEverConnected: Bool) -> Bool {
        !connected && hasEverConnected
    }
}
