import Foundation

/// config/parameters.json に対応する型。
/// 数値パラメータはすべて JSON 側に置く(CLAUDE.md 参照)。
/// JSON は snake_case、Swift 側は camelCase(デコード時に .convertFromSnakeCase を使用)。
public struct AppParameters: Codable, Equatable {
    public var session: Session
    public var budget: Budget
    public var route: Route
    public var heading: Heading
    public var headMount: HeadMountSettings
    public var experiment: Experiment
    public var gesture: Gesture
    public var audio: Audio
    public var location: Location
    public var summary: Summary
    public var mapDownload: MapDownloadSettings
    public var shopHistory: ShopHistorySettings
    public var greeting: Greeting

    public struct Session: Codable, Equatable {
        public var defaultDurationMin: Double
        public var minDurationMin: Double
        public var maxDurationMin: Double
        /// 延長 1 回で足す時間の、元の設定時間に対する比。
        /// 固定分ではなく比例にする(30 分の散歩と 90 分の散歩で延長の意味を揃える。
        /// 2026-08-17 決定、係数は暫定)
        public var extensionRatio: Double
        public var maxExtensions: Int
        public var rePromptIntervalSec: Double
        public var arrivalRadiusM: Double
    }

    public struct Budget: Codable, Equatable {
        /// 歩行速度の**初期値** [m/min]。実測が貯まればそちらを使う(SpeedEstimator)
        public var walkingSpeedMPerMin: Double
        /// 平均速度の集計から「立ち止まっている」サンプルを除く下限 [m/s]。
        /// 実測から歩行速度を求めるための計測用で、判定には使わない
        public var minMovingSpeedMPerS: Double
        /// 経路長に加算する最小の移動量 [m]。これ未満の差分は GPS の揺れとして捨てる。
        /// 水平精度(良い時の実測 3〜5 m)より大きく取る
        public var pathSegmentMinM: Double
        /// 実測に使う fix の水平精度の上限 [m]。これより悪い fix は経路長も速度も使わない
        public var maxAccuracyForMetricsM: Double
        /// 直線距離を歩く距離に直す係数。**経路データがあるときは使わない**。
        /// 実測は 1.09〜1.70 に散らばり、固定値ではどちら側にも外れる(docs/03)
        public var detourFactor: Double
        /// 経路長を信用する上限。直線距離の何倍までを「ありうる遠回り」とみなすか。
        /// これを超えた経路長はスナップの誤りを疑い、この倍数で頭を押さえる
        /// (2026-08-27 の実測: 通常は 95% が 1.68 倍以内、跳ねた時だけ 2.5〜3.06 倍)
        public var routeStraightMaxRatio: Double
        public var returnReserveMin: Double
        public var softZoneRatio: Double
        /// 散歩 1 回ぶんの平均速度をどれだけ取り込むか [0..1]
        public var speedEwmaWeight: Double
        /// 平均速度を採用するのに要る「歩いている」サンプル数
        public var speedMinSamples: Int
        /// 速度の推定として認める範囲 [m/min]。走った回に引きずられて
        /// 帰宅推定が楽観的になる(= 帰りが間に合わない)のを防ぐ
        public var speedMinMPerMin: Double
        public var speedMaxMPerMin: Double

        /// SpeedEstimator に渡す制限値
        public var speedLimits: SpeedEstimator.Limits {
            SpeedEstimator.Limits(ewmaWeight: speedEwmaWeight, minSamples: speedMinSamples,
                                  minMPerMin: speedMinMPerMin, maxMPerMin: speedMaxMPerMin)
        }
    }

    public struct Route: Codable, Equatable {
        public var cellSizeM: Double
        /// 通過の重みが半分になるまでに歩く距離 [m]。**減衰の時計は日数ではなく歩いた総距離**
        public var visitHalfLifeM: Double
        public var sectorWidthDeg: Double
        public var sectorRadiusM: Double
        public var suggestionMinScore: Double
        public var excludedFamiliarity: Double
        /// 直進のスコアをこの差以上上回った時だけ提案する(僅差で曲がらせない)
        public var suggestionMarginOverStraight: Double
        /// 前回提案した地点からこの距離以上進むまで、次の提案を出さない [m]
        public var suggestionMinTravelM: Double
        /// 端末に置く経路データの半径 [m]。徒歩 1 時間圏を覆う目安(docs/04)
        public var mapRadiusM: Double
        /// 手で置かれた経路データとして読む上限 [MB]。**名前を問わず読む**ので、
        /// 巨大な無関係の JSON を掴んで起動やメモリが死ぬのを防ぐ。
        /// 実測の最大は東京都の 40 MB(実機で動作確認済み・2026-08-30)
        public var mapFileMaxMb: Double
        /// 道路スナップの空間索引のセル幅 [m]
        public var mapIndexCellSizeM: Double
        /// この距離より離れた点は道に乗せない [m]。水平精度(実測 3〜5 m)より大きく取る
        public var snapMaxDistanceM: Double
        /// 別の道へ乗り換えるのに要求する差 [m]。**既定 0 = 引き継がない。**
        ///
        /// 「指す向きが 180° 往復する」への対策として入れてみたが、
        /// **再生で測ると入れるほど単調に悪化した**(2026-09-09。docs/05)。
        /// 仕組みは再生で振り直せるように残し、配る値は 0 にしてある
        public var waySwitchMarginM: Double
        /// 線分の別の端点へ乗り換えるのに要求する差 [m]。**既定 0 = 引き継がない。**
        /// こちらは悪化しなかったが、良くもならなかったので 0 のまま
        public var nodeSwitchMarginM: Double
        /// 経路上の節点に「着いた」とみなす距離 [m]。
        /// 真上に立つと、そこへ向かう方位が雑音で暴れるため
        public var nodeArrivalToleranceM: Double

