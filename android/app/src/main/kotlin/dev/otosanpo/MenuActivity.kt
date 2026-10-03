package dev.otosanpo

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.MenuItem
import dev.otosanpo.core.Earcon

/**
 * 左上の三本線から開くメニュー(2026-09-19 利用者依頼・iOS の `MenuView` に対応)。
 *
 * **毎回設定するものは主画面、そうでないものはここ**、という分け方にする。
 * 出発前に触るのは「自宅」「散歩時間」「音楽スポット」だけで、
 * 音の試聴やログは一度見れば足りる。主画面に並べると出発前に見るものが埋もれる。
 *
 * iOS 版との違い: **「真横に聞こえる角度」はここに無い**。
 * あれは HRTF へ渡す角度を歪める設定で、Android は等電力パンしか持たない(→ [MusicPlayer])。
 */
class MenuActivity : Activity() {

    private val session get() = OtoSanpoApp.instance.session

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "メニュー"
        installBackButton()

        val root = column()

        root.addView(heading("音の設定"))
        root.addView(caption("案内音を試聴します。散歩中に鳴るものと同じ音です"))
        val tones = row()
        tones.addView(button("提案音 左") { session.playSample(Earcon.SUGGESTION, -90.0) })
        tones.addView(button("提案音 右") { session.playSample(Earcon.SUGGESTION, 90.0) })
        root.addView(tones)
        val tones2 = row()
        tones2.addView(button("帰路音") { session.playSample(Earcon.HOME_BEACON, 0.0) })
        tones2.addView(button("到着音") { session.playSample(Earcon.ARRIVAL, 0.0) })
        root.addView(tones2)

        root.addView(heading("記録"))
        root.addView(button("フィールドログ") { openLog(LogActivity.MODE_FIELD) })
        root.addView(button("イベントログ") { openLog(LogActivity.MODE_EVENT) })

        // **「時間到来を発火」は置かない**(2026-09-19 利用者判断)。
        // iOS 版では 2026-09-17 に消してある(CLAUDE.md)。片方だけ画面から
        // 流れを起こせると、**同じ手順で試したつもりの記録が食い違う**
        root.addView(heading("クレジット"))
        // 経路データは OpenStreetMap 由来。**ODbL は出典表示を求める**
        // (docs/04「OSM データの持ち方」)。主画面にも 1 行残してある
        root.addView(caption("© OpenStreetMap contributors"))
        root.addView(caption("この経路データは OpenStreetMap から作成しました。" +
            "OpenStreetMap のデータは Open Database License (ODbL) の下で提供されています。"))
        root.addView(button("openstreetmap.org/copyright") {
            open("https://www.openstreetmap.org/copyright")
        })

        setContentView(scrolling(root))
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    private fun openLog(mode: String) {
        startActivity(Intent(this, LogActivity::class.java)
                          .putExtra(LogActivity.EXTRA_MODE, mode))
    }

    private fun open(url: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (e: Exception) {
            android.widget.Toast
                .makeText(this, "開けませんでした: $url", android.widget.Toast.LENGTH_LONG)
                .show()
        }
    }
}
