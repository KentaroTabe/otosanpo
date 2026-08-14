import Foundation

/// earcon(非言語効果音)の語彙。音の実体は EarconSynth が config の tones から合成する。
public enum Earcon: String, CaseIterable, Equatable {
    case suggestion     // 寄り道の提案(パンで方向を示す)。延長了解音としても暫定共用
    case timeUpPrompt   // 時間到来。「帰る? うなずき=帰る / 首振り=延長」
    case returnAck      // 帰路開始に同意したことの確認音(同意後しばらく繰り返す)
    case homeBeacon     // 帰路の方向ビーコン(間欠。近いほど間隔が短い)
    case arrival        // 到着
}

public enum WalkState: Equatable {
    case idle             // 待機
    case wandering        // 散策中(往路。提案あり)
    case promptingReturn  // 時間到来。ジェスチャ応答待ち
    case returning        // 帰路(同意済み)
    case arrived          // 到着
}

public enum WalkEvent: Equatable {
    case start
    case timeUp
    case nod
    case shake
    case promptWindowExpired
    case reachedHome
    case stop
}

public enum WalkEffect: Equatable {
    case play(Earcon)
    case startSuggestionLoop
    case stopSuggestionLoop
    case startPromptWindow
    case extendSession(minutes: Double)
    case startReturnPhase
    case stopLoops
    case endSession
}

/// 状態遷移の純粋 reducer。副作用(タイマー・音・位置)は Controller が Effect を実行する。
public enum WalkMachine {
    public static func reduce(state: WalkState, event: WalkEvent,
                              extensionsUsed: Int,
                              params: AppParameters.Session) -> (WalkState, [WalkEffect]) {
        switch (state, event) {
        case (.idle, .start), (.arrived, .start):
            return (.wandering, [.startSuggestionLoop])

        case (.wandering, .timeUp):
            return (.promptingReturn, [.stopSuggestionLoop, .play(.timeUpPrompt), .startPromptWindow])

        case (.promptingReturn, .nod):
            return (.returning, [.startReturnPhase])

        case (.promptingReturn, .shake) where extensionsUsed < params.maxExtensions:
            return (.wandering, [.extendSession(minutes: params.extensionStepMin),
                                 .play(.suggestion),
                                 .startSuggestionLoop])

        case (.promptingReturn, .shake):
            // 延長回数の上限。再度プロンプトを鳴らす(強制はしない=叱らない)
            return (.promptingReturn, [.play(.timeUpPrompt), .startPromptWindow])

        case (.promptingReturn, .promptWindowExpired):
            return (.promptingReturn, [.play(.timeUpPrompt), .startPromptWindow])

        case (.returning, .reachedHome):
            return (.arrived, [.stopLoops, .play(.arrival), .endSession])

        case (_, .stop) where state != .idle:
            return (.idle, [.stopLoops, .endSession])

        default:
            return (state, [])
        }
    }
}
