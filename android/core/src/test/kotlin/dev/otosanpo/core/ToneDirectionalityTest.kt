package dev.otosanpo.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * 左右の定位を可能にする音の性質(倍音とアタック)。
 * **iOS 版 Tests/ToneDirectionalityTests.swift と同じ規則**を確かめる
 * — 片方だけ直すと、同じ設定ファイルから違う音が出る。
 *
 * 経緯(2026-09-01): 440 Hz の純音 + 左右対称の窓は、
 * ILD(1.5 kHz 以上で効く)も ITD(鋭い立ち上がりが要る)も持たず、
 * 実機で「音の向きが分からず従えなかった」。
 */
class ToneDirectionalityTest {

    private fun spec(harmonics: Int, attack: Double) = AppParameters.ToneSpec(
        freqsHz = listOf(440.0), blipSec = 0.07, gapSec = 0.0, noiseMix = 0.0,
        harmonics = harmonics, harmonicDecay = 0.7, attackRatio = attack
    )

    /** 指定周波数より上の帯域が持つ振幅の割合(素朴な DFT) */
    private fun highBandRatio(s: FloatArray, sampleRate: Double, above: Double): Double {
        var total = 0.0
        var high = 0.0
        var k = 50.0
        while (k <= 6000.0) {
            var re = 0.0
            var im = 0.0
            for ((i, v) in s.withIndex()) {
                val a = 2 * Math.PI * k * i / sampleRate
                re += v * cos(a)
                im += v * sin(a)
            }
            val amplitude = hypot(re, im)
            total += amplitude
            if (k > above) high += amplitude
            k += 50.0
        }
        return if (total > 0) high / total else 0.0
    }

    /** 倍音が ILD の効く帯域(1.5 kHz 超)にエネルギーを作る */
    @Test
    fun harmonicsCreateEnergyAboveTheILDThreshold() {
        val sr = 44100.0
        val pure = ToneRenderer.samples(spec(1, 0.5), sr, 1.0)
        val rich = ToneRenderer.samples(spec(4, 0.5), sr, 1.0)
        assertTrue(highBandRatio(pure, sr, 1500.0) < 0.05, "純音に高域があってはいけない")
        assertTrue(highBandRatio(rich, sr, 1500.0) > 0.08, "倍音が高域成分を作れていない")
    }

    /** 倍音を足しても音量は跳ねない(重みの合計で正規化しているため) */
    @Test
    fun harmonicsDoNotInflateLoudness() {
        val sr = 44100.0
        val pureMax = ToneRenderer.samples(spec(1, 0.5), sr, 1.0).maxOf { abs(it) }
        val richMax = ToneRenderer.samples(spec(4, 0.5), sr, 1.0).maxOf { abs(it) }
        assertTrue(richMax < pureMax * 1.3f, "倍音で音量が跳ねている")
    }

    /** 鋭いアタックは尖頭に早く達する(ITD の手がかり) */
    @Test
    fun sharpAttackReachesPeakSooner() {
        val sr = 44100.0
        fun framesToPeak(attack: Double): Int {
            val s = ToneRenderer.samples(spec(1, attack), sr, 1.0)
            val peak = s.maxOf { abs(it) }
            return s.indexOfFirst { abs(it) >= peak * 0.9f }.let { if (it < 0) s.size else it }
        }
        assertTrue(framesToPeak(0.05) < framesToPeak(0.5) / 4, "アタックが鋭くなっていない")
    }

    /** 鋭くしても先頭は 0 から始まる(プチッと鳴らない) */
    @Test
    fun sharpAttackStillStartsFromSilence() {
        val s = ToneRenderer.samples(spec(4, 0.05), 44100.0, 1.0)
        assertTrue(abs(s.first()) < 1e-6f, "先頭が 0 でない")
        assertTrue(abs(s.last()) < 1e-3f, "終端が 0 へ落ちていない")
    }

    /** 実際に配る設定で、方向を伝える 2 つの音が高域成分を持つ */
    @Test
    fun shippedDirectionalTonesCarryHighFrequencies() {
        val text = java.io.File("../../config/parameters.json").readText()
        val p = AppParameters.decode(text)
        for ((name, tone) in listOf("ビーコン" to p.audio.tones.homeBeacon,
                                    "提案音" to p.audio.tones.suggestion)) {
            assertTrue(tone.harmonics > 1, "$name が純音のままでは左右が伝わらない")
            assertTrue(tone.attackRatio < 0.3, "$name の立ち上がりが鈍い")
        }
    }
}
