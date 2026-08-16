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
    private let fieldLog = FieldLog()
    private var synth: EarconSynth?
    private var grid: VisitGrid
    private var detector: HeadGestureDetector

    private var extensionsUsed = 0
    private var directionUnavailableLogged = false
    private var sessionEnd: Date?
    private var ackEnd: Date?
    private var suggestionTimer: Timer?
    private var beaconTimer: Timer?
    private var promptTimer: Timer?
    private var timeUpTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(params: AppParameters) {
        self.params = params
        durationMin = params.session.defaultDurationMin
        grid = GridStore.load(cellSizeM: params.route.cellSizeM,
                              halfLifeDays: params.route.visitHalfLifeDays)
        detector = HeadGestureDetector(params: params.gesture)
        home = HomeStore.load()

        location.$position
            .sink { [weak self] p in
                Task { @MainActor in self?.onPosition(p) }
            }
            .store(in: &cancellables)
        motion.onSample = { [weak self] s in
            Task { @MainActor in self?.onHeadSample(s) }
        }
        motion.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                self?.log(connected ? "ヘッドフォンを検出しました" : "ヘッドフォンが外れました")
            }
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
        if synth == nil {
            synth = try? EarconSynth(audio: params.audio)
            if synth == nil { log("音声エンジンの初期化に失敗(未確認要素)") }
        }
        extensionsUsed = 0
        ackEnd = nil
        sessionEnd = Date().addingTimeInterval(durationMin * 60)
        location.start()
        // 未接続でも start する(後から装着された時点で更新が始まる)
        motion.start()
        log("ヘッドフォンモーション: 利用可能=\(motion.isAvailable ? "はい" : "いいえ")"
            + " 許可=\(motion.authorizationLabel) 更新中=\(motion.isActive ? "はい" : "いいえ")")
        apply(.start)
        scheduleTimeUp()
        log("散歩を開始(\(Int(durationMin)) 分)")
    }

    func stopManually() {
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

    /// earcon の聴き分け確認用。初回の散歩は全方向が未踏で「直進」が最良になり
    /// 提案音が鳴らないため、音そのものの確認はこの経路で行う。
    func debugPlay(_ e: Earcon, pan: Float = 0) {
        if synth == nil {
            synth = try? EarconSynth(audio: params.audio)
        }
        guard let synth else {
            log("音声エンジンの初期化に失敗しました")
            return
        }
        synth.play(e, pan: pan)
        log("デバッグ再生: \(e.rawValue) pan=\(String(format: "%.1f", pan))")
    }

    // デバッグ用(シミュレータ・モーション非対応時の代替)
    func debugTimeUp() { apply(.timeUp) }
    func debugNod() { apply(.nod) }
    func debugShake() { apply(.shake) }

    // MARK: - イベント適用

    private func apply(_ event: WalkEvent) {
        let (next, effects) = WalkMachine.reduce(state: state, event: event,
                                                 extensionsUsed: extensionsUsed,
                                                 params: params.session)
        state = next
        for e in effects { run(e) }
    }

    private func run(_ effect: WalkEffect) {
        switch effect {
        case .play(let earcon):
            synth?.play(earcon)

        case .startSuggestionLoop:
            startSuggestionLoop()

        case .stopSuggestionLoop:
            suggestionTimer?.invalidate()

        case .startPromptWindow:
            promptTimer?.invalidate()
            promptTimer = Timer.scheduledTimer(withTimeInterval: params.session.rePromptIntervalSec,
                                               repeats: false) { [weak self] _ in
                Task { @MainActor in self?.apply(.promptWindowExpired) }
            }
            log("時間になりました(うなずき=帰る / 首振り=延長)")

        case .extendSession(let minutes):
            extensionsUsed += 1
            sessionEnd = Date().addingTimeInterval(minutes * 60)
            promptTimer?.invalidate()
            scheduleTimeUp()
            log("延長 +\(Int(minutes)) 分(\(extensionsUsed)/\(params.session.maxExtensions) 回)")

        case .startReturnPhase:
            promptTimer?.invalidate()
            ackEnd = Date().addingTimeInterval(params.audio.returnAckDurationSec)
            log("帰路開始に同意。確認音をしばらく繰り返します")
            fireReturnTick()

        case .stopLoops:
            suggestionTimer?.invalidate()
            beaconTimer?.invalidate()
            promptTimer?.invalidate()
            timeUpTimer?.invalidate()

        case .endSession:
            if !commuteLearning { location.stop() }
            motion.stop()
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

    private func startSuggestionLoop() {
        suggestionTimer?.invalidate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: params.audio.suggestionMinIntervalSec,
                                               repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSuggestion() }
        }
    }

    private func tickSuggestion() {
        guard state == .wandering,
              let p = location.position,
              let h = home,
              let end = sessionEnd else { return }
        let fix = location.motionFix()
        guard let travel = TravelDirection.resolve(fix, params: params.location) else {
            noteDirectionUnavailable()
            return
        }
        noteDirectionAvailable()
        let heading = travel.deg
        let remainingMin = end.timeIntervalSinceNow / 60
        let allowed = ReturnBudget.allowedRadiusM(remainingMin: remainingMin, p: params.budget)
        let bias = ReturnBudget.homewardBias(distanceM: Geo.distanceM(p, h),
                                             allowedRadiusM: allowed,
                                             p: params.budget)
        // 端末コンパスへ退避した理由を後から特定できるよう、判定に使った生値も残す
        let context = String(format: "方向=%@ %.0f° 自宅まで=%.0fm 許容=%.0fm bias=%.2f [%@]",
                             label(for: travel.source), heading, Geo.distanceM(p, h), allowed, bias,
                             summary(of: fix))
        if let s = BearingSuggester.suggest(position: p, headingDeg: heading, home: h,
                                            grid: grid, homewardBias: bias,
                                            route: params.route, now: Date()) {
            synth?.play(.suggestion, pan: s.pan)
            log("提案: \(label(for: s.direction)) [\(context)]")
        } else {
            // 「なぜ鳴らなかったか」を後から追えるようにする(直進が最良 or スコア不足)
            logToFile("提案なし [\(context)]")
        }
    }

    /// 帰路の音:同意直後は returnAck を一定間隔で繰り返し、
    /// ack 期間終了後は距離に応じた間隔の方向ビーコンへ移行する。
    private func fireReturnTick() {
        guard state == .returning else { return }
        let interval: TimeInterval
        if let ack = ackEnd, Date() < ack {
            synth?.play(.returnAck)
            interval = params.audio.returnAckRepeatIntervalSec
        } else {
            playBeacon()
            interval = beaconInterval()
        }
        beaconTimer?.invalidate()
        beaconTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireReturnTick() }
        }
    }

    private func playBeacon() {
        guard let p = location.position, let h = home else { return }
        let bearingHome = Geo.bearingDeg(from: p, to: h)
        let fix = location.motionFix()
        guard let travel = TravelDirection.resolve(fix, params: params.location) else {
            // 進行方向が不明なときは左右を付けない(誤った定位を出すより中央で鳴らす)
            noteDirectionUnavailable()
            synth?.play(.homeBeacon)
            return
        }
        noteDirectionAvailable()
        let rel = Geo.angularDiffDeg(bearingHome, travel.deg)
        let pan = Float(sin(rel * .pi / 180))
        synth?.play(.homeBeacon, pan: pan)
        logToFile(String(format: "ビーコン 距離=%.0fm 自宅方位=%.0f° 進行=%.0f°(%@) pan=%.2f 間隔=%.1fs [%@]",
                         Geo.distanceM(p, h), bearingHome, travel.deg,
                         label(for: travel.source), pan, beaconInterval(), summary(of: fix)))
    }

    private func beaconInterval() -> TimeInterval {
        let a = params.audio
        guard let p = location.position, let h = home else { return a.beaconIntervalFarSec }
        let d = Geo.distanceM(p, h)
        let span = a.beaconFarDistanceM - a.beaconNearDistanceM
        let t = span > 0 ? min(1, max(0, (d - a.beaconNearDistanceM) / span)) : 0
        return a.beaconIntervalNearSec + t * (a.beaconIntervalFarSec - a.beaconIntervalNearSec)
    }

    // MARK: - 入力ハンドラ

    private func onPosition(_ p: GeoPoint?) {
        guard let p else { return }
        let now = Date()
        if commuteLearning {
            grid.markExcluded(at: p, date: now)
        } else if state == .wandering || state == .returning {
            grid.recordVisit(at: p, date: now)
        }
        if state == .returning, let h = home,
           Geo.distanceM(p, h) <= params.session.arrivalRadiusM {
            apply(.reachedHome)
            log("到着しました")
        }
        updateStatus()
    }

    private func onHeadSample(_ s: HeadSample) {
        accumulateMotionDiagnostics(s)
        guard state == .promptingReturn else { return }
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
        motionStatusLine = String(format: "モーション %.0f Hz / pitch 振幅 %.1f°(閾値 %.0f) / yaw 振幅 %.1f°(閾値 %.0f)",
                                  hz, pitchRange, params.gesture.nodPitchThresholdDeg * 2,
                                  yawRange, params.gesture.shakeYawThresholdDeg * 2)
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
        let d = Geo.distanceM(p, h)
        let ret = ReturnBudget.estimatedReturnMin(distanceM: d, p: params.budget)
        var parts = ["自宅まで \(Int(d)) m(徒歩約 \(Int(ret.rounded())) 分)"]
        if let end = sessionEnd {
            parts.append("残り \(max(0, Int(end.timeIntervalSinceNow / 60))) 分")
        }
        // 実機テストで「いま左右の定位が何を基準にしているか」を確認するために表示する
        let travel = TravelDirection.resolve(location.motionFix(), params: params.location)
        parts.append("方向: \(travel.map { label(for: $0.source) } ?? "不明")")
        statusLine = parts.joined(separator: " / ")
    }

    /// 進行方向が取れずに音を控えたことを 1 度だけ記録する(25 秒ごとの連投を避ける)
    private func noteDirectionUnavailable() {
        guard !directionUnavailableLogged else { return }
        directionUnavailableLogged = true
        log("進行方向が取得できません(歩き出すと再開します)")
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
    }

    private func label(for s: DirectionSource) -> String {
        switch s {
        case .course: "移動方向"
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
