package dev.otosanpo.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * **iOS 版と同じ `config/parameters.json` をそのまま読めること。**
 * 数値を 2 か所に置かないという約束(docs/10)は、これが通ることで守られる。
 */
class AppParametersTest {
    private fun load(): AppParameters {
        // core モジュールから見たリポジトリのルート
        val f = File("../../config/parameters.json")
        assertTrue(f.exists(), "parameters.json が見つからない: ${f.absolutePath}")
        return AppParameters.decode(f.readText())
    }

    @Test
    fun `reads the shared parameters file`() {
        val p = load()
        assertEquals(30.0, p.session.defaultDurationMin, 1e-9)
        assertEquals(10.0, p.session.arrivalRadiusM, 1e-9)
        assertEquals(1.3, p.budget.detourFactor, 1e-9)
        assertEquals(20_000.0, p.route.visitHalfLifeM, 1e-9)
        assertEquals(35.0, p.route.intersectionLookaheadM, 1e-9)
        assertEquals(1.2, p.audio.guidanceIntervalSec, 1e-9)
        assertEquals(2000, p.summary.maxTrackPoints)
    }

    /** 音色まで読めていること(波形合成に直結する) */
    @Test
    fun `reads the tone definitions`() {
        val p = load()
        assertEquals(listOf(880.0, 1174.7), p.audio.tones.suggestion.freqsHz)
        assertEquals(listOf(440.0), p.audio.tones.homeBeacon.freqsHz)
        assertEquals(p.audio.tones.homeBeacon, p.audio.tones[Earcon.HOME_BEACON])
    }

    /** 誘導の設定値が組み立てられること */
    @Test
    fun `builds the guidance params`() {
        val g = load().guidanceParams()
        assertEquals(35.0, g.startDistanceM, 1e-9)
        assertEquals(10.0, g.peakBeforeM, 1e-9)
        assertEquals(1, g.announceTones)
        assertEquals(100.0, g.abandonBehindDeg, 1e-9)
    }
}

class VisitGridTest {
    private val origin = GeoPoint(35.0, 139.0)

    @Test
    fun `unvisited cells are zero and visits accumulate`() {
        val g = VisitGrid(cellSizeM = 50.0, halfLifeM = 20_000.0)
        assertEquals(0.0, g.familiarity(origin, 8.0), 1e-9)
        g.recordVisit(origin)
        g.recordVisit(origin)
        assertEquals(2.0, g.familiarity(origin, 8.0), 1e-9)
    }

    /** **減衰の時計は歩いた距離。** 歩かなければ減らない */
    @Test
    fun `decay follows the distance walked not time`() {
        val g = VisitGrid(cellSizeM = 50.0, halfLifeM = 1000.0)
        g.recordVisit(origin)
        assertEquals(1.0, g.familiarity(origin, 8.0), 1e-9)
        g.advance(1000.0)   // 半減期ぶん歩いた
        assertEquals(0.5, g.familiarity(origin, 8.0), 1e-6)
        g.advance(1000.0)
        assertEquals(0.25, g.familiarity(origin, 8.0), 1e-6)
    }

    /** 通勤路として除外したセルは、常に高い馴染み度として扱う */
    @Test
    fun `excluded cells stay familiar`() {
        val g = VisitGrid(cellSizeM = 50.0, halfLifeM = 1000.0)
        g.markExcluded(origin)
        g.advance(100_000.0)
        assertEquals(8.0, g.familiarity(origin, 8.0), 1e-9)
    }

    /** 隣のセルは別勘定 */
    @Test
    fun `neighbouring cells are counted separately`() {
        val g = VisitGrid(cellSizeM = 50.0, halfLifeM = 20_000.0)
        g.recordVisit(origin)
        val far = Geo.destination(origin, 90.0, 200.0)
        assertEquals(0.0, g.familiarity(far, 8.0), 1e-9)
    }

    /** **通っていない点は 0 として数える**(半分だけ歩いた道は半分の馴染み度) */
    @Test
    fun `average familiarity counts unvisited points as zero`() {
        val g = VisitGrid(cellSizeM = 50.0, halfLifeM = 20_000.0)
        g.recordVisit(origin)
        val points = listOf(origin, Geo.destination(origin, 90.0, 300.0))
        assertEquals(0.5, g.averageFamiliarity(points, 8.0), 1e-9)
    }
}

class TravelDirectionTest {
    private val location = AppParameters.Location(
        minSpeedForCourseMPerS = 0.7, maxCourseAccuracyDeg = 70.0, maxFixAgeSec = 10.0,
        courseHoldSec = 15.0, allowCompassFallback = false
    )

