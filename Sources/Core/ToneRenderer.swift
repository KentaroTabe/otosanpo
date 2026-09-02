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

        // **倍音の重みを先に作る。** 高域成分が両耳間レベル差(ILD)を生み、
        // 左右の定位を可能にする(440 Hz の基音だけでは頭を回折して差が出ない)
        let harmonicCount = max(1, tone.harmonics)
        var weights: [Double] = []
        var amp = 1.0
        for _ in 0..<harmonicCount {
            weights.append(amp)
            amp *= max(0, tone.harmonicDecay)
        }
        let weightSum = weights.reduce(0, +)

        // 立ち上がりの鋭さ。0.5 で従来の Hann 窓(左右対称)
        let attack = max(0.001, min(0.999, tone.attackRatio))
        let attackFrames = Double(blipFrames) * attack

        for (i, f) in tone.freqsHz.enumerated() {
            for n in 0..<blipFrames {
                let t = Double(n) / sampleRate
                // 非対称エンベロープ: 鋭く立ち上がり、緩やかに減衰する。
                // **立ち上がりの鋭さが両耳間時間差(ITD)の手がかりになる**
                let pos = Double(n)
                let env: Double
                if pos < attackFrames {
                    env = 0.5 * (1 - cos(.pi * pos / attackFrames))
                } else {
                    let rest = Double(blipFrames) - attackFrames
                    let p = rest > 0 ? (pos - attackFrames) / rest : 1
                    env = 0.5 * (1 + cos(.pi * min(1, p)))
                }
                // 基音と倍音を重ねる。合計の重みで割るので音量は倍音数に依らない
                var tonal = 0.0
                for (h, w) in weights.enumerated() {
                    tonal += sin(2 * .pi * f * Double(h + 1) * t) * w
                }
                tonal /= weightSum
                let v = tonal * (1 - mix) + nextNoise() * mix
                out.append(Float(v * env * gain))
            }
            if i < count - 1 {
                out.append(contentsOf: repeatElement(0, count: gapFrames))
            }
        }
        return out
    }

    /// 先頭に無音を足す。
    ///
    /// **なぜ要るか**: 定位は再生ノードの位置(または pan)で付けるが、その値は
    /// 音が鳴り始めてから目標へ滑らかに移る。前の音と向きが大きく違うと、
    /// **その移動が音の頭に乗って「鳴り出しは右、鳴り終わりは左」に聞こえる**
    /// (2026-08-25 の報告。試聴で左右を押し比べると顕著)。
    ///
    /// 実測では、1 音ごとの向きの変化は中央 5° と小さいが、**イベントの 1 音目(予告)は
    /// 22 件中 14 件で 60° 以上跳んでいた**(最大 168°)。いちばん向きを伝えたい音が
    /// いちばん滲む。
    ///
    /// 無音のうちに移動を終わらせれば、鳴り始めた時にはもう目標の向きになっている。
    public static func withLeadSilence(_ samples: [Float], seconds: Double,
                                       sampleRate: Double) -> [Float] {
        let frames = Int(max(0, seconds) * sampleRate)
        guard frames > 0, !samples.isEmpty else { return samples }
        return [Float](repeating: 0, count: frames) + samples
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
