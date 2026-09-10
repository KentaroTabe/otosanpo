import Foundation

/// 頭部固定スマホの device-motion を、**ログ間隔ぶんまとめて 1 行にする**集計。
///
/// ## なぜ瞬時値を 1 Hz で抜くだけにしないか(2026-09-10)
///
/// 次の案件で「方位が回転に応答しているか」をスマホの角速度で検疫したい。
/// その設計には、**軸・符号・遅れ・背景時の間引き**の実測が要る。
/// 50 Hz の角速度を 1 Hz の瞬時値で抜くと 49/50 が失われ、積分と比較できない
/// (積分は 1 秒の間に起きたことを全部含むが、瞬時値は 1 点しか見ていない)。
///
/// そこでログ間隔の中で:
///
/// - 方位の変化(先頭と末尾の円差)
/// - 標本数と**最大の標本間隔**(背景で間引かれたかが分かる)
/// - 三軸角速度の大きさの積分(どれだけ動いたか)
/// - 鉛直軸まわりの回転の積分(**符号つき**。方位の変化と比べる相手)
///
/// をまとめる。**この値はどの判定にも渡さない**(→ 受け入れ条件 E5)。
/// 渡していないことは「gyro の値を変えても使用可能状態が変わらない」テストで固定する。
public struct HeadMotionDigest: Equatable {

    public private(set) var count = 0
    /// 標本間隔の最大 [sec]。背景で間引かれた・配信が止まったことがここに出る
    public private(set) var maxGapSec = 0.0
    /// 三軸角速度の大きさの積分 [deg]。「どれだけ動いたか」の総量
    public private(set) var integratedAbsDeg = 0.0
    /// 鉛直軸まわりの回転の積分 [deg]。符号つき(方位の変化と突き合わせる相手)
    public private(set) var integratedVerticalDeg = 0.0
    /// 磁場較正の最低値(-1 = 未較正 / 0 = 低 / 1 = 中 / 2 = 高)。悪い方を残す
    public private(set) var worstMagneticAccuracy: Int?

    private var firstHeadingDeg: Double?
    private var lastHeadingDeg: Double?
    private var lastTime: TimeInterval?

    public init() {}

    /// この区間の方位の変化 [deg](円差。標本が 2 件未満なら nil)
    public var headingChangeDeg: Double? {
        guard let first = firstHeadingDeg, let last = lastHeadingDeg, count >= 2 else {
            return nil
        }
        return Geo.angularDiffDeg(last, first)
    }

    /// 1 標本を足す。
    /// - Parameters:
    ///   - headingDeg: 真北基準の方位 [deg]
    ///   - sensorTime: センサ時刻 [sec](端末起動からの単調時計)
    ///   - absRateRadPerSec: 三軸角速度の**大きさ** [rad/s]
    ///   - verticalRateRadPerSec: 鉛直軸へ射影した角速度 [rad/s](符号つき)
    ///   - magneticAccuracy: 磁場較正の状態
    ///   - maxIntervalSec: 1 標本に与えてよい時間の上限 [sec]。
    ///     配信が止まった後の 1 標本に何十秒も積分させないための蓋
    public mutating func add(headingDeg: Double, sensorTime: TimeInterval,
                             absRateRadPerSec: Double, verticalRateRadPerSec: Double,
                             magneticAccuracy: Int, maxIntervalSec: Double) {
        count += 1
        if firstHeadingDeg == nil { firstHeadingDeg = headingDeg }
        lastHeadingDeg = headingDeg
        worstMagneticAccuracy = worstMagneticAccuracy.map { Swift.min($0, magneticAccuracy) }
            ?? magneticAccuracy
        defer { lastTime = sensorTime }
        guard let previous = lastTime, sensorTime > previous else { return }
        let gap = sensorTime - previous
        maxGapSec = Swift.max(maxGapSec, gap)
        let dt = Swift.min(gap, maxIntervalSec)
        let toDeg = 180.0 / Double.pi
        integratedAbsDeg += abs(absRateRadPerSec) * dt * toDeg
        integratedVerticalDeg += verticalRateRadPerSec * dt * toDeg
    }

    /// 次の区間へ。**時刻だけ引き継ぐ**(区間をまたぐ間隔も測りたいため)
    public mutating func rollOver() {
        let carried = lastTime
        self = HeadMotionDigest()
        lastTime = carried
    }
}