    @Test
    fun `uses the course while walking`() {
        val fix = MotionFix(courseDeg = 90.0, courseAccuracyDeg = 30.0, speedMps = 1.2, ageSec = 0.0)
        val r = TravelDirection.resolve(fix, null, location)
        assertNotNull(r)
        assertEquals(90.0, r.deg, 1e-9)
        assertEquals(DirectionSource.COURSE, r.source)
    }

    /** 立ち止まると course は使えない → 直前の値を保持して使う */
    @Test
    fun `falls back to the held course when standing still`() {
        val fix = MotionFix(courseDeg = 90.0, speedMps = 0.1, ageSec = 0.0)
        val r = TravelDirection.resolve(fix, HeldCourse(80.0, 5.0), location)
        assertNotNull(r)
        assertEquals(80.0, r.deg, 1e-9)
        assertEquals(DirectionSource.HELD_COURSE, r.source)
    }

    /** 保持の上限を超えたら諦める(コンパスへは退避しない設定) */
    @Test
    fun `gives up when the hold expires`() {
        val fix = MotionFix(courseDeg = 90.0, speedMps = 0.1, ageSec = 0.0,
                            compassHeadingDeg = 200.0)
        assertNull(TravelDirection.resolve(fix, HeldCourse(80.0, 30.0), location))
    }

    /** **端末コンパスは既定で使わない。** ポケットの中の向きは進行方向ではない */
    @Test
    fun `compass is used only when allowed`() {
        val fix = MotionFix(courseDeg = -1.0, speedMps = 1.2, compassHeadingDeg = 200.0)
        assertNull(TravelDirection.resolve(fix, null, location))
        val allowed = location.copy(allowCompassFallback = true)
        val r = TravelDirection.resolve(fix, null, allowed)
        assertNotNull(r)
        assertEquals(DirectionSource.COMPASS, r.source)
    }

    @Test
    fun `rejection reason explains why the course was dropped`() {
        assertEquals("course が無効",
                     TravelDirection.rejectionReason(MotionFix(courseDeg = -1.0), location))
        assertTrue(TravelDirection.rejectionReason(
            MotionFix(courseDeg = 90.0, speedMps = 0.1), location)!!.startsWith("速度不足"))
        assertTrue(TravelDirection.rejectionReason(
            MotionFix(courseDeg = 90.0, speedMps = 1.2, courseAccuracyDeg = 100.0),
            location)!!.startsWith("course 精度不足"))
        assertNull(TravelDirection.rejectionReason(
            MotionFix(courseDeg = 90.0, speedMps = 1.2, courseAccuracyDeg = 30.0), location))
    }
}

class ToneRendererTest {
    private val tone = AppParameters.ToneSpec(
        freqsHz = listOf(880.0, 1174.7), blipSec = 0.09, gapSec = 0.06, noiseMix = 0.0
    )

    /** 標本数は「ブリップ × 音数 + 間 × (音数 − 1)」 */
    @Test
    fun `sample count follows the tone spec`() {
        val s = ToneRenderer.samples(tone, 44100.0, 0.5)
        val blip = (0.09 * 44100).toInt()
        val gap = (0.06 * 44100).toInt()
        assertEquals(blip * 2 + gap, s.size)
    }

    /** 端は窓で 0 に落ちる(プチッと鳴らないこと) */
    @Test
    fun `envelope starts and ends at zero`() {
        val s = ToneRenderer.samples(tone, 44100.0, 1.0)
        assertEquals(0.0f, s.first(), 1e-6f)
        assertTrue(s.max() > 0.5f)
    }

    /** 同じ設定なら毎回同じ音になる(雑音も再現性がある) */
    @Test
    fun `noise is reproducible`() {
        val noisy = tone.copy(noiseMix = 0.5)
        val a = ToneRenderer.samples(noisy, 22050.0, 1.0)
        val b = ToneRenderer.samples(noisy, 22050.0, 1.0)
        assertTrue(a.contentEquals(b))
    }

    /** 暗くすると周波数が下がり、雑音成分が削れる */
    @Test
    fun `darken lowers the frequencies and removes noise`() {
        val dark = ToneRenderer.darken(tone.copy(noiseMix = 0.4), 1.0)
        assertEquals(440.0, dark.freqsHz[0], 1e-9)
        assertEquals(0.0, dark.noiseMix, 1e-9)
        val unchanged = ToneRenderer.darken(tone, 0.0)
        assertEquals(tone.freqsHz, unchanged.freqsHz)
    }

    @Test
    fun `empty spec renders nothing`() {
        assertEquals(0, ToneRenderer.samples(tone.copy(freqsHz = emptyList()), 44100.0, 1.0).size)
    }
}
