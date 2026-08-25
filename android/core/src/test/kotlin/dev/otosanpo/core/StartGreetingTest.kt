package dev.otosanpo.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 散歩を始めるときの一言。**境界の扱い**(開始を含み終了を含まない)と、
 * **真夜中をまたぐ窓**が要点。
 */
class StartGreetingTest {
    private val windows = AppParameters.decode(
        File("../../config/parameters.json").readText()
    ).greeting.windows

    @Test
    fun `late night wraps across midnight`() {
        for (h in listOf(22, 23, 0, 3, 4)) {
            assertEquals("深夜の散歩は是非背後にお気をつけて",
                         StartGreeting.message(h, windows), "hour=$h")
        }
    }

    @Test
    fun `early morning`() {
        for (h in listOf(5, 6)) {
            assertEquals("早起きは3問の得", StartGreeting.message(h, windows), "hour=$h")
        }
    }

    @Test
    fun `day time`() {
        for (h in listOf(7, 12, 18, 21)) {
            assertEquals("さぁ歩き始めましょう", StartGreeting.message(h, windows), "hour=$h")
        }
    }

    /** **境界は開始を含み、終了を含まない。** 5 時ちょうどは早朝、7 時ちょうどは日中 */
    @Test
    fun `boundaries belong to the window that starts there`() {
        assertEquals("早起きは3問の得", StartGreeting.message(5, windows))
        assertEquals("さぁ歩き始めましょう", StartGreeting.message(7, windows))
        assertEquals("深夜の散歩は是非背後にお気をつけて", StartGreeting.message(22, windows))
    }

    /** 24 時間すべてに何かしら当たる(黙る時間帯を作らない) */
    @Test
    fun `every hour has a message`() {
        for (h in 0..23) {
            assertEquals(true, StartGreeting.message(h, windows) != null, "hour=$h")
        }
    }

    @Test
    fun `out of range hours produce nothing`() {
        assertNull(StartGreeting.message(-1, windows))
        assertNull(StartGreeting.message(24, windows))
    }

    /** 窓が無ければ黙る(設定で空にできる) */
    @Test
    fun `no windows means no message`() {
        assertNull(StartGreeting.message(12, emptyList()))
    }
}
