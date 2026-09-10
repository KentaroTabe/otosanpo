import Foundation

/// 取り付けのずれ(スマホの方位軸と顔の向きの定常差)を、**歩きながら学習する**。
///
/// ## なぜ固定値にしないか(2026-09-01・利用者判断)
///
/// 初回の実験で、`offset_deg` を決め忘れたまま歩いてしまった。ずれは一定の +94° で、
/// 検疫が 84% 退避し、**実験としては何も検証されない散歩**になった。
/// 固定値は「付け直すたびにずれる・決め忘れても気づけない」を構造的に抱える。
/// ずれは course との差の**定常成分**としてログから正確に推定できた(残差の中央値 9.2°)
/// のだから、同じ計算を歩き出しにその場でやればよい。
///
/// ## 仕組み
///
/// heading − course の差を**円平均**(cos/sin の減衰つき合計)で追う。
/// 平均を「使ってよい」と判断する条件は 2 つ:
///
/// 1. **量**: 実効の証拠時間(減衰後の重み)が `minEvidenceSec` 以上
/// 2. **質**: 平均合成ベクトルの長さ R が `minConcentration` 以上。
///    R は差が一定なら 1 に近づき、散らばる(= 磁気が乱れている・
///    ポケットの中で揺れている)ほど 0 へ落ちる。**ずれが定数である証拠**を要求する
///
/// ポケットに入れて歩けば差が揺れて R が立たず、学習は成立しない
/// (= 頭部基準は使われない)。装置を外した A/B 比較がそのまま成立する。
///
/// ## 証拠は「標本数」ではなく「異なる fix の間の経過時間」で数える(2026-09-10)
///
/// 以前は `ingest` が呼ばれるたびに重み +1 だった。頭方位は 50 Hz、
/// GPS の fix は約 1 Hz なので、**同じ fix が 50 回、独立した証拠として数えられていた**。
/// `max_fix_age_sec` が 10 秒なので、古い fix 1 個だけで学習条件の半分を作れる。
/// `minWeight = update_hz × offset_min_sec` で辻褄は合わせていたが、
/// 重複そのものは消えていない(更新頻度を変えると学習の立ち上がりが変わってしまう)。
///
/// いまは **fix の時刻を識別子として使い、新しい fix のときだけ、
/// 前の fix からの経過時間ぶんの証拠を積む**。頭方位を 10 Hz で流しても
/// 50 Hz で流しても、同じ fix 列なら同じ学習結果になる。
///
/// ## 成立したら凍結する(2026-09-10)
///
/// 以前は成立後も平均を更新し続け、門が閉じ続けると白紙に戻していた
/// (`gateReopenSec`)。長い首振りが「付け直し」に化けて学習が消え、
/// 実測の散歩で 2 回起きた。いまは:
///
/// - 成立した値は**その散歩の終わりまで固定**する
/// - 門は「その標本を捨てる」ではなく「**門の外だと分類する**」役になり、
///   分類の集計は検疫(`HeadingQuarantine`)が行う
/// - 付け直しは次のセッション(docs/05 の設計原則 4「端末を外したら、
///   その時点以降の頭部データは無効」)
///
/// 凍結する理由はもう 1 つある。**平均を動かし続けると門の中心も動く**ので、
/// 磁気バイアスがゆっくり変わったときに検疫がそれを検出できない。
public struct MountOffset: Equatable {

    public struct Params: Equatable {
        /// 学習が成立するのに要る実効の証拠時間 [sec](減衰後)
        public var minEvidenceSec: Double
        /// 平均の半減期 [sec]
        public var halfLifeSec: Double
        /// 差が定数だと認める合成ベクトル長 R の下限(0..1)。1 に近いほど厳しい
        public var minConcentration: Double
        /// **学習した値から外れた標本を「門の外」と分類する角度** [deg]。0 で門なし。
        ///
        /// **学習が成立した後にだけ効く。** 学習中に掛けると、まだ意味のない円平均を
        /// 中心に門を閉じてしまい、通った側だけで R が上がる(自作自演)。
        /// 分類の結果は検疫が「門の外がどれだけ続いたか」を数える材料になる
        public var gateDeg: Double
        /// 異なる fix の間隔として認める上限 [sec]。これを超えた間隔は証拠に加算しない。
        /// 立ち止まりや受信の途切れを「その間ずっと合っていた」と数えないため
        public var maxGapSec: Double

        public init(minEvidenceSec: Double, halfLifeSec: Double, minConcentration: Double,
                    gateDeg: Double = 0, maxGapSec: Double) {
            self.minEvidenceSec = minEvidenceSec
            self.halfLifeSec = halfLifeSec
            self.minConcentration = minConcentration
            self.gateDeg = gateDeg
            self.maxGapSec = maxGapSec
        }
    }

    /// 1 標本を取り込んだ結果。**門の内外の分類はここだけで行う**(→ 受け入れ条件 D3)。
    /// 検疫はこの結果を集計するだけで、自分では差を計算しない
    public struct Sample: Equatable {
        public enum Kind: Equatable {
            /// 有効な生 course が無い。証拠も状態も動かさない
            case noCourse
            /// 同じ fix を読み直した。証拠は増えない
            case duplicateFix
            /// 新しい fix だが前の fix から離れすぎている。
            /// **未確定の証拠は捨てるが、状態は変えない**
            case gapTooLong
            /// 門の内側(= 学習した値と整合している)
            case inside
            /// 門の外側
            case outside
        }
        public var kind: Kind
        /// この標本が持ち込んだ有効証拠時間 [sec]。`inside` / `outside` 以外は 0
        public var evidenceSec: Double

