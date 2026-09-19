package dev.otosanpo

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * 散歩の間だけ動く常駐サービス。
 *
 * **iOS との最大の違いはここ。** iOS は `UIBackgroundModes` の宣言だけで、
 * ポケットに入れたまま位置更新と音が続く。Android は常駐サービスと通知が要る
 * (docs/10「移せないものへの対処」)。
 *
 * 種別に `location` と `mediaPlayback` の両方を宣言するのは、
 * 画面が消えている間も**位置を取り続け、音を鳴らし続ける**ため。
 */
class WalkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification = Notification.Builder(this, OtoSanpoApp.CHANNEL_ID)
            .setContentTitle("散歩中")
            .setContentText("音で案内しています。画面は見なくて大丈夫です")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(open)
            .setOngoing(true)
            .build()

        startForeground(
            NOTIFICATION_ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        )
        // 画面を閉じても位置の購読が続くようにする(念のため呼び直す)
        OtoSanpoApp.instance.session.startLocation()
        return START_STICKY
    }

    companion object {
        private const val NOTIFICATION_ID = 1

        fun start(context: android.content.Context) {
            context.startForegroundService(Intent(context, WalkService::class.java))
        }

        fun stop(context: android.content.Context) {
            context.stopService(Intent(context, WalkService::class.java))
        }
    }
}
