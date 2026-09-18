import Foundation

/// 頭に固定したスマホの方位を、**定位の基準として使ってよいか**を一手に決める(→ docs/13)。
///
/// ## なぜ 1 つの型にまとめたか(2026-09-08)
///
/// 取り付けのずれの学習(`MountOffset`)と磁気の検疫(`HeadingQuarantine`)は
/// 別々に作られ、**両方を突き合わせる判断は Controller に散っていた**。その結果:
///
/// - 学習が成立していなくても、検疫さえ通れば**未補正の方位が音に出ていた**
///   (docs/13 の「壊れた方位が音に出る経路が無い」はコードでは保証されていなかった)
/// - 学習が外れて補正値が消えると、方位が学習値ぶん(実測 94°)一瞬で飛ぶのに、
///   検疫は `distrust_sec` のあいだ「採用」のままだった
/// - 更新が止まっても**最後の値が残り続けた**(鮮度の判定がどこにも無かった)。
///   画面を消して頭に載せる構成では、音が最後の頭の向きに凍りついたまま戻らない
///
/// 判断を 1 つの純粋な型に集めることで、この 3 つを単体テストで固定でき、
/// **再生ツールも製品と同じ実装を使える**(別々に書くと必ずずれる)。
///
/// ## 使う側の約束
///
/// - `ingest` に渡す course は **いま有効な生の course だけ**。保持値(`heldCourse`)や
///   コンパス退避を渡してはいけない。立ち止まっている間に「止まる直前の course」と
///   「回っている頭」を突き合わせると、R が落ち、検疫が退避に落ちる
///   (= 首を回す試験が自分の前提を壊す)
/// - 使ってよいかは **`use(at:)` を読み出すたびに評価する**。更新が止まった場合を
///   受信側の処理だけで捕まえることはできない
public struct HeadMountFusion: Equatable {

    public struct Params: Equatable {
        public var offset: MountOffset.Params
        public var quarantine: HeadingQuarantine.Params
        /// 最終受信からこれを超えたら「古い」として使わない [sec]
        public var staleSec: Double
        /// **見直しの滑り窓に保つ証拠時間** [sec](0 で見直さない = 従来の一度きり)。
        /// 実効の証拠時間で数える(壁時計ではない)。→ `updateRelearning`
        public var relearnWindowEvidenceSec: Double
        /// 見直しの窓が出した値が、いま使っている値から**これを超えて食い違ったら乗り換える** [deg]。
        ///
        /// **門とは役割が違う**(門は個々の標本の分類・これは成立した 2 つの値の比較)ので、
        /// 設定は別項目にする。ちょうど同値では乗り換えない
        public var relearnMinDisagreeDeg: Double

        /// 見直しの窓に渡す設定。**門は無い**(窓は個々の標本を分類しない)。
        /// R の門は学習と同じ値を使う — 「差が定数である証拠」を要求する基準は同じでよい
        public var relearnWindow: OffsetWindow.Params {
            OffsetWindow.Params(evidenceSec: relearnWindowEvidenceSec,
                                minConcentration: offset.minConcentration)
        }

        public init(offset: MountOffset.Params, quarantine: HeadingQuarantine.Params,
                    staleSec: Double, relearnWindowEvidenceSec: Double = 0,
                    relearnMinDisagreeDeg: Double = 0) {
            self.offset = offset
            self.quarantine = quarantine
            self.staleSec = staleSec
            self.relearnWindowEvidenceSec = relearnWindowEvidenceSec
            self.relearnMinDisagreeDeg = relearnMinDisagreeDeg
        }
    }

    /// 使う / 使わない と、**使わない理由**。理由を区別するのはログに出すため
    /// (「退避が多い」と「学習が立たない」は原因も対処も違う)
    public enum Use: Equatable {
        /// 3 条件が揃った。定位の基準に使う
        case use
        /// まだ 1 標本も来ていない
        case noSample
        /// 最終受信が古い(更新が止まった)
        case stale
        /// 取り付けのずれの学習が成立していない / 失われた
        case offsetNotLearned
        /// 検疫が通していない
        case quarantined(HeadingQuarantine.State)

        public var isUsable: Bool { self == .use }

        /// ログ・画面に出す短い名前
        public var label: String {
            switch self {
            case .use: "採用"
            case .noSample: "標本なし"
            case .stale: "古い"
            case .offsetNotLearned: "補正待ち"
            case .quarantined(let s): s.label
            }
        }
    }

