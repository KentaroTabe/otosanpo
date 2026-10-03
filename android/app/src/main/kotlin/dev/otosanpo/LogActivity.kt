package dev.otosanpo

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.view.MenuItem
import android.widget.TextView

/**
 * ログの画面(2026-09-19 に主画面から分けた・利用者依頼)。
 *
 * > 「フィールドログ・イベントログについては別画面とする」
 *
 * 2 つは性質が違う:
 *
 * - **フィールドログ**は端末内の TSV への追記。散歩のあとで取り出して送ってもらう
 * - **イベントログ**は直近の出来事の生表示。開発中に画面で追うためのもの
 *
 * 中身が違うだけで枠は同じなので、`EXTRA_MODE` で切り替える 1 つの画面にする。
 */
class LogActivity : Activity() {

    private val session get() = OtoSanpoApp.instance.session
    private lateinit var body: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installBackButton()
        val root = column()

        if (intent.getStringExtra(EXTRA_MODE) == MODE_EVENT) {
            title = "イベントログ"
            body = label("").apply { typeface = Typeface.MONOSPACE; textSize = 11f }
            root.addView(body)
        } else {
            title = "フィールドログ"
            root.addView(caption("提案・ビーコン・音楽スポットを端末内の TSV に追記します" +
                "(送信しません)"))
            body = label("")
            root.addView(body)
            root.addView(button("ログをダウンロードへ書き出す") { exportLog() })
            root.addView(caption("ダウンロードに入れば、標準のファイルアプリから送れます。" +
                "アプリの置き場は Android 11 以降ほかのアプリから開けません"))
            root.addView(button("ログを消去") {
                session.clearLog()
                refresh()
            })
        }

        setContentView(scrolling(root))
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    private fun refresh() {
        if (intent.getStringExtra(EXTRA_MODE) == MODE_EVENT) {
            // **新しいものを上に。** 散歩中に画面を見るのは「いま何が起きたか」を見る時
            body.text = session.eventLog.reversed().joinToString("\n")
            if (session.eventLog.isEmpty()) body.text = "まだ何も起きていません"
            return
        }
        val file = OtoSanpoApp.instance.storage.fieldLog
        body.text = if (!file.exists() || file.length() == 0L) {
            "まだ記録がありません"
        } else {
            "%,d 行 / %,d バイト".format(file.readLines().size, file.length())
        }
    }

    private fun exportLog() {
        val name = OtoSanpoApp.instance.storage.exportLogToDownloads()
        if (name == null) {
            toast("書き出せませんでした(記録がまだ無いか、保存に失敗しました)")
            return
        }
        toast("ダウンロードに保存しました: $name")
    }

    private fun toast(t: String) {
        android.widget.Toast.makeText(this, t, android.widget.Toast.LENGTH_LONG).show()
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_FIELD = "field"
        const val MODE_EVENT = "event"
    }
}
