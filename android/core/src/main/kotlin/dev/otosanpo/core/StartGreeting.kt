package dev.otosanpo.core

/**
 * 散歩を始めるときの一言を、時刻から選ぶ純粋ロジック。
 *
 * **文言と時間帯は `config/parameters.json` に置く**(コードに埋めない)。
 * 深夜と早朝で言うことが変わるのは体験の一部なので、実測ではなく好みで動かす値になる。
 * 設定にあれば、アプリを組み直さずに直せる。
 *
 * 時間帯は**日をまたげる**(22 時→5 時のように `from > to` なら真夜中をまたぐ)。
 * 先に書いた窓が優先される(最初に当たったものを採る)。
 */
object StartGreeting {
    /**
     * @param hour 0..23。境界は「開始を含み、終了を含まない」
     * @return 当てはまる窓が無ければ null(何も出さない)
     */
    fun message(hour: Int, windows: List<AppParameters.Greeting.Window>): String? {
        if (hour !in 0..23) return null
        for (w in windows) {
            val matches = if (w.fromHour <= w.toHour) {
                hour >= w.fromHour && hour < w.toHour
            } else {
                // 真夜中をまたぐ窓(22 時〜5 時など)
                hour >= w.fromHour || hour < w.toHour
            }
            if (matches) return w.message
        }
        return null
    }
}
