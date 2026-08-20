import Foundation

/// earcon の波形を作る純粋な計算。
///
/// **アプリと紹介用の書き出しで同じ音を鳴らすために Core へ置く。**
/// もともと `EarconSynth`(Services)にあったが、Services は OS のラッパに徹する約束
/// (CLAUDE.md)であり、合成そのものはロジックなので Core が正しい置き場所。
/// macOS のツール(Sources/Demo)からも同じコードを使える。
public enum ToneRenderer {
    /// 周波数列を Hann 窓エンベロープのサイン波ブリップとして並べ、標本列にする。
    /// 返すのはモノラル。定位は再生側が付ける(位置 or パン)
    public static func samples(_ tone: AppParameters.ToneSpec,
                               sampleRate: Double, gain: Double) -> [Float] {
        let blipFrames = Int(tone.blipSec * sampleRate)
        let gapFrames = Int(tone.gapSec * sampleRate)
        let count = tone.freqsHz.count
        guard count > 0, blipFrames > 0 else { return [] }

        var out = [Float]()
        out.reserveCapacity(count * blipFrames + max(0, count - 1) * gapFrames)

        // 雑音は再現性のために自前の線形合同法で作る(同じ設定なら毎回同じ音になる)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextNoise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
        }
        let mix = max(0, min(1, tone.noiseMix))

        for (i, f) in tone.freqsHz.enumerated() {
            for n in 0..<blipFrames {
                let t = Double(n) / sampleRate
                let env = 0.5 * (1 - cos(2 * .pi * Double(n) / Double(blipFrames)))
                let tonal = sin(2 * .pi * f * t)
                let v = tonal * (1 - mix) + nextNoise() * mix
                out.append(Float(v * env * gain))
            }
            if i < count - 1 {
                out.append(contentsOf: repeatElement(0, count: gapFrames))
            }
        }
        return out
    }

    /// 音色を暗くする(周波数を下げ、雑音成分を削る)。
    /// `darkness` 0 で変化なし、1 で最も暗い。
    /// HRTF では前後を判別できなかった(2026-08-18 実測)ため、背後は音色で分ける
    public static func darken(_ tone: AppParameters.ToneSpec,
                              by darkness: Double) -> AppParameters.ToneSpec {
        let d = max(0, min(1, darkness))
        var out = tone
        out.freqsHz = tone.freqsHz.map { $0 * (1 - 0.5 * d) }
        out.noiseMix = tone.noiseMix * (1 - d)
        return out
    }
}
