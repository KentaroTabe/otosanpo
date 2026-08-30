import Foundation

/// 頭部固定スマホの方位(磁気由来)を、定位の基準に使ってよいかの検疫(→ docs/13)。
///
/// 頭に載せても磁力計は磁力計で、**鉄骨・車・線路の近くでは数十度ずれる**。
/// 端末コンパスが帰路で左右を反転させた実測がある(docs/04・2026-08-16)ので、
/// 「磁気の方位をそのまま信じる」道は最初から取らない。
///
/// **歩いている間は course と突き合わせ、合っている実績が続いた時だけ信頼する。**
/// - 初期状態は「未検証」= 使わない。**信頼は実績から得る**(屋内の乱れた磁気で
///   歩き出す場合に、最初の数音が反転して鳴るのを防ぐ)
/// - |heading − course| が `distrustDeg` を超える状態が `distrustSec` 続いたら退避
/// - 内側が `regainSec` 続いたら採用(復帰も同じ形。行き来が暴れないよう窓で見る)
/// - 立ち止まっている間(course なし)は突き合わせる相手が無い →
///   **直前の状態を引き継ぎ、窓は捨てる**(中断を挟んだ実績を継ぎ足さない)
public struct HeadingQuarantine: Equatable {

    public struct Params: Equatable {
        /// course との差がこれを超えたら乱れを疑う [deg]
        public var distrustDeg: Double
        /// 超過がこれだけ続いたら退避 [sec]
        public var distrustSec: Double
        /// 内側がこれだけ続いたら採用(復帰)[sec]
        public var regainSec: Double

        public init(distrustDeg: Double, distrustSec: Double, regainSec: Double) {
            self.distrustDeg = distrustDeg
            self.distrustSec = distrustSec
            self.regainSec = regainSec
        }
    }

    public enum State: Equatable {
        /// まだ実績が無い(散歩の開始直後)。**使わない**
        case unverified
        /// course と合う実績が続いた。使う
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
    /// 閾値の内側が続いている区間の始まり
    private var agreeSince: TimeInterval?
    /// 閾値の外側が続いている区間の始まり
    private var disagreeSince: TimeInterval?

    public init() {}

    /// 方位を使ってよいか。`unverified` と `distrusted` はどちらも「使わない」だが、
    /// 画面・ログでは区別する(前者は正常な立ち上がり、後者は異常の検出)
    public var isUsable: Bool { state == .trusted }

    /// 1 サンプル分の判定を進める。
    /// - Parameters:
    ///   - headingDeg: 取り付け補正(offset)を**引いた後**の方位 [deg]
    ///   - courseDeg: 進行方位。取れていなければ nil(状態を保つ)
    ///   - t: サンプル時刻 [sec]。単調でありさえすれば基準は問わない
    /// - Returns: このサンプルの時点で方位を使ってよいか(= `isUsable`)
    @discardableResult
    public mutating func assess(headingDeg: Double, courseDeg: Double?,
                                at t: TimeInterval, p: Params) -> Bool {
        guard let course = courseDeg else {
            // 突き合わせる相手が無い間の実績は数えない。状態だけ引き継ぐ
            agreeSince = nil
            disagreeSince = nil
            return isUsable
        }
        let diff = abs(Geo.angularDiffDeg(headingDeg, course))
        if diff > p.distrustDeg {
            agreeSince = nil
            if disagreeSince == nil { disagreeSince = t }
            if t - disagreeSince! >= p.distrustSec { state = .distrusted }
        } else {
            disagreeSince = nil
            if agreeSince == nil { agreeSince = t }
            if t - agreeSince! >= p.regainSec { state = .trusted }
        }
        return isUsable
    }
}
