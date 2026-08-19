import Foundation
import Combine

/// セッションの統合コントローラ。
/// 状態遷移は WalkMachine(純粋)に委譲し、ここでは Effect の実行(タイマー・音・位置・永続化)のみ行う。
@MainActor
final class WalkSessionController: ObservableObject {
    @Published private(set) var state: WalkState = .idle
    @Published var durationMin: Double
    @Published var commuteLearning = false {
        didSet { commuteLearningChanged(oldValue) }
    }
    @Published private(set) var home: GeoPoint?
    @Published private(set) var statusLine = "位置情報待ち"
    /// ヘッドフォンモーションの受信状況。検出できない原因の切り分けに使う
    @Published private(set) var motionStatusLine = "ヘッドフォンモーション: 未開始"
    @Published private(set) var eventLog: [String] = []
    /// 操作が通らなかったことを画面で知らせる(nil で非表示)
    @Published var alertMessage: String?

    let params: AppParameters

    private let location = LocationService()
    private let motion = HeadphoneMotionService()
    /// 歩調。ビーコンを歩みに同期させるためだけに使う(AirPods を外していても取れる)
    private let pedometer = PedometerService()
    private let fieldLog = FieldLog()
    private var synth: EarconSynth?
    private var grid: VisitGrid
    private var detector: HeadGestureDetector
    /// 応答待ち以外でも同じ判定を回し、結果を記録だけする検出器。
    /// 動作には一切影響しない(docs/04「影検出」)
    private var shadowDetector: HeadGestureDetector

