import Foundation

/// 角速度から「頭が進行方向からどれだけ横を向いているか」を短い窓で推定する。
///
/// **なぜ姿勢(yaw)ではなく角速度なのか。**
/// AirPods の `attitude.yaw` は基準が起動時の姿勢で決まる相対値で、実測(2026-08-19)では
/// 旋回そのものを追えていなかった(`|Δraw|` 56° に対し `|Δcourse|` 60°)。
/// 一方 `rotationRate` は「いまどれだけ速く回っているか」だけを答えるので、
/// 基準の取り直しや飛びの影響を受けない。
///
/// **絶対方位は作れない。作らない。**
/// ヨーの絶対基準になるのは磁気か外部参照だけで、ジャイロは角速度しか出せない。
/// 積分すれば必ずドリフトする。そこで**時間で 0 へ戻す**ことでドリフトを打ち消す。
/// 根拠は「頭は平均すれば正面を向く」という前提で、必要なのは
/// **「音のする方を見た数秒」だけ**だから成り立つ(docs/08)。
///
/// 代償: 首を横に向けたまま歩き続けると、推定は半減期で 0 へ戻る。
/// それは「正面を向き直した」と区別できない。区別が要るなら磁力計が要る。
public struct HeadTracker: Equatable {
    public struct Params: Equatable {
        /// 推定が 0 へ戻る半減期 [sec]。短いほどドリフトに強く、長いほど首振りを長く保つ
        public let halfLifeSec: Double
        /// 首の相対角として認める上限 [deg]
        public let maxOffsetDeg: Double
        /// これ未満の角速度は 0 とみなす [deg/sec]。ジャイロの雑音と偏りを捨てる
        public let deadbandDegPerSec: Double
        /// 角速度の向きを「右が正」に合わせる符号(+1 / −1)。
        /// **実測で確かめる**(docs/05 の机上テスト)
        public let sign: Double
        /// サンプルの間隔がこれを超えたら積分せずに捨てる [sec]。
        /// 再装着や中断のあと、間の回転を知らないまま足し込まないため
        public let maxGapSec: Double

        public init(halfLifeSec: Double, maxOffsetDeg: Double, deadbandDegPerSec: Double,
                    sign: Double, maxGapSec: Double) {
            self.halfLifeSec = halfLifeSec
            self.maxOffsetDeg = maxOffsetDeg
            self.deadbandDegPerSec = deadbandDegPerSec
            self.sign = sign
            self.maxGapSec = maxGapSec
        }
    }

    /// 進行方向を 0 とした顔の向き [deg]。右が正
    public private(set) var offsetDeg: Double = 0
    /// 減衰を掛けない生の積分 [deg]。**ジャイロが旋回を追えているかの検証に使う**
    /// (角を曲がった区間で、これが course の変化と一致するかを見る)
    public private(set) var rotationDeg: Double = 0
    private var lastTime: TimeInterval?

    public init() {}

    /// 角速度を 1 サンプル入れて、いまの推定を返す。
    /// - Parameters:
    ///   - yawRateDegPerSec: 鉛直軸まわりの角速度 [deg/sec]
    ///   - time: サンプルの時刻 [sec]。間隔は前回との差から取る
    @discardableResult
    public mutating func ingest(yawRateDegPerSec rate: Double, time: TimeInterval,
                                p: Params) -> Double {
        defer { lastTime = time }
        guard let last = lastTime else { return offsetDeg }
        let dt = time - last
        // 時刻が戻った・間が空きすぎた場合は、間の回転を知らないので積分しない
        guard dt > 0, dt <= p.maxGapSec else { return offsetDeg }

        let r = abs(rate) < p.deadbandDegPerSec ? 0 : rate
        let turned = p.sign * r * dt
        rotationDeg += turned
        offsetDeg += turned
        if p.halfLifeSec > 0 { offsetDeg *= pow(0.5, dt / p.halfLifeSec) }
        offsetDeg = max(-p.maxOffsetDeg, min(p.maxOffsetDeg, offsetDeg))
        return offsetDeg
    }

    /// 生の積分を読み出して 0 に戻す(ログに一定間隔で出すため)
    public mutating func takeRotation() -> Double {
        let v = rotationDeg
        rotationDeg = 0
        return v
    }

    /// 装着し直した時などに捨てる
    public mutating func reset() {
        offsetDeg = 0
        rotationDeg = 0
        lastTime = nil
    }
}
