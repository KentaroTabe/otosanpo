package dev.otosanpo

import android.os.Handler
import android.os.Looper
import dev.otosanpo.core.AppParameters
import dev.otosanpo.core.BeaconRhythm
import dev.otosanpo.core.BearingSuggester
import dev.otosanpo.core.BranchSuggester
import dev.otosanpo.core.Earcon
import dev.otosanpo.core.GaitMetrics
import dev.otosanpo.core.Geo
import dev.otosanpo.core.GeoPoint
import dev.otosanpo.core.HeldCourse
import dev.otosanpo.core.ReturnAck
import dev.otosanpo.core.ReturnBudget
import dev.otosanpo.core.RouteField
import dev.otosanpo.core.SpeedEstimator
import dev.otosanpo.core.TravelDirection
import dev.otosanpo.core.TravelDirectionFix
import dev.otosanpo.core.TurnGuidance
import dev.otosanpo.core.VisitGrid
import dev.otosanpo.core.WalkEffect
import dev.otosanpo.core.WalkEvent
import dev.otosanpo.core.WalkGraph
import dev.otosanpo.core.WalkMachine
import dev.otosanpo.core.WalkState
import dev.otosanpo.core.WalkSummary
import dev.otosanpo.core.ZoneMap
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * セッションの統合。状態遷移は `WalkMachine`(純粋)に委譲し、ここでは Effect の実行
 * (タイマー・音・位置・保存)だけを行う。iOS 版 `WalkSessionController` の対応物。
 *
 * **iOS との違いは 1 点だけ: 頭のジェスチャが無い。**
 * Android にはヘッドフォンの頭部姿勢を取る公開 API が無いので、
 * 「帰る / 延長」の入力は音量ボタンと画面のボタンで受ける(docs/10)。
 */
