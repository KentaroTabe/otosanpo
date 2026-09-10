import Foundation

/// 端末座標系の 3 成分(角速度 [rad/s] や重力 [g])。記録専用の集計で使う
public struct MotionVector: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = MotionVector(x: 0, y: 0, z: 0)
}

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
/// - **三軸それぞれの角速度の積分**(符号つき。どの軸が頭の鉛直軸かを後で決める材料)
/// - 鉛直軸まわりの回転の積分(**符号つき**。方位の変化と比べる相手)
/// - 区間の最後の標本の**瞬時値**(センサ時刻・角速度 3 軸・重力 3 軸)
///
/// をまとめる。**この値はどの判定にも渡さない**(→ 受け入れ条件 E5)。
/// 渡していないことは「gyro の値を変えても使用可能状態が変わらない」テストで固定する。
///
/// **射影の計算はここ(Core)に置く。** Services は OS の値を運ぶだけ(CLAUDE.md のレイヤ規約)。
public struct HeadMotionDigest: Equatable {

    public private(set) var count = 0
    /// 標本間隔の最大 [sec]。背景で間引かれた・配信が止まったことがここに出る
    public private(set) var maxGapSec = 0.0
    /// 三軸それぞれの角速度の積分 [deg](符号つき)
    public private(set) var integratedDeg = MotionVector.zero
    /// 鉛直軸まわりの回転の積分 [deg]。符号つき(方位の変化と突き合わせる相手)
    public private(set) var integratedVerticalDeg = 0.0
    /// 磁場較正の最低値(-1 = 未較正 / 0 = 低 / 1 = 中 / 2 = 高)。悪い方を残す
    public private(set) var worstMagneticAccuracy: Int?
    /// 区間の最後の標本のセンサ時刻 [sec](瞬時値の記録 → 受け入れ条件 E3)
    public private(set) var lastSensorTime: TimeInterval?
    /// 区間の最後の標本の角速度 [rad/s]
    public private(set) var lastRotationRate: MotionVector?
    /// 区間の最後の標本の重力 [g]
    public private(set) var lastGravity: MotionVector?

    private var firstHeadingDeg: Double?
    private var lastHeadingDeg: Double?
    /// 区間をまたいで引き継ぐ時計(`rollOver` でも消さない)
    private var clock: TimeInterval?

    public init() {}

    /// 角速度を**鉛直軸へ射影**した値 [rad/s]。
    /// 端末の取り付け向きが縦でも横でも同じ量になる(`rotationRate.z` 決め打ちを避ける)。
    /// 重力が 0 ベクトル(センサが値を返していない)なら 0
    public static func verticalRate(rotation r: MotionVector, gravity g: MotionVector) -> Double {
        let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard norm > 0 else { return 0 }
        // 重力は「下向き」なので、上向き軸まわりの回転を正にするため符号を反転する
        return -(r.x * g.x + r.y * g.y + r.z * g.z) / norm
    }

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
    ///   - rotationRate: バイアス補正済みの端末三軸角速度 [rad/s]
    ///   - gravity: 端末座標系の重力 [g]
    ///   - magneticAccuracy: 磁場較正の状態
    ///   - maxIntervalSec: 1 標本に与えてよい時間の上限 [sec]。
    ///     配信が止まった後の 1 標本に何十秒も積分させないための蓋
    public mutating func add(headingDeg: Double, sensorTime: TimeInterval,
                             rotationRate: MotionVector, gravity: MotionVector,
                             magneticAccuracy: Int, maxIntervalSec: Double) {
        count += 1
        if firstHeadingDeg == nil { firstHeadingDeg = headingDeg }
        lastHeadingDeg = headingDeg
        worstMagneticAccuracy = worstMagneticAccuracy.map { Swift.min($0, magneticAccuracy) }
            ?? magneticAccuracy
        lastSensorTime = sensorTime
        lastRotationRate = rotationRate
        lastGravity = gravity
        defer { clock = sensorTime }
        guard let previous = clock, sensorTime > previous else { return }
        let gap = sensorTime - previous
        maxGapSec = Swift.max(maxGapSec, gap)
        let dt = Swift.min(gap, maxIntervalSec)
        let toDeg = 180.0 / Double.pi
        integratedDeg.x += rotationRate.x * dt * toDeg
        integratedDeg.y += rotationRate.y * dt * toDeg
        integratedDeg.z += rotationRate.z * dt * toDeg
        integratedVerticalDeg += Self.verticalRate(rotation: rotationRate, gravity: gravity)
            * dt * toDeg
    }

    /// 次の区間へ。**時計だけ引き継ぐ**(区間をまたぐ間隔も測りたいため)。
    /// **散歩をまたぐときは使わない** — 新しい散歩は新しいインスタンスで始める
    /// (前の散歩の末尾の時刻を持ち越すと、最初の 1 行に何分もの空白が出る)
    public mutating func rollOver() {
        let carried = clock
        self = HeadMotionDigest()
        clock = carried
    }
}
