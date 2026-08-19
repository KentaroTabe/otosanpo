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

    /// 繋ぎ直しに必要なものを保持する(経路が変わると接続が壊れるため)
    private let monoFormat: AVAudioFormat
    private let stereoFormat: AVAudioFormat
    private let useSpatialAudio: Bool
    private var observers: [NSObjectProtocol] = []

    /// エンジンの再起動などをフィールドログへ残すための通知口。
    /// **無音は記録が無いと診断できない**(2026-08-18 の実測で気づいた)
    var onEvent: ((String) -> Void)?

    var isRunning: Bool { engine.isRunning }

    init(audio: AppParameters.Audio) throws {
        // 3D 音響(HRTF)は **モノラル入力にしか効かない**。ステレオのままでは
        // AVAudioEnvironmentNode が定位を付けず、黙って素通りする
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2) else {
            throw NSError(domain: "EarconSynth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioFormat の生成に失敗"])
        }
        monoFormat = mono
        stereoFormat = stereo
        useSpatialAudio = audio.useSpatialAudio
        behindThresholdDeg = audio.behindThresholdDeg
        behindDarkness = audio.behindDarkness

        engine.attach(player)
        if audio.useSpatialAudio {
            engine.attach(environment)
            isSpatial = true
        }
        connectGraph()

        let format = mono
        let gain = audio.earconGain
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
        observeRouteChanges()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// ノードの接続。経路が変わると接続は壊れるので、繋ぎ直せる形にしておく
    private func connectGraph() {
        if useSpatialAudio {
            engine.connect(player, to: environment, format: monoFormat)
            engine.connect(environment, to: engine.mainMixerNode, format: stereoFormat)
            // 聴取者は原点。音源はこちらで動かす(頭の向きは HeadingFusion が方位に織り込む)
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            player.renderingAlgorithm = .HRTF
            player.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: monoFormat)
        }
    }

    /// **AirPods の着脱でエンジンが止まる。**
    /// 出力経路が変わると AVAudioEngine は設定変更通知を出して停止し、接続も壊れる。
    /// 繋ぎ直して再開しないと、以後アプリの音だけが一切鳴らなくなる
    /// (2026-08-18 の実測: 散歩の開始 5 秒後に AirPods が繋ぎ直され、
    ///  以後デバッグ再生も含めて完全に無音だった。ログ上は再生が成功しているように見える)。
    private func observeRouteChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.recover(reason: "構成変更")
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recover(reason: "出力経路の変更")
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.recover(reason: "割り込みの終了")
        })
    }

    /// 止まっていれば繋ぎ直して再開する。動いていれば何もしない
    private func recover(reason: String) {
        guard !engine.isRunning else { return }
        do {
            try Self.configureSession()
            connectGraph()
            try engine.start()
            onEvent?("音声エンジンを再開しました(\(reason))")
        } catch {
            onEvent?("音声エンジンの再開に失敗(\(reason)): \(error.localizedDescription)")
        }
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

    /// - Parameter gain: 相対音量 [0..1]。曲がり角の誘導が「角までの近さ」を音量で表すため
    ///   (間隔の変化では距離が伝わらなかった。2026-08-18 実測)。
    ///   バッファは焼き直さず、再生ノードの音量で変える
    func play(_ e: Earcon, relativeBearingDeg: Double? = nil, gain: Double = 1.0) {
        // 鳴らす直前にも確かめる。通知を取りこぼしても無音のままにしない
        if !engine.isRunning { recover(reason: "再生前の点検") }
        let deg = relativeBearingDeg ?? 0
        // 前後は定位では伝わらない(2026-08-18 実測)。音色で分ける
        let useBehind = Self.isBehind(deg, thresholdDeg: behindThresholdDeg)
        guard let b = (useBehind ? behindBuffers[e] : nil) ?? buffers[e] else { return }
        player.volume = Float(max(0, min(1, gain)))
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
