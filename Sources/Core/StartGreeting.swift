import Foundation

/// 散歩を始めるときの一言を、時刻から選ぶ純粋ロジック。
///
/// **文言と時間帯は `config/parameters.json` に置く**(コードに埋めない)。
/// 深夜と早朝で言うことが変わるのは体験の一部で、実測ではなく好みで動かす値になる。
/// 設定にあれば、アプリを組み直さずに直せる。
///
/// 時間帯は**日をまたげる**(22 時 → 5 時のように `from > to` なら真夜中をまたぐ)。
/// 先に書いた窓が優先される(最初に当たったものを採る)。
public enum StartGreeting {
    /// - Parameter hour: 0..23。境界は「開始を含み、終了を含まない」
    /// - Returns: 当てはまる窓が無ければ nil(何も出さない)
    public static func message(hour: Int,
                               windows: [AppParameters.GreetingWindow]) -> String? {
        guard (0...23).contains(hour) else { return nil }
        for w in windows {
            let matches: Bool
            if w.fromHour <= w.toHour {
                matches = hour >= w.fromHour && hour < w.toHour
            } else {
                // 真夜中をまたぐ窓(22 時〜5 時など)
                matches = hour >= w.fromHour || hour < w.toHour
            }
            if matches { return w.message }
        }
        return nil
    }

    /// いまの時刻で選ぶ。時計の読み取りは呼び出し側から渡す(Core は時計を持たない)
    public static func message(at date: Date, calendar: Calendar = .current,
                               windows: [AppParameters.GreetingWindow]) -> String? {
        message(hour: calendar.component(.hour, from: date), windows: windows)
    }
}
