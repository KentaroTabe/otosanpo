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

        public init(offset: MountOffset.Params, quarantine: HeadingQuarantine.Params,
                    staleSec: Double) {
            self.offset = offset
            self.quarantine = quarantine
            self.staleSec = staleSec
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

    public init() {}

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
    ///   - t: 標本時刻 [sec]。単調でありさえすれば基準は問わない
    /// - Returns: この標本の時点での判定
    @discardableResult
    public mutating func ingest(headingDeg: Double, rawCourseDeg: Double?,
                                at t: TimeInterval, p: Params) -> Use {
        lastSampleAt = t
        lastRawHeadingDeg = headingDeg
        // 学習は**生の方位**で行う(補正後を食わせると自分の出力を追いかけて循環する)
        offset.ingest(headingDeg: headingDeg, courseDeg: rawCourseDeg, at: t, p: p.offset)
        let learned = offset.offsetDeg(p: p.offset)
        // **学習の有無が切り替わったら検疫の実績を捨てる。**
        // 補正値が付く / 消えると方位が学習値ぶん飛ぶので、それまでの
        // 「course と合っていた」実績は、次の方位に対する保証にならない
        if (learned == nil) != (learnedDeg == nil) {
            quarantine = HeadingQuarantine()
        }
        learnedDeg = learned
        // **検疫は補正後の方位に対してだけ進める。** 学習前の未補正方位で実績を積むと、
        // 学習が立った瞬間に「別の量に対する実績」を引き継いでしまう
        if let learned {
            quarantine.assess(headingDeg: Geo.normalizeDeg(headingDeg - learned),
                              courseDeg: rawCourseDeg, at: t, p: p.quarantine)
        }
        return use(at: t, p: p)
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
}