        /// RouteField に渡す追跡の引き継ぎ設定
        public var routeTrace: RouteField.TraceParams {
            RouteField.TraceParams(waySwitchMarginM: waySwitchMarginM,
                                   nodeSwitchMarginM: nodeSwitchMarginM)
        }
        /// 前方この距離以内の交差点を「これから曲がる場所」として扱う [m]
        public var intersectionLookaheadM: Double
        /// 進行方向との差がこれ以内の分岐は「直進」とみなす [deg]
        public var branchStraightDeg: Double
        /// 進行方向との差がこれ以上の分岐は「来た道」として候補から外す [deg]
        public var branchBackwardDeg: Double
        /// 横断コスト 1 段あたりスコアから引く量
        public var crossCostWeight: Double
        /// 道の種別の序列 1 段あたりスコアから引く量(歩行者専用を好む強さ)
        public var wayClassWeight: Double
        /// 分岐が直進より何倍新鮮なら鳴らすか。**絶対差ではなく比**で見る。
        /// 新鮮さは馴染むほど 0 に圧縮されるので、絶対差では歩き込んだ地点ほど黙る
        public var branchNoveltyRatio: Double
        /// 行き先の地帯の一辺 [m]
        public var zoneSizeM: Double
        /// 行き先として認める道の総延長の下限 [m]。**道の無い地帯へ向かわせない**
        public var zoneMinRoadM: Double
        /// 地帯の馴染み度を測る標本の 1 辺あたりの数(3 なら 3×3 = 9 点)
        public var zoneSampleGrid: Int
        /// 行き先として認める現在地からの最短距離 [m]。すぐ隣は行き先にならない
        public var targetMinDistanceM: Double
        /// 上の距離を、行ける範囲に対する比でも抑える。
        /// 固定値だけだと短い散歩で行き先を 1 つも選べなくなる(2026-08-19 実測)
        public var targetMinDistanceRatio: Double
        /// 行き先にこの距離まで近づいたら、次の行き先を選び直す [m]
        public var targetReachedM: Double
        /// 分岐スコアで行き先の向きをどれだけ重んじるか。
        /// 帰宅バイアスが立つにつれ線形に畳まれる(帰宅が常に優先)
        public var targetBiasWeight: Double

        /// ZoneMap に渡す設定値
        public var zoneParams: ZoneMap.Params {
            ZoneMap.Params(zoneSizeM: zoneSizeM, minRoadM: zoneMinRoadM,
                           sampleGrid: zoneSampleGrid, minDistanceM: targetMinDistanceM,
                           minDistanceRatio: targetMinDistanceRatio,
                           excludedFamiliarity: excludedFamiliarity)
        }
    }

    public struct Location: Codable, Equatable {
        /// この速度未満では CLLocation.course を信用しない [m/s]
        public var minSpeedForCourseMPerS: Double
        /// course の許容誤差 [deg]。これを超える精度の値は使わない
        public var maxCourseAccuracyDeg: Double
        /// 位置更新からこの秒数を超えた course は使わない [sec]
        public var maxFixAgeSec: Double
        /// course が使えなくなってから、直前の有効な course を使い続ける上限 [sec]。
        /// 0 でホールドなし
        public var courseHoldSec: Double
        /// course が使えないとき端末コンパスへ退避するか
        public var allowCompassFallback: Bool
        /// **位置を「案内向けの最高精度」で取るか**(`kCLLocationAccuracyBestForNavigation`)。
        ///
        /// 追加のセンサ(加速度・ジャイロ)を使う最高精度の要求で、**電力を多く使う**。
        /// Apple は給電しながらの利用を勧めている。2026-09-18 の利用者判断で有効にした
        /// (「電力消費は問題になっておらず、やる価値はある」)。
        ///
        /// **効果は未確認。** `horizontalAccuracy` は OS の見積もりであって実測誤差ではないので、
        /// 数字が下がったことだけでは精度が上がった根拠にならない(2026-09-18 合議)。
        /// 散歩の前後で比べる材料として、ログに「どちらで取ったか」を残す
        public var useBestForNavigation: Bool
    }

    /// 散歩の記録(WalkSummary)。**開発中の振り返り用**の画面に効く
    public struct Summary: Codable, Equatable {
        /// 経路として残す点の上限。超えたら 1 つおきに間引き、以後の間隔を 2 倍にする。
        /// 長い散歩でも記録が伸び続けないようにするための上限
        public var maxTrackPoints: Int
        /// 経路図の余白 [m]。端のイベントが枠に貼り付かないように
        public var mapMarginM: Double
        /// 経路図の最小の広さ [m]。ごく短い散歩でも図が破綻しないように
        public var mapMinSpanM: Double
    }

    /// 経路データ(タイル)の配信先。**アプリで唯一、外へ出る通信**(→ docs/12)
    public struct MapDownloadSettings: Codable, Equatable {
        /// 配信先の基点。**空なら取得の機能を出さない**(通信しない状態に戻せる)。
        /// 末尾のスラッシュは有っても無くてもよい。
        ///
        /// **`baseURL` ではなく `baseUrl`。** デコーダは `.convertFromSnakeCase` を使い、
        /// JSON の `base_url` は照合の**前に** `baseUrl` へ変換される。
        /// `URL` と大文字で綴ると一致せず、**実機の起動時に読み込みが失敗する**
        /// (2026-08-29 に実際に起きた)。この構造体に `CodingKeys` を書いてはいけない
        public var baseUrl: String
        public var timeoutSec: Double
        /// **生成側**が使うタイル角 [度](scripts/build_tiles.sh が読む)。
        /// アプリは配信先の meta.json の値を使う — 配信データの分割はデータと一緒に
        /// 宣言されるべきで、端末側の設定と食い違っても配信側が正になるため
        public var tileSizeDeg: Double

