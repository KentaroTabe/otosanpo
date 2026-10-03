import Foundation

/// **大きく向きが変わる時だけ、数秒の裏取りを要求する関所**(2026-10-03)。
///
/// ## なぜ要るか
///
/// 帰路のビーコンが指す向きが **1.5 秒で 180° 往復**していた(2026-09-08 の散歩・
/// 274 発のうち 67 発が後ろを指した)。原因は `WalkGraph.snap` も
/// `RouteField.forwardNode` も前回の選択を見ていないことで、交差点の近くでは
/// GPS の揺れだけでスナップ先の道が付け替わる(→ docs/05)。
///
/// **歩行では 1.5 秒で 180° 向きが変わることはない。** なので
/// 「大きな変化は、数秒続いた時だけ受け入れる」で往復は落とせる。
///
/// ## これは対症療法である(2026-10-03 の合議)
///
/// **根治ではない。** 誤った向きが確定時間より長く続けば、この関所は素通りさせる。
/// 63 秒続いた誤りには効かない。根治は経路追跡の側(向き付き線分での map matching、
/// 低精度の fix では経路仮説を変えない、スナップ点基準の端点コスト)にある。
/// **ここは防波堤**として、根治が入ったあとも残せる形にしてある。
///
/// ## 既存の `BearingHold` を使わない理由
///
/// あれは遊び + 指数追従(音楽スポット用)で、**180° を時間をかけて舐める**。
/// 途中ずっと真横を指すことになり、帰路の案内としては最悪の挙動になる。
/// ここが要るのは「切り替えるか、切り替えないか」の二択。
///
/// ## 設計の約束(合議で足した条件)
///
/// - 角度は**世界座標の絶対方位**。差は必ず円周差で取る
/// - 証拠は**固有の位置更新ごと**に数える(同じ fix を 2 度読んでも 1 件)
/// - 時間だけでなく**最小の標本数**も要求する(1 件が 2 回読まれただけで確定しない)
/// - **標本が途切れたら保留を捨てる**(測位が止まった前後を「続いた」と見ない)
/// - 入口と出口で閾値を分ける(Schmitt)。境目でのばたつきを避ける
/// - 帰路の開始・自宅の変更・経路の場の作り直しでは [reset] する
public struct BearingFlipGate {

    public struct Params: Equatable {
        /// この角度を超える変化は、すぐには受け入れない [deg]
        public var enterDeg: Double
        /// 保留中に、いま出している向きのこの範囲へ戻ってきたら保留を捨てる [deg]。
        /// **enterDeg より小さくする**(同じ値だと境目でばたつく)
        public var exitDeg: Double
        /// 保留中の候補を「同じ群」とみなす幅 [deg]。
        /// 外れたら群を作り直す。**毎回作り直すと永久に確定しない**ので広めに取る
        public var clusterDeg: Double
        /// 群が続いたと認める時間 [sec]。実測の往復は 1.3〜2.1 秒
        public var confirmSec: Double
        /// 確定に要る固有 fix の数
        public var minSamples: Int
        /// 標本の間隔がこれを超えたら保留を捨てる [sec]
        public var maxGapSec: Double

        public init(enterDeg: Double, exitDeg: Double, clusterDeg: Double,
                    confirmSec: Double, minSamples: Int, maxGapSec: Double) {
            self.enterDeg = enterDeg
            self.exitDeg = exitDeg
            self.clusterDeg = clusterDeg
            self.confirmSec = confirmSec
            self.minSamples = minSamples
            self.maxGapSec = maxGapSec
        }
    }

    /// いま出している向き [deg]。まだ何も入っていなければ nil
    public private(set) var current: Double?

    /// 保留中の候補群
    private struct Pending {
        var sumSin: Double
        var sumCos: Double
        var since: TimeInterval
        var last: TimeInterval
        var count: Int

        /// 群の中心(円周平均)
        var mean: Double {
            var deg = atan2(sumSin, sumCos) * 180 / .pi
            if deg < 0 { deg += 360 }
            return deg
        }

        mutating func add(_ deg: Double, at t: TimeInterval) {
            sumSin += sin(deg * .pi / 180)
            sumCos += cos(deg * .pi / 180)
            last = t
            count += 1
        }
    }

    private var pending: Pending?
    /// 最後に取り込んだ fix の時刻。**同じ fix を 2 度数えない**ため
    private var lastFixTime: TimeInterval?

    // 記録用(ログと再生で挙動を見るため)
    public private(set) var holds = 0      // 保留を始めた回数
    public private(set) var cancels = 0    // 元へ戻ってきて保留を捨てた回数
    public private(set) var confirms = 0   // 裏が取れて切り替えた回数
    public private(set) var drops = 0      // 時間切れ・ばらつきで捨てた回数

    public init() {}

    /// 全部捨てる。**帰路の開始・自宅の変更・経路の場の作り直し**で呼ぶ
    public mutating func reset() {
        current = nil
        pending = nil
        lastFixTime = nil
    }

    /// 新しい候補を取り込み、**いま出すべき向き**を返す。
    ///
    /// - Parameter deg: 経路の場が出した絶対方位
    /// - Parameter t: その方位の元になった**位置更新の時刻**。
    ///   同じ時刻で 2 度呼ばれても 1 件としてしか数えない
    @discardableResult
    public mutating func ingest(_ deg: Double, at t: TimeInterval, p: Params) -> Double {
        // **同じ fix を 2 度読まない。** ビーコンは定期発火と位置更新の両方から引かれる
        if let lastFix = lastFixTime, t <= lastFix { return current ?? deg }
        lastFixTime = t

        guard let now = current else {
            current = deg
            return deg
        }

        let moved = abs(Geo.angularDiffDeg(deg, now))

        // 保留中に、いま出している向きの近くへ戻ってきた → 往復だったので捨てる
        if pending != nil, moved <= p.exitDeg {
            pending = nil
            cancels += 1
            current = deg
            return deg
        }

        // 小さい変化は遅らせない(普通に曲がる時の追従を鈍らせない)
        if pending == nil, moved <= p.enterDeg {
            current = deg
            return deg
        }

        // ここから先は「大きな変化」。裏が取れるまで出さない
        if var waiting = pending,
           t - waiting.last <= p.maxGapSec,
           abs(Geo.angularDiffDeg(deg, waiting.mean)) <= p.clusterDeg {
            waiting.add(deg, at: t)
            pending = waiting
            if t - waiting.since >= p.confirmSec, waiting.count >= p.minSamples {
                // **確定したら最新の標本を出す。** 群の中心は古い位置のものを含むので、
                // 歩いて動いた後の向きとしては最新が正しい
                pending = nil
                confirms += 1
                current = deg
                return deg
            }
            return now
        }

        // 群から外れた / 間が空いた → 新しい群として数え直す
        if pending != nil { drops += 1 } else { holds += 1 }
        pending = Pending(sumSin: sin(deg * .pi / 180), sumCos: cos(deg * .pi / 180),
                          since: t, last: t, count: 1)
        return now
    }
}
