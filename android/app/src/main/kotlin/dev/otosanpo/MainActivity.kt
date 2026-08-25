package dev.otosanpo

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.otosanpo.core.Earcon
import dev.otosanpo.core.StartGreeting
import dev.otosanpo.core.WalkState
import kotlin.math.roundToInt

/**
 * 設定とデバッグのための画面。**散歩が始まったら端末はポケットに入れる**のが本来の体験で、
 * ここは出発前と帰宅後にだけ見るもの。
 *
 * 画面は素の View で組む(外部の UI ライブラリを足さない。docs/10)。
 *
 * **音量ボタンで「帰る / 延長」を受ける。** Android にはヘッドフォンの頭部姿勢を取る
 * 公開 API が無いので、うなずき / 首振りの代わり。ポケットの中でも押せるので
 * 「画面を見ない」は保てる。
 */
class MainActivity : Activity() {
    private val session get() = OtoSanpoApp.instance.session
    private val handler = Handler(Looper.getMainLooper())

    private lateinit var stateText: TextView
    private lateinit var statusText: TextView
    private lateinit var summaryText: TextView
    private lateinit var logText: TextView
    private lateinit var startButton: Button
    private lateinit var durationText: TextView
    private lateinit var homeText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        OtoSanpoApp.instance.configError?.let {
            setContentView(errorView(it))
            return
        }

        setContentView(buildView())
        requestPermissionsIfNeeded()
        session.onChange = { handler.post { refresh() } }
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    /**
     * **音量ボタンを応答に使う**(時間到来の応答待ちの間だけ)。
     * 下げる = 帰る、上げる = 延長。それ以外の場面では普通の音量操作に通す
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (session.state == WalkState.PROMPTING_RETURN) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> { session.nod(); return true }
                KeyEvent.KEYCODE_VOLUME_UP -> { session.shake(); return true }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun requestPermissionsIfNeeded() {
        val wanted = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION,
                                   Manifest.permission.ACTIVITY_RECOGNITION)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = wanted.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            session.startLocation()
            return
        }
        requestPermissions(missing.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
                                            grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        session.startLocation()
        refresh()
    }

    // MARK: - 画面の組み立て

    private fun buildView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }

        root.addView(heading("設定"))
        homeText = label("自宅: 未設定")
        root.addView(homeText)
        root.addView(button("自宅を現在地に設定") {
            if (!session.setHomeHere()) toast("現在地をまだ取得できていません")
            refresh()
        })

        durationText = label("散歩時間: 30 分")
        root.addView(durationText)
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(button("− 5 分") { changeDuration(-5.0) })
        row.addView(button("+ 5 分") { changeDuration(5.0) })
        root.addView(row)

        root.addView(heading("セッション"))
        stateText = label("待機中").apply {
            textSize = 20f
            setTypeface(typeface, Typeface.BOLD)
        }
        root.addView(stateText)
        statusText = label("")
        root.addView(statusText)
        startButton = button("散歩を開始") { toggleWalk() }
        root.addView(startButton)

        root.addView(heading("応答(時間到来のとき)"))
        root.addView(label("音量↓ = 帰る / 音量↑ = 延長。ポケットの中でも押せます"))
        val answer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        answer.addView(button("帰る") { session.nod() })
        answer.addView(button("延長") { session.shake() })
        root.addView(answer)

        root.addView(heading("前回の散歩(開発用)"))
        summaryText = label("記録はまだありません")
        root.addView(summaryText)

        root.addView(heading("デバッグ"))
        root.addView(button("時間到来を発火") { session.debugTimeUp() })
        val tones = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tones.addView(button("提案音 左") { session.playSample(Earcon.SUGGESTION, -90.0) })
        tones.addView(button("提案音 右") { session.playSample(Earcon.SUGGESTION, 90.0) })
        root.addView(tones)
        val tones2 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tones2.addView(button("帰路音") { session.playSample(Earcon.HOME_BEACON, 0.0) })
        tones2.addView(button("到着音") { session.playSample(Earcon.ARRIVAL, 0.0) })
        root.addView(tones2)

        root.addView(heading("フィールドログ"))
        root.addView(label("端末内の TSV に追記します(送信しません)"))
        root.addView(button("ログをダウンロードへ書き出す") { shareLog() })
        root.addView(button("ログを消去") { session.clearLog(); refresh() })

        root.addView(heading("イベントログ"))
        logText = label("").apply { typeface = Typeface.MONOSPACE; textSize = 11f }
        root.addView(logText)

        root.addView(heading("経路データの出典"))
        root.addView(label("© OpenStreetMap contributors\n" +
            "この経路データは OpenStreetMap から作成しました。ODbL の下で提供されています。"))

        return ScrollView(this).apply {
            addView(root, ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT)
        }
    }

    private fun errorView(message: String): View =
        TextView(this).apply {
            text = "設定ファイルを読み込めません:\n$message\n\n" +
                "parameters.json が assets に入っていない可能性があります。"
            setPadding(48, 48, 48, 48)
            gravity = Gravity.CENTER
        }

    private fun heading(t: String) = TextView(this).apply {
        text = t
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 40, 0, 8)
    }

    private fun label(t: String) = TextView(this).apply {
        text = t
        setPadding(0, 4, 0, 4)
    }

    private fun button(t: String, action: () -> Unit) = Button(this).apply {
        text = t
        setOnClickListener { action() }
    }

    // MARK: - 操作

    private fun changeDuration(delta: Double) {
        val p = session.params.session
        session.durationMin = (session.durationMin + delta)
            .coerceIn(p.minDurationMin, p.maxDurationMin)
        refresh()
    }

    private fun toggleWalk() {
        if (session.state == WalkState.IDLE || session.state == WalkState.ARRIVED) {
            if (!session.start()) {
                toast("現在地をまだ取得できていません")
                return
            }
            WalkService.start(this)
            showGreeting()
        } else {
            session.stopManually()
            WalkService.stop(this)
        }
        refresh()
    }

    /**
     * 出発の一言。**画面を見るのは開始の瞬間だけ**なので、ここに出す。
     * 文言と時間帯は `config/parameters.json`(判断は Core の `StartGreeting`)
     */
    private fun showGreeting() {
        val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        val message = StartGreeting.message(hour, session.params.greeting.windows) ?: return
        android.app.AlertDialog.Builder(this)
            .setMessage(message)
            .setPositiveButton("はい") { d, _ -> d.dismiss() }
            .show()
    }

