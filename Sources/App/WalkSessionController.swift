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
    @Published private(set) var eventLog: [String] = []

    let params: AppParameters

    private let location = LocationService()
    private let motion = HeadphoneMotionService()
    private var synth: EarconSynth?
    private var grid: VisitGrid
    private var detector: HeadGestureDetector

    private var extensionsUsed = 0
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
        location.requestPermission()
    }

    // MARK: - UI から呼ばれる操作

    func setHomeHere() {
        guard let p = location.position else {
            log("現在地が未取得です。少し待ってから再試行してください")
            location.start()
            return
        }
        home = p
        HomeStore.save(p)
        log("自宅を現在地に設定しました")
    }

    func start() {
        guard state == .idle || state == .arrived else { return }
        guard home != nil else {
            log("先に自宅を設定してください")
            return
        }
        if synth == nil {
            synth = try? EarconSynth(audio: params.audio)
            if synth == nil { log("音声エンジンの初期化に失敗(未確認要素)") }
        }
        extensionsUsed = 0
        ackEnd = nil
        sessionEnd = Date().addingTimeInterval(durationMin * 60)
        location.start()
        if motion.isAvailable {
            motion.start()
        } else {
            log("ヘッドフォンモーション非対応。デバッグボタンで応答を代替できます")
        }
        apply(.start)
        scheduleTimeUp()
        log("散歩を開始(\(Int(durationMin)) 分)")
    }

    func stopManually() {
        apply(.stop)
        log("終了しました")
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
              let heading = location.headingDeg,
              let end = sessionEnd else { return }
        let remainingMin = end.timeIntervalSinceNow / 60
        let allowed = ReturnBudget.allowedRadiusM(remainingMin: remainingMin, p: params.budget)
        let bias = ReturnBudget.homewardBias(distanceM: Geo.distanceM(p, h),
                                             allowedRadiusM: allowed,
                                             p: params.budget)
        if let s = BearingSuggester.suggest(position: p, headingDeg: heading, home: h,
                                            grid: grid, homewardBias: bias,
                                            route: params.route, now: Date()) {
            synth?.play(.suggestion, pan: s.pan)
            log("提案: \(label(for: s.direction))")
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
        let heading = location.headingDeg ?? 0
        let bearingHome = Geo.bearingDeg(from: p, to: h)
        let rel = Geo.angularDiffDeg(bearingHome, heading)
        let pan = Float(sin(rel * .pi / 180))
        synth?.play(.homeBeacon, pan: pan)
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
        guard state == .promptingReturn else { return }
        switch detector.ingest(s) {
        case .nod: apply(.nod)
        case .shake: apply(.shake)
        case nil: break
        }
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
        guard let p = location.position, let h = home else {
            statusLine = "位置情報待ち"
            return
        }
        let d = Geo.distanceM(p, h)
        let ret = ReturnBudget.estimatedReturnMin(distanceM: d, p: params.budget)
        var parts = ["自宅まで \(Int(d)) m(徒歩約 \(Int(ret.rounded())) 分)"]
        if let end = sessionEnd {
            parts.append("残り \(max(0, Int(end.timeIntervalSinceNow / 60))) 分")
        }
        statusLine = parts.joined(separator: " / ")
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
    }
}
