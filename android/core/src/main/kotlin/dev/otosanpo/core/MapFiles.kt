package dev.otosanpo.core

/**
 * 置かれた経路データを、**どの順に読むか**を決める。
 * **iOS 版の `Sources/Core/MapFiles.swift` と同じ規則**(片方だけ直すとずれる)。
 *
 * ## なぜ要るか(2026-08-30)
 *
 * 読むファイル名を `otosanpo-map.json` に固定していたため、
 * `scripts/build_maps.sh` が出す**都市名のファイル**(`名古屋市.json` など)を
 * そのまま置いた端末で**永久に読まれなかった**。iOS 側で実際に起きた。
 *
 * Android の同梱版はビルド時に改名しているので同じ形では起きないが、
 * **手でファイルを置いた人は同じ穴を踏む**。先に塞ぐ。
 */
object MapFiles {

    /** 以前から使っている名前。**互換のため最優先で読む**(先に重い他ファイルを解かない) */
    const val PREFERRED_NAME = "otosanpo-map.json"

    /** 読める見込みのあるファイル 1 つぶん。判定に要る情報だけを持つ */
    data class Candidate(
        val name: String,
        /** 更新時刻(エポックミリ秒) */
        val modifiedMillis: Long,
        val sizeBytes: Long,
    )

    /** 読めなかった理由。**「未読込」の一言に潰さない** */
    sealed interface Failure {
        /** `.json` が 1 つも置かれていない */
        data object NoFile : Failure

        /** 置かれてはいるが、経路データとして解けなかった */
        data class Undecodable(val names: List<String>) : Failure
    }

    /**
     * 読む順。**正式名が先、その後は新しい順。**
     *
     * 先頭から試して最初に解けたものを使う。普通は 1 つしか置かれないので解くのは 1 回。
     * 新しい順にするのは、配り直したときに**古い地図を消し忘れても新しいほうが勝つ**ため。
     */
    fun order(candidates: List<Candidate>): List<Candidate> =
        candidates.sortedWith(
            compareByDescending<Candidate> { it.name == PREFERRED_NAME }
                .thenByDescending { it.modifiedMillis }
                // 同着は名前で決める。**実行のたびに読むファイルが変わらないように**
                .thenBy { it.name }
        )

    /**
     * 置かれたファイルの指紋。**変わっていなければ読み直さない**ための印。
     * 名前・更新時刻・サイズを見る(同じ時刻に同名で差し替えられてもサイズで気づく)。
     */
    fun fingerprint(candidates: List<Candidate>): String =
        order(candidates).joinToString("|") { "${it.name}:${it.modifiedMillis}:${it.sizeBytes}" }
}