class WalkSession(
    val params: AppParameters,
    private val storage: Storage,
    private val location: LocationSource,
    private val steps: StepCadence,
    private val player: EarconPlayer,
) {
    var state: WalkState = WalkState.IDLE
        private set

    var durationMin: Double = params.session.defaultDurationMin
    var home: GeoPoint? = storage.loadHome()
        private set

    var statusLine: String = "位置情報待ち"
        private set

    val eventLog = ArrayDeque<String>()

    /** 画面へ「変わった」ことだけを知らせる(状態は都度読み出す) */
    var onChange: (() -> Unit)? = null

    var lastSummary: WalkSummary? = null
        private set

    private val handler = Handler(Looper.getMainLooper())
    private var grid: VisitGrid =
        storage.loadGrid(params.route.cellSizeM, params.route.visitHalfLifeM)
    private var speed: SpeedEstimator = storage.loadSpeed()
    private var graph: WalkGraph? = storage.loadGraph(params.route.mapIndexCellSizeM)
    private var zones: ZoneMap? = graph?.let { ZoneMap(it.map, params.route.zoneSizeM) }
    private var routeField: RouteField? = null

    private var extensionsUsed = 0
    private var plannedDurationMin = 0.0
    private var sessionEndMillis: Long? = null
    private var suggestionsEnabled = false
    private var lastGoodCourse: Pair<Double, Long>? = null
    private var lastSuggestionPoint: GeoPoint? = null
    private var lastSuggestionAt: Long? = null
    private var returnAckStart: Long? = null
    private var returnDirectionStarted = false
    private var walkMetrics = GaitMetrics()
    private var odometerBaseM = 0.0
    private var returnMetrics: GaitMetrics? = null
    private var returnStart: Pair<Double, Long>? = null
    private var lastBeacon: Pair<Double, Long>? = null
    private var turnGuidance: TurnGuidance? = null
    private var guidanceNumber: Int? = null
    private var lastBehindCorner: GeoPoint? = null
    private var summary: WalkSummary? = null
    private var target: ZoneMap.Target? = null

    private var guidanceTick: Runnable? = null
    private var beaconTick: Runnable? = null
    private var ackTick: Runnable? = null
    private var promptTick: Runnable? = null
    private var timeUpTick: Runnable? = null

    init {
        location.onPosition = { onPosition(it) }
        lastSummary = null
    }

    // MARK: - 画面から呼ばれる操作

    /**
     * 位置の購読を始める。**権限が下りた直後に画面から呼ぶ。**
     * 起動時から取っておかないと、「自宅を設定」を押した時に現在地が無くて失敗する
     */
    fun startLocation() = location.start()

    fun setHomeHere(): Boolean {
        val p = location.position ?: return false
        home = p
        storage.saveHome(p)
        log("自宅を現在地に設定しました")
        return true
    }

    fun start(): Boolean {
        if (state != WalkState.IDLE && state != WalkState.ARRIVED) return false
        if (home == null) {
            val p = location.position ?: return false
            home = p
            storage.saveHome(p)
            log("出発点を自宅として設定しました")
        }
        extensionsUsed = 0
        plannedDurationMin = durationMin
        returnAckStart = null
        returnDirectionStarted = false
        lastSuggestionPoint = null
        lastSuggestionAt = null
        lastGoodCourse = null
        walkMetrics = GaitMetrics()
        odometerBaseM = 0.0
        returnMetrics = null
        returnStart = null
        lastBeacon = null
        turnGuidance = null
        guidanceNumber = null
        lastBehindCorner = null
        target = null
        cancel(guidanceTick); guidanceTick = null
        summary = WalkSummary(System.currentTimeMillis(), home)
        buildRouteField()
        sessionEndMillis = System.currentTimeMillis() + (durationMin * 60_000).toLong()
        location.start()
        steps.start()
        apply(WalkEvent.START)
        scheduleTimeUp()
        log("散歩を開始(${durationMin.roundToInt()} 分)")
        return true
    }

    fun stopManually() {
        logWalkTotals()
        apply(WalkEvent.STOP)
        log("終了しました")
    }

    /** 音量ボタン(下)= 帰る / (上)= 延長。画面のボタンからも同じ入口を使う */
    fun nod() = apply(WalkEvent.NOD)
    fun shake() = apply(WalkEvent.SHAKE)
    fun debugTimeUp() = apply(WalkEvent.TIME_UP)

    fun playSample(e: Earcon, relativeBearingDeg: Double) {
        player.play(e, relativeBearingDeg)
    }

    fun clearLog() {
        storage.clearLog()
        log("フィールドログを消去しました")
    }

    val hasMap: Boolean get() = graph != null
    val mapLabel: String
        get() = graph?.let {
            "地図: 半径${(it.map.radiusM / 1000).roundToInt()}km・${it.map.generated}"
        } ?: "地図: 未読込"

    // MARK: - イベント適用

    private fun apply(event: WalkEvent) {
        val (next, effects) = WalkMachine.reduce(
            state, event, extensionsUsed, plannedDurationMin, params.session
        )
        state = next
        for (e in effects) run(e)
        onChange?.invoke()
    }

    private fun run(effect: WalkEffect) {
        when (effect) {
            is WalkEffect.Play -> player.play(effect.earcon)

            WalkEffect.StartSuggestionLoop -> suggestionsEnabled = true

            WalkEffect.StopSuggestionLoop -> {
                suggestionsEnabled = false
                stopTurnGuidance("提案の停止")
            }

            WalkEffect.StartPromptWindow -> {
                cancel(promptTick)
                promptTick = Runnable { apply(WalkEvent.PROMPT_WINDOW_EXPIRED) }
                handler.postDelayed(promptTick!!,
                                    (params.session.rePromptIntervalSec * 1000).toLong())
                log("時間になりました(音量↓=帰る / 音量↑=延長)")
            }

            is WalkEffect.ExtendSession -> {
                extensionsUsed += 1
                // **延長は「もう少し歩ける時間」でなければ意味がない。**
                // 帰宅ぶんと予備を先に確保したうえで、延長分だけ歩ける締切にする
                val reserveMin = location.position?.let { p ->
                    homeDistance(p)?.let {
                        ReturnBudget.estimatedReturnMin(it, effectiveSpeedMPerMin, params.budget) +
                            params.budget.returnReserveMin
                    }
                } ?: 0.0
                sessionEndMillis = System.currentTimeMillis() +
                    ((reserveMin + effect.minutes) * 60_000).toLong()
                cancel(promptTick)
                scheduleTimeUp()
                location.position?.let {
                    summary?.addMark(WalkSummary.Mark.EXTENDED, it, false,
                                     System.currentTimeMillis())
                }
                log("延長 +%.0f 分(帰宅ぶん %.0f 分を別に確保)(%d/%d 回)".format(
                    effect.minutes, reserveMin, extensionsUsed, params.session.maxExtensions))
            }

            WalkEffect.StartReturnPhase -> {
                cancel(promptTick)
                returnAckStart = System.currentTimeMillis()
                returnDirectionStarted = false
                returnMetrics = GaitMetrics()
                val p = location.position
                val h = home
                if (p != null && h != null) {
                    returnStart = Pair(Geo.distanceM(p, h), System.currentTimeMillis())
                    summary?.addMark(WalkSummary.Mark.RETURN_START, p, true,
                                     System.currentTimeMillis())
                }
                log("帰路開始に同意")
                // **同意した瞬間から案内を始める。** 確認音の終了を待たない
                player.play(Earcon.RETURN_ACK)
                fireAckTick()
                p?.let { checkReturnGuidance(it) }
                fireReturnTick()
            }

            WalkEffect.StopLoops -> {
                cancel(guidanceTick); cancel(beaconTick); cancel(ackTick)
                cancel(promptTick); cancel(timeUpTick)
                turnGuidance = null
            }

            WalkEffect.EndSession -> {
                location.stop()
                steps.stop()
                storage.saveGrid(grid)
                finishSummary()
                sessionEndMillis = null
            }
        }
    }

    // MARK: - 位置更新

    private fun onPosition(p: GeoPoint) {
        val now = System.currentTimeMillis()
        if (state == WalkState.WANDERING || state == WalkState.PROMPTING_RETURN ||
            state == WalkState.RETURNING) {
            val fix = location.motionFix()
            walkMetrics.add(p, fix.speedMps, fix.horizontalAccuracyM, params.budget.gaitLimits)
            returnMetrics?.add(p, fix.speedMps, fix.horizontalAccuracyM, params.budget.gaitLimits)
            // 位置更新を 1 件ずつ残す。再生で純粋ロジックを検証できる粒度(docs/05)
            logToFile("fix [${summaryOf(fix)}]")
            // **馴染み度の減衰の時計は「歩いた総距離」**(docs/04)
            grid.advance(walkMetrics.pathLengthM - odometerBaseM)
            odometerBaseM = walkMetrics.pathLengthM
            summary?.add(p, params.budget.pathSegmentMinM, params.summary.maxTrackPoints)
        }
        if (state == WalkState.WANDERING || state == WalkState.RETURNING) {
            grid.recordVisit(p)
        }

        val h = home
        if (state == WalkState.RETURNING && h != null &&
            Geo.distanceM(p, h) <= params.session.arrivalRadiusM) {
            logReturnMeasurements(now)
            summary?.addMark(WalkSummary.Mark.ARRIVAL, p, true, now)
            apply(WalkEvent.REACHED_HOME)
            log("到着しました")
        } else if (state == WalkState.RETURNING) {
            checkReturnGuidance(p)
            advanceBeaconIfDirectionChanged(p, now)
        } else if (state == WalkState.WANDERING) {
            checkReturnPrompt(p)
            tickSuggestion()
        }
        updateStatus()
        onChange?.invoke()
    }

    // MARK: - 提案

    private fun tickSuggestion() {
        // 誘導が鳴っている間は次の提案を評価しない(1 つの曲がるイベントに 1 つの誘導)
        if (turnGuidance != null) return
        if (!suggestionsEnabled || state != WalkState.WANDERING) return
        val p = location.position ?: return
        val h = home ?: return
        val end = sessionEndMillis ?: return
        // 立ち止まっている間や同じ交差点で繰り返し鳴らさない
        lastSuggestionPoint?.let {
            if (Geo.distanceM(it, p) < params.route.suggestionMinTravelM) return
        }
        lastSuggestionAt?.let {
            if ((System.currentTimeMillis() - it) / 1000.0 <
                params.audio.suggestionMinIntervalSec) return
        }
        val fix = location.motionFix()
        val travel = currentTravel(fix) ?: return
        val heading = travel.deg
        val remainingMin = (end - System.currentTimeMillis()) / 60_000.0
        val allowed = ReturnBudget.allowedRadiusM(remainingMin, effectiveSpeedMPerMin,
                                                  params.budget)
        val bias = ReturnBudget.homewardBias(Geo.distanceM(p, h), allowed, params.budget)
        updateTarget(p, h, allowed, bias)

        val g = graph
        if (g != null && g.map.covers(p)) {
            val x = g.upcomingIntersection(p, heading, params.route.intersectionLookaheadM,
                                           params.route.snapMaxDistanceM)
            if (x == null) {
                logToFile("提案なし(前方に交差点なし)")
                return
            }
            val decision = BranchSuggester.decide(x, heading, p, h, grid, bias,
                                                  target?.zone?.center, g, params.route)
            if (decision !is BranchSuggester.Decision.Suggest) {
                val why = (decision as? BranchSuggester.Decision.Silent)?.why?.label ?: "不明"
                logToFile("提案なし($why・分岐 ${x.branches.size} 本・交差点まで %.0fm)"
                              .format(x.distanceM))
                return
            }
            val c = decision.choice
            lastSuggestionPoint = p
            lastSuggestionAt = System.currentTimeMillis()
            log("提案(分岐): 相対 %+.0f° %s 横断=%d 交差点まで=%.0fm score=%.2f".format(
                c.relativeBearingDeg, c.branch.cls.name, c.branch.crossCost, x.distanceM, c.score))
            startTurnGuidance(x.point, c.branch.bearingDeg)
            return
        }

        // 経路データが無いときはグリッドのみの推測に落ちる
        val s = BearingSuggester.suggest(p, heading, h, grid, bias, params.route)
        if (s == null) {
            logToFile("提案なし")
            return
        }
        val rel = Geo.angularDiffDeg(s.absoluteBearingDeg, placementReference(heading))
        player.play(Earcon.SUGGESTION, rel)
        lastSuggestionPoint = p
        lastSuggestionAt = System.currentTimeMillis()
        log("提案: ${s.direction.label}")
    }

    /** 向かう地帯を決める・選び直す(docs/06 柱 4) */
    private fun updateTarget(p: GeoPoint, h: GeoPoint, allowedRadiusM: Double, bias: Double) {
        val z = zones ?: return
        // 帰りどきが近づいたら行き先は捨てる。帰宅が優先
        if (bias >= 1) {
            if (target != null) {
                target = null
                logToFile("行き先を解除(帰宅を優先)")
            }
            return
        }
        val t = target
        val reason = when {
            t == null -> "未設定"
            Geo.distanceM(p, t.zone.center) <= params.route.targetReachedM -> "到達"
            Geo.distanceM(t.zone.center, h) > allowedRadiusM -> "予算の外に出た"
            else -> null
        } ?: return
        // **選ぶ半径は捨てる半径より内側にする。** 予算いっぱいだと数秒で失効する
        val pickRadius = allowedRadiusM * params.budget.softZoneRatio
        val next = z.chooseTarget(p, h, pickRadius, grid, params.route.zoneParams())
        if (next == null) {
            if (target != null) logToFile("行き先を選べません($reason)")
            target = null
            return
        }
        target = next
        log("行き先: %.0fm 先 方位 %.0f°(新鮮さ %.2f・道 %.0fm・%s)".format(
            next.distanceM, Geo.bearingDeg(p, next.zone.center), next.novelty,
            next.zone.roadLengthM, reason))
    }

    // MARK: - 帰路

    /** 帰路のビーコン。**誘導が鳴っている間は休む**(音の裁定。docs/03) */
    private fun fireReturnTick() {
        if (state != WalkState.RETURNING) return
        if (turnGuidance == null) playBeacon()
        cancel(beaconTick)
        beaconTick = Runnable { fireReturnTick() }
        handler.postDelayed(beaconTick!!, (beaconInterval() * 1000).toLong())
    }

    /** 同意の確認音。**方向のある音が鳴り始めたら止める**(ReturnAck) */
    private fun fireAckTick() {
        cancel(ackTick)
        if (state != WalkState.RETURNING) return
        val start = returnAckStart ?: return
        val elapsed = (System.currentTimeMillis() - start) / 1000.0
        if (!ReturnAck.shouldRepeat(returnDirectionStarted, elapsed,
                                    params.audio.returnAckDurationSec)) {
            logToFile("帰路確認音を終了(%s・経過 %.0fs)".format(
                if (returnDirectionStarted) "案内が始まった" else "上限", elapsed))
            return
        }
        ackTick = Runnable {
            if (state != WalkState.RETURNING) return@Runnable
            val e = (System.currentTimeMillis() - (returnAckStart ?: 0L)) / 1000.0
            if (ReturnAck.shouldRepeat(returnDirectionStarted, e,
                                       params.audio.returnAckDurationSec)) {
                player.play(Earcon.RETURN_ACK)
                logToFile("帰路確認音(案内がまだ出せていない)")
            }
            fireAckTick()
        }
        handler.postDelayed(ackTick!!,
                            (params.audio.returnAckRepeatIntervalSec * 1000).toLong())
    }

    /**
     * ビーコンが指す方位。**経路が分かるならそちらを指す**(自宅を直線で指すと
     * 川や街区の向こうを指しうる)。**鳴らす側と繰り上げの判定はこれを共有する**
     */
    private fun beaconBearing(p: GeoPoint): Pair<Double, Boolean>? {
        val h = home ?: return null
        val g = graph
        val route = if (g != null) {
            routeField?.nextBearingDeg(p, g, params.route.nodeArrivalToleranceM)
        } else null
        return if (route != null) Pair(route, true) else Pair(Geo.bearingDeg(p, h), false)
    }

    private fun playBeacon() {
        val p = location.position ?: return
        val h = home ?: return
        val bearing = beaconBearing(p) ?: return
        val fix = location.motionFix()
        val travel = currentTravel(fix)
        val gain = beaconGain()
        if (travel == null) {
            // 進行方向が不明なときは左右を付けない(誤った定位を出すより中央で鳴らす)
            player.play(Earcon.HOME_BEACON, null, gain)
            logToFile("ビーコン(中央) 距離=%.0fm 音量=%.2f".format(Geo.distanceM(p, h), gain))
            return
        }
        val rel = Geo.angularDiffDeg(bearing.first, placementReference(travel.deg))
        player.play(Earcon.HOME_BEACON, rel, gain)
        lastBeacon = Pair(rel, System.currentTimeMillis())
        noteReturnDirectionStarted()
        val cadence = steps.cadence(params.audio.beaconCadenceMaxAgeSec)
        logToFile(("ビーコン 距離=%.0fm 指す方位=%.0f°(%s) 進行=%.0f°(%s) " +
            "間隔=%.1fs 歩調=%s 音量=%.2f").format(
            Geo.distanceM(p, h), bearing.first, if (bearing.second) "経路" else "自宅を直線",
            travel.deg, travel.source.label, beaconInterval(),
            cadence?.let { "%.2f歩/s".format(it) } ?: "-", gain))
    }

    /**
     * 角を曲がった直後は、次のビーコンを待たずに繰り上げて鳴らす。
     * **判定は鳴らす側と同じ方位・同じ基準で行う**(基準が違うと毎秒空振りする。
     * iOS の実測では 99 回中 95 回が空振りだった)
     */
    private fun advanceBeaconIfDirectionChanged(p: GeoPoint, now: Long) {
        if (turnGuidance != null) return
        val last = lastBeacon ?: return
        val bearing = beaconBearing(p) ?: return
        if ((now - last.second) / 1000.0 < params.audio.beaconMinGapSec) return
        val travel = currentTravel(location.motionFix()) ?: return
        val rel = Geo.angularDiffDeg(bearing.first, placementReference(travel.deg))
        val change = abs(Geo.angularDiffDeg(rel, last.first))
        if (change < params.audio.beaconDirectionChangeDeg) return
        logToFile("ビーコン繰り上げ 方向が %.0f° 変化".format(change))
        cancel(beaconTick)
        fireReturnTick()
    }

    private fun beaconInterval(): Double =
        BeaconRhythm.intervalSec(steps.cadence(params.audio.beaconCadenceMaxAgeSec),
                                 params.audio.beaconRhythm)

    private fun beaconGain(): Double {
        val p = location.position ?: return params.audio.beaconGainFar
        val h = home ?: return params.audio.beaconGainFar
        return BeaconRhythm.gain(Geo.distanceM(p, h), params.audio.beaconRhythm)
    }

    /**
     * 帰路でも、経路上の次の角へ誘導音を張る。
     * **背後の角なら始めない**(始めても 1 音目で止まるだけで、それを毎秒繰り返す)
     */
    private fun checkReturnGuidance(p: GeoPoint) {
        if (turnGuidance != null) return
        val f = routeField ?: return
        val g = graph ?: return
        val turn = f.nextTurn(p, g, params.route.branchStraightDeg,
                              params.route.intersectionLookaheadM,
                              params.route.nodeArrivalToleranceM) ?: return
        val travel = currentTravel(location.motionFix())?.deg
        if (TurnGuidance.isBehind(turn.corner, p, travel, turn.distanceM,
                                  params.guidanceParams())) {
            if (lastBehindCorner != turn.corner) {
                lastBehindCorner = turn.corner
                logToFile("帰路の誘導を見送り(角が背後・角まで %.0fm)".format(turn.distanceM))
            }
            return
        }
        lastBehindCorner = null
        logToFile("帰路の誘導を開始(角まで %.0fm)".format(turn.distanceM))
        startTurnGuidance(turn.corner, turn.branchBearingDeg)
    }

    private fun noteReturnDirectionStarted() {
        if (state != WalkState.RETURNING || returnDirectionStarted) return
        returnDirectionStarted = true
        fireAckTick()
    }

    // MARK: - 曲がり角の誘導

    private fun startTurnGuidance(point: GeoPoint, branchBearingDeg: Double) {
        val d = location.position?.let { Geo.distanceM(it, point) } ?: Double.MAX_VALUE
        turnGuidance = TurnGuidance(point, branchBearingDeg, d)
        guidanceNumber = null
        fireGuidanceTick()
    }

    private fun stopTurnGuidance(reason: String) {
        val g = turnGuidance ?: return
        turnGuidance = null
        cancel(guidanceTick)
        // 1 音も鳴らなかった誘導は記録に残さない(利用者に届いていないものはイベントではない)
        if (guidanceNumber != null) summary?.finishGuidance(reason)
        logToFile("誘導終了%s(%s・最接近 %.0fm)".format(guidanceLabel, reason, g.closestM))
        guidanceNumber = null
    }

    private val guidanceLabel: String get() = guidanceNumber?.let { " #$it" } ?: ""

    private fun fireGuidanceTick() {
        if (state != WalkState.WANDERING && state != WalkState.RETURNING) {
            stopTurnGuidance("状態が変わった")
            return
        }
        val g = turnGuidance ?: return
        val p = location.position ?: run { stopTurnGuidance("現在地が無い"); return }
        val travel = currentTravel(location.motionFix())?.deg
        // next は状態を進めるので **1 回だけ呼ぶ**
        val outcome = g.next(p, travel, params.guidanceParams())
        if (outcome is TurnGuidance.Outcome.Finished) {
            stopTurnGuidance(outcome.ending.label)
            return
        }
        val step = (outcome as TurnGuidance.Outcome.Play).step
        val rel = travel?.let {
            Geo.angularDiffDeg(step.targetBearingDeg, placementReference(it))
        }
        // **帰路は帰路の音で案内する**(2026-08-21 の利用者判断)。判断は Core に置く
        player.play(WalkMachine.guidanceEarcon(state), rel, step.gain)
        if (guidanceNumber == null) {
            guidanceNumber = summary?.startGuidance(g.corner, g.branchBearingDeg,
                                                    state == WalkState.RETURNING,
                                                    System.currentTimeMillis())
        }
        noteReturnDirectionStarted()
        logToFile("誘導%s 角まで=%.0fm 鳴らす向き=%s 音量=%.2f%s%s%s".format(
            guidanceLabel, step.distanceM,
            rel?.let { "%+.0f°".format(it) } ?: "-", step.gain,
            if (step.isAnnouncing) " 予告" else "",
            if (step.isClosing) " 終端" else "",
            if (state == WalkState.RETURNING) " 帰路" else ""))
        cancel(guidanceTick)
        guidanceTick = Runnable { fireGuidanceTick() }
        handler.postDelayed(guidanceTick!!, (step.intervalSec * 1000).toLong())
    }

    // MARK: - 帰宅予算

    private fun buildRouteField() {
        routeField = null
        val g = graph ?: return
        val h = home ?: return
        if (!g.map.covers(h)) return
        val weights = RouteField.Weights(params.route.crossCostWeight,
                                         params.route.wayClassWeight)
        // 数万節点の探索になるので背景で解く。できるまでは直線距離で代替する
        Thread {
            val started = System.currentTimeMillis()
            val field = RouteField.build(g, h, params.route.snapMaxDistanceM, weights)
            handler.post {
                if (state == WalkState.IDLE) return@post
                routeField = field
                if (field == null) {
                    log("経路の場を作れません(自宅が道に乗らない)")
                } else {
                    log("経路の場を作りました(到達できる節点 %d / %d・%.1f 秒)".format(
                        field.reachableNodes, g.map.nodes.size,
                        (System.currentTimeMillis() - started) / 1000.0))
                }
            }
        }.start()
    }

    private val effectiveSpeedMPerMin: Double
        get() = speed.effectiveMPerMin(walkMetrics.averageMovingSpeedMPerMin,
                                       walkMetrics.movingSamples,
                                       params.budget.walkingSpeedMPerMin,
                                       params.budget.speedLimits)

    /** 自宅までの距離。**経路データがあれば実際に歩く距離**、無ければ直線距離 */
    private fun homeDistance(p: GeoPoint): ReturnBudget.Distance? {
        val h = home ?: return null
        val g = graph
        val f = routeField
        if (g != null && f != null) {
            f.pathLengthM(p, g)?.let { return ReturnBudget.Distance.Route(it) }
        }
        return ReturnBudget.Distance.Straight(Geo.distanceM(p, h))
    }

    /** 「今帰り始めれば設定時間ちょうどに着く」瞬間に発火する */
    private fun checkReturnPrompt(p: GeoPoint) {
        val end = sessionEndMillis ?: return
        val d = homeDistance(p) ?: return
        val remainingMin = (end - System.currentTimeMillis()) / 60_000.0
        val v = effectiveSpeedMPerMin
        if (!ReturnBudget.shouldPromptReturn(remainingMin, d, v, params.budget)) return
        log("帰りどきです(残り %.0f 分・帰宅推定 %.0f 分・%s %.0fm)".format(
            remainingMin, ReturnBudget.estimatedReturnMin(d, v, params.budget), d.label, d.rawM))
        apply(WalkEvent.TIME_UP)
    }

    private fun scheduleTimeUp() {
        cancel(timeUpTick)
        val end = sessionEndMillis ?: return
        timeUpTick = Runnable { apply(WalkEvent.TIME_UP) }
        handler.postDelayed(timeUpTick!!, maxOf(0L, end - System.currentTimeMillis()))
    }

    // MARK: - 記録

    private fun logReturnMeasurements(now: Long) {
        val m = returnMetrics ?: return
        val s = returnStart ?: return
        val elapsedMin = (now - s.second) / 60_000.0
        logToFile(("帰路実測 直線=%.0fm 経路長=%.0fm 所要=%.1fmin 平均速度=%s " +
            "迂回率=%s 精度不足で除外=%d件").format(
            s.first, m.pathLengthM, elapsedMin,
            m.averageMovingSpeedMPerMin?.let { "%.0f".format(it) } ?: "-",
            m.detourFactor(s.first)?.let { "%.2f".format(it) } ?: "-",
            m.rejectedSamples))
        logWalkTotals()
    }

    private fun logWalkTotals() {
        val avg = walkMetrics.averageMovingSpeedMPerMin
        logToFile("散歩全体 経路長=%.0fm 平均速度=%s".format(
            walkMetrics.pathLengthM, avg?.let { "%.0f".format(it) } ?: "-"))
        val before = speed.mPerMin
        speed.record(avg, walkMetrics.movingSamples, params.budget.speedLimits)
        if (speed.mPerMin != before) {
            storage.saveSpeed(speed)
            logToFile("速度の推定を更新 → %.0fm/min(%d 回目)".format(
                speed.mPerMin ?: 0.0, speed.walks))
        }
    }

    private fun finishSummary() {
        val s = summary ?: return
        s.finish(System.currentTimeMillis(), walkMetrics.pathLengthM)
        summary = null
        guidanceNumber = null
        lastSummary = s
        log("記録: %.0fm・%.0f 分・イベント %d 件".format(
            s.pathLengthM, s.durationSec / 60, s.guidanceEvents.size))
    }

    // MARK: - 補助

    /**
     * 定位の基準。**Android では進行方位のみ。**
     * ヘッドフォンの頭部姿勢を取る公開 API が無いため(docs/10)。
     * `TYPE_HEAD_TRACKER` が使える端末が確認できたら、ここへ足す
     */
    private fun placementReference(travelDeg: Double): Double = travelDeg

    private fun currentTravel(fix: dev.otosanpo.core.MotionFix,
                              now: Long = System.currentTimeMillis()): TravelDirectionFix? {
        val held = lastGoodCourse?.let { HeldCourse(it.first, (now - it.second) / 1000.0) }
        val travel = TravelDirection.resolve(fix, held, params.location)
        if (travel != null && travel.source == dev.otosanpo.core.DirectionSource.COURSE) {
            lastGoodCourse = Pair(travel.deg, now)
        }
        return travel
    }

    private fun summaryOf(f: dev.otosanpo.core.MotionFix): String {
        fun num(v: Double?, fmt: String) = v?.let { fmt.format(it) } ?: "-"
        return "course=${num(f.courseDeg, "%.0f")} 速度=${num(f.speedMps, "%.2f")}m/s " +
            "course精度=${num(f.courseAccuracyDeg, "%.0f")} " +
            "経過=${num(f.ageSec, "%.1f")}s 水平精度=${num(f.horizontalAccuracyM, "%.0f")}m"
    }

    private fun updateStatus() {
        val p = location.position
        if (p == null) {
            statusLine = "現在地を取得中…"
            return
        }
        val h = home
        if (h == null) {
            statusLine = "現在地を取得しました。自宅を設定してください"
            return
        }
        val d = homeDistance(p) ?: ReturnBudget.Distance.Straight(Geo.distanceM(p, h))
        val ret = ReturnBudget.estimatedReturnMin(d, effectiveSpeedMPerMin, params.budget)
        val parts = mutableListOf(
            "自宅まで ${d.rawM.roundToInt()} m(${d.label}・徒歩約 ${ret.roundToInt()} 分)"
        )
        sessionEndMillis?.let {
            parts.add("残り ${maxOf(0, ((it - System.currentTimeMillis()) / 60_000).toInt())} 分")
        }
        parts.add(mapLabel)
        statusLine = parts.joinToString(" / ")
    }

    private fun cancel(r: Runnable?) {
        r?.let { handler.removeCallbacks(it) }
    }

    private fun log(message: String) {
        val t = android.text.format.DateFormat.format("HH:mm:ss", System.currentTimeMillis())
        eventLog.addLast("$t $message")
        while (eventLog.size > 50) eventLog.removeFirst()
        logToFile(message)
        onChange?.invoke()
    }

    private fun logToFile(message: String) {
        storage.appendLog(state.name.lowercase(), location.position, message)
    }
}
