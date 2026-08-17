import Foundation
import AVFoundation

/// earcon をコードで合成して鳴らす。
/// 音源ファイルを使わないためライセンス問題がなく、即フィールドテストできる。
/// 音色の定義(周波数列・ブリップ長・間隔)は config/parameters.json の audio.tones。
/// 完成品ではデザインされた音(CC0 か自作)に差し替える(docs/03 参照)。
///
/// AVAudioSession は .playback + .mixWithOthers + .duckOthers:
/// ユーザーの音楽や Podcast を主役のまま、earcon の瞬間だけ一時的に音量を下げて割り込む。
final class EarconSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let environment = AVAudioEnvironmentNode()
    private var buffers: [Earcon: AVAudioPCMBuffer] = [:]
    /// 真後ろ用の暗い音色。HRTF の前後判別は当てにならないため、音色で前後を分ける
    private var behindBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    private let behindThresholdDeg: Double
    private let behindDarkness: Double
    /// 3D 音響として繋げられたか。false の間はステレオパンで代替する
    private(set) var isSpatial = false

    init(audio: AppParameters.Audio) throws {
        // 3D 音響(HRTF)は **モノラル入力にしか効かない**。ステレオのままでは
        // AVAudioEnvironmentNode が定位を付けず、黙って素通りする
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2) else {
            throw NSError(domain: "EarconSynth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioFormat の生成に失敗"])
        }
        engine.attach(player)
        if audio.useSpatialAudio {
            engine.attach(environment)
            engine.connect(player, to: environment, format: mono)
            engine.connect(environment, to: engine.mainMixerNode, format: stereo)
            // 聴取者は原点。音源はこちらで動かす(頭の向きは HeadingFusion が方位に織り込む)
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            player.renderingAlgorithm = .HRTF
            player.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
            isSpatial = true
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: mono)
        }

        let format = mono
        let gain = audio.earconGain
        behindThresholdDeg = audio.behindThresholdDeg
        behindDarkness = audio.behindDarkness
        buffers[.suggestion] = Self.render(audio.tones.suggestion, format: format, gain: gain)
        buffers[.timeUpPrompt] = Self.render(audio.tones.timeUpPrompt, format: format, gain: gain)
        buffers[.returnAck] = Self.render(audio.tones.returnAck, format: format, gain: gain)
        buffers[.homeBeacon] = Self.render(audio.tones.homeBeacon, format: format, gain: gain)
        buffers[.arrival] = Self.render(audio.tones.arrival, format: format, gain: gain)
        // ビーコンだけは「真後ろ」用の変種を持つ。周波数を下げて雑音成分を削り、
        // 耳介で高域が遮られた音(= 背後から来る音)に寄せる
        behindBuffers[.homeBeacon] = Self.render(
            Self.darken(audio.tones.homeBeacon, by: audio.behindDarkness),
            format: format, gain: gain)

        try Self.configureSession()
        try engine.start()
    }

    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        try session.setActive(true)
    }

    /// 相対方位(顔の向きを 0、右を正)を指定して鳴らす。
    /// 3D が使えれば前後も区別して定位し、使えなければ左右のパンで代替する。
    /// nil は「方向を付けない」= 正面。
    /// 「真後ろ寄り」の音色に切り替える閾値を超えているか
    static func isBehind(_ deg: Double, thresholdDeg: Double) -> Bool {
        abs(Geo.angularDiffDeg(deg, 0)) > thresholdDeg
    }

    /// 音色を暗くする(周波数を下げ、雑音成分を削る)。
    /// `darkness` 0 で変化なし、1 で最も暗い
    static func darken(_ tone: AppParameters.ToneSpec, by darkness: Double) -> AppParameters.ToneSpec {
        let d = max(0, min(1, darkness))
        var out = tone
        out.freqsHz = tone.freqsHz.map { $0 * (1 - 0.5 * d) }
        out.noiseMix = tone.noiseMix * (1 - d)
        return out
    }

    func play(_ e: Earcon, relativeBearingDeg: Double? = nil) {
        let deg = relativeBearingDeg ?? 0
        // 前後は定位では伝わらない(2026-08-18 実測)。音色で分ける
        let useBehind = Self.isBehind(deg, thresholdDeg: behindThresholdDeg)
        guard let b = (useBehind ? behindBuffers[e] : nil) ?? buffers[e] else { return }
        if isSpatial {
            let p = SoundPlacement.position(relativeBearingDeg: deg)
            player.position = AVAudio3DPoint(x: Float(p.x), y: Float(p.y), z: Float(p.z))
        } else {
            player.pan = Float(max(-1, min(1, SoundPlacement.pan(relativeBearingDeg: deg))))
        }
        player.scheduleBuffer(b)
        if !player.isPlaying {
            player.play()
        }
    }

    /// 周波数列を Hann 窓エンベロープのサイン波ブリップとしてレンダリングする
    static func render(_ tone: AppParameters.ToneSpec, format: AVAudioFormat, gain: Double) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let blipFrames = Int(tone.blipSec * sr)
        let gapFrames = Int(tone.gapSec * sr)
        let count = tone.freqsHz.count
        guard count > 0, blipFrames > 0 else { return nil }
        let total = count * blipFrames + max(0, count - 1) * gapFrames
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        // モノラル 1 チャンネル。定位は再生時に位置(またはパン)で付ける
        let out = ch[0]

        // 雑音は再現性のために自前の線形合同法で作る(同じ設定なら毎回同じ音になる)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextNoise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
        }
        let mix = max(0, min(1, tone.noiseMix))

        var idx = 0
        for (i, f) in tone.freqsHz.enumerated() {
            for n in 0..<blipFrames {
                let t = Double(n) / sr
                let env = 0.5 * (1 - cos(2 * .pi * Double(n) / Double(blipFrames)))
                let tonal = sin(2 * .pi * f * t)
                let v = tonal * (1 - mix) + nextNoise() * mix
                out[idx] = Float(v * env * gain)
                idx += 1
            }
            if i < count - 1 {
                for _ in 0..<gapFrames {
                    out[idx] = 0
                    idx += 1
                }
            }
        }
        return buf
    }
}
