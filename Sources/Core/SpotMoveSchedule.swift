import Foundation

/// **スポットを移すイベントの日程**(2026-09-18 利用者依頼)。
///
/// > 「スポットについてある程度時間が経ったらイベントが発生し、うなずくとスポット位置が
/// > 変更される仕様を実装してください。イベントを拒否した場合はイベントまでの長さが
/// > 倍々に増えるように、イベントに合意してスポットが移動したときは長さを同じにする」
///
/// ## 何を決める型か
///
/// - **次にイベントを出す時刻**(間隔は合意で据え置き・断りで倍)
/// - **応答を受け付ける窓**(プロンプトが鳴り終わってから開く)
///
/// 実際に音を鳴らすこと・ジェスチャを読むこと・スポットを選び直すことは呼ぶ側の仕事。
/// ここは**時刻の勘定だけ**を持ち、外部環境なしで試せるようにする。
///
/// ## 断りの数え方(2026-09-18 の合議)
///
/// - **首振り**と**窓の中で何も来なかった**の両方を「今回は移さない」として倍にする
/// - **中断は断りに数えない**(音が鳴らせなかった・モーションが切れた・帰路のプロンプトが
///   割り込んだ)。数えると、利用者が何もしていないのに提案が遠のく
/// - **上限は置かない。** 断るほど来なくなるのは要望どおりの結果。
///   残り時間で早める細工もしない(断ったのにまた早く来ることになる)
public struct SpotMoveSchedule: Equatable {

    public struct Params: Equatable {
        /// 最初の間隔 [sec]。断るたびに 2 倍になる
        public var baseIntervalSec: Double
        /// プロンプトが鳴り終わってから、応答の窓を開くまでの待ち [sec]。
        /// 鳴っている最中のうなずきを拾わないため
        public var responseDelaySec: Double
        /// 応答を受け付ける長さ [sec]。**散策中に常時ジェスチャを開けない**ための窓
        public var responseWindowSec: Double

        public init(baseIntervalSec: Double, responseDelaySec: Double,
                    responseWindowSec: Double) {
            self.baseIntervalSec = baseIntervalSec
            self.responseDelaySec = responseDelaySec
            self.responseWindowSec = responseWindowSec
        }
    }

    /// いまの間隔 [sec]
    public private(set) var intervalSec: Double = 0
    /// 次にイベントを出す時刻。nil なら予約なし(音楽が鳴っていない)
    public private(set) var nextAt: TimeInterval?
    /// 応答の窓(開く時刻, 閉じる時刻)。nil なら応答待ちではない
    public private(set) var window: (opensAt: TimeInterval, closesAt: TimeInterval)?
    /// 断った回数(ログ用)
    public private(set) var refusals = 0
    /// 実際に移した回数(ログ用)
    public private(set) var moves = 0

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.intervalSec == b.intervalSec && a.nextAt == b.nextAt
            && a.window?.opensAt == b.window?.opensAt
            && a.window?.closesAt == b.window?.closesAt
            && a.refusals == b.refusals && a.moves == b.moves
    }

    /// **音楽が実際に鳴り始めた時**に呼ぶ。待っていた時間は含めない(→ 合議 E1)
    public mutating func start(at t: TimeInterval, p: Params) {
        intervalSec = Swift.max(0, p.baseIntervalSec)
        nextAt = t + intervalSec
        window = nil
    }

    /// イベントを出す時刻になったか。**応答待ちの間は出さない**
    public func isDue(at t: TimeInterval) -> Bool {
        guard let next = nextAt, window == nil else { return false }
        return t >= next
    }

    /// プロンプトを鳴らした。**鳴り終わる時刻**を渡す(そこから待って窓を開く → 合議 E3)
    public mutating func prompted(promptEndsAt: TimeInterval, p: Params) {
        let opens = promptEndsAt + Swift.max(0, p.responseDelaySec)
        window = (opens, opens + Swift.max(0, p.responseWindowSec))
        nextAt = nil
    }

    /// いま応答を受け付けているか
    public func acceptsResponse(at t: TimeInterval) -> Bool {
        guard let w = window else { return false }
        return t >= w.opensAt && t < w.closesAt
    }

    /// 応答が無いまま窓が閉じたか(→ 断り)
    public func windowExpired(at t: TimeInterval) -> Bool {
        guard let w = window else { return false }
        return t >= w.closesAt
    }

    /// **合意して移した。** 間隔は変えない(→ 合議 E4)
    public mutating func accepted(at t: TimeInterval) {
        moves += 1
        window = nil
        nextAt = t + intervalSec
    }

    /// **断られた。** 間隔を 2 倍にする(→ 合議 E5・E6)
    public mutating func refused(at t: TimeInterval) {
        refusals += 1
        window = nil
        // **溢れさせない。** 倍々を繰り返しても、短い間隔へ戻ってはいけない(→ 合議 E12)
        let doubled = intervalSec * 2
        intervalSec = doubled.isFinite ? doubled : intervalSec
        nextAt = t + intervalSec
    }

    /// **中断。断りに数えない**(→ 合議 E10)。いまの間隔でもう一度待つ
    public mutating func postpone(at t: TimeInterval) {
        window = nil
        nextAt = t + intervalSec
    }

    /// **応答待ちの最中に割り込まれた**(帰路の問いかけが入った・散策から抜けた)。
    ///
    /// 応答待ちでなければ何もしない。待っていた時だけ [postpone] する。
    ///
    /// ## なぜ要るか(2026-09-19・Android への移植中に見つけた穴)
    ///
    /// 呼ぶ側は「散策中でなければ何もしない」で返していた。すると**窓が開いたまま
    /// 置き去りになり**、延長して散策へ戻った時に期限切れとして [refused] が呼ばれ、
    /// **利用者が何もしていないのに間隔が倍**になっていた。合議 E10 に反する。
    ///
    /// - Returns: 実際に見送ったか(記録に残すかの判断に使う)
    @discardableResult
    public mutating func interruptIfWaiting(at t: TimeInterval) -> Bool {
        guard window != nil else { return false }
        postpone(at: t)
        return true
    }

    /// 予約と応答待ちを捨てる(音楽の終了・帰路・散歩の終わり → 合議 E11)
    public mutating func stop() {
        nextAt = nil
        window = nil
    }
}
