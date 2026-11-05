package dev.otosanpo

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import dev.otosanpo.core.AppParameters
import dev.otosanpo.core.Earcon
import dev.otosanpo.core.SoundPlacement
import dev.otosanpo.core.ToneRenderer

/**
 * earcon を鳴らす。**波形は Core(`ToneRenderer`)が作る**ので、iOS 版とまったく同じ音になる。
 * ここは `AudioTrack` に載せるだけ(Services にロジックを持たせない。CLAUDE.md)。
 *
 * **定位はステレオパン。** Android に `AVAudioEnvironmentNode` 相当は無いが、
 * iOS の実測で HRTF でも前後は判別できず、前後は音色で分けている(docs/03)。
 * その手は Android でもそのまま使えるので、失うのは前後だけ — もともと使えていない。
 *
 * 音量ではなく `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` を使うのは、
 * 利用者の音楽を止めずに**一瞬だけ被せる**ため(iOS の duckOthers に相当)。
 */
class EarconPlayer(private val audio: AppParameters.Audio) {
    private val sampleRate = audio.sampleRate.toInt()

    /** 音色ごとの標本列を先に作っておく。鳴らすたびに合成しない */
    private val cache = HashMap<String, FloatArray>()

    private fun samplesFor(e: Earcon, behind: Boolean): FloatArray {
        val key = "${e.name}:$behind"
        return cache.getOrPut(key) {
            val spec = audio.tones[e]
            val tone = if (behind) ToneRenderer.darken(spec, audio.behindDarkness) else spec
            ToneRenderer.samples(tone, audio.sampleRate, audio.earconGain)
        }
    }

    /**
     * @param relativeBearingDeg 進行方向を 0、右を正とした相対方位。null なら中央
     * @param gain 相対音量 [0..1]。距離を音量で表すため(docs/03)
     */
    fun play(e: Earcon, relativeBearingDeg: Double? = null, gain: Double = 1.0) {
        val deg = relativeBearingDeg ?: 0.0
        // 前後は定位では伝わらない(2026-08-18 実測)。音色で分ける
        val behind = kotlin.math.abs(dev.otosanpo.core.Geo.angularDiffDeg(deg, 0.0)) >
            audio.behindThresholdDeg
        val mono = samplesFor(e, behind)
        if (mono.isEmpty()) return

        val pan = SoundPlacement.pan(deg).coerceIn(-1.0, 1.0)
        // 等電力パン。中央でも端でも聞こえの大きさが変わらないようにする
        val left = kotlin.math.sqrt((1 - pan) / 2).toFloat()
        val right = kotlin.math.sqrt((1 + pan) / 2).toFloat()
        val g = gain.coerceIn(0.0, 1.0).toFloat()

        val out = ShortArray(mono.size * 2)
        for (i in mono.indices) {
            val v = mono[i] * g
            out[i * 2] = (v * left * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
            out[i * 2 + 1] = (v * right * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(out.size * 2)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        track.write(out, 0, out.size)
        track.setNotificationMarkerPosition(mono.size)
        track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
            override fun onMarkerReached(t: AudioTrack?) {
                // 鳴り終わったら捨てる。1 音ごとに作って捨てる作りなので、残すと溜まる
                t?.release()
            }

            override fun onPeriodicNotification(t: AudioTrack?) {}
        })
        track.play()
    }
}
