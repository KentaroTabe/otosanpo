package dev.otosanpo.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * 経路データのファイルを**名前を問わず読む**ための順序づけ。
 * **iOS 版 `Tests/MapFilesTests.swift` と同じ規則**を確かめる(片方だけ直すとずれる)。
 */
class MapFilesTest {

    private fun c(name: String, minutesAgo: Long, size: Long = 1000) =
        MapFiles.Candidate(name, 1_000_000_000L - minutesAgo * 60_000L, size)

    /** **今回の不具合そのもの。** 都市名のファイルだけでも読む対象になる */
    @Test
    fun cityNamedFileIsAccepted() {
        assertEquals(listOf("名古屋市.json"), MapFiles.order(listOf(c("名古屋市.json", 0))).map { it.name })
    }

    /** 正式名は最優先。既に正しく置けている端末で、先に重い他ファイルを解かない */
    @Test
    fun preferredNameWinsEvenWhenOlder() {
        val ordered = MapFiles.order(listOf(c("名古屋市.json", 0), c(MapFiles.PREFERRED_NAME, 500)))
        assertEquals(MapFiles.PREFERRED_NAME, ordered.first().name)
    }

    /** 正式名が無ければ新しい順。消し忘れた古い地図に負けない */
    @Test
    fun newestFirstWithoutPreferredName() {
        val ordered = MapFiles.order(
            listOf(c("金沢市.json", 300), c("名古屋市.json", 10), c("東京都.json", 900))
        )
        assertEquals(listOf("名古屋市.json", "金沢市.json", "東京都.json"), ordered.map { it.name })
    }

    /** 更新時刻が同着でも順が揺れない(実行のたびに読むファイルが変わると再現しない) */
    @Test
    fun tiesAreBrokenByNameSoOrderIsStable() {
        val a = MapFiles.order(listOf(c("b.json", 10), c("a.json", 10))).map { it.name }
        val b = MapFiles.order(listOf(c("a.json", 10), c("b.json", 10))).map { it.name }
        assertEquals(listOf("a.json", "b.json"), a)
        assertEquals(a, b)
    }

    @Test
    fun emptyStaysEmpty() {
        assertTrue(MapFiles.order(emptyList()).isEmpty())
    }

    @Test
    fun fingerprintIsStableForSameFiles() {
        val files = listOf(c("名古屋市.json", 10), c(MapFiles.PREFERRED_NAME, 20))
        assertEquals(MapFiles.fingerprint(files), MapFiles.fingerprint(files.reversed()))
    }

    @Test
    fun fingerprintChangesWhenFileIsAdded() {
        assertNotEquals(
            MapFiles.fingerprint(listOf(c("名古屋市.json", 10))),
            MapFiles.fingerprint(listOf(c("名古屋市.json", 10), c("金沢市.json", 5)))
        )
    }

    /** 同じ時刻に同名で差し替えられても気づく(更新時刻だけ見ていると取りこぼす) */
    @Test
    fun fingerprintChangesWhenSizeChangesAtSameTime() {
        assertNotEquals(
            MapFiles.fingerprint(listOf(c("名古屋市.json", 10, size = 1000))),
            MapFiles.fingerprint(listOf(c("名古屋市.json", 10, size = 2000)))
        )
    }

    @Test
    fun fingerprintOfNothingIsEmpty() {
        assertEquals("", MapFiles.fingerprint(emptyList()))
    }
}