        /// 取得を出してよいか。空の設定を「機能なし」として扱う
        public var isConfigured: Bool { !baseUrl.isEmpty }
    }

    /// 散歩中に通った店舗の記録。店舗候補の取得自体は Services 側で差し替える。
    public struct ShopHistorySettings: Codable, Equatable {
        /// 店舗の前を通ったとみなす距離 [m]。初期値は 30 m。
        public var passageRadiusM: Double
        /// 店舗候補を取得する範囲 [m]。API の検索半径で、通過判定の 30 m とは分ける。
        public var searchRadiusM: Double
        /// 通過判定に使う fix の水平精度の上限 [m]。これより悪い位置では記録しない。
        public var maxHorizontalAccuracyM: Double
    }

    /// 散歩を始めるときの一言。**文言も時間帯もここに置く**(コードに埋めない)
    public struct Greeting: Codable, Equatable {
        public var windows: [GreetingWindow]
        /// 音楽スポットを選んだ時だけ、**時間帯の一言のうしろに足す**一文。
        ///
        /// 三種それぞれに同じ文を書き写すのではなく、1 つ持って継ぎ足す。
        /// 音楽を選んでいない散歩では出さないため(2026-09-10 利用者依頼)
        public var musicNote: String
    }

    public struct GreetingWindow: Codable, Equatable {
        /// 開始の時(この時を含む)
        public var fromHour: Int
        /// 終了の時(この時を**含まない**)。`from` より小さければ真夜中をまたぐ
        public var toHour: Int
        public var message: String
    }

    /// 顔の向きの推定(HeadingFusion)。docs/03「頭の向きを定位に反映」
    public struct Heading: Codable, Equatable {
        /// 顔の向きを定位の基準に使うか。false なら従来どおり進行方位だけを使う
        public var useHeadOrientation: Bool
        /// 基準線の追従係数(1 サンプルあたり)。50 Hz で 0.0005 なら時定数は約 40 秒
        public var baselineAlpha: Double
        /// 首の相対角として認める上限 [deg]
        public var maxOffsetDeg: Double
        /// 基準線が使えると判断するまでの最小サンプル数(50 Hz で 250 = 5 秒)
        public var minSamples: Int
        /// yaw と course の対をログに残す間隔 [sec]。回転の向きが揃っているかの判定材料
        public var logIntervalSec: Double
        /// **角速度から推定した頭の向きを定位に使うか。** false なら記録だけして動作に影響しない。
        /// 姿勢(yaw)を使う `useHeadOrientation` とは別系統(そちらは 2026-08-19 に不成立)
        public var useGyroHeadOffset: Bool
        /// 角速度の推定が 0 へ戻る半減期 [sec]。絶対基準を持たないのでドリフトは時間で消す
        public var headOffsetHalfLifeSec: Double
        /// 角速度の推定として認める首の相対角の上限 [deg]
        public var headOffsetMaxDeg: Double
        /// これ未満の角速度は 0 とみなす [deg/sec]。ジャイロの雑音と偏りを捨てる
        public var headRateDeadbandDegPerSec: Double
        /// 角速度の向きを「右が正」に合わせる符号(+1 / −1)。**机上テストで確かめる**
        public var headRateSign: Double
        /// サンプルの間隔がこれを超えたら積分しない [sec](再装着・中断のあと)
        public var headRateMaxGapSec: Double

        /// HeadTracker に渡す設定値
        public var headTracker: HeadTracker.Params {
            HeadTracker.Params(halfLifeSec: headOffsetHalfLifeSec,
                               maxOffsetDeg: headOffsetMaxDeg,
                               deadbandDegPerSec: headRateDeadbandDegPerSec,
                               sign: headRateSign, maxGapSec: headRateMaxGapSec)
        }

        /// yaw の回転の向きを方位に合わせる符号(+1 / −1)。
        /// **符号を直しても顔の向きは推定できない**(2026-08-19 実測)。
        /// yaw は旋回そのものを追えておらず、|Δraw| が |Δcourse| とほぼ同じだった。
        /// `use_head_orientation` は false のままにする(docs/03)
        public var yawSign: Double
    }

