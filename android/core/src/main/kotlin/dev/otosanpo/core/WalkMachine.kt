package dev.otosanpo.core

/**
 * earcon(非言語効果音)の語彙。音の実体は再生側が `config` の tones から合成する。
 * **5 種から増やさない**(docs/01)。
 */
enum class Earcon {
    /** 寄り道の提案(散策中の曲がり角の誘導)。延長了解音としても暫定共用 */
    SUGGESTION,

    /** 時間到来。「帰る? うなずき=帰る / 首振り=延長」 */
    TIME_UP_PROMPT,

    /** 帰路開始に同意したことの確認音 */
    RETURN_ACK,

    /** 帰路の音。自宅の在り処(ビーコン)と帰路の曲がり角の誘導を兼ねる */
    HOME_BEACON,

    /** 到着 */
    ARRIVAL,
}

enum class WalkState { IDLE, WANDERING, PROMPTING_RETURN, RETURNING, ARRIVED }

enum class WalkEvent { START, TIME_UP, NOD, SHAKE, PROMPT_WINDOW_EXPIRED, REACHED_HOME, STOP }

sealed interface WalkEffect {
    data class Play(val earcon: Earcon) : WalkEffect
    data object StartSuggestionLoop : WalkEffect
    data object StopSuggestionLoop : WalkEffect
    data object StartPromptWindow : WalkEffect
    data class ExtendSession(val minutes: Double) : WalkEffect
    data object StartReturnPhase : WalkEffect
    data object StopLoops : WalkEffect
    data object EndSession : WalkEffect
}

/**
 * 状態遷移の純粋 reducer。副作用(タイマー・音・位置)は呼び出し側が Effect を実行する。
 *
 * iOS 版 `Sources/Core/WalkMachine.swift` の移植。**遷移表を変えない。**
 */
object WalkMachine {
    /**
     * 曲がり角の誘導に使う earcon。
     *
     * **帰路は帰路の音で案内する**(2026-08-21 の利用者判断)。
     * 帰路で誘導とビーコンが交互に鳴ると、同じ区間なのに音が 2 種類混ざって落ち着かない。
     * 指す先が角か自宅かの違いは間隔と音量が担う。
     */
    fun guidanceEarcon(state: WalkState): Earcon =
        if (state == WalkState.RETURNING) Earcon.HOME_BEACON else Earcon.SUGGESTION

    /**
     * @param plannedDurationMin この散歩の設定時間。延長量はこれに比例する
     */
    fun reduce(
        state: WalkState,
        event: WalkEvent,
        extensionsUsed: Int,
        plannedDurationMin: Double,
        params: AppParameters.Session,
    ): Pair<WalkState, List<WalkEffect>> = when {
        (state == WalkState.IDLE || state == WalkState.ARRIVED) && event == WalkEvent.START ->
            WalkState.WANDERING to listOf(WalkEffect.StartSuggestionLoop)

        state == WalkState.WANDERING && event == WalkEvent.TIME_UP ->
            WalkState.PROMPTING_RETURN to listOf(
                WalkEffect.StopSuggestionLoop,
                WalkEffect.Play(Earcon.TIME_UP_PROMPT),
                WalkEffect.StartPromptWindow,
            )

        state == WalkState.PROMPTING_RETURN && event == WalkEvent.NOD ->
            WalkState.RETURNING to listOf(WalkEffect.StartReturnPhase)

        state == WalkState.PROMPTING_RETURN && event == WalkEvent.SHAKE &&
            extensionsUsed < params.maxExtensions ->
            WalkState.WANDERING to listOf(
                WalkEffect.ExtendSession(plannedDurationMin * params.extensionRatio),
                WalkEffect.Play(Earcon.SUGGESTION),
                WalkEffect.StartSuggestionLoop,
            )

        // 延長回数の上限。再度プロンプトを鳴らす(強制はしない = 叱らない)
        state == WalkState.PROMPTING_RETURN && event == WalkEvent.SHAKE ->
            WalkState.PROMPTING_RETURN to listOf(
                WalkEffect.Play(Earcon.TIME_UP_PROMPT),
                WalkEffect.StartPromptWindow,
            )

        state == WalkState.PROMPTING_RETURN && event == WalkEvent.PROMPT_WINDOW_EXPIRED ->
            WalkState.PROMPTING_RETURN to listOf(
                WalkEffect.Play(Earcon.TIME_UP_PROMPT),
                WalkEffect.StartPromptWindow,
            )

        state == WalkState.RETURNING && event == WalkEvent.REACHED_HOME ->
            WalkState.ARRIVED to listOf(
                WalkEffect.StopLoops,
                WalkEffect.Play(Earcon.ARRIVAL),
                WalkEffect.EndSession,
            )

        event == WalkEvent.STOP && state != WalkState.IDLE ->
            WalkState.IDLE to listOf(WalkEffect.StopLoops, WalkEffect.EndSession)

        else -> state to emptyList()
    }
}
