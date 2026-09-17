import Foundation

/// 頭部固定スマホの方位(磁気由来)を、定位の基準に使ってよいかの検疫(→ docs/13)。
///
/// 頭に載せても磁力計は磁力計で、**鉄骨・車・線路の近くでは数十度ずれる**。
/// 端末コンパスが帰路で左右を反転させた実測がある(docs/04・2026-08-16)ので、
/// 「磁気の方位をそのまま信じる」道は最初から取らない。
///
/// ## 何を作り直したか(2026-09-10)
///
/// 以前は「|heading − course| ≤ `distrustDeg` が**途切れず** `regainSec` 続いたら採用」
/// だった。これが 2 つの理由で成立しなかった:
///
/// 1. **course は間欠。** 速度・精度が足りない fix では取れない。
///    1 標本でも欠けると窓がゼロに戻るため、実測の散歩(course 37%)では
///    条件が続いた最長が 3 秒で、`regainSec = 5` を**一度も満たさなかった**
///    (頭方位 389 件・採用 0 件)
/// 2. **頭部固定では、頭が進行方向から外れるのは正常。** 瞬時の差で
///    磁気の乱れを判定すると、店先を見ただけで退避する
///
/// いまは:
///
/// - **初期の信頼は検疫が与えない。** 取り付け補正の成立(証拠時間 + R)が与える。
///   成立した時点で `trusted` から始める(`markLearned`)
/// - 検疫は**退避と復帰だけ**を担う。判定は `MountOffset` が返す門の内外の分類を、
///   **異なる fix の証拠時間で重み付けした割合**で見る
/// - 証拠は有限の窓(`windowSec`)で保つ。累積全期間だと、前半の大量の門内が
///   後半の磁気バイアス変化を覆い隠す
///
/// ## この方式で区別できないこと(docs/13 にも記す)
///
/// **「進行方向から大きく外したまま歩き続ける」と「磁気バイアスが変わった」は、
/// heading と course だけでは区別できない。** 前者でも退避しうる。
/// そのときの実害は「進行方位へ落ちる」= 頭部固定を使わない従来の挙動で、
/// より危険な方位を採用する方向には倒れない。
/// スマホの角速度との突き合わせを入れるまでの暫定(→ 次の案件)。
public struct HeadingQuarantine: Equatable {

    public struct Params: Equatable {
        /// 証拠を保つ窓の長さ [sec](有効証拠時間で数える。壁時計ではない)
        public var windowSec: Double
        /// 退避に要る門外の割合(0..1)
        public var distrustRatio: Double
        /// 退避の判定に要る有効証拠時間 [sec]
        public var distrustSec: Double
        /// 復帰に要る門内の割合(0..1)
        public var regainRatio: Double
        /// 復帰の判定に要る有効証拠時間 [sec]
        public var regainSec: Double

        public init(windowSec: Double, distrustRatio: Double, distrustSec: Double,
                    regainRatio: Double, regainSec: Double) {
            self.windowSec = windowSec
            self.distrustRatio = distrustRatio
            self.distrustSec = distrustSec
            self.regainRatio = regainRatio
            self.regainSec = regainSec
        }
    }

    public enum State: Equatable {
        /// 取り付け補正がまだ成立していない。**使わない**
        /// (成立後にこの状態へ戻ることはない → 受け入れ条件 A2/E1)
        case unverified
        /// 使ってよい
        case trusted
        /// 乱れを検出した。course 定位へ退避中
        case distrusted

        /// ログ・画面に出す短い名前
        public var label: String {
            switch self {
            case .unverified: "未検証"
            case .trusted: "採用"
            case .distrusted: "退避"
            }
        }
    }

    public private(set) var state: State = .unverified

    /// 証拠窓の 1 件。**タプルにしない** — 合成の Equatable が付かず、
    /// `HeadingQuarantine` を単体テストで比較できなくなる
    private struct Entry: Equatable {
        var sec: Double
        var outside: Bool
    }