    /// スマホ頭部固定(docs/13)。**実験装置**なので既定は off。
    /// スマホの真北基準の方位を定位の基準に使い、磁気の乱れは検疫する(HeadingQuarantine)。
    ///
    /// **`CodingKeys` を書かないこと**(→ MapDownloadSettings の注記。
    /// デコーダの `.convertFromSnakeCase` が照合の前に変換する)
    public struct HeadMountSettings: Codable, Equatable {
        /// 装置を着けた実験でだけ true にする
        public var enabled: Bool
        /// スマホのモーション更新頻度 [Hz]。定位は再生時に参照するだけなので高頻度は要らない
        public var updateHz: Double
        /// 取り付けのずれの学習が成立するのに要る**証拠時間** [sec]。
        ///
        /// **標本数ではなく、異なる location fix の間の経過時間で数える**(2026-09-10)。
        /// 標本数だと 50 Hz で同じ fix を 50 回数えてしまい、`update_hz` を上げた途端に
        /// 学習が早まる。推定の質を決めるのは「どれだけの区間を歩いたか」であって
        /// 「何件読んだか」ではない
        public var offsetMinSec: Double
        /// ずれの平均の半減期 [sec]。長め = 付け直し程度の変化にゆっくり追従
        public var offsetHalfLifeSec: Double
        /// ずれが「定数である」と認める合成ベクトル長 R の下限(0..1)
        public var offsetMinConcentration: Double
        /// 学習した値から外れた標本を「門の外」と分類する角度 [deg]。0 で門なし。
        /// **学習が成立した後にだけ効く**(学習中に掛けると、まだ意味のない円平均を中心に
        /// 片側だけ通し、自作自演で R を上げて出鱈目な値を学習する → MountOffset)
        public var offsetGateDeg: Double
        /// course の途切れとして許す上限 [sec]。これより長く途切れた後の fix は証拠にしない。
        /// 立ち止まりや受信の途切れを「その間ずっと合っていた」と数えないため
        public var evidenceMaxGapSec: Double
        /// 検疫の証拠窓の長さ [sec](有効証拠時間で数える。壁時計ではない)
        public var quarantineWindowSec: Double
        /// 退避に要る門外の割合(0..1)
        public var quarantineDistrustRatio: Double
        /// 退避の判定に要る有効証拠時間 [sec]
        public var quarantineDistrustSec: Double
        /// 復帰に要る門内の割合(0..1)
        public var quarantineRegainRatio: Double
        /// 復帰の判定に要る有効証拠時間 [sec]
        public var quarantineRegainSec: Double
        /// 生データ(頭方位 行)をログに残す間隔 [sec]。replay で閾値を振り直す材料
        public var logIntervalSec: Double
        /// 頭方位の最終受信からこれを超えたら「古い」として定位に使わない [sec]。
        /// **画面を消して頭に載せる構成の要**: CoreMotion の配信が止まっても、
        /// 最後の頭の向きに音が凍りついたまま残らないようにする(2026-09-08)
        public var staleSec: Double
        /// **音楽スポットの定位では、検疫の判断を無視するか**(2026-09-18 利用者判断)。
        ///
        /// 連続音では、基準が切り替わること自体が壊れた体験になる。
        /// 実測(2026-09-18)では検疫の退避で 53 秒間、音が進行方位を基準に置かれ、
        /// 「首を振っても音が動かない・階段状に飛ぶ」状態になった。
        /// 鮮度と取り付けのずれの学習は守り、検疫の判断だけ捨てる
        /// (→ HeadMountFusion.facingDegIgnoringQuarantine)
        public var musicIgnoresQuarantine: Bool
        /// **いま使っている値を見直す滑り窓に保つ証拠時間** [sec]。0 で見直さない(従来の一度きり)。
        ///
        /// 学習は一度きりで凍結する設計だったが、2026-09-18 の散歩で
        /// **学習した 344.0° が、その後の実測と 106° 食い違ったまま 10 分続いた**。
        /// **スマホは頭の後ろに固定するので、装着は必ず「開始」の後になる**ため、
        /// 手に持っている間のずれ(実測 347°)を学習してしまった。
        /// 凍結値は分類にしか使われず更新されないので、正しい値へ戻る道が無かった。
        ///
        /// 直近の証拠だけを見る滑り窓を並行して回し、窓が成立したら突き合わせる
        /// (減衰つきの平均では、装着前の証拠を数分ぶん引きずってしまう)。
        /// → HeadMountFusion.updateRelearning / OffsetWindow
        public var relearnWindowEvidenceSec: Double
        /// 見直しの窓の値が、いま使っている値から**これを超えて食い違ったら乗り換える** [deg]。
        ///
        /// 実測のずれは窓ごとに数十度散らばるので、小さくすると
        /// **取り付けが変わっていないのに乗り換えが起き、音の基準が跳ぶ**。
        /// **門(`offset_gate_deg`)とは役割が違う**(門は個々の標本の分類・
        /// これは成立した 2 つの値の比較)ので、値が同じでも別項目にする
        public var relearnMinDisagreeDeg: Double

        /// HeadingQuarantine に渡す設定値
        public var quarantine: HeadingQuarantine.Params {
            HeadingQuarantine.Params(windowSec: quarantineWindowSec,
                                     distrustRatio: quarantineDistrustRatio,
                                     distrustSec: quarantineDistrustSec,
                                     regainRatio: quarantineRegainRatio,
                                     regainSec: quarantineRegainSec)
        }

        /// MountOffset に渡す設定値
        public var offsetEstimator: MountOffset.Params {
            MountOffset.Params(minEvidenceSec: offsetMinSec,
                               halfLifeSec: offsetHalfLifeSec,
                               minConcentration: offsetMinConcentration,
                               gateDeg: offsetGateDeg,
                               maxGapSec: evidenceMaxGapSec)
        }

        /// HeadMountFusion に渡す設定値(学習・検疫・鮮度をまとめたもの)
        public var fusion: HeadMountFusion.Params {
            HeadMountFusion.Params(offset: offsetEstimator,
                                   quarantine: quarantine,
                                   staleSec: staleSec,
                                   relearnWindowEvidenceSec: relearnWindowEvidenceSec,
                                   relearnMinDisagreeDeg: relearnMinDisagreeDeg)
        }
    }

