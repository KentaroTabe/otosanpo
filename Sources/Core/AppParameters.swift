import Foundation

/// config/parameters.json に対応する型。
/// 数値パラメータはすべて JSON 側に置く(CLAUDE.md 参照)。
/// JSON は snake_case、Swift 側は camelCase(デコード時に .convertFromSnakeCase を使用)。
public struct AppParameters: Codable, Equatable {
    public var session: Session
    public var budget: Budget
    public var route: Route
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
    }
}
