import Foundation

/// 取り付けのずれを**直近の証拠だけ**から作り直す滑り窓(2026-09-18)。
///
/// ## なぜ要るか
///
/// `MountOffset` は成立した値を**散歩の終わりまで凍結**する。長い首振りで学習が
/// 白紙に戻る事故を 2 回踏んだ末の設計で、それ自体は正しい。
/// しかし 2026-09-18 の散歩で、**凍結した値が実測と 106° 食い違ったまま 10 分続いた**。
///
/// 原因は構造的なものだった。**スマホは頭の後ろに固定するので、装着は必ず
/// 「散歩を開始」の後になる**(利用者の明言。固定してから開始する運用は取れない)。
/// 実測(`scripts/head_offset_window.awk`)では:
///
/// - 0:00〜1:35 のずれ ≈ 347°(**手に持っている間**)。ここで 1:02 に学習が成立し凍結
/// - 1:40 に 93° へ跳ぶ(**装着した瞬間**)。以降 8 分間 ≈ 95° で安定
///
/// つまり「最初に成立した値」は**構造的に、装着前の値になりうる**。
/// 凍結を保ちながら誤りから戻るには、**凍結値とは別に、いまのずれを測り続ける**必要がある。
///
/// ## なぜ減衰つきの平均(`MountOffset`)ではなく滑り窓か
///
/// 減衰つきの和は**急に忘れられない**。半減期 300 秒では、装着前の証拠が装着後の
/// 推定を何分も引っ張る(実測の数字で試算すると、R が 0.8 へ戻るまで 5 分以上)。
/// 半減期を短くすると、こんどは証拠が飽和して `minEvidenceSec` に届かず
/// **一度も成立しなくなる**(0.38 s/s で半減期 30 秒なら飽和値 16 秒 < 20 秒)。
///
/// 滑り窓は、**窓が装着後の証拠だけで埋まった瞬間**に正しい値を出す。
/// 再生で測った乗り換え時刻(`field-logs/field-log-20260918-105111.tsv`。
/// 経過は再生の起点 = 最初の頭方位 行):
///
/// | 仕組み | 乗り換え |
/// |---|---|
/// | 退避 30 秒を待ってから白紙で学び直す(最初の実装) | 3:16 |
/// | 白紙の窓に証拠の上限を置いて捨てる | 3:43(**今より遅い**) |
/// | 滑り窓(これ) | → `docs/13_head_mount.md` の再生の表 |
///
/// ## 何を守るか
///
/// - 窓は**実効の証拠時間**で数える(fix の時刻・course の有無は `MountOffset` が
///   すでに解いている。ここへは「credited された証拠」と「差」だけが渡る)。
///   `MountOffset.evidence` は減衰するが、**窓の長さは減衰しない累計**で測る
/// - 窓が埋まる前は値を出さない。**一時的に横を向いただけで乗り換えないため**、
///   R(合成ベクトル長)の門も置く
/// - 乗り換えた後は窓を空にする。**同じ証拠で 2 回乗り換えない**
///
/// ## 保証しないこと(2026-09-18 の合議で指摘)
///
/// - **「取り付けが変わる瞬間をまたいだ窓は成立しない」とは言えない。**
///   混ざり方によっては R が門を越える(0° と 60° が等量なら円平均 30°・R ≈ 0.87)。
///   その場合に出る値は 2 つのずれの中間になる。実測の 344°/95° の組で試算すると、
///   装着後の証拠が 85% を占めた時点で R = 0.82 で成立し、値は 85° 前後
///   (真の 95° に対し 10° ほど内側)。**誤りの向きは大きく縮むが、消えはしない**
/// - **窓の値が「顔の向きとして正しい」ことは示せない。** 言えるのは
///   「直近の観測(生の方位 − course)と整合するずれ」までである
/// - 長く横を向いて歩けば、その姿勢のずれを学ぶ。heading と course だけでは、
///   取り付けの変化と持続した横向きを分離できない
public struct OffsetWindow: Equatable {

    public struct Params: Equatable {
        /// 窓に保つ実効証拠時間 [sec]。0 で無効(値を出さない)
        public var evidenceSec: Double
        /// 窓の値を信じる合成ベクトル長 R の下限(0..1)
        public var minConcentration: Double

        public init(evidenceSec: Double, minConcentration: Double) {
            self.evidenceSec = evidenceSec
            self.minConcentration = minConcentration
        }
    }

    /// 窓に入っている 1 件。単位ベクトルを持っておき、三角関数を足し直さない
    private struct Entry: Equatable {
        var ux: Double
        var uy: Double
        var evidenceSec: Double
    }

    private var entries: [Entry] = []
    private var sx = 0.0
    private var sy = 0.0
    private var total = 0.0
    /// 一度でも窓が満ちたか。**満ちる前の平均は信じない**
    private var filled = false

    public init() {}

    /// 1 件の証拠を足す。
    /// - Parameters:
    ///   - diffDeg: 生の方位 − course [deg]
    ///   - evidenceSec: `MountOffset.Sample.evidenceSec`(0 なら何もしない)
    ///   - p: 窓の設定
    public mutating func add(diffDeg: Double, evidenceSec: Double, p: Params) {
        guard p.evidenceSec > 0, evidenceSec > 0, diffDeg.isFinite else { return }
        let rad = diffDeg * .pi / 180
        entries.append(Entry(ux: cos(rad), uy: sin(rad), evidenceSec: evidenceSec))
        total += evidenceSec
        // **ちょうど届いたかを浮動小数の等号で測らない。** 0.2 秒を 50 回足すと
        // 10 にわずかに届かないことがあり、窓が永久に「満ちていない」ままになる
        if total >= p.evidenceSec * (1 - 1e-9) { filled = true }
        // 窓から溢れた分を古い側から削る。**端の 1 件は部分的に削る**
        // (丸ごと捨てると窓の長さが鋸歯状に揺れ、R と平均が更新間隔に依存する)
        var overflow = total - p.evidenceSec
        while overflow > 0, let first = entries.first {
            if first.evidenceSec > overflow {
                entries[0].evidenceSec = first.evidenceSec - overflow
                total -= overflow
                overflow = 0
            } else {
                entries.removeFirst()
                total -= first.evidenceSec
                overflow -= first.evidenceSec
            }
        }
        // **和は毎回作り直す。** 引き算で維持すると誤差が積もる(窓は数十件なので安い)
        sx = 0
        sy = 0
        for e in entries {
            sx += e.evidenceSec * e.ux
            sy += e.evidenceSec * e.uy
        }
    }

    /// 窓に入っている実効証拠時間 [sec]
    public var evidence: Double { total }

    /// 一度でも窓が満ちたか
    public var isFull: Bool { filled }

    /// 窓の円平均 [deg]。空なら nil
    public var meanDeg: Double? {
        guard total > 0 else { return nil }
        return Geo.normalizeDeg(atan2(sy, sx) * 180 / .pi)
    }

    /// 差の散らばりの少なさ(合成ベクトル長 R・0..1)
    public var concentration: Double {
        total > 0 ? (sx * sx + sy * sy).squareRoot() / total : 0
    }

    /// **信じてよい窓の値** [deg]。満ちていて R が門を越えていなければ nil
    public func estimateDeg(p: Params) -> Double? {
        guard p.evidenceSec > 0, filled, concentration >= p.minConcentration else { return nil }
        return meanDeg
    }

    /// 窓を空にする(乗り換えた直後。同じ証拠で 2 回乗り換えないため)
    public mutating func clear() {
        entries.removeAll()
        sx = 0
        sy = 0
        total = 0
        filled = false
    }
}