    private var offset = MountOffset()
    private var quarantine = HeadingQuarantine()
    private var lastSampleAt: TimeInterval?
    private var lastRawHeadingDeg: Double?
    private var learnedDeg: Double?
    /// 最後に**新しい fix** を見た標本の分類。
    ///
    /// 直前の標本そのものを出すと、50 Hz のうち 49 回は同じ fix の読み直しなので、
    /// 1 秒ごとのログがほぼ常に「同fix」になり、門内・門外が読めない(2026-09-10)
    private var lastNewFix: MountOffset.Sample?
    /// 直前の標本の種類(ログの「今回」用)
    private var lastSampleKind: MountOffset.Sample.Kind?
    /// いま使っている値を見直す滑り窓(→ `updateRelearning`)。
    /// **窓が成立するまでは今の値で鳴らし続ける** — 途中で基準が消えると音が飛ぶため
    private var window = OffsetWindow()
    /// 乗り換えた回数(ログ用)。**0 でないなら、途中でずれが変わったと判断した**
    /// (原因は装着・付け直し・長い横向き・磁気の変化のどれもあり得る。断定はできない)
    public private(set) var relearnCount = 0
    /// 見直しの窓がいま出している値 [deg](ログ用。成立していなければ nil)
    public func windowOffsetDeg(p: Params) -> Double? { window.estimateDeg(p: p.relearnWindow) }
    /// 見直しの窓に積まれた実効証拠時間 [sec](ログ用)
    public var windowEvidenceSec: Double { window.evidence }
    /// 見直しの窓の R(ログ用)
    public var windowConcentration: Double { window.concentration }

    public init() {}

    /// 最後に新しい fix を見た標本の分類(ログ用)。まだ無ければ "-"
    public var lastNewFixLabel: String { lastNewFix?.label ?? "-" }
    /// 直前の標本が新しい fix だったか(ログ用): 「fix無 / 重複 / 新規」。
    /// 「最後の新 fix の分類」とは別の欄にする — 片方だけだと、いまの標本が
    /// 読み直しなのか新しい fix なのかがログから読めない(2026-09-10 の 2 回目の検証で指摘)
    public var currentObservationLabel: String {
        guard let kind = lastSampleKind, kind != .noFix else { return "fix無" }
        // 期限切れ(位置更新が止まっている)も、同じ fix の読み直しであることは変わらない
        return (kind == .duplicateFix || kind == .courseExpired) ? "重複" : "新規"
    }
    /// 検疫の証拠窓の門内時間 [sec](ログ用)
    public var insideEvidenceSec: Double { quarantine.insideEvidenceSec }
    /// 検疫の証拠窓の門外時間 [sec](ログ用)
    public var outsideEvidenceSec: Double { quarantine.outsideEvidenceSec }
    /// 検疫の証拠窓の門外割合(ログ用・証拠が無ければ 0)
    public var outsideRatio: Double { quarantine.outsideRatio }
    /// 学習に積み上がっている実効の証拠時間 [sec](ログ用)
    public var offsetEvidenceSec: Double { offset.evidence }

    /// 学習できた取り付けのずれ [deg]。成立していなければ nil
    public var learnedOffsetDeg: Double? { learnedDeg }
    /// ずれの散らばりの少なさ(合成ベクトル長 R・0..1)
    public var concentration: Double { offset.concentration }
    /// 検疫の状態(未検証 / 採用 / 退避)
    public var quarantineState: HeadingQuarantine.State { quarantine.state }
    /// 最後に受けた**生の**方位 [deg]
    public var rawHeadingDeg: Double? { lastRawHeadingDeg }

    /// 取り付けのずれを引いた方位 [deg]。**使ってよいかは別の判断**(`use(at:)`)。
    /// 学習前は補正 0 のまま返す(ログに出すため。定位には流れない)
    public var correctedHeadingDeg: Double? {
        guard let raw = lastRawHeadingDeg else { return nil }
        return Geo.normalizeDeg(raw - (learnedDeg ?? 0))
    }

