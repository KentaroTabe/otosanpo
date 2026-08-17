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
        public var extensionStepMin: Double
        public var maxExtensions: Int
        public var rePromptIntervalSec: Double
        public var arrivalRadiusM: Double
    }

    public struct Budget: Codable, Equatable {
        public var walkingSpeedMPerMin: Double
        /// 平均速度の集計から「立ち止まっている」サンプルを除く下限 [m/s]。
        /// 実測から歩行速度を求めるための計測用で、判定には使わない
        public var minMovingSpeedMPerS: Double
        /// 経路長に加算する最小の移動量 [m]。これ未満の差分は GPS の揺れとして捨てる。
        /// 水平精度(良い時の実測 3〜5 m)より大きく取る
        public var pathSegmentMinM: Double
        /// 実測に使う fix の水平精度の上限 [m]。これより悪い fix は経路長も速度も使わない
        public var maxAccuracyForMetricsM: Double
        public var detourFactor: Double
        public var returnReserveMin: Double
        public var maxReturnWalkMin: Double
        public var softZoneRatio: Double
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
        public var beaconIntervalNearSec: Double
        public var beaconIntervalFarSec: Double
        public var beaconNearDistanceM: Double
        public var beaconFarDistanceM: Double
        /// 相対方位がこれ以上変わったら、次のビーコンを待たずに繰り上げて鳴らす [deg]。
        /// 角を曲がってから最大 5 秒待たせないため
        public var beaconDirectionChangeDeg: Double
        /// 繰り上げの下限間隔 [sec]。連打を防ぐ
        public var beaconMinGapSec: Double
        /// 3D 音響(HRTF)で定位するか。false ならステレオパンで代替する。
        /// 3D は前後を区別できるが、モノラル入力と AVAudioEnvironmentNode を要する
        public var useSpatialAudio: Bool
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
