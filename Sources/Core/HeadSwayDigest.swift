import Foundation

/// **歩いている間の頭の揺れ**を、区間ごとに分布で要約する(2026-10-31)。
///
/// ## なぜ要るか
///
/// ジェスチャの誤検出(docs/17 の T6)の根治候補は「直前の歩行の揺れを基準線にし、
/// そこからの増分で判定する」こと(docs/04)。これを決めるには**普段の揺れの分布**が要る。
///
/// ところが記録は閾値の 0.7 倍を超えた窓だけで、**普段の揺れは 1 行も残っていなかった**。
/// 全窓(2 回/秒)をそのまま書くと 1 時間で 7,200 行になるので、区間ごとに要約する。
///
/// **この値はどの判定にも渡さない。** 記録専用。
public struct HeadSwayDigest: Equatable {

    public struct Summary: Equatable {
        public var windows: Int
        public var pitchMedianDeg: Double
        public var pitchP90Deg: Double
        public var pitchMaxDeg: Double
        public var yawMedianDeg: Double
        public var yawP90Deg: Double
        public var yawMaxDeg: Double
    }

    private var pitchRanges: [Double] = []
    private var yawRanges: [Double] = []

    public init() {}

    /// 診断の窓 1 つぶんの振幅を積む
    public mutating func add(pitchRangeDeg: Double, yawRangeDeg: Double) {
        pitchRanges.append(pitchRangeDeg)
        yawRanges.append(yawRangeDeg)
    }

    /// 積んだ窓の要約。窓が無ければ nil
    public func summary() -> Summary? {
        guard !pitchRanges.isEmpty else { return nil }
        let pitch = pitchRanges.sorted()
        let yaw = yawRanges.sorted()
        return Summary(windows: pitch.count,
                       pitchMedianDeg: Self.rank(pitch, 0.5),
                       pitchP90Deg: Self.rank(pitch, 0.9),
                       pitchMaxDeg: pitch[pitch.count - 1],
                       yawMedianDeg: Self.rank(yaw, 0.5),
                       yawP90Deg: Self.rank(yaw, 0.9),
                       yawMaxDeg: yaw[yaw.count - 1])
    }

    public mutating func reset() {
        pitchRanges.removeAll(keepingCapacity: true)
        yawRanges.removeAll(keepingCapacity: true)
    }

    /// 最近接順位法のパーセンタイル。**標本にある値をそのまま返す**(補間しない)
    private static func rank(_ sorted: [Double], _ q: Double) -> Double {
        let index = Int((q * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}