    /// 実験装置(頭部固定)を着けた時だけ働く設定。
    ///
    /// **スイッチは `head_mount.enabled` ただ 1 つ。** ここに `enabled` を置かない。
    /// 第 2 のスイッチを作ると「実験のとき片方だけ入れ忘れる」経路が生まれ、
    /// 取り付けのずれ(`offset_deg`)の決め忘れで散歩 1 回を失った失敗を繰り返す
    /// (2026-09-08 合議)。配布設定は `head_mount.enabled == false` なので配布版には出ない。
    public struct Experiment: Codable, Equatable {
        /// 有効性パルスの間隔 [sec]。**仮置き**(利用者判断待ち)
        public var validityPulseSec: Double
        /// 有効性パルスの音量 [0..1]。環境音を覆わない程度に抑える
        public var validityPulseGain: Double
        /// 有効性パルスの音色。**既存 5 種を流用しない**(誤った行動を誘わないため)
        public var validityPulseTone: ToneSpec
        /// 方向を担う音(suggestion / home_beacon)に載せる倍音の数。
        /// 1 = 純音(配布版と同じ)。左右の定位は 1.5 kHz 超の成分が要る(→ docs/03)
        public var directionalHarmonics: Int
        /// 倍音の減衰(1 つ上の倍音に掛かる比)
        public var directionalHarmonicDecay: Double
        /// 立ち上がりが音全体に占める割合 [0..1]。小さいほど鋭い(ITD の手がかり)
        public var directionalAttackRatio: Double
        /// 左右の聴き比べで 1 音ごとに空ける時間 [sec]
        public var abToneIntervalSec: Double
        /// 聴き比べの前半(配布版)と後半(実験値)の間に足す時間 [sec]
        public var abGapSec: Double
        /// 音楽スポットを置く距離の**下限・上限**を、散歩 1 分あたりで表したもの [m/min]。
        /// **散歩時間に比例させる**(2026-09-09 利用者判断)。
        /// 30 分なら 75〜105 m。短い散歩で遠くに置くと辿り着けず、
        /// 長い散歩で近くに置くとすぐ通り過ぎて後は遠ざかるだけになる
        public var musicSpotMinDistancePerMin: Double
        public var musicSpotMaxDistancePerMin: Double
        /// 候補を探す距離の段数(下限から上限までを何段に分けるか)
        public var musicSpotDistanceSteps: Int
        /// これより近づいたら着いたとして止める [m]
        public var musicSpotReachedM: Double
        /// 候補を探す方位の刻み [deg]
        public var musicSpotBearingStepDeg: Double
        /// 距離の差がこれ未満なら「同じ距離」とみなす [m](→ MusicSpot)
        public var musicSpotSameDistanceToleranceM: Double
        /// 音楽の行をログに残す間隔 [sec]。**音は頭方位の受信ごと(10 Hz)に付け直す**が、
        /// ログをその頻度で書くとファイルが音楽で埋まる
        public var musicLogIntervalSec: Double
        /// 鳴り始めを何秒かけて立ち上げるか [sec]。**じんわり入る**(2026-09-10 利用者依頼)。
        /// 待った末に不意に鳴り出すと驚くので、距離から決めた音量まで滑らかに上げる
        public var musicFadeInSec: Double
        /// 頭の向きが定まるのを待つ上限 [sec]。**これを過ぎたら待たずに鳴らす。**
        ///
        /// 待ちは「進行方位で置かれた音を聴かせない」ためだが、待ち続けると
        /// **散歩が終わるまで無音になりうる**(2026-09-09 の実測: 待ち 6 分 8 秒。
        /// 鳴り出した時にはスポットから 258 m 離れて音量は下限、90 秒後に散歩終了)
        public var musicWaitMaxSec: Double
        /// 音楽スポットの音量の範囲 [0..1] と、それが最小・最大になる距離 [m]
        public var musicSpotMinGain: Double
        public var musicSpotMaxGain: Double

        // 遠い側は musicSpotFarDistancePerMin(散歩時間に比例)へ移した

        /// 左右の聴き比べで音を置く角度 [deg]。左右へ交互に振る
        public var abBearingDeg: Double