    /// 1 標本を取り込む。
    /// - Parameters:
    ///   - headingDeg: スマホの**生の**方位(真北基準 0..360)
    ///   - rawCourseDeg: **いま有効な生の** course。無ければ nil(保持値を渡さない)
    ///   - fixTime: 最新の location fix の時刻。**course が無効でも渡す**
    ///     (渡さないと、無効な fix を挟んだ区間まで次の証拠に入る)
    ///   - t: 標本時刻 [sec]。鮮度の判定と、**位置更新が止まった場合の course の途切れの期限**
    ///     に使う(学習と検疫の証拠は fix の時刻で数える)
    /// - Returns: この標本の時点での判定
    @discardableResult
    public mutating func ingest(headingDeg: Double, rawCourseDeg: Double?,
                                fixTime: TimeInterval?, at t: TimeInterval, p: Params) -> Use {
        lastSampleAt = t
        lastRawHeadingDeg = headingDeg
        // 学習は**生の方位**で行う(補正後を食わせると自分の出力を追いかけて循環する)。
        // 門の内外の分類もここで一緒に返る(→ 受け入れ条件 D3。検疫は差を計算しない)
        // 学習と証拠は fix の時刻で数える。`t` で減衰や証拠を測ると、新しい fix を
        // 最初に見た位相で結果が変わる(2026-09-10 の検証)。
        // **`t` は course の途切れの期限にだけ使う** — 位置更新が止まると fix の時刻が
        // 進まず、fix の時刻だけでは期限が来ない(3 回目の検証で指摘)
        let sample = offset.ingest(headingDeg: headingDeg, courseDeg: rawCourseDeg,
                                   fixTime: fixTime, observedAt: t, p: p.offset)
        if sample.isNewFix { lastNewFix = sample }
        lastSampleKind = sample.kind
        // **成立は一度きり、以後は変わらない。** 成立した瞬間に検疫を採用状態から始める
        // (補正が付くと方位が学習値ぶん飛ぶので、それ以前の証拠は捨てる)
        if learnedDeg == nil, let learned = offset.offsetDeg {
            learnedDeg = learned
            quarantine.markLearned()
        }
        // 成立させた標本は `.learning` なので検疫は数えない — 窓は白紙のまま始まる(D1)
        quarantine.assess(sample, p: p.quarantine)
        updateRelearning(headingDeg: headingDeg, rawCourseDeg: rawCourseDeg,
                         sample: sample, p: p)
        return use(at: t, p: p)
    }

    /// **凍結した値を、白紙の窓で作り直し続けて見直す**(2026-09-18)。
    ///
    /// ## なぜ要るか
    ///
    /// 学習は**一度きりで凍結**する設計だった。ところが 2026-09-18 の散歩で、
    /// 学習した値(344.0°)が、その後の実測と **106° 食い違った**まま 10 分間直らなかった。
    ///
    /// 原因は構造的なものだった。**スマホは頭の後ろに固定するので、装着は必ず
    /// 「散歩を開始」の後になる**(利用者の明言。固定してから開始する運用は取れない)。
    /// 実測(`scripts/head_offset_window.awk`)では:
    ///
    /// - 0:00〜1:35 のずれ ≈ 347°(**手に持っている間**)。ここで 1:02 に学習が成立
    /// - 1:40 に 93° へ跳ぶ(**装着した瞬間**)。以降 8 分間 ≈ 95° で安定
    ///
    /// 凍結値は**分類にしか使われず更新されない**ので、正しい値へ戻る道が無かった
    /// (門はその上で、食い違う標本を「門外」と分類し続けた)。
    ///
    /// ## どう直すか
    ///
    /// **直近の証拠だけを見る滑り窓(`OffsetWindow`)を、常に並行して回す。**
    /// 窓が満ちて R が門を越えたら、いま使っている値と比べ、
    /// `relearnMinDisagreeDeg` を超えて食い違うなら**乗り換える**。
    ///
    /// 窓は `MountOffset` が credited した証拠だけを受け取る(fix の識別・course の
    /// 有無・間隔の上限はすでにそこで解かれている)。**門は掛からない** —
    /// いま使っている値が正しい保証が無いので、その周りに門を置くと自作自演になる。
    ///
    /// ## なぜ検疫を起点にしないか(2026-09-18・当初の実装を差し替えた)
    ///
    /// 最初は「退避が実効 30 秒続いたら学び直す」とした。しかし再生
    /// (`scripts/replay_log.sh`)で測ると乗り換えは 3:16 で、**起点を早めても
    /// 律速は「学習に要る 20 秒ぶんの証拠」(このログでは壁時計 53 秒)**だった。
    /// 検疫を起点にすると、さらに
    ///
    /// - 門より小さいずれは退避に至らないので、**永久に直らない**
    /// - 退避の累計を待つぶん、乗り換えが 80 秒ほど遅れる
    ///
    /// という穴が残る。検疫から切り離し、**ずれの大きさに依らず見直す**形にした。
    ///
    /// ## なぜ食い違いの閾値を大きく取るか
    ///
    /// 実測のずれは窓ごとに数十度散らばる(頭の動きと course の雑音)。
    /// 閾値を小さくすると、**取り付けが変わっていないのに窓ごとに乗り換えが起き、
    /// 音の基準が跳ぶ**(利用者が「離散的」と呼んだ現象を作り直すことになる)。
    /// ただしこれは乗り換えを**抑える**幅であって、誤った乗り換えを防ぐ保証ではない
    /// (長く横を向いて歩けば、その姿勢のずれが成立して乗り換わりうる)。
    ///
    /// **いま使っている値は、新しい値が成立するまで使い続ける。** その場で捨てると
    /// 基準が消えて音が飛ぶ(同じ理由)
    private mutating func updateRelearning(headingDeg: Double, rawCourseDeg: Double?,
                                           sample: MountOffset.Sample, p: Params) {
        guard p.relearnWindowEvidenceSec > 0 else { return }
        // **窓は学習の成立を待たずに回す。** 装着前に成立した値を持っている場合、
        // 窓がすでに回っていれば装着後の証拠で最短で追い越せる
        if let course = rawCourseDeg, sample.evidenceSec > 0 {
            window.add(diffDeg: Geo.normalizeDeg(headingDeg - course),
                       evidenceSec: sample.evidenceSec, p: p.relearnWindow)
        }
        guard let frozen = learnedDeg,
              let fresh = window.estimateDeg(p: p.relearnWindow),
              abs(Geo.angularDiffDeg(fresh, frozen)) > p.relearnMinDisagreeDeg else { return }
        // 前の取り付けの証拠を持ち込まずに差し替える(**fix の履歴は保つ** — 捨てると
        // 差し替え直後の証拠が更新頻度に依存する。→ MountOffset.replaceFrozen)
        offset.replaceFrozen(deg: fresh, concentration: window.concentration)
        learnedDeg = fresh
        relearnCount += 1
        // 乗り換えた瞬間、方位が差のぶん飛ぶので、それ以前の証拠は捨てる
        quarantine = HeadingQuarantine()
        quarantine.markLearned()
        // **同じ証拠で 2 回乗り換えない**(→ OffsetWindow の「保証しないこと」)
        window.clear()
    }

