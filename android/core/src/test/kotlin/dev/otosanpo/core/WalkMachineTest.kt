package dev.otosanpo.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** iOS 版 `WalkMachineTests` と同じ遷移を確かめる */
class WalkMachineTest {
    private val session = AppParameters.Session(
        defaultDurationMin = 30.0, minDurationMin = 10.0, maxDurationMin = 90.0,
        extensionRatio = 0.33, maxExtensions = 2, rePromptIntervalSec = 60.0,
        arrivalRadiusM = 10.0
    )

    @Test
    fun `start from idle begins wandering`() {
        val (s, e) = WalkMachine.reduce(WalkState.IDLE, WalkEvent.START, 0, 30.0, session)
        assertEquals(WalkState.WANDERING, s)
        assertTrue(e.contains(WalkEffect.StartSuggestionLoop))
    }

    @Test
    fun `time up prompts`() {
        val (s, e) = WalkMachine.reduce(WalkState.WANDERING, WalkEvent.TIME_UP, 0, 30.0, session)
        assertEquals(WalkState.PROMPTING_RETURN, s)
        assertTrue(e.contains(WalkEffect.Play(Earcon.TIME_UP_PROMPT)))
        assertTrue(e.contains(WalkEffect.StartPromptWindow))
    }

    @Test
    fun `nod starts the return phase`() {
        val (s, e) = WalkMachine.reduce(WalkState.PROMPTING_RETURN, WalkEvent.NOD, 0, 30.0, session)
        assertEquals(WalkState.RETURNING, s)
        assertTrue(e.contains(WalkEffect.StartReturnPhase))
    }

    @Test
    fun `shake extends until the limit`() {
        val (s, e) = WalkMachine.reduce(WalkState.PROMPTING_RETURN, WalkEvent.SHAKE, 0, 30.0, session)
        assertEquals(WalkState.WANDERING, s)
        // 延長は設定時間に比例する(30 分 × 0.33)
        assertTrue(e.contains(WalkEffect.ExtendSession(30.0 * 0.33)))
    }

    @Test
    fun `shake at the limit only reprompts`() {
        val (s, e) = WalkMachine.reduce(WalkState.PROMPTING_RETURN, WalkEvent.SHAKE, 2, 30.0, session)
        assertEquals(WalkState.PROMPTING_RETURN, s)
        assertTrue(e.contains(WalkEffect.Play(Earcon.TIME_UP_PROMPT)))
        assertTrue(e.none { it is WalkEffect.ExtendSession })
    }

    @Test
    fun `reached home arrives`() {
        val (s, e) = WalkMachine.reduce(WalkState.RETURNING, WalkEvent.REACHED_HOME, 0, 30.0, session)
        assertEquals(WalkState.ARRIVED, s)
        assertTrue(e.contains(WalkEffect.Play(Earcon.ARRIVAL)))
        assertTrue(e.contains(WalkEffect.EndSession))
    }

    @Test
    fun `stop from anywhere`() {
        for (state in listOf(WalkState.WANDERING, WalkState.PROMPTING_RETURN,
                             WalkState.RETURNING, WalkState.ARRIVED)) {
            val (s, e) = WalkMachine.reduce(state, WalkEvent.STOP, 0, 30.0, session)
            assertEquals(WalkState.IDLE, s)
            assertTrue(e.contains(WalkEffect.EndSession))
        }
    }

    /** **帰路の案内は帰路の音で鳴らす**(2026-08-21 の利用者判断) */
    @Test
    fun `guidance uses the return tone only while returning`() {
        assertEquals(Earcon.HOME_BEACON, WalkMachine.guidanceEarcon(WalkState.RETURNING))
        for (state in listOf(WalkState.IDLE, WalkState.WANDERING,
                             WalkState.PROMPTING_RETURN, WalkState.ARRIVED)) {
            assertEquals(Earcon.SUGGESTION, WalkMachine.guidanceEarcon(state))
        }
    }
}
