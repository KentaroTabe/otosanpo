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
    val experiment: Experiment,
) {
    /**
     * **音楽スポット**(→ docs/08)。iOS 版の `experiment` 節のうち、
     * Android で使うものだけを受ける(残りの鍵は無視される)。
     *
     * 節の名前が `experiment` なのは iOS 側の経緯によるもので、
     * **音楽スポットは配る版にも入っている**(頭の向きを使わない形で)。
     */
    @Serializable
    data class Experiment(
        val musicSpotMinDistancePerMin: Double,
        val musicSpotMaxDistancePerMin: Double,
        val musicSpotDistanceSteps: Int,
        val musicSpotReachedM: Double,
        val musicSpotBearingStepDeg: Double,
        val musicSpotSameDistanceToleranceM: Double,
        val musicLogIntervalSec: Double,
        val musicFadeInSec: Double,
        val musicSpotReferenceDistanceM: Double,
        val musicSpotGainMinSpanM: Double,
        val musicSpotMaxGain: Double,
        val musicSpotMinGain: Double,
        val musicSpotPinpointStartM: Double,
        val musicSpotPinpointFullM: Double,
        val musicSpotPinpointBeamDeg: Double,
        val musicSpotPinpointDepthDb: Double,
        val musicSpotDirectivityDepthDb: Double,
        val musicSpotRearShelfStartDeg: Double,
        val musicSpotRearShelfDepthDb: Double,
        val musicSpotRearShelfHz: Double,
        val musicSpotListenerHeightM: Double,
        val musicSpotSpreadFarM: Double,
        val musicSpotSpreadNearM: Double,
        val musicSpotSpreadMax: Double,
        val musicSpotBearingDeadbandMinDeg: Double,
        val musicSpotBearingDeadbandMaxDeg: Double,
        val musicSpotBearingFollowSec: Double,
        val musicSpotMoveIntervalSec: Double,
        val musicSpotMoveResponseDelaySec: Double,
        val musicSpotMoveResponseWindowSec: Double,
        val musicSpotMoveMinSeparationM: Double,
        val musicSpotMoveFadeSec: Double,
    ) {
        /** MusicSpot に渡す設定値。**散歩時間で距離が決まる**ので時間を渡す */
        fun musicSpot(durationMin: Double) = MusicSpot.Params(
            minDistanceM = musicSpotMinDistancePerMin * durationMin,
            maxDistanceM = musicSpotMaxDistancePerMin * durationMin,
            distanceStepCount = musicSpotDistanceSteps,
            reachedM = musicSpotReachedM,
            bearingStepDeg = musicSpotBearingStepDeg,
            sameDistanceToleranceM = musicSpotSameDistanceToleranceM,
            referenceDistanceM = musicSpotReferenceDistanceM,
            gainMinSpanM = musicSpotGainMinSpanM,
            maxGain = musicSpotMaxGain,
            minGain = musicSpotMinGain,
            pinpointStartM = musicSpotPinpointStartM,
            pinpointFullM = musicSpotPinpointFullM,
            pinpointBeamDeg = musicSpotPinpointBeamDeg,
            pinpointDepthDb = musicSpotPinpointDepthDb,
            directivityDepthDb = musicSpotDirectivityDepthDb,
            rearShelfStartDeg = musicSpotRearShelfStartDeg,
            rearShelfDepthDb = musicSpotRearShelfDepthDb,
            listenerHeightM = musicSpotListenerHeightM,
            spreadFarM = musicSpotSpreadFarM,
            spreadNearM = musicSpotSpreadNearM,
        )

        /** BearingHold に渡す設定値 */
        val musicSpotBearingHold: BearingHold.Params
            get() = BearingHold.Params(
                minDeadbandDeg = musicSpotBearingDeadbandMinDeg,
                maxDeadbandDeg = musicSpotBearingDeadbandMaxDeg,
                timeConstantSec = musicSpotBearingFollowSec,
            )

        /** SpotMoveSchedule に渡す設定値 */
        val musicSpotMove: SpotMoveSchedule.Params
            get() = SpotMoveSchedule.Params(
                baseIntervalSec = musicSpotMoveIntervalSec,
                responseDelaySec = musicSpotMoveResponseDelaySec,
                responseWindowSec = musicSpotMoveResponseWindowSec,
            )
    }
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
        /**
         * 経路長を信用する上限。直線距離の何倍までを「ありうる遠回り」とみなすか。
         * これを超えた経路長はスナップの誤りを疑い、この倍数で頭を押さえる
         * (2026-08-27 の実測: 通常は 95% が 1.68 倍以内、跳ねた時だけ 2.5〜3.06 倍)
         */
        val routeStraightMaxRatio: Double,
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
        /**
         * **音楽スポットで読む音源の拡張子**(小文字)。iOS と同じ 1 か所を読む。
         * 両方が読めるのは m4a(AAC)・mp3・wav・flac。
         * `aif` / `aiff` / `caf` は Apple だけなので、Android では開けない
         */
        val musicSourceExtensions: List<String> = emptyList(),
        val tones: Tones,
    ) {
        /** **Android が復号できる拡張子だけ**に絞る(→ docs/08「音源の形式」) */
        val androidReadableExtensions: List<String>
            get() = musicSourceExtensions.map { it.lowercase() }
                .filter { it in ANDROID_READABLE }

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
        val spotMove: ToneSpec,
    ) {
        operator fun get(e: Earcon): ToneSpec = when (e) {
            Earcon.SUGGESTION -> suggestion
            Earcon.TIME_UP_PROMPT -> timeUpPrompt
            Earcon.RETURN_ACK -> returnAck
            Earcon.HOME_BEACON -> homeBeacon
            Earcon.ARRIVAL -> arrival
            Earcon.SPOT_MOVE -> spotMove
        }
    }

    @Serializable
    data class ToneSpec(
        val freqsHz: List<Double>,
        val blipSec: Double,
        val gapSec: Double,
        /** 白色雑音を混ぜる割合 [0..1]。広帯域成分は前後の手がかりになる */
        val noiseMix: Double,
        /**
         * 倍音の数(1 = 基音のみ = 純音)。**左右の定位に直接効く**(iOS 版と同じ規則)。
         *
         * 440 Hz の純音は波長 78 cm で頭(約 18 cm)を回折し、
         * 両耳間レベル差(ILD)がほとんど出ない。ILD が効くのは概ね 1.5 kHz 以上。
         * 倍音を足すと同じ音程のまま高域成分が生まれる(2026-09-01)
         */
        val harmonics: Int,
        /** 倍音 1 段あたりの振幅比 [0..1] */
        val harmonicDecay: Double,
        /**
         * 立ち上がりが 1 音に占める割合 [0..1]。0.5 で左右対称(従来の Hann 窓)。
         * 小さいほど鋭くなり、両耳間時間差(ITD)の手がかりになる
         */
        val attackRatio: Double,
    ) {
        /**
         * **この音が鳴り終わるまでの長さ** [sec]。
         * 応答の窓を「鳴り終わってから」開くために要る(→ SpotMoveSchedule)。
         * 音は「blip を freqs の数だけ、間に gap を挟んで」並べる(→ ToneRenderer)
         */
        val durationSec: Double
            get() {
                val n = freqsHz.size
                if (n <= 0) return 0.0
                return n * maxOf(0.0, blipSec) + (n - 1) * maxOf(0.0, gapSec)
            }
    }

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
        /**
         * **Android が素で復号できる音源の拡張子。**
         * `aif` / `aiff` / `caf` は Apple だけ、`ogg` / `opus` は Android だけ
         * (→ docs/08「音源の形式」)
         */
        val ANDROID_READABLE = setOf("m4a", "mp3", "wav", "flac")

        private val json = Json {
            namingStrategy = JsonNamingStrategy.SnakeCase
            ignoreUnknownKeys = true
        }

        /** 文字列から読む。**失敗は例外のまま上げる**(黙って既定値へ落ちない) */
        fun decode(text: String): AppParameters = json.decodeFromString(serializer(), text)
    }
}
