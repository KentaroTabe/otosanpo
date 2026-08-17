import Foundation

/// 音を置く位置。`AVAudioEnvironmentNode` の座標系に合わせる
/// (聴取者は原点で **−Z を向く**。+X が右、+Y が上)。
public struct SoundPosition: Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// 相対方位(顔の向きを 0、右を正)から、音の置き場所を決める純粋な変換。
///
/// 2 つの出力を持つ理由:
/// - `position` は 3D 音響(HRTF)用。**前後を区別できる**のが本質的な利点で、
///   「真後ろが正面と同じに聞こえる」既知の欠点が解消される
/// - `pan` は 3D が使えない場合の代替。左右の音量差だけなので前後は区別できない
public enum SoundPlacement {
    /// ステレオパン(-1 = 左, +1 = 右)。
    /// 真横で ±1、正面と真後ろがどちらも 0 になる(前後の曖昧性。docs/03)
    public static func pan(relativeBearingDeg deg: Double) -> Double {
        sin(deg * .pi / 180)
    }

    /// 3D の位置。減衰の基準距離に合わせて半径 `radiusM` の円周上に置く。
    /// 基準距離のまま置けば距離減衰が働かないので、音量は方向によらず一定になる
    /// (距離は間隔で伝える。docs/03「ビーコンの距離・方向キュー」)。
    public static func position(relativeBearingDeg deg: Double,
                                radiusM: Double = 1.0) -> SoundPosition {
        let rad = deg * .pi / 180
        // 正面 = −Z、右 = +X
        return SoundPosition(x: sin(rad) * radiusM,
                             y: 0,
                             z: -cos(rad) * radiusM)
    }
}
