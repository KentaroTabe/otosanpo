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
import android.view.MenuItem
import android.view.View
import android.widget.Button
import android.widget.TextView
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

    private companion object {
        const val REQUEST_PICK_MUSIC = 2
    }

    private lateinit var stateText: TextView
    private lateinit var statusText: TextView
    private lateinit var summaryText: TextView
    private lateinit var startButton: Button
    private lateinit var durationText: TextView
    private lateinit var homeText: TextView
    private lateinit var musicText: TextView
    private lateinit var musicToggle: Button

    /**
     * **曲を選ぶピッカー**(2026-09-19 利用者依頼)。
     *
     * `androidx.activity` の仕組み(`registerForActivityResult`)は使わない。
     * **外部の UI ライブラリを足さない**方針(docs/10)なので、素の
     * `startActivityForResult` + [onActivityResult] で受ける。
     *
     * `ACTION_OPEN_DOCUMENT` が返すのは `content://` の URI。**持ち続けない** —
     * 元を消された・SD を外された・提供元アプリを消された、で失効するうえ、
     * クラウド上の曲だと読むたびに通信が要る(散歩中に止まる)。
     * **選んだその場でアプリの中へ写す**ので、使い切りで足りる
     */
    private fun pickMusic() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_MUSIC)
        } catch (e: Exception) {
            toast("曲を選ぶ画面を開けませんでした")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_MUSIC || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        val ext = session.params.audio.androidReadableExtensions
        val saved = OtoSanpoApp.instance.storage.importMusic(uri, displayNameOf(uri), ext)
        if (saved == null) {
            toast("この曲は読み込めませんでした(${ext.joinToString(" / ")})")
        } else {
            toast("曲を取り込みました: ${saved.name}")
        }
        refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        OtoSanpoApp.instance.configError?.let {
            setContentView(errorView(it))
            return
        }

        // 毎回設定するわけではないものはメニューへ(2026-09-19 利用者依頼)。
        // **画面を組む前に決める** — 上の帯が無い端末では画面の中に導線を置く
        val hasBar = installMenuButton()
        setContentView(buildView(showMenuRow = !hasBar))
        requestPermissionsIfNeeded()
        session.onChange = { handler.post { refresh() } }
        refresh()
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            openMenu()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    private fun openMenu() = startActivity(Intent(this, MenuActivity::class.java))

    override fun onResume() {
        super.onResume()
        refresh()
    }

    /**
     * **音量ボタンを応答に使う**(応答待ちの間だけ)。それ以外の場面では普通の音量操作に通す。
     *
     * 2 種類の問いかけがあるが、**同時には開かない**(スポットを移す提案は
     * 散策中しか出さず、帰路の問いかけが入れば見送られる → `WalkSession.tickSpotMove`)。
     *
     * | 問いかけ | 音量↓ | 音量↑ |
     * |---|---|---|
     * | 時間到来 | 帰る | 延長 |
     * | スポットを移す | 移す | そのまま |
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (session.state == WalkState.PROMPTING_RETURN) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> { session.nod(); return true }
                KeyEvent.KEYCODE_VOLUME_UP -> { session.shake(); return true }
            }
        }
        if (session.acceptsSpotMoveResponse) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> { session.acceptSpotMove(); return true }
                KeyEvent.KEYCODE_VOLUME_UP -> { session.refuseSpotMove(); return true }
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

    private fun buildView(showMenuRow: Boolean): View {
        val root = column()

        if (showMenuRow) root.addView(button("≡ メニュー") { openMenu() })

        root.addView(heading("設定"))
        homeText = label("自宅: 未設定")
        root.addView(homeText)
        root.addView(button("自宅を現在地に設定") {
            if (!session.setHomeHere()) toast("現在地をまだ取得できていません")
            refresh()
        })

        durationText = label("散歩時間: 30 分")
        root.addView(durationText)
        val duration = row()
        duration.addView(button("− 5 分") { changeDuration(-5.0) })
        duration.addView(button("+ 5 分") { changeDuration(5.0) })
        root.addView(duration)

        // **音楽スポット**(2026-09-19 に iOS から移植)。曲が取り込まれていなければ
        // 選ぶ導線だけを出す。**基準は進む向きだけ**(頭の向きは使わない)
        musicText = label("")
        root.addView(musicText)
        root.addView(button("音楽スポットに使う曲を選ぶ") { pickMusic() })
        musicToggle = button("音楽スポット: 切") { toggleMusicSpot() }
        root.addView(musicToggle)

        root.addView(heading("状態"))
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
        val answer = row()
        answer.addView(button("帰る") { session.nod() })
        answer.addView(button("延長") { session.shake() })
        root.addView(answer)

        root.addView(heading("前回の散歩"))
        summaryText = label("記録はまだありません")
        root.addView(summaryText)

        // 試聴・ログ・出典は左上のメニューへ移した(2026-09-19 利用者依頼)。
        // **出典の 1 行だけは主画面に残す**(ODbL の表示義務。iOS 版も同じ扱い)
        root.addView(caption("© OpenStreetMap contributors"))

        return scrolling(root)
    }

    private fun errorView(message: String): View =
        TextView(this).apply {
            text = "設定ファイルを読み込めません:\n$message\n\n" +
                "parameters.json が assets に入っていない可能性があります。"
            setPadding(48, 48, 48, 48)
            gravity = Gravity.CENTER
        }

    /** ピッカーが返した表示名(拡張子の判定に使う)。取れなければ null */
    private fun displayNameOf(uri: android.net.Uri): String? =
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) c.getString(i) else null
        }

    private fun toggleMusicSpot() {
        val ext = session.params.audio.androidReadableExtensions
        if (OtoSanpoApp.instance.storage.musicFile(ext) == null) {
            toast("先に曲を選んでください")
            return
        }
        session.musicSpotWanted = !session.musicSpotWanted
        refresh()
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
            // 「はい」は問いへの答えに見える。ここはただの一言なので「OK」
            // (2026-09-19 利用者依頼・iOS 版と同じ)
            .setPositiveButton("OK") { d, _ -> d.dismiss() }
            .show()
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

        val ext = session.params.audio.androidReadableExtensions
        val song = OtoSanpoApp.instance.storage.musicFile(ext)
        musicText.text = if (song == null) {
            "音楽スポット: 曲が未選択\n端末の曲を 1 つ選びます。選んだ曲はアプリの中へ写します"
        } else {
            "音楽スポット: 曲 ${song.name}\n出発した地点から散歩時間に応じた距離に 1 つ置きます"
        }
        musicToggle.text = if (session.musicSpotWanted) "音楽スポット: 入" else "音楽スポット: 切"
        musicToggle.isEnabled = song != null
        startButton.text =
            if (session.state == WalkState.IDLE || session.state == WalkState.ARRIVED) {
                if (session.home == null) "ここを自宅にして散歩を開始" else "散歩を開始"
            } else "終了"

        summaryText.text = session.lastSummary?.let { s ->
            val endings = s.endingCounts().joinToString(" / ") { "${it.first} ${it.second}" }
            "距離 %.0f m / 時間 %.0f 分 / イベント %d 件\n%s".format(
                s.pathLengthM, s.durationSec / 60, s.guidanceEvents.size, endings)
        } ?: "記録はまだありません"
    }
}
