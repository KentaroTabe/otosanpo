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
    }

    public struct Gesture: Codable, Equatable {
        public var nodPitchThresholdDeg: Double
        public var shakeYawThresholdDeg: Double
        public var minReversals: Int
        public var windowSec: Double
        public var refractorySec: Double
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