        /// 音量が最大になる距離 [m]。これより近づいても大きくならない
        public var musicSpotReferenceDistanceM: Double
        /// 音量の幅を割り振る距離の最小の長さ [m]。**鳴り始めた地点がスポットのすぐ近くでも、
        /// 1 歩で音量が跳ばないようにする**(→ MusicSpot.Params.gainMinSpanM・2026-09-11)
        public var musicSpotGainMinSpanM: Double
        /// **直線の向きと道をたどる向きを混ぜる比** [0..1]。0 = 直線だけ / 1 = 道だけ
        public var musicSpotRouteBlend: Double
        /// ピンポイントの効果が始まる距離 [m](→ MusicSpot.Params.pinpointStartM・2026-09-15)
        public var musicSpotPinpointStartM: Double
        /// ピンポイントの効果が最大になる距離 [m]。利用者の言う「スポットの 5 m 以内」
        public var musicSpotPinpointFullM: Double
        /// 正面から外れた時に、音量の下げ幅が最大に達する角度 [deg]
        public var musicSpotPinpointBeamDeg: Double
        /// 効果が最大の時、正面から外れたら下げる音量 [dB]。**首を振って探せる**ようにする
        public var musicSpotPinpointDepthDb: Double
        /// **向きによる音量の割り振り** [dB]。正面 0・真後ろ −この値(→ MusicSpot.directivityDb)。
        /// 左右の合計をほぼ一定に保つ HRTF だけでは前後が分からない、という実測への手当て(2026-09-18)
        public var musicSpotDirectivityDepthDb: Double
        /// 後ろの音を暗くし始める角度 [deg](正面から測る・2026-09-18)
        public var musicSpotRearShelfStartDeg: Double
        /// 真後ろで高域を落とす量 [dB](正の値)。**前後を音色で補助する**(→ MusicSpot.rearShelfDb)
        public var musicSpotRearShelfDepthDb: Double
        /// 高域を落とし始める周波数 [Hz]。耳介の手がかりが載る帯域より上に置く
        public var musicSpotRearShelfHz: Double
        /// **スポットの向きの遊び(不感帯)の下限** [deg]。0 で素通し。
        ///
        /// スポットの中心は動かないのに「小刻みに移動して聞こえる」のは、
        /// 自分の位置の推定が揺れるため(実測 0〜5 m で 19°/s・20 m 以上で 1°/s 以下)。
        /// → BearingHold。**段差を作らない遊び**なので、本当に動いた時は連続して付いていく
        public var musicSpotBearingDeadbandMinDeg: Double
        /// スポットの向きの遊びの上限 [deg]。近距離で不確かさが大きくなっても凍結させない蓋。
        /// **大きくしすぎると、通り過ぎても向きが前のままになる**(2026-09-18 の合議で 10° へ)
        public var musicSpotBearingDeadbandMaxDeg: Double
        /// 遊びを抜けた目標へ追従する時定数 [sec]。
        /// 遊びだけでは**入力が飛んだ時に出力も飛ぶ**(実測 82°)ので、ここで吸収する。
        /// 2〜3 秒では通り過ぎる場面に間に合わない
        public var musicSpotBearingFollowSec: Double

        /// **耳の高さ** [m](スポットは地表にある)。0 で仰角を付けない。
        ///
        /// 近づくほど音が下から来る(5 m で −17°・2 m で −37°)。
        /// **この角度は水平距離だけで決まる**ので、方位と違って位置の誤差に強い
        /// (2026-09-18 利用者依頼)
        public var musicSpotListenerHeightM: Double
        /// 音の広がりが最大になる距離 [m]。これより遠いと一番広い
        public var musicSpotSpreadFarM: Double
        /// 音の広がりが消える距離 [m]。これより近いと一点に締まる
        public var musicSpotSpreadNearM: Double
        /// 広がりの最大値 [0..1]。直接音に対する残響の割合の上限。
        /// **混ぜすぎると屋外の散歩で不自然になる**
        public var musicSpotSpreadMax: Double
        /// **スポットを移す提案の間隔** [sec]。断るたびに 2 倍になる(→ SpotMoveSchedule)
        public var musicSpotMoveIntervalSec: Double
        /// 提案が鳴り終わってから、応答を受け付け始めるまでの待ち [sec]。
        /// 鳴っている最中のうなずきを拾わないため
        public var musicSpotMoveResponseDelaySec: Double
        /// 応答を受け付ける長さ [sec]。**散策中に常時ジェスチャを開けない**ための窓
        public var musicSpotMoveResponseWindowSec: Double
        /// 移す時、**これまでに置いた所から空ける距離** [m]。
        /// 「特定の箇所に固まらないように」(2026-09-18 利用者依頼)
        public var musicSpotMoveMinSeparationM: Double
        /// 移す時に音を絞る / 戻す長さ [sec]。**向きと音量が飛ぶのを隠す**
        public var musicSpotMoveFadeSec: Double

        /// SpotMoveSchedule に渡す設定値
        public var musicSpotMove: SpotMoveSchedule.Params {
            SpotMoveSchedule.Params(baseIntervalSec: musicSpotMoveIntervalSec,
                                    responseDelaySec: musicSpotMoveResponseDelaySec,
                                    responseWindowSec: musicSpotMoveResponseWindowSec)
        }

        /// BearingHold に渡す設定値
        public var musicSpotBearingHold: BearingHold.Params {
            BearingHold.Params(minDeadbandDeg: musicSpotBearingDeadbandMinDeg,
                               maxDeadbandDeg: musicSpotBearingDeadbandMaxDeg,
                               timeConstantSec: musicSpotBearingFollowSec)
        }

        /// MusicSpot に渡す設定値。**散歩時間で距離が決まる**ので時間を渡す
        public func musicSpot(durationMin: Double) -> MusicSpot.Params {
            MusicSpot.Params(
                minDistanceM: musicSpotMinDistancePerMin * durationMin,
                maxDistanceM: musicSpotMaxDistancePerMin * durationMin,
                distanceStepCount: musicSpotDistanceSteps,
                reachedM: musicSpotReachedM,
                bearingStepDeg: musicSpotBearingStepDeg,
                sameDistanceToleranceM: musicSpotSameDistanceToleranceM,
                referenceDistanceM: musicSpotReferenceDistanceM,
                gainMinSpanM: musicSpotGainMinSpanM,
                maxGain: musicSpotMaxGain, minGain: musicSpotMinGain,
                routeBlend: musicSpotRouteBlend,
                pinpointStartM: musicSpotPinpointStartM,
                pinpointFullM: musicSpotPinpointFullM,
                pinpointBeamDeg: musicSpotPinpointBeamDeg,
                pinpointDepthDb: musicSpotPinpointDepthDb,
                directivityDepthDb: musicSpotDirectivityDepthDb,
                rearShelfStartDeg: musicSpotRearShelfStartDeg,
                rearShelfDepthDb: musicSpotRearShelfDepthDb,
                listenerHeightM: musicSpotListenerHeightM,
                spreadFarM: musicSpotSpreadFarM,
                spreadNearM: musicSpotSpreadNearM)
        }

