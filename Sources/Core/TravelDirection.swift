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
    case course      // GPS の移動方向(歩行中のみ有効)
    case heldCourse  // 直前まで有効だった course の保持値(曲がった直後は古い向きを指す)
    case compass     // 端末の磁気コンパス(端末の向き = 進行方向とは限らない)
}

/// 直前まで有効だった course。呼び出し側が保持し、resolve に渡す
/// (Core を純粋に保つため、状態は Core の外に置く)。
public struct HeldCourse: Equatable {
    public let deg: Double
    /// 保持した時点からの経過秒
    public let ageSec: Double

    public init(deg: Double, ageSec: Double) {
        self.deg = deg
        self.ageSec = ageSec
    }
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
/// - course は静止・低速時と GPS 不良時に無効になるため、その間は直前の有効な course を
///   `course_hold_sec` まで使い続ける。歩行中の向きは急には変わらないので、
///   数十秒前の移動方向のほうがポケットの中の端末の向きよりはるかに確からしい
///   (2026-08-16 の実測: コンパス退避は左右を反転させていた。docs/04 参照)
/// - それも尽きた場合のみコンパスへ退避する
///   (退避を許すかは allow_compass_fallback。既定は false)
/// - どれも使えない場合は nil。呼び出し側は「鳴らさない」または「中央で鳴らす」を選ぶ
public enum TravelDirection {
    public static func resolve(_ fix: MotionFix, held: HeldCourse? = nil,
                               params: AppParameters.Location) -> TravelDirectionFix? {
        if let course = validCourse(fix, params: params) {
            return TravelDirectionFix(deg: Geo.normalizeDeg(course), source: .course)
        }
        if let held, held.ageSec <= params.courseHoldSec {
            return TravelDirectionFix(deg: Geo.normalizeDeg(held.deg), source: .heldCourse)
        }
        if params.allowCompassFallback, let compass = fix.compassHeadingDeg, compass >= 0 {
            return TravelDirectionFix(deg: Geo.normalizeDeg(compass), source: .compass)
        }
        return nil
    }

    /// course が無効になった理由。ログに残して「なぜ左右が付かなかったか」を追えるようにする
    public static func rejectionReason(_ fix: MotionFix, params: AppParameters.Location) -> String? {
        guard let course = fix.courseDeg, course >= 0 else { return "course が無効" }
        guard let speed = fix.speedMps else { return "速度が不明" }
        if speed < params.minSpeedForCourseMPerS {
            return String(format: "速度不足(%.2f < %.2f m/s)", speed, params.minSpeedForCourseMPerS)
        }
        if let age = fix.ageSec, age > params.maxFixAgeSec {
            return String(format: "fix が古い(%.1f > %.1f s)", age, params.maxFixAgeSec)
        }
        if let acc = fix.courseAccuracyDeg, acc >= 0, acc > params.maxCourseAccuracyDeg {
            return String(format: "course 精度不足(%.0f > %.0f°)", acc, params.maxCourseAccuracyDeg)
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
