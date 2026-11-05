package dev.otosanpo.core

/**
 * **スポットを移すイベントの日程**(iOS 版 `SpotMoveSchedule.swift` の移植・2026-09-19)。
 *
 * > 「スポットについてある程度時間が経ったらイベントが発生し、うなずくとスポット位置が
 * > 変更される仕様を実装してください。イベントを拒否した場合はイベントまでの長さが
 * > 倍々に増えるように、イベントに合意してスポットが移動したときは長さを同じにする」
 *
 * ## 何を決める型か
 *
 * - **次にイベントを出す時刻**(間隔は合意で据え置き・断りで倍)
 * - **応答を受け付ける窓**(プロンプトが鳴り終わってから開く)
 *
 * 実際に音を鳴らすこと・応答を読むこと・スポットを選び直すことは呼ぶ側の仕事。
 * ここは**時刻の勘定だけ**を持ち、外部環境なしで試せるようにする。
 *
 * ## iOS との違いは「応答の取り方」だけ
 *
 * iOS はうなずき / 首振り、**Android は音量ボタン**(↓ = 移す / ↑ = そのまま)。
 * 受け口が違うだけで、時刻の勘定はまったく同じなので、この型は共有できる。
 *
 * ## 断りの数え方(2026-09-18 の合議)
 *
 * - **断る操作**と**窓の中で何も来なかった**の両方を「今回は移さない」として倍にする
 * - **中断は断りに数えない**(音が鳴らせなかった・帰路のプロンプトが割り込んだ)。
 *   数えると、利用者が何もしていないのに提案が遠のく
 * - **上限は置かない。** 断るほど来なくなるのは要望どおりの結果。
 *   残り時間で早める細工もしない(断ったのにまた早く来ることになる)
 *
 * 時刻の単位は**秒**。呼ぶ側はミリ秒を 1000 で割って渡す。
 */
data class SpotMoveSchedule(
    /** いまの間隔 [sec] */
    var intervalSec: Double = 0.0,
    /** 次にイベントを出す時刻。null なら予約なし(音楽が鳴っていない) */
    var nextAt: Double? = null,
    /** 応答を受け付ける窓。null なら応答待ちではない */
    var window: Window? = null,
    /** 断った回数(ログ用) */
    var refusals: Int = 0,
    /** 実際に移した回数(ログ用) */
    var moves: Int = 0,
) {
    data class Window(val opensAt: Double, val closesAt: Double)

    data class Params(
        /** 最初の間隔 [sec]。断るたびに 2 倍になる */
        val baseIntervalSec: Double,
        /**
         * プロンプトが鳴り終わってから、応答の窓を開くまでの待ち [sec]。
         * 鳴っている最中の操作を拾わないため
         */
        val responseDelaySec: Double,
        /** 応答を受け付ける長さ [sec] */
        val responseWindowSec: Double,
    )

    /** **音楽が実際に鳴り始めた時**に呼ぶ。待っていた時間は含めない(→ 合議 E1) */
    fun start(at: Double, p: Params) {
        intervalSec = maxOf(0.0, p.baseIntervalSec)
        nextAt = at + intervalSec
        window = null
    }

    /** イベントを出す時刻になったか。**応答待ちの間は出さない** */
    fun isDue(at: Double): Boolean {
        val next = nextAt ?: return false
        if (window != null) return false
        return at >= next
    }

    /** プロンプトを鳴らした。**鳴り終わる時刻**を渡す(そこから待って窓を開く → 合議 E3) */
    fun prompted(promptEndsAt: Double, p: Params) {
        val opens = promptEndsAt + maxOf(0.0, p.responseDelaySec)
        window = Window(opens, opens + maxOf(0.0, p.responseWindowSec))
        nextAt = null
    }

    /** いま応答を受け付けているか */
    fun acceptsResponse(at: Double): Boolean {
        val w = window ?: return false
        return at >= w.opensAt && at < w.closesAt
    }

    /** 応答が無いまま窓が閉じたか(→ 断り) */
    fun windowExpired(at: Double): Boolean {
        val w = window ?: return false
        return at >= w.closesAt
    }

    /** **合意して移した。** 間隔は変えない(→ 合議 E4) */
    fun accepted(at: Double) {
        moves += 1
        window = null
        nextAt = at + intervalSec
    }

    /** **断られた。** 間隔を 2 倍にする(→ 合議 E5・E6) */
    fun refused(at: Double) {
        refusals += 1
        window = null
        // **溢れさせない。** 倍々を繰り返しても、短い間隔へ戻ってはいけない(→ 合議 E12)
        val doubled = intervalSec * 2
        if (doubled.isFinite()) intervalSec = doubled
        nextAt = at + intervalSec
    }

    /** **中断。断りに数えない**(→ 合議 E10)。いまの間隔でもう一度待つ */
    fun postpone(at: Double) {
        window = null
        nextAt = at + intervalSec
    }

    /** 予約と応答待ちを捨てる(音楽の終了・帰路・散歩の終わり → 合議 E11) */
    fun stop() {
        nextAt = null
        window = null
    }
}