        /// 実験ビルドで実際に鳴らす音色を決める。
        ///
        /// **どの音に上書きするかの判断をここに置く**(2026-09-09)。
        /// EarconSynth の中に書いていた頃は、その判断を単体テストで押さえられなかった。
        /// 方向を担う 2 種だけを差し替え、方向を持たない 3 種は配布値のまま
        public func tones(from shipped: Audio.Tones, active: Bool) -> Audio.Tones {
            guard active else { return shipped }
            var out = shipped
            out.suggestion = applied(to: shipped.suggestion)
            out.homeBeacon = applied(to: shipped.homeBeacon)
            return out
        }

        /// 方向を担う音に実験用の値を載せる。
        /// **方向を持たない音(時間到来・確認音・到着)は触らない** — 無関係な
        /// 音色変更を実験に混ぜないため(2026-09-08 合議)
        public func applied(to tone: ToneSpec) -> ToneSpec {
            ToneSpec(freqsHz: tone.freqsHz, blipSec: tone.blipSec, gapSec: tone.gapSec,
                     noiseMix: tone.noiseMix, harmonics: directionalHarmonics,
                     harmonicDecay: directionalHarmonicDecay,
                     attackRatio: directionalAttackRatio)
        }
    }

    public struct Gesture: Codable, Equatable {
        public var nodPitchThresholdDeg: Double
        public var shakeYawThresholdDeg: Double
        public var minReversals: Int
        public var windowSec: Double
        public var refractorySec: Double
        /// モーション受信状況(サンプリング頻度・実測振幅)を集計して表示・記録する間隔 [sec]
        public var diagnosticsIntervalSec: Double
        /// 応答待ち以外の状態で振幅を記録する下限(検出に必要な振幅に対する比)。
        /// 歩行中に「あと少しで誤検出」だった動きだけを拾い、ログを埋め尽くさないための係数
        public var diagnosticsReportRatio: Double
    }

    public struct Audio: Codable, Equatable {
        public var sampleRate: Double
        public var suggestionMinIntervalSec: Double
        public var returnAckRepeatIntervalSec: Double
        public var returnAckDurationSec: Double
        /// 何歩に 1 回ビーコンを鳴らすか。**間隔は歩調に同期させる**
        /// (2026-08-16 の要望「歩くペースに合わせた頻度でなる」)
        public var beaconStepsPerTone: Double
        /// 間隔の下限・上限 [sec]。歩調が極端なときに暴れないよう挟む
        public var beaconIntervalMinSec: Double
        public var beaconIntervalMaxSec: Double
        /// 歩調が取れないときの間隔 [sec]
        public var beaconIntervalFallbackSec: Double
        /// 歩調をこの秒数まで有効とみなす。立ち止まると更新が来なくなるため
        public var beaconCadenceMaxAgeSec: Double
        /// ビーコンの音量 [0..1]。**距離は音量で表す**(間隔は歩調に取られるため)
        public var beaconGainFar: Double
        public var beaconGainNear: Double
        /// 音量が最大・最小になる自宅までの距離 [m]
        public var beaconNearDistanceM: Double
        public var beaconFarDistanceM: Double