    /**
     * ログを「ダウンロード」へ複製する。**そこからなら標準のファイルアプリで共有できる。**
     * アプリの置き場は Android 11 以降ほかのアプリから開けないので、そのままでは返せない
     */
    private fun shareLog() {
        val name = Storage(this).exportLogToDownloads()
        if (name == null) {
            toast("書き出せませんでした(記録がまだ無いか、保存に失敗しました)")
            return
        }
        toast("ダウンロードに保存しました: $name")
    }

    private fun toast(t: String) {
        android.widget.Toast.makeText(this, t, android.widget.Toast.LENGTH_LONG).show()
    }

    private fun refresh() {
        homeText.text = if (session.home == null) "自宅: 未設定" else "自宅: 設定済み"
        durationText.text = "散歩時間: ${session.durationMin.roundToInt()} 分"
        stateText.text = when (session.state) {
            WalkState.IDLE -> "待機中"
            WalkState.WANDERING -> "散策中(音の提案あり)"
            WalkState.PROMPTING_RETURN -> "帰りますか?(音量↓=帰る / 音量↑=延長)"
            WalkState.RETURNING -> "帰路(音で案内中)"
            WalkState.ARRIVED -> "到着"
        }
        statusText.text = session.statusLine
        startButton.text =
            if (session.state == WalkState.IDLE || session.state == WalkState.ARRIVED) {
                if (session.home == null) "ここを自宅にして散歩を開始" else "散歩を開始"
            } else "終了"

        summaryText.text = session.lastSummary?.let { s ->
            val endings = s.endingCounts().joinToString(" / ") { "${it.first} ${it.second}" }
            "距離 %.0f m / 時間 %.0f 分 / イベント %d 件\n%s".format(
                s.pathLengthM, s.durationSec / 60, s.guidanceEvents.size, endings)
        } ?: "記録はまだありません"

        logText.text = session.eventLog.reversed().take(12).joinToString("\n")
    }
}
