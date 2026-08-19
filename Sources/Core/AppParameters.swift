import Foundation

/// config/parameters.json に対応する型。
/// 数値パラメータはすべて JSON 側に置く(CLAUDE.md 参照)。
/// JSON は snake_case、Swift 側は camelCase(デコード時に .convertFromSnakeCase を使用)。
public struct AppParameters: Codable, Equatable {
    public var session: Session
    public var budget: Budget
    public var route: Route
    public var heading: Heading
    public var gesture: Gesture
    public var audio: Audio
    public var location: Location

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
        public var visitHalfLifeDays: Double
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
        /// 道路スナップの空間索引のセル幅 [m]
        public var mapIndexCellSizeM: Double
        /// この距離より離れた点は道に乗せない [m]。水平精度(実測 3〜5 m)より大きく取る
        public var snapMaxDistanceM: Double
        /// 経路上の節点に「着いた」とみなす距離 [m]。
        /// 真上に立つと、そこへ向かう方位が雑音で暴れるため
        public var nodeArrivalToleranceM: Double
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
        /// yaw の回転の向きを方位に合わせる符号(+1 / −1)。
        /// **符号を直しても顔の向きは推定できない**(2026-08-19 実測)。
        /// yaw は旋回そのものを追えておらず、|Δraw| が |Δcourse| とほぼ同じだった。
        /// `use_head_orientation` は false のままにする(docs/03)
        public var yawSign: Double
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
        /// 3D 音響(HRTF)で定位するか。false ならステレオパンで代替する。
        /// 3D は前後を区別できるが、モノラル入力と AVAudioEnvironmentNode を要する
        public var useSpatialAudio: Bool
        /// 相対方位の大きさがこれを超えたら「真後ろ寄り」の音色に切り替える [deg]。
        /// HRTF では前後が判別できなかった(2026-08-18 実測)ため、音色で分ける
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
        /// 角からこの距離以上離れたら誘導を終える [m](通過後は間隔が開いて自然に消える)
        public var guidanceEndDistanceM: Double
        /// 最接近点からこれ以上遠ざかったら誘導を終える [m]。
        /// 通り過ぎた角を指し続けると混乱するだけなので、離れ始めたら諦める
        public var guidanceLeftBehindM: Double
        public var earconGain: Double
        public var tones: Tones

        public struct Tones: Codable, Equatable {
            public var suggestion: ToneSpec
            public var timeUpPrompt: ToneSpec
            public var returnAck: ToneSpec
            public var homeBeacon: ToneSpec
            public var arrival: ToneSpec
        }
    }

    public struct ToneSpec: Codable, Equatable {
        public var freqsHz: [Double]
        public var blipSec: Double
        public var gapSec: Double
        /// 白色雑音を混ぜる割合 [0..1]。
        /// 純音には 4〜10 kHz の成分が無く、HRTF の前後判別が依存する耳介の
        /// スペクトル手がかりを運べない。広帯域成分を足すと前後が聴き分けやすくなる
        /// (2026-08-18 の実測で、純音のビーコンは前後がほぼ判別不能だった)
        public var noiseMix: Double
    }
}
