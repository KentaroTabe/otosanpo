package dev.otosanpo

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager

/**
 * アプリ全体で 1 つのセッションを持つ。
 *
 * 画面と常駐サービスの両方がこれを見る。プロセスは 1 つなので、
 * バインダを挟まず素直に共有する(試作の割り切り)。
 */
class OtoSanpoApp : Application() {
    lateinit var session: WalkSession
        private set

    /** 設定の読み込みに失敗した理由。画面はこれを出して止まる(既定値へ落ちない) */
    var configError: String? = null
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this

        val storage = Storage(this)
        try {
            val params = storage.loadParameters()
            session = WalkSession(
                params = params,
                storage = storage,
                location = LocationSource(this),
                steps = StepCadence(this),
                player = EarconPlayer(params.audio),
            )
        } catch (e: Exception) {
            // **数値の既定値をコードに持たない**(CLAUDE.md)。読めなければ止める
            configError = e.message ?: e.toString()
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "散歩中",
                                NotificationManager.IMPORTANCE_LOW)
        )
    }

    companion object {
        const val CHANNEL_ID = "walk"
        lateinit var instance: OtoSanpoApp
            private set
    }
}
