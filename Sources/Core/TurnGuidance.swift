import Foundation

/// 1 つの「曲がるイベント」に対する連続音の作り方を決める純粋ロジック。
///
/// 単発の提案では「どの角のことか」が伝わらなかった(2026-08-18 実測)ため、
/// 角へ向かう間ずっと鳴らし続ける。設計の要点は 3 つ。
///
/// 1. **距離は音量で表す。** 間隔の変化では距離として伝わらなかった(2026-08-18 実測・
///    利用者判断)。間隔は固定にし、「連続音である」ことだけを担わせる
/// 2. **音量の頂点は角そのものではなく手前に置く。** 間隔方式では最も密になるのが
///    角まで 5 m 前後 = 曲がっている最中で、「あの角だ」と確定してから
///    曲がる準備をする時間が無かった
/// 3. **向きのブレンドは片道。** 遠いうちは角そのものを指し、近づくにつれて曲がる先へ
///    移す。**通過後に角へ戻さない。** 距離だけで補間していた旧実装は、曲がり終えた
///    直後に「背後になった角」へ引き戻し、右に曲がったのに音が左へ流れていた
///    (実測 12:39:52〜58 で +56° → −33°)
public struct TurnGuidance: Equatable {
    public struct Params: Equatable {
        /// 補間と音量の起点となる距離 [m]。これより遠い間は「角そのもの」を指す
        public let startDistanceM: Double
        /// ここで音量が最大になり、向きも曲がる先を指し切る [m]。
        /// 角に着く手前で「ここで曲がる」を確定させるための余裕
        public let peakBeforeM: Double
        /// 音の間隔 [sec](固定)
        public let intervalSec: Double
        /// 最も遠いときの音量 [0..1]
        public let gainFar: Double
        /// 頂点の音量 [0..1]
        public let gainNear: Double
        /// 角からこの距離以上離れたら終える [m]
        public let endDistanceM: Double
        /// 最接近点からこれ以上遠ざかったら終える [m]
        public let leftBehindM: Double
        /// 進行方位と曲がる先の差がこれ以内になったら「曲がり終えた」とみなす [deg]
        public let turnedWithinDeg: Double
        /// 曲がり終えた後、音量を落としながら鳴らす音の数
        public let closingTones: Int

        public init(startDistanceM: Double, peakBeforeM: Double, intervalSec: Double,
                    gainFar: Double, gainNear: Double, endDistanceM: Double,
                    leftBehindM: Double, turnedWithinDeg: Double, closingTones: Int) {
            self.startDistanceM = startDistanceM
            self.peakBeforeM = peakBeforeM
            self.intervalSec = intervalSec
            self.gainFar = gainFar
            self.gainNear = gainNear
            self.endDistanceM = endDistanceM
            self.leftBehindM = leftBehindM
            self.turnedWithinDeg = turnedWithinDeg
            self.closingTones = closingTones
        }
    }

    /// 誘導が終わった理由。ログの読み手が「うまくいったのか」を判別できるようにする
    public enum Ending: String, Equatable {
        /// 曲がり終えた(狙いどおりの終わり方)
        case turned = "曲がり終えた"
        /// 角に寄らないまま離れた(提案に従わなかった、または角を取り違えた)
        case leftBehind = "角から離れた"
    }

    /// 1 音ぶんの指示
    public struct Step: Equatable {
        /// 鳴らす向き(絶対方位)
        public let targetBearingDeg: Double
        public let gain: Double
        public let intervalSec: Double
        public let distanceM: Double
        /// 終端(曲がり終えた後の減衰)の音か
        public let isClosing: Bool
    }

    public enum Outcome: Equatable {
        case play(Step)
        case finished(Ending)
    }

    public let corner: GeoPoint
    /// 曲がった先へ踏み出す絶対方位
    public let branchBearingDeg: Double

    /// これまでの最接近距離 [m]
    public private(set) var closestM: Double
    /// 補間係数。1 = 角を指す、0 = 曲がる先を指す。**単調にしか減らない**
    private var blend: Double = 1
    /// 終端に入ってから残っている音の数(nil なら未突入)
    private var closingLeft: Int?

    public init(corner: GeoPoint, branchBearingDeg: Double, distanceM: Double) {
        self.corner = corner
        self.branchBearingDeg = branchBearingDeg
        self.closestM = distanceM
    }

    /// 曲がり終えたと判断できるか。
    /// **角まで寄ったうえで**、進行方位が曲がる先に揃ったときだけ成立させる。
    /// 角に寄る前は、提案の条件から進行方位と分岐は必ず離れている(直進は提案しない)ので
    /// 誤って成立することはないが、条件を明示しておく
    private func hasTurned(travelBearingDeg: Double?, p: Params) -> Bool {
        guard closestM <= p.peakBeforeM, let travel = travelBearingDeg else { return false }
        return abs(Geo.angularDiffDeg(branchBearingDeg, travel)) <= p.turnedWithinDeg
    }

    /// 次の 1 音を決める。位置更新ではなく**音を鳴らす直前**に呼ぶ。
    /// - Parameters:
    ///   - position: 現在地
    ///   - travelBearingDeg: 進行方位(取れないときは nil。曲がり終えた判定だけが止まる)
    public mutating func next(position: GeoPoint, travelBearingDeg: Double?,
                              p: Params) -> Outcome {
        let d = Geo.distanceM(position, corner)
        closestM = min(closestM, d)

        // 終端に入っていれば、残りを鳴らして終わる。距離による打ち切りより優先する
        // (曲がり終えた直後は角から離れていくので、打ち切り条件にも同時に当たる)
        if let left = closingLeft {
            guard left > 0 else { return .finished(.turned) }
            closingLeft = left - 1
            // 1 音ごとに落ちていく音量。「イベントが終わりかけている」を音で伝える
            let step = Double(left) / Double(p.closingTones + 1)
            return .play(Step(targetBearingDeg: branchBearingDeg,
                              gain: p.gainNear * step,
                              intervalSec: p.intervalSec,
                              distanceM: d, isClosing: true))
        }

        if hasTurned(travelBearingDeg: travelBearingDeg, p: p) {
            guard p.closingTones > 0 else { return .finished(.turned) }
            closingLeft = p.closingTones - 1
            return .play(Step(targetBearingDeg: branchBearingDeg,
                              gain: p.gainNear * Double(p.closingTones) / Double(p.closingTones + 1),
                              intervalSec: p.intervalSec,
                              distanceM: d, isClosing: true))
        }

        if d > p.endDistanceM { return .finished(.leftBehind) }
        if d > closestM + p.leftBehindM { return .finished(.leftBehind) }

        // **補間は片道。** 一度詰まった向きは、離れても角へ戻さない
        let span = p.startDistanceM - p.peakBeforeM
        let raw = span > 0 ? min(1, max(0, (d - p.peakBeforeM) / span)) : 0
        blend = min(blend, raw)

        let toCorner = Geo.bearingDeg(from: position, to: corner)
        let target = Geo.normalizeDeg(
            branchBearingDeg + Geo.angularDiffDeg(toCorner, branchBearingDeg) * blend)
        // 音量も片道(blend が単調なので自動的に単調増加する)。頂点に達したら維持する
        let gain = p.gainFar + (p.gainNear - p.gainFar) * (1 - blend)
        return .play(Step(targetBearingDeg: target, gain: gain,
                          intervalSec: p.intervalSec, distanceM: d, isClosing: false))
    }
}
