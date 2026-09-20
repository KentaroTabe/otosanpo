package dev.otosanpo

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import dev.otosanpo.core.MusicSpot
import dev.otosanpo.core.SoundPlacement
import java.io.File
import kotlin.math.sqrt

/**
 * 音楽スポットの曲を鳴らす(→ docs/08)。
 *
 * ## iOS 版と何が違うか(2026-09-19)
 *
 * iOS は `AVAudioEnvironmentNode`(HRTF)へ渡し、**仰角**(近づくと下から)と
 * **広がり**(遠いほど残響が多い)を載せている。**Android に相当する仕組みは無い**ので、
 * ここでできるのは**左右と音量だけ**:
 *
 * | 手がかり | iOS | Android |
 * |---|---|---|
 * | 左右 | HRTF | **等電力パン**(`MediaPlayer.setVolume(l, r)`) |
 * | 距離 | 音量 | **音量**(同じ) |
 * | 向きによる割り振り | 指向性 dB | **同じ**(音量に掛ける) |
 * | 前後(高域シェルフ) | EQ | 無い |
 * | 仰角・広がり | あり | **無い** |
 *
 * 前後はもともと伝わらないと実測で確定しているので(docs/03)、失うのは
 * 「近づいた時に下から鳴る」手がかりだけ。**そこは Android の弱点として記録しておく。**
 *
 * ## なぜ MediaPlayer か
 *
 * 連続音に毎フレーム左右比を掛けるだけなら `setVolume(left, right)` で足りる。
 * ExoPlayer(Media3)は依存が増え、`MediaCodec` + `AudioTrack` は復号を自前で書くことになる。
 * **入れない依存は壊れない。**
 */
class MusicPlayer(private val context: Context) {

    private var player: MediaPlayer? = null
    /** 鳴り終わった時に呼ぶ(「一度だけ」の約束を守るため、呼ぶ側が記録する) */
    var onFinished: ((String) -> Unit)? = null

    val isPlaying: Boolean get() = player?.isPlaying == true

    /**
     * 鳴らし始める。
     *
     * @return 始められたか。読めない形式・壊れたファイルなら false
     */
    fun start(file: File, placement: MusicSpot.Placement, fade: Double): Boolean {
        stop()
        val mp = MediaPlayer()
        return try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            mp.setDataSource(file.absolutePath)
            mp.prepare()
            mp.setOnCompletionListener {
                player = null
                it.release()
                onFinished?.invoke("最後まで鳴り終わった")
            }
            player = mp
            // **鳴らす前に置く。** 位置と音量を決めてから再生を始める(iOS と同じ順)
            setPlacement(placement, fade)
            mp.start()
            true
        } catch (e: Exception) {
            mp.release()
            player = null
            false
        }
    }

    /**
     * 鳴らしている音の置き方を更新する。**音を止めずに何度でも呼べる**。
     *
     * @param fade 立ち上がりの係数 [0..1]
     */
    fun setPlacement(placement: MusicSpot.Placement, fade: Double) {
        val mp = player ?: return
        val pan = SoundPlacement.pan(placement.relDeg).coerceIn(-1.0, 1.0)
        // 等電力パン(earcon と同じ規則)
        val left = sqrt((1 - pan) / 2)
        val right = sqrt((1 + pan) / 2)
        val g = (placement.gain * fade).coerceIn(0.0, 1.0)
        try {
            mp.setVolume((g * left).toFloat(), (g * right).toFloat())
        } catch (e: IllegalStateException) {
            // 停止と競合した。次の更新で拾う
        }
    }

    fun stop() {
        val mp = player ?: return
        player = null
        try {
            if (mp.isPlaying) mp.stop()
        } catch (e: IllegalStateException) {
            // すでに止まっている
        }
        mp.release()
    }
}
