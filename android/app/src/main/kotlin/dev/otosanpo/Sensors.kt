package dev.otosanpo

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import dev.otosanpo.core.GeoPoint
import dev.otosanpo.core.MotionFix

/**
 * 位置情報。**`LocationManager` を直に使う**(Play Services に依存しない)。
 *
 * iOS の `CLLocation` と 1 対 1 で対応する:
 * course → `bearing` / courseAccuracy → `bearingAccuracyDegrees` / speed → `speed` /
 * horizontalAccuracy → `accuracy`。
 *
 * **送信はしない。** 端末内で使い、記録も端末内に置く(docs/04)。
 */
class LocationSource(context: Context) {
    private val manager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    var onPosition: ((GeoPoint) -> Unit)? = null

    var position: GeoPoint? = null
        private set

    private var last: Location? = null

    private val listener = object : LocationListener {
        override fun onLocationChanged(l: Location) {
            last = l
            val p = GeoPoint(l.latitude, l.longitude)
            position = p
            onPosition?.invoke(p)
        }

        // 古い API のための空実装(端末によっては呼ばれる)
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    /** 権限が無い状態で呼ばれても落ちないようにする(画面側で要求してから呼ぶ) */
    @SuppressLint("MissingPermission")
    fun start() {
        try {
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, listener)
        } catch (e: SecurityException) {
            // 権限が無い。画面が要求し直す
        } catch (e: IllegalArgumentException) {
            // GPS が無い端末
        }
    }

    fun stop() {
        manager.removeUpdates(listener)
    }

    /** 方向の判定材料。**無効値の扱いは Core(TravelDirection)に集約する** */
    fun motionFix(): MotionFix {
        val l = last ?: return MotionFix()
        val ageSec = (System.currentTimeMillis() - l.time) / 1000.0
        return MotionFix(
            courseDeg = if (l.hasBearing()) l.bearing.toDouble() else null,
            courseAccuracyDeg =
                if (l.hasBearingAccuracy()) l.bearingAccuracyDegrees.toDouble() else null,
            speedMps = if (l.hasSpeed()) l.speed.toDouble() else null,
            compassHeadingDeg = null,
            ageSec = ageSec,
            horizontalAccuracyM = if (l.hasAccuracy()) l.accuracy.toDouble() else null,
        )
    }
}

/**
 * 歩調。`TYPE_STEP_DETECTOR` は 1 歩ごとに 1 件来るので、その間隔から歩/秒を出す。
 *
 * ビーコンの間隔を歩みに同期させるためだけに使う(歩数も移動距離も使わない。
 * 距離は位置情報から取るほうが確かで、端末に余計な情報を置かないため)。
 */
class StepCadence(context: Context) : SensorEventListener {
    private val manager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor: Sensor? = manager.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)

    val isAvailable: Boolean get() = sensor != null

    /** 直近の歩の時刻 [ms]。間隔の平均から歩調を出す */
    private val recent = ArrayDeque<Long>()

    fun start() {
        sensor?.let { manager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) }
    }

    fun stop() {
        manager.unregisterListener(this)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val now = System.currentTimeMillis()
        recent.addLast(now)
        while (recent.size > 8) recent.removeFirst()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    /**
     * いま使える歩調 [歩/秒]。立ち止まると更新が来なくなるので鮮度で切る。
     * 取れなければ null(呼び出し側が既定の間隔へ落ちる)
     */
    fun cadence(maxAgeSec: Double): Double? {
        if (recent.size < 3) return null
        val now = System.currentTimeMillis()
        val lastStep = recent.last()
        if ((now - lastStep) / 1000.0 > maxAgeSec) return null
        val span = (lastStep - recent.first()) / 1000.0
        if (span <= 0) return null
        return (recent.size - 1) / span
    }
}