        /// BeaconRhythm に渡す設定値
        public var beaconRhythm: BeaconRhythm.Params {
            BeaconRhythm.Params(
                stepsPerTone: beaconStepsPerTone, minIntervalSec: beaconIntervalMinSec,
                maxIntervalSec: beaconIntervalMaxSec,
                fallbackIntervalSec: beaconIntervalFallbackSec,
                gainFar: beaconGainFar, gainNear: beaconGainNear,
                nearDistanceM: beaconNearDistanceM, farDistanceM: beaconFarDistanceM)
        }
        /// 相対方位がこれ以上変わったら、次のビーコンを待たずに繰り上げて鳴らす [deg]。
        /// 角を曲がってから最大 5 秒待たせないため
        public var beaconDirectionChangeDeg: Double
        /// 繰り上げの下限間隔 [sec]。連打を防ぐ
        public var beaconMinGapSec: Double
        /// 3D 音響(HRTF)で定位するか。false ならステレオパンで代替する
        public var useSpatialAudio: Bool
        /// **定位を前半球に畳むか**(→ SoundPlacement.foldToFrontDeg・docs/03)。
        /// 前後は伝わらないチャネルだと実測で確定しており(純音 + 汎用 HRTF)、
        /// 全球に置くと**前に置いた音まで背後から聞こえる**(2026-08-30 テスター報告。
        /// 帰路 204 発中 201 発が前半球なのに「背後から鳴る」)。
        /// true でこの誤知覚を断つ。左右の情報は失わない(pan は畳む前後で同値)
        public var frontHemisphereOnly: Bool
        /// 相対方位の大きさがこれを超えたら「真後ろ寄り」の音色に切り替える [deg]。
        /// **`front_hemisphere_only` が true の間は到達しない**(畳んだ後は必ず 90° 以内)。
        /// 前半球化を取り下げて A/B するときのために残してある
        public var behindThresholdDeg: Double
        /// 真後ろ用の音色をどれだけ暗くするか [0..1]。周波数を下げ雑音成分を削る
        public var behindDarkness: Double
        /// 曲がり角の誘導音の間隔 [sec]。**固定**。
        /// 間隔の変化では距離が伝わらなかった(2026-08-18 実測)ため、距離は音量で表す。
        /// 間隔は「連続音である」ことだけを担う
        public var guidanceIntervalSec: Double
        /// 最も遠いときと頂点の音量 [0..1]
        public var guidanceGainFar: Double
        public var guidanceGainNear: Double
        /// 角のこの距離手前で音量が最大になり、向きも曲がる先を指し切る [m]。
        /// 角そのものを頂点にすると、確定するのが曲がっている最中になる
        public var guidancePeakBeforeM: Double
        /// 曲がり終えた後、音量を落としながら鳴らす音の数。
        /// 「イベントが終わりかけている」ことを音で伝える
        public var guidanceClosingTones: Int
        /// 冒頭に「曲がる先」を指す音の数。0 で無効。
        /// 角を指す設計上、遠い時点では角は真正面にある。**1 音目は前の音が無いので、
        /// それ単独で「どちらへ曲がるか」を伝える必要がある**(2026-08-20 の指摘)
        public var guidanceAnnounceTones: Int
        /// 角への方位が進行方向からこれ以上離れたら、従わなかったとみなして誘導を止める [deg]。
        /// **90° を超えるとは、幾何的にその角から遠ざかっているということ。**
        /// 背後の角を指し続けるのは「戻れ」と言っているのと同じで、それは叱っている
        public var guidanceAbandonBehindDeg: Double
        /// 角からこの距離以上離れたら誘導を終える [m](通過後は間隔が開いて自然に消える)
        public var guidanceEndDistanceM: Double
        /// 最接近点からこれ以上遠ざかったら誘導を終える [m]。
        /// 通り過ぎた角を指し続けると混乱するだけなので、離れ始めたら諦める
        public var guidanceLeftBehindM: Double
        /// 各 earcon の先頭に足す無音 [sec]。
        /// 定位が目標の向きへ移り終わるのを待つため(docs/03「向きが滲む」)。
        /// 0 で無効
        public var earconLeadSilenceSec: Double
        public var earconGain: Double
        /// **真横に聞こえる角度を合わせる時、つまみが振れる幅** [deg](片側)。
        ///
        /// 180 まで振れると、正面付近を合わせるのにつまみの travel を使い切ってしまう。
        /// 真後ろは校正に使わない(印を付けられない)ので、そこまで動かす必要が無い。
        /// **狭くするほど、同じ指の動きで細かく合わせられる**(2026-09-18 利用者依頼)
        public var earCalibrationSpanDeg: Double
        /// つまみの刻み [deg]。細かすぎると狙った所で止めにくい
        public var earCalibrationStepDeg: Double
        public var tones: Tones

        public struct Tones: Codable, Equatable {
            public var suggestion: ToneSpec
            public var timeUpPrompt: ToneSpec
            public var returnAck: ToneSpec
            public var homeBeacon: ToneSpec
            public var arrival: ToneSpec
            /// スポットを移す提案(2026-09-18)。**時間到来とは別の音**
            public var spotMove: ToneSpec
        }
    }

    public struct ToneSpec: Codable, Equatable {
        public var freqsHz: [Double]
        public var blipSec: Double
        public var gapSec: Double
        /// 白色雑音を混ぜる割合 [0..1]。
        /// 純音には 4〜10 kHz の成分が無く、HRTF の前後判別が依存する耳介の
        /// スペクトル手がかりを運べない。広帯域成分を足すと前後が聴き分けやすくなる
        /// (2026-08-18 の実測で、純音のビーコンは前後がほぼ判別不能だった)。
        /// **ただし「さっ」という雑音が不快と評価され 0 にした**(2026-08-18)。
        /// 代わりに倍音とアタックで手がかりを作る(下記・2026-09-01)
        public var noiseMix: Double

        /// 倍音の数(1 = 基音のみ = 純音)。**左右の定位に直接効く。**
        ///
        /// 440 Hz の純音は波長 78 cm で、頭(約 18 cm)を回折してしまうため
        /// **両耳間レベル差(ILD)がほとんど出ない**。ILD が効くのは概ね 1.5 kHz 以上。
        /// 倍音を足すと高域成分が生まれ、同じ音程のまま ILD の手がかりを持てる
        /// (440 Hz に 4 倍音まで足せば 1760 Hz まで伸びる)。
        /// 雑音と違い「豊かな音色」として聞こえるので、`noiseMix` の不快さを避けられる
        public var harmonics: Int

        /// 倍音 1 段あたりの振幅比 [0..1]。小さいほど基音に近い素朴な音になる
        public var harmonicDecay: Double

        /// 立ち上がりが 1 音に占める割合 [0..1]。**0.5 で左右対称(従来の Hann 窓)**。
        ///
        /// 小さくするほど立ち上がりが鋭くなる。**鋭い立ち上がりは
        /// 両耳間時間差(ITD)の手がかりになる** — 持続する純音の位相差は
        /// 周期的で曖昧だが、「どちらの耳に先に届いたか」は一意に決まるため。
        /// 打楽器的になるので音色としても不自然ではない
        public var attackRatio: Double

        /// **この音が鳴り終わるまでの長さ** [sec]。
        /// 応答の窓を「鳴り終わってから」開くために要る(→ SpotMoveSchedule・2026-09-18)。
        /// 音は「blip を freqs の数だけ、間に gap を挟んで」並べる(→ ToneRenderer)
        public var durationSec: Double {
            let n = Swift.max(0, freqsHz.count)
            guard n > 0 else { return 0 }
            return Double(n) * Swift.max(0, blipSec)
                + Double(n - 1) * Swift.max(0, gapSec)
        }
    }
}