    private var extensionsUsed = 0
    /// この散歩の設定時間(開始時に確定)。延長量とプロンプト条件の分母になる
    private var plannedDurationMin: Double = 0
    /// 直前まで有効だった course。course が一時的に無効になっても左右を出し続けるために保持する
    private var lastGoodCourse: (deg: Double, at: Date)?
    private var directionUnavailableLogged = false
    private var lastSuggestionPoint: GeoPoint?
    private var lastSuggestionAt: Date?
    /// 提案を出してよい状態か(WalkMachine の効果で切り替える)
    private var suggestionsEnabled = false
    private var sessionEnd: Date?
    /// 帰路に同意した時刻(確認音の上限を測る基準)
    private var returnAckStart: Date?
    /// 帰路で「方向のある音」を鳴らせたか。確認音を止める合図(ReturnAck)
    private var returnDirectionStarted = false
    /// 散歩全体と帰路それぞれの歩行実測。予算模型の係数を実測から決めるための計測
    private var walkMetrics = GaitMetrics()
    private var returnMetrics: GaitMetrics?
    private var returnStart: (distanceM: Double, at: Date)?
    /// ヘッドフォンの接続状態と、外している間に持ち越したプロンプト
    private var headphonesConnected = false
    private var promptPending = false
    /// 直近のビーコンで鳴らした相対方位と時刻(方向が変わったら次を繰り上げるため)
    private var lastBeacon: (relDeg: Double, at: Date)?
    /// 進行中の曲がり角誘導。1 つの曲がるイベントに対して、角へ近づくほど音量が上がる
    /// 連続音を出し、曲がり終えたら数音かけて閉じる。判断は Core(TurnGuidance)が持つ
    private var turnGuidance: TurnGuidance?
    private var guidanceTimer: Timer?
    /// 経路データ。Documents に置かれていれば読む。無ければグリッドのみで動く
    private var graph: WalkGraph?
    /// 自宅を終点とする経路の場。開始時に 1 回だけ解き、以後は引くだけ。
    /// 逸脱しても作り直さない(逸脱先の節点も既に答えを持っている)
    private var routeField: RouteField?
    /// 散歩をまたいで積む歩行速度の推定。帰宅推定の分母になる
    private var speed: SpeedEstimator
    /// 広域の「面白そうな地帯」の地図。局所の分岐選択に向きを与える
    private var zones: ZoneMap?
    /// いま向かっている地帯。到達したら選び直す
    private var target: ZoneMap.Target?
    /// 顔の向きの推定。定位の基準を進行方位から「顔の向き」へ寄せる
    private var headingFusion = HeadingFusion()
    /// 直近に解決した進行方位(50 Hz のモーション側から参照する)
    private var latestCourseBearing: Double?
    /// 推定した顔の絶対方位。nil なら進行方位をそのまま使う
    private var latestFacingBearing: Double?
    /// yaw と course を突き合わせた記録を残した時刻(符号の判定材料。間隔を空けて残す)
    private var lastHeadingLogAt: Date?
    private var suggestionTimer: Timer?
    private var beaconTimer: Timer?
    /// 確認音は誘導・ビーコンと**別の系統**で回す。同じタイマーに乗せると互いをせき止める
    private var ackTimer: Timer?
    private var promptTimer: Timer?
    private var timeUpTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(params: AppParameters) {
        self.params = params
        durationMin = params.session.defaultDurationMin
        grid = GridStore.load(cellSizeM: params.route.cellSizeM,
                              halfLifeDays: params.route.visitHalfLifeDays)
        detector = HeadGestureDetector(params: params.gesture)
        shadowDetector = HeadGestureDetector(params: params.gesture)
        home = HomeStore.load()
        graph = MapStore.load(cellSizeM: params.route.mapIndexCellSizeM)
        speed = SpeedStore.load()
        zones = graph.map { ZoneMap(map: $0.map, zoneSizeM: params.route.zoneSizeM) }

        location.$position
            .sink { [weak self] p in
                Task { @MainActor in self?.onPosition(p) }
            }
            .store(in: &cancellables)
        motion.onSample = { [weak self] s in
            Task { @MainActor in self?.onHeadSample(s) }
        }
        motion.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.onHeadphoneConnectionChange(connected) }
        }
        location.requestPermission()
        // 起動時から取得しておく。ボタンを押した時に fix が無くて失敗するのを避ける
        location.startForeground()
    }

    // MARK: - UI から呼ばれる操作

    func setHomeHere() {
        guard let p = location.position else {
            // 失敗はイベントログだけでは気づけない。画面を止めて知らせる
            alertMessage = "現在地をまだ取得できていません。空の見える場所で数秒待ってから、もう一度お試しください。"
            log("自宅の設定に失敗(現在地が未取得)")
            location.startForeground()
            return
        }
        home = p
        HomeStore.save(p)
        log("自宅を現在地に設定しました")
    }

    func start() {
        guard state == .idle || state == .arrived else { return }
        // 自宅が未設定のときだけ、出発点をそのまま自宅にして開始する(初回の 2 手間を 1 手に)。
        // 設定済みの場合は上書きしない。出発点が自宅とは限らないため、更新は明示操作に限る
        if home == nil {
            guard let p = location.position else {
                alertMessage = "現在地をまだ取得できていません。空の見える場所で数秒待ってから、もう一度お試しください。"
                log("開始できません(現在地が未取得で自宅を決められない)")
                return
            }
            home = p
            HomeStore.save(p)
            log("出発点を自宅として設定しました")
        }
        ensureSynth()
        if synth == nil { log("音声エンジンの初期化に失敗(未確認要素)") }
        extensionsUsed = 0
        plannedDurationMin = durationMin
        returnAckStart = nil
        returnDirectionStarted = false
        ackTimer?.invalidate()
        lastSuggestionPoint = nil
        // 前回の散歩の向き・影検出の窓・実測値を持ち越さない
        lastGoodCourse = nil
        shadowDetector = HeadGestureDetector(params: params.gesture)
        walkMetrics = GaitMetrics()
        returnMetrics = nil
        returnStart = nil
        promptPending = false
        lastBeacon = nil
        headingFusion.reset()
        latestCourseBearing = nil
        latestFacingBearing = nil
        lastSuggestionAt = nil
        lastHeadingLogAt = nil
        turnGuidance = nil
        target = nil
        guidanceTimer?.invalidate()
        buildRouteField()
        sessionEnd = Date().addingTimeInterval(durationMin * 60)
        location.start()
        // 未接続でも start する(後から装着された時点で更新が始まる)
        motion.start()
        pedometer.start()
        log("歩調: 利用可能=\(PedometerService.isAvailable ? "はい" : "いいえ")"
            + " 許可=\(pedometer.authorizationLabel)")
        log("ヘッドフォンモーション: 利用可能=\(motion.isAvailable ? "はい" : "いいえ")"
            + " 許可=\(motion.authorizationLabel) 更新中=\(motion.isActive ? "はい" : "いいえ")")
        apply(.start)
        scheduleTimeUp()
        log("散歩を開始(\(Int(durationMin)) 分)")
    }

    func stopManually() {
        logWalkTotals()
        apply(.stop)
        log("終了しました")
    }

    /// フィールドログの実体(共有シートで書き出す)。まだ 1 行も書かれていなければ nil
    var fieldLogURL: URL? {
        guard let url = FieldLog.fileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func clearFieldLog() {
        fieldLog.clear()
        log("フィールドログを消去しました")
    }

    /// 音声エンジンを用意する。エンジンの再起動をフィールドログへ流す配線もここで行う
    private func ensureSynth() {
        guard synth == nil else { return }
        let s = try? EarconSynth(audio: params.audio)
        s?.onEvent = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        synth = s
    }

    /// earcon の聴き分け確認用。初回の散歩は全方向が未踏で「直進」が最良になり
    /// 提案音が鳴らないため、音そのものの確認はこの経路で行う。
    func debugPlay(_ e: Earcon, relativeBearingDeg: Double = 0) {
        ensureSynth()
        guard let synth else {
            log("音声エンジンの初期化に失敗しました")
            return
        }
        synth.play(e, relativeBearingDeg: relativeBearingDeg)
        log("デバッグ再生: \(e.rawValue) 方位=\(String(format: "%.0f", relativeBearingDeg))°"
            + "(\(synth.isSpatial ? "3D" : "パン")"
            + "・エンジン\(synth.isRunning ? "稼働" : "停止"))")
    }

    // デバッグ用(シミュレータ・モーション非対応時の代替)
    func debugTimeUp() { apply(.timeUp) }
    func debugNod() { apply(.nod) }
    func debugShake() { apply(.shake) }

    // MARK: - イベント適用

    private func apply(_ event: WalkEvent) {
        let (next, effects) = WalkMachine.reduce(state: state, event: event,
                                                 extensionsUsed: extensionsUsed,
                                                 plannedDurationMin: plannedDurationMin,
                                                 params: params.session)
        state = next
        // 応答待ちを抜けたら、保留していたプロンプトは用済み
        if next != .promptingReturn { promptPending = false }
        for e in effects { run(e) }
    }

    private func run(_ effect: WalkEffect) {
        switch effect {
        case .play(let earcon):
            // 会話などで AirPods を外している間はプロンプトを鳴らさず、再装着時に鳴らし直す。
            // 応答待ちのまま待つ挙動は変えない(docs/01「応答待ち中に外している間は…」)
            if earcon == .timeUpPrompt, !headphonesConnected {
                promptPending = true
                log("ヘッドフォン未装着のためプロンプトを保留します")
                return
            }
            synth?.play(earcon)

        case .startSuggestionLoop:
            // タイマーでは回さない。交差点は「近づいた時」にしか意味を持たないので、
            // 位置更新のたびに評価する(25 秒ごとの点検では交差点を取りこぼす。
            // 2026-08-18 の実測: 実機は 13 分で 1 回しか鳴らなかったが、
            // 同じログを 1 Hz で再生すると 12 回鳴っていた)
            suggestionsEnabled = true

        case .stopSuggestionLoop:
            suggestionsEnabled = false
            stopTurnGuidance("提案の停止")

        case .startPromptWindow:
            promptTimer?.invalidate()
            promptTimer = Timer.scheduledTimer(withTimeInterval: params.session.rePromptIntervalSec,
                                               repeats: false) { [weak self] _ in
                Task { @MainActor in self?.apply(.promptWindowExpired) }
            }
            log("時間になりました(うなずき=帰る / 首振り=延長)")

        case .extendSession(let minutes):
            extensionsUsed += 1
            // **延長は「もう少し歩ける時間」でなければ意味がない。**
            // 単に now + 延長分にすると、帰宅推定がそれを上回る場所では
            // 直後にまた発火する。実測(2026-08-18): +3 分の延長に対し帰宅推定 4 分で、
            // 1 秒後に再発火して 4 回連続で首を振る羽目になった。
            // 帰宅ぶんと予備を先に確保したうえで、延長分だけ歩ける締切にする
            let reserveMin: Double = {
                guard let p = location.position, let d = homeDistance(from: p) else { return 0 }
                return ReturnBudget.estimatedReturnMin(d, speedMPerMin: effectiveSpeedMPerMin,
                                                       p: params.budget)
                    + params.budget.returnReserveMin
            }()
            sessionEnd = Date().addingTimeInterval((reserveMin + minutes) * 60)
            promptTimer?.invalidate()
            scheduleTimeUp()
            log(String(format: "延長 +%.0f 分(帰宅ぶん %.0f 分を別に確保)(%d/%d 回)",
                       minutes, reserveMin, extensionsUsed, params.session.maxExtensions))

        case .startReturnPhase:
            promptTimer?.invalidate()
            returnAckStart = Date()
            returnDirectionStarted = false
            // 帰路は目的地が決まっている唯一の区間。迂回率の実測はここでしか取れない
            returnMetrics = GaitMetrics()
            if let p = location.position, let h = home {
                returnStart = (distanceM: Geo.distanceM(p, h), at: Date())
            }
            log("帰路開始に同意")
            // **同意した瞬間から案内を始める。** 確認音が終わるのを待たない。
            // 実測(2026-08-19)では確認音が 60 秒せき止め、その間ずっと
            // 方向の手がかりが無かった(docs/03「確認音は案内が始まるまで」)
            synth?.play(.returnAck)
            fireAckTick()
            if let p = location.position { checkReturnGuidance(at: p) }
            fireReturnTick()

        case .stopLoops:
            suggestionTimer?.invalidate()
            guidanceTimer?.invalidate()
            turnGuidance = nil
            beaconTimer?.invalidate()
            ackTimer?.invalidate()
            promptTimer?.invalidate()
            timeUpTimer?.invalidate()

        case .endSession:
            if !commuteLearning { location.stop() }
            motion.stop()
            pedometer.stop()
            GridStore.save(grid)
            sessionEnd = nil
        }
    }

    // MARK: - タイマー

    private func scheduleTimeUp() {
        timeUpTimer?.invalidate()
        guard let end = sessionEnd else { return }
        timeUpTimer = Timer.scheduledTimer(withTimeInterval: max(0, end.timeIntervalSinceNow),
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.apply(.timeUp) }
        }
    }

    private func tickSuggestion() {
        // 誘導が鳴っている間は次の提案を評価しない(1 つの曲がるイベントに 1 つの誘導)
        guard turnGuidance == nil else { return }
        guard suggestionsEnabled,
              state == .wandering,
              let p = location.position,
              let h = home,
              let end = sessionEnd else { return }
        // 前回提案した地点からほとんど動いていないなら評価しない。
        // 立ち止まっている間や同じ交差点で繰り返し鳴らさないため
        if let last = lastSuggestionPoint,
           Geo.distanceM(last, p) < params.route.suggestionMinTravelM {
            return
        }
        // 密な交差点で連続して鳴らないよう、時間の下限も置く
        if let at = lastSuggestionAt,
           Date().timeIntervalSince(at) < params.audio.suggestionMinIntervalSec {
            return
        }
        let fix = location.motionFix()
        guard let travel = currentTravel(fix) else {
            noteDirectionUnavailable(fix)
            return
        }
        noteDirectionAvailable()
        let heading = travel.deg
        let remainingMin = end.timeIntervalSinceNow / 60
        let allowed = ReturnBudget.allowedRadiusM(remainingMin: remainingMin,
                                                  speedMPerMin: effectiveSpeedMPerMin,
                                                  p: params.budget)
        let bias = ReturnBudget.homewardBias(distanceM: Geo.distanceM(p, h),
                                             allowedRadiusM: allowed,
                                             p: params.budget)
        // 広域の行き先を先に決める。局所の分岐選択に一貫した向きを与える(docs/06 柱 4)
        updateTarget(at: p, home: h, allowedRadiusM: allowed, bias: bias)
        // 端末コンパスへ退避した理由を後から特定できるよう、判定に使った生値も残す
        let targetLabel = target.map {
            String(format: " 行き先=%.0fm/%.0f°", Geo.distanceM(p, $0.zone.center),
                   Geo.bearingDeg(from: p, to: $0.zone.center))
        } ?? ""
        let context = String(format: "方向=%@ %.0f° 自宅まで=%.0fm 許容=%.0fm bias=%.2f%@ [%@]",
                             label(for: travel.source), heading, Geo.distanceM(p, h), allowed, bias,
                             targetLabel, summary(of: fix))
        // 経路データがあれば、実在する分岐から選ぶ。
        // 無ければ従来のグリッドのみの推測(±45°/±90°)に落ちる
        if let graph, graph.map.covers(p) {
            guard let x = graph.upcomingIntersection(
                from: p, bearingDeg: heading,
                withinM: params.route.intersectionLookaheadM,
                snapMaxDistanceM: params.route.snapMaxDistanceM) else {
                logToFile("提案なし(前方に交差点なし) [\(context)]")
                return
            }
            let decision = BranchSuggester.decide(intersection: x, travelBearingDeg: heading,
                                                  position: p, home: h, grid: grid,
                                                  homewardBias: bias,
                                                  target: target?.zone.center, graph: graph,
                                                  route: params.route, now: Date())
            guard case .suggest(let c) = decision else {
                if case .silent(let why, let best) = decision {
                    // 最良候補も残す。「惜しかったのか、遠く及ばなかったのか」が
                    // 分からないと閾値を動かせない
                    let bestLabel = best.map {
                        String(format: "最良 %+.0f° score=%.2f 新鮮さ=%.2f",
                               $0.relativeBearingDeg, $0.score, $0.novelty)
                    } ?? "候補なし"
                    logToFile(String(format: "提案なし(%@・分岐 %d 本・交差点まで %.0fm・%@) [%@]",
                                     why.rawValue, x.branches.count, x.distanceM,
                                     bestLabel, context))
                }
                return
            }
            lastSuggestionPoint = p
            lastSuggestionAt = Date()
            log(String(format: "提案(分岐): 相対 %+.0f° %@ 横断=%d 交差点まで=%.0fm score=%.2f [%@]",
                       c.relativeBearingDeg, "\(c.branch.cls)", c.branch.crossCost,
                       x.distanceM, c.score, context))
            // 単発で鳴らさず、角までの誘導を始める。
            // 35 m 手前の 1 音だけでは「言われた場所に道が無い」ように聞こえる
            // (2026-08-18 の実測: 提案 9 件中 7 件が 32〜35 m 手前 = 探索範囲の縁で鳴っており、
            //  体感では半分が「道の無い場所」だった)
            startTurnGuidance(at: x.point, branchBearingDeg: c.branch.bearingDeg)
            return
        }

        if let s = BearingSuggester.suggest(position: p, headingDeg: heading, home: h,
                                            grid: grid, homewardBias: bias,
                                            route: params.route, now: Date()) {
            let reference = latestFacingBearing ?? heading
            let rel = Geo.angularDiffDeg(s.absoluteBearingDeg, reference)
            synth?.play(.suggestion, relativeBearingDeg: rel)
            lastSuggestionPoint = p
            lastSuggestionAt = Date()
            log("提案: \(label(for: s.direction)) [\(context)]")
        } else {
            // 「なぜ鳴らなかったか」を後から追えるようにする(直進が最良 or スコア不足)
            logToFile("提案なし [\(context)]")
        }
    }

    /// 帰路のビーコン。**同意した瞬間から回る**(確認音の終了を待たない)。
    ///
    /// **音の裁定: プロンプト > 誘導 > 提案 > ビーコン。**
    /// 誘導が鳴っている間はビーコンを休む。曲がる場所を指す音と自宅の在り処を指す音が
    /// 交互に鳴ると、どちらの方向を聞いているのか分からなくなる(docs/06 柱 1)。
    private func fireReturnTick() {
        guard state == .returning else { return }
        if turnGuidance == nil { playBeacon() }
        beaconTimer?.invalidate()
        beaconTimer = Timer.scheduledTimer(withTimeInterval: beaconInterval(),
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireReturnTick() }
        }
    }

    /// 同意の確認音。**方向のある音が鳴り始めたら止める**(ReturnAck)。
    /// 役目は「同意が伝わったか」の不安を消すことで、案内が始まればそれが答えになる。
    /// 上限は残す — 進行方向が取れない・地図が無いなど、案内を出せない状況では
    /// この音だけが頼りになる。
    private func fireAckTick() {
        ackTimer?.invalidate()
        guard state == .returning, let start = returnAckStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard ReturnAck.shouldRepeat(directionStarted: returnDirectionStarted,
                                     elapsedSec: elapsed,
                                     durationSec: params.audio.returnAckDurationSec) else {
            logToFile(String(format: "帰路確認音を終了(%@・経過 %.0fs)",
                             returnDirectionStarted ? "案内が始まった" : "上限", elapsed))
            return
        }
        ackTimer = Timer.scheduledTimer(withTimeInterval: params.audio.returnAckRepeatIntervalSec,
                                        repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .returning else { return }
                guard ReturnAck.shouldRepeat(
                    directionStarted: self.returnDirectionStarted,
                    elapsedSec: Date().timeIntervalSince(self.returnAckStart ?? Date()),
                    durationSec: self.params.audio.returnAckDurationSec) else {
                    self.fireAckTick()
                    return
                }
                self.synth?.play(.returnAck)
                self.logToFile("帰路確認音(案内がまだ出せていない)")
                self.fireAckTick()
            }
        }
    }

    private func playBeacon() {
        guard let p = location.position, let h = home else { return }
        // **経路が分かるなら、そちらを指す。** 自宅を直線で指すと川や街区の向こうを指しうる
        // (2026-08-19 実測)。道の上を指していれば「音の鳴る方に歩く」が成り立つ。
        // 経路が無い(地図なし・圏外)ときだけ直線に落ちる
        let routeBearing = routeField.flatMap { f in
            graph.flatMap {
                f.nextBearingDeg(from: p, graph: $0,
                                 nodeToleranceM: params.route.nodeArrivalToleranceM)
            }
        }
        let bearingHome = routeBearing ?? Geo.bearingDeg(from: p, to: h)
        let fix = location.motionFix()
        guard let travel = currentTravel(fix) else {
            // 進行方向が不明なときは左右を付けない(誤った定位を出すより中央で鳴らす)。
            // 中央で鳴った回数を数えられないと「左右が付かなすぎる」を測れないため記録する
            noteDirectionUnavailable(fix)
            synth?.play(.homeBeacon, gain: beaconGain())
            logToFile(String(format: "ビーコン(中央) 距離=%.0fm 音量=%.2f [%@]",
                             Geo.distanceM(p, h), beaconGain(), summary(of: fix)))
            return
        }
        noteDirectionAvailable()
        // 定位の基準は「顔の向き」。取れないうちは進行方位で代用する。
        // 顔基準にすると、首を振っても音が世界に固定されて聞こえる
        let reference = latestFacingBearing ?? travel.deg
        let rel = Geo.angularDiffDeg(bearingHome, reference)
        let pan = SoundPlacement.pan(relativeBearingDeg: rel)
        let gain = beaconGain()
        synth?.play(.homeBeacon, relativeBearingDeg: rel, gain: gain)
        lastBeacon = (relDeg: rel, at: Date())
        noteReturnDirectionStarted()
        // 顔基準に切り替えた影響を後から評価できるよう、顔の向きと進行方位の両方を残す
        let facingLabel = latestFacingBearing.map { String(format: "%.0f°", $0) } ?? "-"
        let baselineLabel = headingFusion.baselineDeg.map { String(format: "%.0f°", $0) } ?? "-"
        let travelPan = sin(Geo.angularDiffDeg(bearingHome, travel.deg) * .pi / 180)
        // 歩調も残す。間隔が歩みに乗っているかを後から確かめられるようにする
        let cadenceLabel = currentCadence.map { String(format: "%.2f歩/s", $0) } ?? "-"
        logToFile(String(format: "ビーコン 距離=%.0fm 指す方位=%.0f°(%@) 進行=%.0f°(%@) 顔=%@ 基準線=%@"
                         + " pan=%.2f(進行基準なら %.2f) 間隔=%.1fs 歩調=%@ 音量=%.2f [%@]",
                         Geo.distanceM(p, h), bearingHome,
                         routeBearing == nil ? "自宅を直線" : "経路", travel.deg,
                         label(for: travel.source), facingLabel, baselineLabel, pan, travelPan,
                         beaconInterval(), cadenceLabel, gain, summary(of: fix)))
    }

    /// いま使える歩調 [歩/秒]。立ち止まると更新が来なくなるので鮮度で切る
    private var currentCadence: Double? {
        pedometer.cadence(maxAgeSec: params.audio.beaconCadenceMaxAgeSec)
    }

    /// ビーコンの間隔。**歩調に同期する**(距離ではなく)
    private func beaconInterval() -> TimeInterval {
        BeaconRhythm.intervalSec(cadenceStepsPerSec: currentCadence, p: params.audio.beaconRhythm)
    }

    /// ビーコンの音量。**距離はここで表す**(間隔は歩調に取られるため)
    private func beaconGain() -> Double {
        guard let p = location.position, let h = home else { return params.audio.beaconGainFar }
        return BeaconRhythm.gain(distanceM: Geo.distanceM(p, h), p: params.audio.beaconRhythm)
    }

    // MARK: - 入力ハンドラ

    private func onPosition(_ p: GeoPoint?) {
        guard let p else { return }
        let now = Date()
        if state == .wandering || state == .promptingReturn || state == .returning {
            let fix = location.motionFix(now: now)
            let limits = GaitMetrics.Limits(
                minMovingSpeedMps: params.budget.minMovingSpeedMPerS,
                minSegmentM: params.budget.pathSegmentMinM,
                maxAccuracyM: params.budget.maxAccuracyForMetricsM)
            walkMetrics.add(p, speedMps: fix.speedMps,
                            accuracyM: fix.horizontalAccuracyM, limits: limits)
            returnMetrics?.add(p, speedMps: fix.speedMps,
                               accuracyM: fix.horizontalAccuracyM, limits: limits)
            // 位置更新を 1 件ずつ残す。これがあれば、経路長・迂回率・提案の判定といった
            // 純粋ロジックの変更は、歩き直さずに記録したログの再生で検証できる
            // (scripts/replay_log.sh)。docs/05「検証の方針」
            logToFile("fix [\(summary(of: fix))]")
        }
        if commuteLearning {
            grid.markExcluded(at: p, date: now)
        } else if state == .wandering || state == .returning {
            grid.recordVisit(at: p, date: now)
        }
        if state == .returning, let h = home,
           Geo.distanceM(p, h) <= params.session.arrivalRadiusM {
            logReturnMeasurements(now: now)
            apply(.reachedHome)
            log("到着しました")
        } else if state == .returning {
            checkReturnGuidance(at: p)
            advanceBeaconIfDirectionChanged(at: p, now: now)
        } else if state == .wandering {
            checkReturnPrompt(at: p)
            tickSuggestion()
        }
        updateStatus()
    }

    private func onHeadphoneConnectionChange(_ connected: Bool) {
        headphonesConnected = connected
        log(connected ? "ヘッドフォンを検出しました" : "ヘッドフォンが外れました")
        // 再装着すると姿勢の基準が引き直され、yaw が不連続に跳ぶ。
        // 段階 8 の実測では装着直後に yaw 振幅 203.7° が記録されており、
        // 窓に残った古いサンプルと繋がると首振りに化ける。検出器と計測窓を捨てる
        resetMotionWindows()
        guard connected, promptPending, state == .promptingReturn else { return }
        promptPending = false
        synth?.play(.timeUpPrompt)
        log("再装着を検出したのでプロンプトを鳴らし直します")
    }

    /// 顔の絶対方位を更新する。進行方位が取れている間だけ基準線を育てる
    private func updateFacingBearing(_ s: HeadSample) {
        guard let course = latestCourseBearing else { return }
        // yaw と course の対を一定間隔で残す。角を曲がれば両方が同じだけ回るので、
        // 回転の向きが揃っているかを後から自動判定できる(再生ツールが読む)
        let now = Date()
        if state == .wandering || state == .returning,
           lastHeadingLogAt == nil
            || now.timeIntervalSince(lastHeadingLogAt!) >= params.heading.logIntervalSec {
            lastHeadingLogAt = now
            logToFile(String(format: "頭向き yaw=%.1f° course=%.1f°", s.yawDeg, course))
        }
        guard params.heading.useHeadOrientation else { return }
        let p = HeadingFusion.Params(baselineAlpha: params.heading.baselineAlpha,
                                     maxOffsetDeg: params.heading.maxOffsetDeg,
                                     minSamples: params.heading.minSamples,
                                     yawSign: params.heading.yawSign)
        latestFacingBearing = headingFusion.ingest(headYawDeg: s.yawDeg,
                                                   travelBearingDeg: course, p: p)
    }

    /// 姿勢の基準が変わったときに、検出器と診断の窓を捨てる
    private func resetMotionWindows() {
        detector = HeadGestureDetector(params: params.gesture)
        shadowDetector = HeadGestureDetector(params: params.gesture)
        // 再装着で yaw の基準が引き直されるため、顔の向きの基準線も作り直す
        headingFusion.reset()
        latestFacingBearing = nil
        diagCount = 0
        diagPitchMin = .infinity
        diagPitchMax = -.infinity
        diagYawMin = .infinity
        diagYawMax = -.infinity
        diagWindowStart = nil
        diagYawPrevRaw = nil
        diagYawOffset = 0
    }

    private func onHeadSample(_ s: HeadSample) {
        accumulateMotionDiagnostics(s)
        updateFacingBearing(s)

        if state == .promptingReturn {
            switch detector.ingest(s) {
            case .nod:
                log("うなずきを検出")
                apply(.nod)
            case .shake:
                log("首振りを検出")
                apply(.shake)
            case nil:
                break
            }
            return
        }

        // 応答待ち以外でも同じ判定を回し、記録だけする。
        // 実際の応答は数秒で終わるため、その短い窓を狙って誤検出を観察するのは現実的でない。
        // 散歩中ずっと影で回しておけば、閾値の誤検出率をテスト手順を変えずに数えられる
        guard state == .wandering || state == .returning else { return }
        if let g = shadowDetector.ingest(s) {
            logToFile("影検出: \(g == .nod ? "うなずき" : "首振り")(動作には影響しない)")
        }
    }

    // MARK: - モーション受信の計測

    private var diagCount = 0
    private var diagPitchMin = Double.infinity
    private var diagPitchMax = -Double.infinity
    private var diagYawMin = Double.infinity
    private var diagYawMax = -Double.infinity
    private var diagWindowStart: TimeInterval?
    private var diagYawPrevRaw: Double?
    private var diagYawOffset = 0.0

    /// 一定間隔でサンプリング頻度と実測振幅をまとめる。
    /// 「サンプルが届いていない」のか「振幅が閾値に届いていない」のかを切り分けるための計測。
    private func accumulateMotionDiagnostics(_ s: HeadSample) {
        if diagWindowStart == nil { diagWindowStart = s.time }
        diagCount += 1
        diagPitchMin = min(diagPitchMin, s.pitchDeg)
        diagPitchMax = max(diagPitchMax, s.pitchDeg)

        // yaw は ±180° で折り返すため、検出器と同じく連続値に直してから振幅を取る
        if let prev = diagYawPrevRaw {
            let d = s.yawDeg - prev
            if d > 180 {
                diagYawOffset -= 360
            } else if d < -180 {
                diagYawOffset += 360
            }
        }
        diagYawPrevRaw = s.yawDeg
        let yaw = s.yawDeg + diagYawOffset
        diagYawMin = min(diagYawMin, yaw)
        diagYawMax = max(diagYawMax, yaw)

        guard let start = diagWindowStart,
              s.time - start >= params.gesture.diagnosticsIntervalSec else { return }

        let elapsed = s.time - start
        let hz = elapsed > 0 ? Double(diagCount) / elapsed : 0
        let pitchRange = diagPitchMax - diagPitchMin
        let yawRange = diagYawMax - diagYawMin
        // yaw の生値と基準線も出す。CoreMotion の yaw が右回りに増えるのか減るのかを
        // 屋内で確かめられるようにするため(顔を右に向けて数字が増えるかを見る)。
        // 2026-08-18 の実測で顔の向きの推定が逆側の定位を出したため、符号の切り分けに使う
        motionStatusLine = String(format: "モーション %.0f Hz / pitch 振幅 %.1f°(閾値 %.0f) / yaw 振幅 %.1f°(閾値 %.0f)"
                                  + " / yaw 生値 %.0f° 基準線 %@",
                                  hz, pitchRange, params.gesture.nodPitchThresholdDeg * 2,
                                  yawRange, params.gesture.shakeYawThresholdDeg * 2,
                                  s.yawDeg,
                                  headingFusion.baselineDeg.map { String(format: "%.0f°", $0) } ?? "未確立")
        if state == .promptingReturn {
            logToFile(motionStatusLine)
        } else if state != .idle {
            // 応答待ち以外(主に歩行中)は、検出に必要な振幅の一定割合を超えた時だけ残す。
            // 「あと少しで誤検出だった」動きを集め、閾値を下げられる余地の判断材料にする
            let ratio = params.gesture.diagnosticsReportRatio
            if pitchRange >= params.gesture.nodPitchThresholdDeg * 2 * ratio
                || yawRange >= params.gesture.shakeYawThresholdDeg * 2 * ratio {
                logToFile("誤検出候補 \(motionStatusLine)")
            }
        }

        diagCount = 0
        diagPitchMin = .infinity
        diagPitchMax = -.infinity
        diagYawMin = .infinity
        diagYawMax = -.infinity
        diagWindowStart = s.time
    }

    // MARK: - 表示・ログ

    private func commuteLearningChanged(_ oldValue: Bool) {
        guard commuteLearning != oldValue else { return }
        if commuteLearning {
            location.start()
            log("通勤路の学習を開始(この移動は今後の提案から除外されます)")
        } else {
            if state == .idle { location.stop() }
            GridStore.save(grid)
            log("通勤路の学習を終了・保存しました")
        }
    }

    private func updateStatus() {
        // 「現在地が無い」のか「自宅が未設定」なのかを取り違えないよう分けて示す
        guard let p = location.position else {
            statusLine = "現在地を取得中…(取得できるまで自宅は設定できません)"
            return
        }
        guard let h = home else {
            statusLine = "現在地を取得しました。自宅を設定してください"
            return
        }
        let d = homeDistance(from: p) ?? .straight(Geo.distanceM(p, h))
        let ret = ReturnBudget.estimatedReturnMin(d, speedMPerMin: effectiveSpeedMPerMin,
                                                  p: params.budget)
        var parts = ["自宅まで \(Int(d.rawM)) m(\(d.label)・徒歩約 \(Int(ret.rounded())) 分)"]
        if let end = sessionEnd {
            parts.append("残り \(max(0, Int(end.timeIntervalSinceNow / 60))) 分")
        }
        // 無音に気づけるよう、音声エンジンの稼働状態を画面に出す
        if let synth {
            parts.append("音声: \(synth.isRunning ? "稼働" : "停止")")
        }
        // 経路データの有無で提案の質が変わるので、読めているかを画面で示す
        if let graph {
            parts.append("地図: 半径\(Int(graph.map.radiusM / 1000))km・\(graph.map.generated)"
                         + (graph.map.covers(p) ? "" : "(圏外)"))
        } else {
            parts.append("地図: 未読込")
        }
        // 実機テストで「いま左右の定位が何を基準にしているか」を確認するために表示する。
        // 表示は副作用を持たせたくないので、保持値の更新は行わない
        let held = lastGoodCourse.map {
            HeldCourse(deg: $0.deg, ageSec: Date().timeIntervalSince($0.at))
        }
        let travel = TravelDirection.resolve(location.motionFix(), held: held, params: params.location)
        parts.append("方向: \(travel.map { label(for: $0.source) } ?? "不明")")
        statusLine = parts.joined(separator: " / ")
    }

    /// 角を曲がった直後は、次のビーコンを待たずに繰り上げて鳴らす。
    /// 遠距離では間隔が最大 5 秒あり、曲がってから 1〜2 音ぶん古い方向を聞かされるため
    /// (docs/03「ビーコンの距離・方向キュー」の実測課題)。
    private func advanceBeaconIfDirectionChanged(at p: GeoPoint, now: Date) {
        // 誘導が鳴っている間はビーコンを休んでいるので、繰り上げも行わない(音の裁定)
        guard turnGuidance == nil else { return }
        guard let h = home, let last = lastBeacon else { return }
        guard now.timeIntervalSince(last.at) >= params.audio.beaconMinGapSec else { return }
        let fix = location.motionFix(now: now)
        guard let travel = currentTravel(fix, now: now) else { return }
        let rel = Geo.angularDiffDeg(Geo.bearingDeg(from: p, to: h), travel.deg)
        let change = abs(Geo.angularDiffDeg(rel, last.relDeg))
        guard change >= params.audio.beaconDirectionChangeDeg else { return }
        logToFile(String(format: "ビーコン繰り上げ 方向が %.0f° 変化(%.0f° → %.0f°)",
                         change, last.relDeg, rel))
        beaconTimer?.invalidate()
        fireReturnTick()
    }

    // MARK: - 曲がり角の誘導

    // MARK: - 行き先(広域)

    /// 向かう地帯を決める・選び直す。
    ///
    /// 交差点ごとの評価だけでは、曲がった直後の評価が高くてもその先がつまらない場所に
    /// 出ることがある(2026-08-19 の指摘)。先に「どのあたりへ向かうか」を決めておけば、
    /// 局所の選択に一貫した向きが与えられる。
    ///
    /// 選び直すのは 3 つの場合だけ:まだ無い / 着いた / 予算の外へ出た。
    /// 毎回選び直すと行き先がふらついて、向きを与える意味が無くなる。
    private func updateTarget(at p: GeoPoint, home h: GeoPoint,
                              allowedRadiusM: Double, bias: Double) {
        guard let zones else { return }
        // 帰りどきが近づいたら行き先は捨てる。帰宅が優先(スコア側でも畳まれている)
        if bias >= 1 {
            if target != nil {
                target = nil
                logToFile("行き先を解除(帰宅を優先)")
            }
            return
        }
        var reason: String?
        if target == nil {
            reason = "未設定"
        } else if let t = target,
                  Geo.distanceM(p, t.zone.center) <= params.route.targetReachedM {
            reason = "到達"
        } else if let t = target,
                  Geo.distanceM(t.zone.center, h) > allowedRadiusM {
            reason = "予算の外に出た"
        }
        guard let reason else { return }
        // **選ぶ半径は捨てる半径より内側にする。** 許容半径は時間とともに縮むので、
        // 予算いっぱいの地帯を選ぶと数秒で「予算の外」になって消える
        // (2026-08-19 実測: 許容 369m のとき 363m 先を選び、9 秒で失効した)
        let pickRadius = allowedRadiusM * params.budget.softZoneRatio
        guard let next = zones.chooseTarget(from: p, home: h, allowedRadiusM: pickRadius,
                                            grid: grid, now: Date(),
                                            p: params.route.zoneParams) else {
            if target != nil { logToFile("行き先を選べません(\(reason))") }
            target = nil
            return
        }
        target = next
        log(String(format: "行き先: %.0fm 先 方位 %.0f°(新鮮さ %.2f・道 %.0fm・%@・選定半径 %.0fm)",
                   next.distanceM, Geo.bearingDeg(from: p, to: next.zone.center),
                   next.novelty, next.zone.roadLengthM, reason, pickRadius))
    }

    /// 帰路でも、経路上の次の角へ誘導音を張る。
    /// ビーコンは「自宅の在り処」を指すだけなので、川や私有地越しにも鳴りうる。
    /// 実際に曲がる場所を指せるのは経路データがある場合だけ(docs/06 柱 3)。
    /// ビーコンとの重なりは音の裁定(誘導 > ビーコン)で解決している
    private func checkReturnGuidance(at p: GeoPoint) {
        guard turnGuidance == nil, let f = routeField, let graph else { return }
        guard let turn = f.nextTurn(from: p, graph: graph,
                                    straightWithinDeg: params.route.branchStraightDeg,
                                    maxLookM: params.route.intersectionLookaheadM,
                                    nodeToleranceM: params.route.nodeArrivalToleranceM)
        else { return }
        logToFile(String(format: "帰路の誘導を開始(角まで %.0fm)", turn.distanceM))
        // 散策と同じ音を使う。**聞き分けられる必要は無い**(2026-08-19 の利用者判断)。
        // 音の意味を揃えるほうが分かりやすい:
        // suggestion =「こちらへ曲がれ」/ homeBeacon =「自宅はあちら」
        startTurnGuidance(at: turn.corner, branchBearingDeg: turn.branchBearingDeg)
    }

    /// 帰路で方向のある音を鳴らせたことを記録する。確認音を止める合図(ReturnAck)
    private func noteReturnDirectionStarted() {
        guard state == .returning, !returnDirectionStarted else { return }
        returnDirectionStarted = true
        fireAckTick()
    }

    /// 誘導の設定値。Core は数値を持たないので、ここで束ねて渡す
    private var guidanceParams: TurnGuidance.Params {
        let a = params.audio
        return TurnGuidance.Params(
            startDistanceM: params.route.intersectionLookaheadM,
            peakBeforeM: a.guidancePeakBeforeM,
            intervalSec: a.guidanceIntervalSec,
            gainFar: a.guidanceGainFar,
            gainNear: a.guidanceGainNear,
            endDistanceM: a.guidanceEndDistanceM,
            leftBehindM: a.guidanceLeftBehindM,
            turnedWithinDeg: params.route.branchStraightDeg,
            closingTones: a.guidanceClosingTones)
    }

    /// 角へ近づくほど音量が上がる連続音。遠いうちは角そのものを指し、
    /// 手前で曲がる先を指し切り、曲がり終えたら数音かけて閉じる(判断は TurnGuidance)。
    ///
    /// 散策でも帰路でも `suggestion` を使う。音の意味を「こちらへ曲がれ」に揃え、
    /// 「自宅はあちら」の `homeBeacon` と区別する(語彙は 5 種のまま)。
    private func startTurnGuidance(at point: GeoPoint, branchBearingDeg: Double) {
        let d = location.position.map { Geo.distanceM($0, point) } ?? .greatestFiniteMagnitude
        turnGuidance = TurnGuidance(corner: point, branchBearingDeg: branchBearingDeg,
                                    distanceM: d)
        fireGuidanceTick()
    }

    private func stopTurnGuidance(_ reason: String) {
        guard let g = turnGuidance else { return }
        turnGuidance = nil
        guidanceTimer?.invalidate()
        logToFile(String(format: "誘導終了(%@・最接近 %.0fm)", reason, g.closestM))
    }

    private func fireGuidanceTick() {
        // 散策でも帰路でも同じ誘導を使う。帰路は「次にどこで曲がるか」が経路から決まるだけで、
        // 音の作り方は変わらない(docs/06 柱 3)
        guard state == .wandering || state == .returning,
              turnGuidance != nil, let p = location.position else {
            stopTurnGuidance("状態が変わった")
            return
        }
        let travel = currentTravel(location.motionFix())?.deg
        // next は状態を進めるので **1 回だけ呼ぶ**
        let outcome = turnGuidance!.next(position: p, travelBearingDeg: travel,
                                         p: guidanceParams)
        guard case .play(let step) = outcome else {
            if case .finished(let ending) = outcome { stopTurnGuidance(ending.rawValue) }
            return
        }

        // 定位の基準は顔の向き。取れないうちは進行方位で代用する
        let reference = latestFacingBearing ?? travel
        let rel = reference.map { Geo.angularDiffDeg(step.targetBearingDeg, $0) }
        synth?.play(.suggestion, relativeBearingDeg: rel, gain: step.gain)
        // 誘導が鳴った時点で「方向のある音」は出せている。確認音はここで終わる
        noteReturnDirectionStarted()
        logToFile(String(format: "誘導 角まで=%.0fm 鳴らす向き=%@ 音量=%.2f%@%@",
                         step.distanceM,
                         rel.map { String(format: "%+.0f°", $0) } ?? "-",
                         step.gain,
                         step.isClosing ? " 終端" : "",
                         state == .returning ? " 帰路" : ""))
        guidanceTimer?.invalidate()
        guidanceTimer = Timer.scheduledTimer(withTimeInterval: step.intervalSec,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireGuidanceTick() }
        }
    }

    // MARK: - 帰宅予算(経路長と実測速度で見積もる)

    /// 自宅を終点とする経路の場を作る。散歩の開始時に 1 回だけ。
    ///
    /// 数万節点の探索になるので**背景で解く**(実測 0.6 秒・Mac の Debug ビルド。
    /// 実機の Debug はこれより遅い)。開始の操作を待たせない。
    /// できるまでの数秒は直線距離で代替するので、動作は止まらない
    private func buildRouteField() {
        routeField = nil
        guard let graph, let h = home, graph.map.covers(h) else { return }
        let snapMax = params.route.snapMaxDistanceM
        let weights = RouteField.Weights(crossCostWeight: params.route.crossCostWeight,
                                         wayClassWeight: params.route.wayClassWeight)
        let started = Date()
        Task.detached(priority: .userInitiated) {
            let field = RouteField(graph: graph, goal: h,
                                   snapMaxDistanceM: snapMax, weights: weights)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 解いている間に散歩が終わっていたら捨てる
                guard self.state != .idle else { return }
                self.routeField = field
                guard let f = field else {
                    self.log("経路の場を作れません(自宅が道に乗らない)")
                    return
                }
                self.log(String(format: "経路の場を作りました(到達できる節点 %d / %d・%.1f 秒)",
                                f.reachableNodes, graph.map.nodes.count,
                                -started.timeIntervalSinceNow))
            }
        }
    }

    /// いま帰宅推定に使う歩行速度 [m/min]。
    /// 歩いている最中の実測を優先し、無ければ過去の推定、それも無ければ設定値
    private var effectiveSpeedMPerMin: Double {
        speed.effectiveMPerMin(sessionAverageMPerMin: walkMetrics.averageMovingSpeedMPerMin,
                               movingSamples: walkMetrics.movingSamples,
                               fallback: params.budget.walkingSpeedMPerMin,
                               limits: params.budget.speedLimits)
    }

    /// 自宅までの距離。**経路データがあれば実際に歩く距離**、無ければ直線距離。
    /// 直線 × 迂回率は川や私有地を突っ切った値になるので、取れるなら使わない
    private func homeDistance(from p: GeoPoint) -> ReturnBudget.Distance? {
        guard let h = home else { return nil }
        if let f = routeField, let graph, let m = f.pathLengthM(from: p, graph: graph) {
            return .route(m)
        }
        return .straight(Geo.distanceM(p, h))
    }

    /// 「今帰り始めれば設定時間ちょうどに着く」瞬間にプロンプトを発火する。
    /// sessionEnd で鳴らす方式では鳴った時点からさらに帰路の時間がかかり、
    /// 実測でも利用者はタイマーの 6 分前に「帰るべき時が過ぎている」と感じて手動発火した
    /// (2026-08-18)。sessionEnd のタイマーは GPS が取れない場合の後詰めとして残す。
    private func checkReturnPrompt(at p: GeoPoint) {
        guard let end = sessionEnd, let d = homeDistance(from: p) else { return }
        let remainingMin = end.timeIntervalSinceNow / 60
        let v = effectiveSpeedMPerMin
        guard ReturnBudget.shouldPromptReturn(remainingMin: remainingMin, distance: d,
                                              speedMPerMin: v, p: params.budget) else { return }
        log(String(format: "帰りどきです(残り %.0f 分・帰宅推定 %.0f 分・%@ %.0fm・%.0fm/min)",
                   remainingMin,
                   ReturnBudget.estimatedReturnMin(d, speedMPerMin: v, p: params.budget),
                   d.label, d.rawM, v))
        apply(.timeUp)
    }

    /// 帰路の実測を残す。予算模型の 2 係数を実測値と並べて記録し、
    /// 仮置きの値がどれだけずれているかを 1 回の散歩ごとに見えるようにする。
    private func logReturnMeasurements(now: Date) {
        guard let m = returnMetrics, let s = returnStart else { return }
        let elapsedMin = now.timeIntervalSince(s.at) / 60
        func num(_ v: Double?, _ format: String) -> String {
            guard let v else { return "-" }
            return String(format: format, v)
        }
        logToFile("帰路実測 直線=\(String(format: "%.0f", s.distanceM))m"
                  + " 経路長=\(String(format: "%.0f", m.pathLengthM))m"
                  + " 所要=\(String(format: "%.1f", elapsedMin))min"
                  + " 平均速度=\(num(m.averageMovingSpeedMPerMin, "%.0f"))m/min(設定 "
                  + String(format: "%.0f", params.budget.walkingSpeedMPerMin) + ")"
                  + " 迂回率=\(num(m.detourFactor(straightLineM: s.distanceM), "%.2f"))(設定 "
                  + String(format: "%.2f", params.budget.detourFactor) + ")"
                  + " 精度不足で除外=\(m.rejectedSamples)件")
        logWalkTotals()
    }

    /// 散歩全体の実測。途中で終了した場合も残す(帰路が完了しなくても速度は取れる)。
    /// ここで速度の推定に取り込む。次回以降の帰宅推定の分母になる
    private func logWalkTotals() {
        let avg = walkMetrics.averageMovingSpeedMPerMin
        logToFile("散歩全体 経路長=\(String(format: "%.0f", walkMetrics.pathLengthM))m"
                  + " 平均速度=\(avg.map { String(format: "%.0f", $0) } ?? "-")m/min"
                  + " 最高速度=\(String(format: "%.2f", walkMetrics.maxSpeedMps))m/s")
        let before = speed.mPerMin
        speed.record(sessionAverageMPerMin: avg, movingSamples: walkMetrics.movingSamples,
                     limits: params.budget.speedLimits)
        guard speed.mPerMin != before else {
            logToFile("速度の推定は据え置き(サンプル \(walkMetrics.movingSamples) 件)")
            return
        }
        SpeedStore.save(speed)
        logToFile(String(format: "速度の推定を更新 %@ → %.0fm/min(%d 回目・設定値 %.0f)",
                         before.map { String(format: "%.0f", $0) } ?? "なし",
                         speed.mPerMin ?? 0, speed.walks, params.budget.walkingSpeedMPerMin))
    }

    /// 進行方向の解決と、有効だった course の保持をまとめて行う。
    /// resolve は純粋関数のままにしたいので、保持はここ(Effect 側)の責務にする。
    private func currentTravel(_ fix: MotionFix, now: Date = Date()) -> TravelDirectionFix? {
        let held = lastGoodCourse.map {
            HeldCourse(deg: $0.deg, ageSec: now.timeIntervalSince($0.at))
        }
        let travel = TravelDirection.resolve(fix, held: held, params: params.location)
        if let travel, travel.source == .course {
            lastGoodCourse = (deg: travel.deg, at: now)
            // 顔の向きの基準線は、進行方位が信頼できるときにだけ育てる
            latestCourseBearing = travel.deg
        }
        return travel
    }

    /// 進行方向が取れずに音を控えたことを 1 度だけ記録する(25 秒ごとの連投を避ける)。
    /// 「なぜ取れなかったか」が分からないと閾値を動かせないため、棄却理由と生値を添える。
    private func noteDirectionUnavailable(_ fix: MotionFix) {
        guard !directionUnavailableLogged else { return }
        directionUnavailableLogged = true
        let reason = TravelDirection.rejectionReason(fix, params: params.location) ?? "理由不明"
        log("進行方向が取得できません(\(reason))[\(summary(of: fix))]")
    }

    private func noteDirectionAvailable() {
        guard directionUnavailableLogged else { return }
        directionUnavailableLogged = false
        log("進行方向を取得しました")
    }

    /// TravelDirection の判定材料。course が使われなかった理由の切り分けに使う
    private func summary(of f: MotionFix) -> String {
        func num(_ v: Double?, _ format: String) -> String {
            guard let v else { return "-" }
            return String(format: format, v)
        }
        return "course=\(num(f.courseDeg, "%.0f")) 速度=\(num(f.speedMps, "%.2f"))m/s"
            + " course精度=\(num(f.courseAccuracyDeg, "%.0f")) 経過=\(num(f.ageSec, "%.1f"))s"
            + " 水平精度=\(num(f.horizontalAccuracyM, "%.0f"))m"
    }

    private func label(for s: DirectionSource) -> String {
        switch s {
        case .course: "移動方向"
        case .heldCourse: "移動方向(保持)"
        case .compass: "端末コンパス"
        }
    }

    private func label(for d: RelativeDirection) -> String {
        switch d {
        case .straight: "直進"
        case .left45: "左ななめ前"
        case .right45: "右ななめ前"
        case .left90: "左"
        case .right90: "右"
        }
    }

    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        eventLog.append("\(f.string(from: Date())) \(message)")
        if eventLog.count > 50 {
            eventLog.removeFirst(eventLog.count - 50)
        }
        logToFile(message)
    }

    /// 画面には出さずファイルにだけ残す(頻度が高く、閾値調整に必要な観測値)
    private func logToFile(_ message: String) {
        fieldLog.append(state: stateKey, position: location.position, message: message)
    }

    private var stateKey: String {
        switch state {
        case .idle: "idle"
        case .wandering: "wandering"
        case .promptingReturn: "promptingReturn"
        case .returning: "returning"
        case .arrived: "arrived"
        }
    }
}