    /// 使ってよいか。**呼ぶたびに鮮度を評価する**ので、更新が止まれば自動的に `stale` へ落ちる。
    /// 判定の順序は「標本の有無 → 鮮度 → 学習 → 検疫」。
    /// 古い標本に対して検疫の状態を語っても意味が無いため、鮮度を先に見る
    public func use(at now: TimeInterval, p: Params) -> Use {
        guard let last = lastSampleAt else { return .noSample }
        if now - last > p.staleSec { return .stale }
        guard learnedDeg != nil else { return .offsetNotLearned }
        guard quarantine.isUsable else { return .quarantined(quarantine.state) }
        return .use
    }

    /// 定位の基準に使う方位 [deg]。使ってよくなければ nil(呼び出し側は進行方位で代用する)
    public func facingDeg(at now: TimeInterval, p: Params) -> Double? {
        use(at: now, p: p).isUsable ? correctedHeadingDeg : nil
    }

    /// **検疫の判断を無視して**定位に使う方位 [deg](音楽スポット専用・2026-09-18 利用者判断)。
    ///
    /// ## なぜ要るか
    ///
    /// 連続音では、**基準が切り替わること自体が壊れた体験になる**。
    /// 2026-09-18 の散歩で、01:13:01 に検疫が退避を出して基準が「頭部 → 進行」へ変わり
    /// (相対方位が +71° 跳んだ)、そこから **53 秒間**、音は進行方位を基準に置かれた。
    /// その間は**首を振っても音が動かず**、course が更新される時だけ階段状に動く。
    /// 途中では基準が「なし」になり、音が中央へ飛んだ。
    /// 利用者の言葉では「音楽の向きの変化が離散的になった」。
    ///
    /// ## 何を守り、何を捨てるか
    ///
    /// - **守る**: 鮮度(更新が止まったら使わない)と、取り付けのずれの学習
    ///   (ずれが分からなければ方位そのものが不明)
    /// - **捨てる**: 検疫の判断。磁気の乱れで向きがずれる危険は残るが、
    ///   **基準が飛ぶことの方が体験を壊す**という判断(利用者)
    ///
    /// 検疫は「首を回すほど学習が汚れる」性質を持つ(docs/13)。
    /// **音の方へ首を振って探す**というこの体験では、その前提自体が噛み合わない。
    public func facingDegIgnoringQuarantine(at now: TimeInterval, p: Params) -> Double? {
        switch use(at: now, p: p) {
        case .use, .quarantined:
            return correctedHeadingDeg
        case .noSample, .stale, .offsetNotLearned:
            return nil
        }
    }
}
