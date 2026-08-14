import Foundation

/// 方向の推定に使う生データ。CoreLocation / CLHeading の値をそのまま入れる(Services 側で詰める)。
/// 無効値は CoreLocation の流儀に合わせて「負値」で表現される場合があるため、判定は本ファイルに集約する。
public struct MotionFix: Equatable {
    /// CLLocation.course(進行方向 0..360、負値は無効)
    public var courseDeg: Double?
    /// CLLocation.courseAccuracy(度、負値は無効。nil = 不明として扱う)
    public var courseAccuracyDeg: Double?
    /// CLLocation.speed(m/s、負値は無効)
    public var speedMps: Double?
    /// CLHeading(端末そのものの向き。ポケットに入れると進行方向と一致しない)
    public var compassHeadingDeg: Double?
    /// 位置更新からの経過秒(nil = 不明)
    public var ageSec: Double?

    public init(courseDeg: Double? = nil, courseAccuracyDeg: Double? = nil,
                speedMps: Double? = nil, compassHeadingDeg: Double? = nil,
                ageSec: Double? = nil) {
        self.courseDeg = courseDeg
        self.courseAccuracyDeg = courseAccuracyDeg
        self.speedMps = speedMps
        self.compassHeadingDeg = compassHeadingDeg
        self.ageSec = ageSec
    }
}

/// 方向をどこから得たか。フィールドログに残して事後検証するために保持する。
public enum DirectionSource: String, Equatable {
    case course   // GPS の移動方向(歩行中のみ有効)
    case compass  // 端末の磁気コンパス(端末の向き = 進行方向とは限らない)
}

public struct TravelDirectionFix: Equatable {
    public let deg: Double
    public let source: DirectionSource

    public init(deg: Double, source: DirectionSource) {
        self.deg = deg
        self.source = source
    }
}

/// 「いま体はどちらを向いて進んでいるか」を決める純粋ロジック。
///
/// 設計上の決まり:
/// - iPhone をポケットに入れる前提のため、**端末コンパスは進行方向の代用にならない**。
///   歩行中は CLLocation.course(移動の軌跡から出る方向)を第一候補とする
/// - course は静止・低速時と GPS 不良時に無効になるため、その場合のみコンパスへ退避する
///   (退避を許すかは allow_compass_fallback。退避中は音の左右が実際の体の向きとずれ得る)
/// - どちらも使えない場合は nil。呼び出し側は「鳴らさない」ことを選ぶ
public enum TravelDirection {
    public static func resolve(_ fix: MotionFix, params: AppParameters.Location) -> TravelDirectionFix? {
        if let course = validCourse(fix, params: params) {
            return TravelDirectionFix(deg: Geo.normalizeDeg(course), source: .course)
        }
        if params.allowCompassFallback, let compass = fix.compassHeadingDeg, compass >= 0 {
            return TravelDirectionFix(deg: Geo.normalizeDeg(compass), source: .compass)
        }
        return nil
    }

    /// course が「歩いている最中の、信頼できる移動方向」と言える場合のみ返す
    private static func validCourse(_ fix: MotionFix, params: AppParameters.Location) -> Double? {
        guard let course = fix.courseDeg, course >= 0 else { return nil }
        guard let speed = fix.speedMps, speed >= params.minSpeedForCourseMPerS else { return nil }
        if let age = fix.ageSec, age > params.maxFixAgeSec { return nil }
        // courseAccuracy は不明(nil)または負値(未提供)なら精度判定をしない
        if let acc = fix.courseAccuracyDeg, acc >= 0, acc > params.maxCourseAccuracyDeg { return nil }
        return course
    }
}