        public init(kind: Kind, evidenceSec: Double) {
            self.kind = kind
            self.evidenceSec = evidenceSec
        }

        /// ログに出す短い名前
        public var label: String {
            switch kind {
            case .noCourse: "course無"
            case .duplicateFix: "同fix"
            case .gapTooLong: "間隔超"
            case .inside: "門内"
            case .outside: "門外"
            }
        }
    }

    private var x = 0.0
    private var y = 0.0
    private var evidenceSec = 0.0
    private var lastDecayT: TimeInterval?
    /// 最後に証拠として取り込んだ fix の時刻。**これが fix の識別子**
    private var lastFixTime: TimeInterval?
    /// 成立した値。**一度入ったら散歩の終わりまで変わらない**
    private var frozenDeg: Double?
    /// 成立した時点の R。凍結後の表示に使う
    private var frozenConcentration: Double?

    public init() {}

    /// 1 標本を取り込む。
    /// - Parameters:
    ///   - headingDeg: スマホの**生の**方位 [deg]
    ///   - courseDeg: **いま有効な生の** course。無ければ nil
    ///   - fixTime: その course を生んだ location fix の時刻。**同じ値なら同じ fix**
    ///   - t: 標本時刻 [sec](減衰の基準。fix の時刻とは別)
    /// - Returns: 門の内外の分類と、持ち込んだ証拠時間
    @discardableResult
    public mutating func ingest(headingDeg: Double, courseDeg: Double?,
                                fixTime: TimeInterval?, at t: TimeInterval,
                                p: Params) -> Sample {
        guard let course = courseDeg, let fixTime else {
            return Sample(kind: .noCourse, evidenceSec: 0)
        }
        // **同じ fix を読み直しても証拠は増えない。**
        // 50 Hz で回っていても、1 Hz の fix は 1 Hz ぶんの証拠しか持たない
        guard let previous = lastFixTime else {
            // 最初の fix。**間隔が測れないので証拠にはしない**(区間の始点になるだけ)
            lastFixTime = fixTime
            lastDecayT = t
            return Sample(kind: .duplicateFix, evidenceSec: 0)
        }
        guard fixTime > previous else {
            return Sample(kind: .duplicateFix, evidenceSec: 0)
        }
        let gap = fixTime - previous
        lastFixTime = fixTime
        guard gap <= p.maxGapSec else {
            // 離れすぎた区間は「その間ずっと合っていた」証拠にならない。
            // 次の区間の始点として時刻だけ進める
            lastDecayT = t
            return Sample(kind: .gapTooLong, evidenceSec: 0)
        }

        let diffDeg = Geo.normalizeDeg(headingDeg - course)
        // **凍結後は分類だけ返す。** 統計を動かすと門の中心が動き、
        // 磁気バイアスの変化を検疫が検出できなくなる
        if let frozen = frozenDeg {
            let outside = p.gateDeg > 0
                && abs(Geo.angularDiffDeg(diffDeg, frozen)) > p.gateDeg
            return Sample(kind: outside ? .outside : .inside, evidenceSec: gap)
        }

        // **学習中は門を開かない。**
        //
        // 以前は「証拠が貯まったら推定から離れた標本を捨てる」を学習中にも掛けていた。
        // これは**量だけを条件にしていて、推定の質を見ていなかった**。差が散らばっている
        // 間の円平均はほぼ無意味な向きを指すのに、そこを中心に門を閉じるため、
        // たまたま多かった側だけが通り続けて R が 1 に近づく — **自作自演で高い R を作り、
        // 出鱈目な値を学習してしまう**(2026-09-10 のテストで実際に 270° を学習した)。
        // 学習した値を散歩の終わりまで凍結する以上、この誤りは取り返しがつかない。
        //
        // 首を回している間の標本で平均が汚れる問題は、**R の門(`minConcentration`)が
        // 受け持つ**。汚れていれば学習が成立しないだけで、誤った値は作られない。
        if let last = lastDecayT, t > last, p.halfLifeSec > 0 {
            let decay = pow(0.5, (t - last) / p.halfLifeSec)
            x *= decay
            y *= decay
            evidenceSec *= decay
        }
        lastDecayT = t
        let rad = diffDeg * .pi / 180
        x += gap * cos(rad)
        y += gap * sin(rad)
        evidenceSec += gap
        // 成立したらその場で凍結する
        if evidenceSec >= p.minEvidenceSec, concentration >= p.minConcentration {
            frozenDeg = meanDeg
            frozenConcentration = concentration
        }
        return Sample(kind: .inside, evidenceSec: gap)
    }

    /// 閾値を通していない生の円平均 [deg]。**門の中心に使う**(表に出す値ではない)
    private var meanDeg: Double {
        Geo.normalizeDeg(atan2(y, x) * 180 / .pi)
    }

    /// 差の散らばりの少なさ(合成ベクトル長 R・0..1)。1 = 完全に一定。
    /// **凍結後は成立時点の値のまま**(C2: 学習後に R が変わらない)
    public var concentration: Double {
        if let frozen = frozenConcentration { return frozen }
        return evidenceSec > 0 ? (x * x + y * y).squareRoot() / evidenceSec : 0
    }

    /// 学習できたずれ [deg]。成立するまで nil、成立したら**散歩の終わりまで同じ値**
    public var offsetDeg: Double? { frozenDeg }

    /// 積み上がっている実効の証拠時間 [sec](ログと再生の表示用)
    public var evidence: Double { evidenceSec }
}
