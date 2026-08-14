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
    private var buffers: [Earcon: AVAudioPCMBuffer] = [:]

    init(audio: AppParameters.Audio) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2) else {
            throw NSError(domain: "EarconSynth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioFormat の生成に失敗"])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let gain = audio.earconGain
        buffers[.suggestion] = Self.render(audio.tones.suggestion, format: format, gain: gain)
        buffers[.timeUpPrompt] = Self.render(audio.tones.timeUpPrompt, format: format, gain: gain)
        buffers[.returnAck] = Self.render(audio.tones.returnAck, format: format, gain: gain)
        buffers[.homeBeacon] = Self.render(audio.tones.homeBeacon, format: format, gain: gain)
        buffers[.arrival] = Self.render(audio.tones.arrival, format: format, gain: gain)

        try Self.configureSession()
        try engine.start()
    }

    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        try session.setActive(true)
    }

    /// pan: -1(左)〜 +1(右)
    func play(_ e: Earcon, pan: Float = 0) {
        guard let b = buffers[e] else { return }
        player.pan = max(-1, min(1, pan))
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
        let left = ch[0]
        let right = ch[1]

        var idx = 0
        for (i, f) in tone.freqsHz.enumerated() {
            for n in 0..<blipFrames {
                let t = Double(n) / sr
                let env = 0.5 * (1 - cos(2 * .pi * Double(n) / Double(blipFrames)))
                let v = Float(sin(2 * .pi * f * t) * env * gain)
                left[idx] = v
                right[idx] = v
                idx += 1
            }
            if i < count - 1 {
                for _ in 0..<gapFrames {
                    left[idx] = 0
                    right[idx] = 0
                    idx += 1
                }
            }
        }
        return buf
    }
}
