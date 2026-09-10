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
/// ## 証拠は「標本数」ではなく「fix の間の経過時間」で数える(2026-09-10)
///
/// 以前は `ingest` が呼ばれるたびに重み +1 だった。頭方位は 50 Hz、
/// GPS の fix は約 1 Hz なので、**同じ fix が 50 回、独立した証拠として数えられていた**。
///
/// いまの規則:
///
/// - **fix の時刻を識別子として使う。** 同じ時刻の fix を何度読んでも証拠は増えない
/// - 有効な course を持つ fix は、**直前の fix(course の有無を問わない)からの経過時間**
///   ぶんの証拠になる。course の無い fix を挟んだら、その区間は証拠に含めない
///   (有効 t=0 → 無効 t=1 → 有効 t=2 なら、最後の証拠は 1 秒であって 2 秒ではない)
/// - course が `maxGapSec` より長く途切れていたら、その fix は証拠にしない
/// - **減衰も fix の時刻で測る。** 頭方位のコールバック時刻で測ると、
///   新しい fix を最初に見た位相(10 Hz なら最大 0.1 秒・50 Hz なら 0.02 秒の遅れ)で
///   結果が変わってしまう
///
/// これで、頭方位を 10 Hz で流しても 50 Hz で流しても、
/// 同じ fix 列と方位の列なら**同じ学習結果**になる。
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
        /// 平均の半減期 [sec](fix の時刻で測る)
        public var halfLifeSec: Double
        /// 差が定数だと認める合成ベクトル長 R の下限(0..1)。1 に近いほど厳しい
        public var minConcentration: Double
        /// **学習した値から外れた標本を「門の外」と分類する角度** [deg]。0 で門なし。
        ///
        /// **学習が成立した後にだけ効く。** 学習中に掛けると、まだ意味のない円平均を
        /// 中心に門を閉じてしまい、通った側だけで R が上がる(自作自演)。
        /// 分類の結果は検疫が「門の外がどれだけ続いたか」を数える材料になる
        public var gateDeg: Double
        /// course の途切れとして許す上限 [sec]。これより長く途切れた後の fix は証拠にしない。
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
            /// location fix がまだ 1 つも無い
            case noFix
            /// 同じ fix を読み直した。証拠は増えない
            case duplicateFix
            /// 最初に有効な course を持った fix。**区間の始点になるだけ**で証拠は無い
            case firstFix
            /// 新しい fix だが course が無効。**区間の始点だけ進め、この区間を証拠にしない**
            case noCourse
            /// course が上限より長く途切れた後の fix。
            /// **未確定の証拠は捨てるが、状態は変えない**
            case gapTooLong
            /// 学習に取り込んだ(まだ固定前)。**固定値に対する分類ではないので、検疫は数えない**
            /// (学習を成立させた標本もこれ。数えると、成立直後の窓が白紙にならない)
            case learning
            /// 門の内側(= 固定した学習値と整合している)
            case inside
            /// 門の外側
            case outside
        }
        public var kind: Kind
        /// この標本が持ち込んだ有効証拠時間 [sec]。
        /// `learning` / `inside` / `outside` 以外は 0
        public var evidenceSec: Double

        public init(kind: Kind, evidenceSec: Double) {
            self.kind = kind
            self.evidenceSec = evidenceSec
        }

        /// 新しい fix を見た標本か(`noFix` と `duplicateFix` 以外)。ログの 1 行に
        /// 「最後に来た fix がどう扱われたか」を出すために使う
        public var isNewFix: Bool { kind != .noFix && kind != .duplicateFix }

        /// ログに出す短い名前
        public var label: String {
            switch kind {
            case .noFix: "fix無"
            case .duplicateFix: "同fix"
            case .firstFix: "始点"
            case .noCourse: "course無"
            case .gapTooLong: "間隔超"
            case .learning: "学習"
            case .inside: "門内"
            case .outside: "門外"
            }
        }
    }

    private var x = 0.0
    private var y = 0.0
    private var evidenceSec = 0.0
    /// 最後に見た fix の時刻(course の有無を問わない)。**これが fix の識別子**
    private var lastFixTime: TimeInterval?
    /// 最後に有効な course を持った fix の時刻。途切れの長さを測る
    private var lastCourseFixTime: TimeInterval?
    /// 最後に減衰を掛けた fix の時刻
    private var lastDecayFixTime: TimeInterval?
    /// 成立した値。**一度入ったら散歩の終わりまで変わらない**
    private var frozenDeg: Double?
    /// 成立した時点の R。凍結後の表示に使う
    private var frozenConcentration: Double?

    public init() {}

    /// 1 標本を取り込む。**頭方位のコールバック時刻は使わない**(fix の時刻だけで数える)。
    /// - Parameters:
    ///   - headingDeg: スマホの**生の**方位 [deg]
    ///   - courseDeg: **いま有効な生の** course。無効なら nil
    ///   - fixTime: 最新の location fix の時刻。**course が無効でも渡す**
    ///     (渡さないと、無効な fix を挟んだ区間まで次の証拠に入ってしまう)
    /// - Returns: 分類と、持ち込んだ証拠時間
    @discardableResult
    public mutating func ingest(headingDeg: Double, courseDeg: Double?,
                                fixTime: TimeInterval?, p: Params) -> Sample {
        guard let fixTime else { return Sample(kind: .noFix, evidenceSec: 0) }
        // **同じ fix を読み直しても証拠は増えない。**
        // 50 Hz で回っていても、1 Hz の fix は 1 Hz ぶんの証拠しか持たない
        if let last = lastFixTime, fixTime <= last {
            return Sample(kind: .duplicateFix, evidenceSec: 0)
        }
        let previousFix = lastFixTime
        lastFixTime = fixTime
        guard let course = courseDeg else {
            // 新しい fix だが course が無効。**区間の始点だけ進める**
            return Sample(kind: .noCourse, evidenceSec: 0)
        }
        let previousCourseFix = lastCourseFixTime
        lastCourseFixTime = fixTime
        // 有効な course が前に無ければ、間隔が測れない。区間の始点になるだけ
        guard let prevCourse = previousCourseFix, let prevFix = previousFix else {
            return Sample(kind: .firstFix, evidenceSec: 0)
        }
        // course が長く途切れていた。「その間ずっと合っていた」証拠にはならない
        guard fixTime - prevCourse <= p.maxGapSec else {
            return Sample(kind: .gapTooLong, evidenceSec: 0)
        }
        // **直前の fix からの時間だけ**を証拠にする。course の無い fix を挟んでいれば、
        // その区間は含まれない
        let credited = fixTime - prevFix

        let diffDeg = Geo.normalizeDeg(headingDeg - course)
        // **凍結後は分類だけ返す。** 統計を動かすと門の中心が動き、
        // 磁気バイアスの変化を検疫が検出できなくなる
        if let frozen = frozenDeg {
            let outside = p.gateDeg > 0
                && abs(Geo.angularDiffDeg(diffDeg, frozen)) > p.gateDeg
            return Sample(kind: outside ? .outside : .inside, evidenceSec: credited)
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
        if let last = lastDecayFixTime, p.halfLifeSec > 0 {
            let decay = pow(0.5, (fixTime - last) / p.halfLifeSec)
            x *= decay
            y *= decay
            evidenceSec *= decay
        }
        lastDecayFixTime = fixTime
        let rad = diffDeg * .pi / 180
        x += credited * cos(rad)
        y += credited * sin(rad)
        evidenceSec += credited
        // 成立したらその場で凍結する
        if evidenceSec >= p.minEvidenceSec, concentration >= p.minConcentration {
            frozenDeg = meanDeg
            frozenConcentration = concentration
        }
        return Sample(kind: .learning, evidenceSec: credited)
    }

    /// 閾値を通していない生の円平均 [deg](凍結する値の元)
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
