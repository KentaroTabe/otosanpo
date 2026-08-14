import Foundation

public struct HeadSample: Equatable {
    public var time: TimeInterval
    public var pitchDeg: Double
    public var yawDeg: Double

    public init(time: TimeInterval, pitchDeg: Double, yawDeg: Double) {
        self.time = time
        self.pitchDeg = pitchDeg
        self.yawDeg = yawDeg
    }
}

public enum HeadGesture: Equatable {
    case nod    // うなずき = 帰路開始に同意
    case shake  // 首振り = 延長
}

/// AirPods の姿勢サンプル列から、うなずき(pitch の往復)と首振り(yaw の往復)を検出する。
/// アルゴリズム:
/// 1. windowSec 分のサンプルを保持
/// 2. 窓内の (min+max)/2 を基準に偏差を取り、±threshold を跨いだ「符号の反転回数」を数える
/// 3. minReversals 回以上の反転で検出。検出後 refractorySec は再検出しない
/// 歩行中の緩やかな体の回転(yaw の単調変化)は反転を生まないため誤検出しにくい。
/// 呼び出し側の責務:promptingReturn 状態のときだけサンプルを流すこと(常時検出はしない)。
public struct HeadGestureDetector {
    private var samples: [HeadSample] = []
    private var lastDetection: TimeInterval = -.infinity
    private let p: AppParameters.Gesture

    public init(params: AppParameters.Gesture) {
        p = params
    }

    public mutating func ingest(_ s: HeadSample) -> HeadGesture? {
        samples.append(s)
        samples.removeAll { s.time - $0.time > p.windowSec }
        guard s.time - lastDetection >= p.refractorySec else { return nil }

        if reversals(of: samples.map(\.pitchDeg), threshold: p.nodPitchThresholdDeg) >= p.minReversals {
            lastDetection = s.time
            samples.removeAll()
            return .nod
        }
        if reversals(of: samples.map(\.yawDeg), threshold: p.shakeYawThresholdDeg) >= p.minReversals {
            lastDetection = s.time
            samples.removeAll()
            return .shake
        }
        return nil
    }

    /// (min+max)/2 を基準とした偏差が ±threshold を跨いで符号反転した回数
    func reversals(of series: [Double], threshold: Double) -> Int {
        guard series.count > 2, let mn = series.min(), let mx = series.max() else { return 0 }
        let base = (mn + mx) / 2
        var count = 0
        var lastSign = 0
        for v in series {
            let d = v - base
            let sign = d > threshold ? 1 : (d < -threshold ? -1 : 0)
            if sign != 0 && sign != lastSign {
                if lastSign != 0 { count += 1 }
                lastSign = sign
            }
        }
        return count
    }
}