    /// 証拠窓。古いものから落とす(合計が `windowSec` を超えたぶんだけ削る)
    private var entries: [Entry] = []
    private var insideSec = 0.0
    private var outsideSec = 0.0

    public init() {}

    public var isUsable: Bool { state == .trusted }

    /// 窓に溜まっている有効証拠時間 [sec]
    public var evidenceSec: Double { insideSec + outsideSec }
    /// 窓の門外割合(証拠が無ければ 0)
    public var outsideRatio: Double {
        evidenceSec > 0 ? outsideSec / evidenceSec : 0
    }
    /// 窓の門内時間 [sec](ログ用)
    public var insideEvidenceSec: Double { insideSec }
    /// 窓の門外時間 [sec](ログ用)
    public var outsideEvidenceSec: Double { outsideSec }

    /// **取り付け補正が成立した。** 証拠を白紙にして採用状態から始める(受け入れ条件 D1)。
    /// 補正が付くと方位が学習値ぶん飛ぶので、それ以前の証拠は次の方位の保証にならない
    public mutating func markLearned() {
        guard state == .unverified else { return }
        clearWindow()
        state = .trusted
    }

    /// 1 標本ぶんの分類を取り込む。**差の計算はしない**
    /// (門の内外は `MountOffset` が 1 か所で決める → 受け入れ条件 D3)
    /// - Returns: この標本の時点で方位を使ってよいか
    @discardableResult
    public mutating func assess(_ sample: MountOffset.Sample, p: Params) -> Bool {
        // 補正が成立するまでは何も数えない
        guard state != .unverified else { return false }
        switch sample.kind {
        case .noFix, .duplicateFix, .firstFix, .noCourse:
            // 突き合わせる相手が無い / 同じ相手 / 区間の始点。**証拠も状態も動かさない**
            return isUsable
        case .learning:
            // **学習中の標本は、固定値に対する分類ではない。** 数えない。
            // 学習を成立させた標本もこれなので、成立直後の窓は白紙のまま始まる(D1)
            return isUsable
        case .gapTooLong, .courseExpired:
            // course の途切れが上限を超えた(新しい fix で分かった場合も、位置更新が止まって
            // 観測時刻で分かった場合も)。**未確定の証拠だけ捨てる。状態は変えない**(D6)
            clearWindow()
            return isUsable
        case .inside:
            append(sec: sample.evidenceSec, outside: false, p: p)
        case .outside:
            append(sec: sample.evidenceSec, outside: true, p: p)
        }
        switch state {
        case .trusted:
            if evidenceSec >= p.distrustSec, outsideRatio >= p.distrustRatio {
                state = .distrusted
                clearWindow()   // 遷移時に白紙化(D5)
            }
        case .distrusted:
            if evidenceSec >= p.regainSec, 1 - outsideRatio >= p.regainRatio {
                state = .trusted
                clearWindow()
            }
        case .unverified:
            break
        }
        return isUsable
    }

    private mutating func append(sec: Double, outside: Bool, p: Params) {
        guard sec > 0 else { return }
        entries.append(Entry(sec: sec, outside: outside))
        if outside { outsideSec += sec } else { insideSec += sec }
        // 窓からはみ出したぶんを古い順に削る。**端の 1 件は部分的に削る**
        // (件数で切ると、間隔の長い標本 1 件で窓が飛ぶ)
        var excess = evidenceSec - p.windowSec
        while excess > 0, let oldest = entries.first {
            let cut = Swift.min(oldest.sec, excess)
            if oldest.outside { outsideSec -= cut } else { insideSec -= cut }
            excess -= cut
            if cut >= oldest.sec {
                entries.removeFirst()
            } else {
                entries[0].sec -= cut
            }
        }
    }

    private mutating func clearWindow() {
        entries.removeAll()
        insideSec = 0
        outsideSec = 0
    }
}
