package dev.otosanpo.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy

/**
 * `config/parameters.json` に対応する型。
 *
 * **JSON は iOS 版とまったく同じファイルを読む**(docs/10)。数値を 2 か所に置くと、
 * 片方だけ直したときに iOS と Android で挙動が変わり、実測の比較ができなくなる。
 * 鍵は snake_case のままで、命名規則の変換で受ける。
 *
 * **フォールバック値をコードに持たない**(CLAUDE.md)。読み込みに失敗したら止める。
 */
@Serializable
data class AppParameters(
    val session: Session,
    val budget: Budget,
    val route: Route,
    val location: Location,
    val heading: Heading,
    val gesture: Gesture,
    val audio: Audio,
    val summary: Summary,
    val greeting: Greeting,
) {
    @Serializable
    data class Session(
        val defaultDurationMin: Double,
        val minDurationMin: Double,
        val maxDurationMin: Double,
        /** 延長 1 回で足す時間の、元の設定時間に対する比 */
        val extensionRatio: Double,
        val maxExtensions: Int,
        val rePromptIntervalSec: Double,
        val arrivalRadiusM: Double,
    )

    @Serializable
    data class Budget(
        /** 歩行速度の**初期値** [m/min]。実測が貯まればそちらを使う */
        val walkingSpeedMPerMin: Double,
        val minMovingSpeedMPerS: Double,
        val pathSegmentMinM: Double,
        val maxAccuracyForMetricsM: Double,
        /** 直線距離を歩く距離に直す係数。**経路データがあるときは使わない** */
        val detourFactor: Double,
        val returnReserveMin: Double,
        val softZoneRatio: Double,
        val speedEwmaWeight: Double,
        val speedMinSamples: Int,
        val speedMinMPerMin: Double,
        val speedMaxMPerMin: Double,
    ) {
        val speedLimits: SpeedEstimator.Limits
            get() = SpeedEstimator.Limits(speedEwmaWeight, speedMinSamples,
                                          speedMinMPerMin, speedMaxMPerMin)

        val gaitLimits: GaitMetrics.Limits
            get() = GaitMetrics.Limits(minMovingSpeedMPerS, pathSegmentMinM,
                                       maxAccuracyForMetricsM)
    }

    @Serializable
    data class Route(
        val cellSizeM: Double,
        /** 通過の重みが半分になるまでに歩く距離 [m]。**減衰の時計は歩いた総距離** */
        val visitHalfLifeM: Double,
        val sectorWidthDeg: Double,
        val sectorRadiusM: Double,
        val suggestionMinScore: Double,
        val excludedFamiliarity: Double,
        val suggestionMarginOverStraight: Double,
        val suggestionMinTravelM: Double,
        val mapRadiusM: Double,
        val mapIndexCellSizeM: Double,
        val snapMaxDistanceM: Double,
        val nodeArrivalToleranceM: Double,
        val intersectionLookaheadM: Double,
        val branchStraightDeg: Double,
        val branchBackwardDeg: Double,
        val crossCostWeight: Double,
        val wayClassWeight: Double,
        val branchNoveltyRatio: Double,
        val zoneSizeM: Double,
        val zoneMinRoadM: Double,
        val zoneSampleGrid: Int,
        val targetMinDistanceM: Double,
        val targetMinDistanceRatio: Double,
        val targetReachedM: Double,
        val targetBiasWeight: Double,
    ) {
        /** ZoneMap に渡す設定値 */
        fun zoneParams(): ZoneMap.Params = ZoneMap.Params(
            zoneSizeM = zoneSizeM, minRoadM = zoneMinRoadM, sampleGrid = zoneSampleGrid,
            minDistanceM = targetMinDistanceM, minDistanceRatio = targetMinDistanceRatio,
            excludedFamiliarity = excludedFamiliarity
        )
    }

    @Serializable
    data class Location(
        val minSpeedForCourseMPerS: Double,
        val maxCourseAccuracyDeg: Double,
        val maxFixAgeSec: Double,
        val courseHoldSec: Double,
        val allowCompassFallback: Boolean,
    )

    @Serializable
    data class Heading(
        val useHeadOrientation: Boolean,
        val baselineAlpha: Double,
        val maxOffsetDeg: Double,
        val minSamples: Int,
        val logIntervalSec: Double,
        val yawSign: Double,
        val useGyroHeadOffset: Boolean,
        val headOffsetHalfLifeSec: Double,
        val headOffsetMaxDeg: Double,
        val headRateDeadbandDegPerSec: Double,
        val headRateSign: Double,
        val headRateMaxGapSec: Double,
    ) {
        val headTracker: HeadTracker.Params
            get() = HeadTracker.Params(headOffsetHalfLifeSec, headOffsetMaxDeg,
                                       headRateDeadbandDegPerSec, headRateSign,
                                       headRateMaxGapSec)
    }

    @Serializable
    data class Gesture(
        val nodPitchThresholdDeg: Double,
        val shakeYawThresholdDeg: Double,
        val minReversals: Int,
        val windowSec: Double,
        val refractorySec: Double,
        val diagnosticsIntervalSec: Double,
        val diagnosticsReportRatio: Double,
    )

    @Serializable
    data class Audio(
        val sampleRate: Double,
        val suggestionMinIntervalSec: Double,
        val returnAckRepeatIntervalSec: Double,
        val returnAckDurationSec: Double,
        val beaconStepsPerTone: Double,
        val beaconIntervalMinSec: Double,
        val beaconIntervalMaxSec: Double,
        val beaconIntervalFallbackSec: Double,
        val beaconCadenceMaxAgeSec: Double,
        val beaconGainFar: Double,
        val beaconGainNear: Double,
        val beaconNearDistanceM: Double,
        val beaconFarDistanceM: Double,
        val beaconDirectionChangeDeg: Double,
        val beaconMinGapSec: Double,
        val useSpatialAudio: Boolean,
        val behindThresholdDeg: Double,
        val behindDarkness: Double,
        val guidanceIntervalSec: Double,
        val guidanceGainFar: Double,
        val guidanceGainNear: Double,
        val guidancePeakBeforeM: Double,
        val guidanceClosingTones: Int,
        val guidanceAnnounceTones: Int,
        val guidanceAbandonBehindDeg: Double,
        val guidanceEndDistanceM: Double,
        val guidanceLeftBehindM: Double,
        val earconGain: Double,
        val tones: Tones,
    ) {
        val beaconRhythm: BeaconRhythm.Params
            get() = BeaconRhythm.Params(
                beaconStepsPerTone, beaconIntervalMinSec, beaconIntervalMaxSec,
                beaconIntervalFallbackSec, beaconGainFar, beaconGainNear,
                beaconNearDistanceM, beaconFarDistanceM
            )
    }

    @Serializable
    data class Tones(
        val suggestion: ToneSpec,
        val timeUpPrompt: ToneSpec,
        val returnAck: ToneSpec,
        val homeBeacon: ToneSpec,
        val arrival: ToneSpec,
    ) {
        operator fun get(e: Earcon): ToneSpec = when (e) {
            Earcon.SUGGESTION -> suggestion
            Earcon.TIME_UP_PROMPT -> timeUpPrompt
            Earcon.RETURN_ACK -> returnAck
            Earcon.HOME_BEACON -> homeBeacon
            Earcon.ARRIVAL -> arrival
        }
    }

    @Serializable
    data class ToneSpec(
        val freqsHz: List<Double>,
        val blipSec: Double,
        val gapSec: Double,
        /** 白色雑音を混ぜる割合 [0..1]。広帯域成分は前後の手がかりになる */
        val noiseMix: Double,
    )

    @Serializable
    data class Summary(
        val maxTrackPoints: Int,
        val mapMarginM: Double,
        val mapMinSpanM: Double,
    )

    /** 散歩を始めるときの一言。**文言も時間帯もここに置く**(コードに埋めない) */
    @Serializable
    data class Greeting(val windows: List<Window>) {
        @Serializable
        data class Window(
            /** 開始の時(この時を含む) */
            val fromHour: Int,
            /** 終了の時(この時を**含まない**)。`from` より小さければ真夜中をまたぐ */
            val toHour: Int,
            val message: String,
        )
    }

    /** 誘導の設定値。Core は数値を持たないので、ここで束ねて渡す */
    fun guidanceParams(): TurnGuidance.Params = TurnGuidance.Params(
        startDistanceM = route.intersectionLookaheadM,
        peakBeforeM = audio.guidancePeakBeforeM,
        intervalSec = audio.guidanceIntervalSec,
        gainFar = audio.guidanceGainFar,
        gainNear = audio.guidanceGainNear,
        endDistanceM = audio.guidanceEndDistanceM,
        leftBehindM = audio.guidanceLeftBehindM,
        turnedWithinDeg = route.branchStraightDeg,
        closingTones = audio.guidanceClosingTones,
        announceTones = audio.guidanceAnnounceTones,
        abandonBehindDeg = audio.guidanceAbandonBehindDeg,
    )

    companion object {
        @OptIn(ExperimentalSerializationApi::class)
        private val json = Json {
            namingStrategy = JsonNamingStrategy.SnakeCase
            ignoreUnknownKeys = true
        }

        /** 文字列から読む。**失敗は例外のまま上げる**(黙って既定値へ落ちない) */
        fun decode(text: String): AppParameters = json.decodeFromString(serializer(), text)
    }
}
