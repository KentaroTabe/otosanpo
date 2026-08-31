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
/// - `position` は 3D 音響(HRTF)用。当初は**前後を区別できる**ことを利点と
///   見込んだが、**純音 + 汎用 HRTF では前後は伝わらないと実測で確定**した
///   (2026-08-18・docs/03)。以後、前後は伝達チャネルとして使わない
/// - `pan` は 3D が使えない場合の代替。左右の音量差だけなので前後は区別できない
public enum SoundPlacement {
    /// ステレオパン(-1 = 左, +1 = 右)。
    /// 真横で ±1、正面と真後ろがどちらも 0 になる(前後の曖昧性。docs/03)
    public static func pan(relativeBearingDeg deg: Double) -> Double {
        sin(deg * .pi / 180)
    }

    /// 相対方位を**前半球に畳む**(耳軸を鏡として、左右を保ったまま前へ映す)。
    ///
    /// なぜ要るか(2026-08-31): 前後は伝わらないチャネルだと確定している
    /// (純音に耳介の手がかりとなる 4〜10 kHz 成分が無く、汎用 HRTF は前後が弱い)のに、
    /// 置く側は全球を使い続けていた。**伝わらないチャネルへの出力は、雑音になる** —
    /// 曖昧な音を人は「後ろ」に解決しやすく、前に置いた音まで背後から聞こえる
    /// (実測: テスターの帰路 204 発のうち 201 発は前半球に置いていたのに
    /// 「背後から鳴る」と報告された)。畳めば HRTF が後ろの色付けをすることが無くなる。
    ///
    /// **左右の情報は 1 ビットも失わない**: `sin(180° − x) = sin(x)` なので
    /// `pan` は畳む前後で同値。変わるのは HRTF の前後の色付けだけ。
    public static func foldToFrontDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        guard abs(d) > 90 else { return d }
        // 真後ろ(±180°)は正面 0° に映る(左右の手がかりが無いのは畳む前から同じ)
        return (d >= 0 ? 1.0 : -1.0) * (180 - abs(d))
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
