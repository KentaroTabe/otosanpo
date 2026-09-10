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
    /// 有効性パルス専用のノード。**機能音と同じノードに載せない**(2026-09-08 の検証)。
    /// 単一ノードだと、鳴らすたびに音量・位置を書き換えるので、
    /// 再生中の確認音の定位を動かしたり、後続の機能音をキューで待たせたりしうる。
    /// パルスは方向を持たない診断音なので、環境ノードを通さず直接ミキサへ出す
    private let pulsePlayer = AVAudioPlayerNode()
    /// 音楽スポット(→ Core の MusicSpot)。**連続音は別のノードで回す** —
    /// earcon を止めずに鳴らし続けるため。
    /// `AVAudioEnvironmentNode` はモノラル入力にしか効かないので、
    /// ステレオの音源はミキサでモノラルへ落としてから環境ノードへ入れる
    private let musicPlayer = AVAudioPlayerNode()
    private let musicMixer = AVAudioMixerNode()
    /// 音楽が止まったときに理由つきで呼ばれる(**一度だけ**鳴らす約束のため)。
    /// 鳴り終わった場合と、音声経路が切れて中断した場合を区別する
    var onMusicStopped: ((String) -> Void)?
    private(set) var isMusicPlaying = false
    /// 音源の形式。**エンジンが再起動すると接続が壊れる**ので、繋ぎ直すために覚えておく
    private var musicFormat: AVAudioFormat?
    /// 再生の世代。完了通知が遅れて届いたときに、**次の再生を止めない**ための識別
    private var musicGeneration: UInt64 = 0
    private let environment = AVAudioEnvironmentNode()
    private var buffers: [Earcon: AVAudioPCMBuffer] = [:]
    /// 真後ろ用の暗い音色。HRTF の前後判別は当てにならないため、音色で前後を分ける
    private var behindBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    /// **配布版の音色**。実験ビルドでだけ持つ(左右の聴き比べを実機の音響経路で行うため)。
    /// `build-demo/ab-*.wav` は等パワーのパンによる近似で、実機の HRTF とは経路が違う。
    /// 「散歩に出てよいか」の判定は、判定対象と同じ経路で行う(2026-09-08)
    private var shippedBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    /// 定位を前半球に畳むか(→ SoundPlacement.foldToFrontDeg)
    private let frontHemisphereOnly: Bool
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

    /// - Parameters:
    ///   - experiment: 実験装置を着けた時だけ使う設定(音色の差し替えと有効性パルス)
    ///   - experimentActive: `head_mount.enabled`。**スイッチはこれ 1 つ**(→ AppParameters.Experiment)。
    ///     false なら音は配布版とまったく同じで、有効性パルスの音は作られもしない
    init(audio: AppParameters.Audio, experiment: AppParameters.Experiment,
         experimentActive: Bool) throws {
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
        frontHemisphereOnly = audio.frontHemisphereOnly
        behindThresholdDeg = audio.behindThresholdDeg
        behindDarkness = audio.behindDarkness

        engine.attach(player)
        engine.attach(pulsePlayer)
        engine.attach(musicPlayer)
        engine.attach(musicMixer)
        if audio.useSpatialAudio {
            engine.attach(environment)
            isSpatial = true
        }
        connectGraph()

        let format = mono
        let gain = audio.earconGain
        let lead = audio.earconLeadSilenceSec
        // **方向を担う 2 種だけ**に実験用の音色(倍音とアタック)を載せる。
        // 曲がり角の誘導もこの 2 種を使う(WalkMachine.guidanceEarcon)ので、
        // 方向を持つ音はこれで全部。時間到来・確認音・到着は方向を持たないので触らない
        // — 無関係な音色変更を実験に混ぜないため(2026-09-08 合議)
        // **どの音に上書きするかの判断は Core に置いてある**(単体テストで押さえるため)
        let tones = experiment.tones(from: audio.tones, active: experimentActive)
        buffers[.suggestion] = Self.render(tones.suggestion, format: format, gain: gain, leadSilenceSec: lead)
        buffers[.timeUpPrompt] = Self.render(tones.timeUpPrompt, format: format, gain: gain, leadSilenceSec: lead)
        buffers[.returnAck] = Self.render(tones.returnAck, format: format, gain: gain, leadSilenceSec: lead)
        buffers[.homeBeacon] = Self.render(tones.homeBeacon, format: format, gain: gain, leadSilenceSec: lead)
        buffers[.arrival] = Self.render(tones.arrival, format: format, gain: gain, leadSilenceSec: lead)
        let beaconTone = tones.homeBeacon
        // 有効性パルスは**実験のときだけ作る**。作らなければ play が黙って何もしないので、
        // 配布版で鳴る経路が存在しないことがここで担保される
        if experimentActive {
            buffers[.validityPulse] = Self.render(experiment.validityPulseTone,
                                                  format: format, gain: gain, leadSilenceSec: lead)
            // 聴き比べの相手として配布版の音色も持つ。**実験ビルドでだけ**作る
            shippedBuffers[.suggestion] = Self.render(audio.tones.suggestion, format: format,
                                                      gain: gain, leadSilenceSec: lead)
            shippedBuffers[.homeBeacon] = Self.render(audio.tones.homeBeacon, format: format,
                                                      gain: gain, leadSilenceSec: lead)
        }
        // ビーコンだけは「真後ろ」用の変種を持つ。周波数を下げて雑音成分を削り、
        // 耳介で高域が遮られた音(= 背後から来る音)に寄せる
        behindBuffers[.homeBeacon] = Self.render(
            Self.darken(beaconTone, by: audio.behindDarkness),
            format: format, gain: gain, leadSilenceSec: lead)

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
        // パルスは環境ノードを通さず直接ミキサへ。方向を持たないことが**構造で**保証され、
        // 機能音の定位・音量・再生順にも触れない
        engine.connect(pulsePlayer, to: engine.mainMixerNode, format: monoFormat)
        // 音楽は「player → ミキサ(モノラルへ落とす)→ 環境ノード」。
        // 環境ノードはモノラル入力にしか効かないので、ここでチャンネル数を落とす。
        // player 側は接続時に音源の形式へ合わせる(startMusic で繋ぎ直す)
        if useSpatialAudio {
            engine.connect(musicMixer, to: environment, format: monoFormat)
            // **定位は環境ノードに直結したノードに設定する。**
            // AVAudioMixing の position / renderingAlgorithm が効くのは
            // 「その接続先が持つ入力バス」で、ここでは musicMixer → environment の側。
            // 上流の musicPlayer に設定しても効かない(2026-09-09 の検証で判明)。
            //
            // **連続音は HRTFHQ。** 素の `.HRTF` は角度の分解能が粗く、
            // 「向きの選択肢が数えるほどしかない」と感じられた(2026-09-08 の散歩)。
            // 点の earcon は一瞬なので粗さが出にくいが、鳴り続ける音では効く。
            // 計算量は増えるが、同時に鳴る連続音は 1 つだけ
            musicMixer.renderingAlgorithm = .HRTFHQ
        } else {
            engine.connect(musicMixer, to: engine.mainMixerNode, format: monoFormat)
        }
        // **音源側も繋ぎ直す。** エンジンが再起動すると接続は全部壊れるので、
        // ここで戻さないと「音楽だけが黙って鳴らなくなる」(2026-09-09 に自分で踏んだ)
        if let musicFormat {
            engine.connect(musicPlayer, to: musicMixer, format: musicFormat)
        }
    }

    // MARK: - 音楽スポット(実験)

    /// 音源を鳴らし始める。**一度だけ**再生し、止まったら `onMusicStopped` を呼ぶ。
    ///
    /// - Parameters:
    ///   - relativeBearingDeg: 鳴らし始める向き。**鳴らす前に置く** —
    ///     既定の音量・正面のまま鳴り出すと、最初の一瞬だけ間違った大きさで聞こえる
    ///   - gain: 同上。距離から決めた音量
    func startMusic(url: URL, relativeBearingDeg: Double, gain: Double) throws {
        stopMusic()
        let file = try AVAudioFile(forReading: url)
        // 音源の形式で繋ぎ直す(ステレオ / モノラル・標本化周波数が音源ごとに違う)
        musicFormat = file.processingFormat
        engine.disconnectNodeOutput(musicPlayer)
        engine.connect(musicPlayer, to: musicMixer, format: file.processingFormat)
        if !engine.isRunning { recover(reason: "音楽の再生前") }
        // **鳴らす前に置く。** 位置と音量を決めてから再生を始める
        setMusicPlacement(relativeBearingDeg: relativeBearingDeg, gain: gain)
        // **世代を進める。** 前の再生の完了通知が遅れて届いても、
        // 新しい再生を止めないようにする(「一度だけ」の約束が競合で崩れないため)
        musicGeneration &+= 1
        let generation = musicGeneration
        isMusicPlaying = true
        musicPlayer.scheduleFile(file, at: nil) { [weak self] in
            // 再生スレッドから来るのでメインへ渡す。
            // **停止でも呼ばれる**ので、同じ世代で鳴っている時だけ「鳴り終わった」と扱う
            DispatchQueue.main.async {
                guard let self, self.isMusicPlaying, self.musicGeneration == generation else {
                    return
                }
                self.isMusicPlaying = false
                self.onMusicStopped?("最後まで鳴り終わった")
            }
        }
        musicPlayer.play()
    }

    /// 音楽の置き場所と音量を更新する。
    ///
    /// **前半球へ畳まない**(利用者判断・2026-09-08)。通り過ぎれば後ろにあるのが自然で、
    /// 畳むと通り過ぎたことが分からなくなる。
    ///
    /// 設定するのは **`musicMixer`**(環境ノードに直結している側)。
    /// 上流の `musicPlayer` に設定しても定位には効かない
    func setMusicPlacement(relativeBearingDeg deg: Double, gain: Double) {
        musicMixer.volume = Float(max(0, min(1, gain)))
        if isSpatial {
            let p = SoundPlacement.position(relativeBearingDeg: deg)
            musicMixer.position = AVAudio3DPoint(x: Float(p.x), y: Float(p.y), z: Float(p.z))
        } else {
            musicMixer.pan = Float(max(-1, min(1, SoundPlacement.pan(relativeBearingDeg: deg))))
        }
    }

    func stopMusic() {
        guard isMusicPlaying || musicPlayer.isPlaying else { return }
        // **先に旗を降ろす。** 完了ハンドラは stop でも呼ばれるので、
        // これが後だと「鳴り終わった」と誤って通知される(一度だけの約束が崩れる)
        isMusicPlaying = false
        musicPlayer.stop()
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
        // 再起動すると再生位置は失われる。**勝手に鳴らし直さない**
        // (「一度だけ鳴る」という約束を、こちらの都合で破らない)。
        // **旗を降ろすだけでは足りない** — 予約済みの音源はノードに残るので、
        // stop() で明示的に解除しないと再開しない保証が無い(2026-09-09 の検証で指摘)
        let wasPlayingMusic = isMusicPlaying
        isMusicPlaying = false
        if wasPlayingMusic { musicPlayer.stop() }
        do {
            try Self.configureSession()
            connectGraph()
            try engine.start()
            onEvent?("音声エンジンを再開しました(\(reason))")
            if wasPlayingMusic { onMusicStopped?("音声経路が切れて中断した") }
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

    /// 音色を暗くする(Core の実装を使う。紹介用の書き出しと同じ音にするため)
    static func darken(_ tone: AppParameters.ToneSpec, by darkness: Double) -> AppParameters.ToneSpec {
        ToneRenderer.darken(tone, by: darkness)
    }

    /// - Parameter gain: 相対音量 [0..1]。曲がり角の誘導が「角までの近さ」を音量で表すため
    ///   (間隔の変化では距離が伝わらなかった。2026-08-18 実測)。
    ///   バッファは焼き直さず、再生ノードの音量で変える
    /// - Parameter useShipped: 実験ビルドで**配布版の音色**を鳴らす(左右の聴き比べ用)。
    ///   配布ビルドでは変種を持たないので、指定しても同じ音が鳴る
    func play(_ e: Earcon, relativeBearingDeg: Double? = nil, gain: Double = 1.0,
              useShipped: Bool = false) {
        // 鳴らす直前にも確かめる。通知を取りこぼしても無音のままにしない
        if !engine.isRunning { recover(reason: "再生前の点検") }
        // 有効性パルスは専用ノード。**機能音の定位・音量・再生順に一切触れない**
        if e == .validityPulse {
            guard let b = buffers[e] else { return }
            pulsePlayer.volume = Float(max(0, min(1, gain)))
            pulsePlayer.scheduleBuffer(b)
            if !pulsePlayer.isPlaying { pulsePlayer.play() }
            return
        }
        // **前後は伝わらないチャネルなので、主張しない**(→ SoundPlacement.foldToFrontDeg)。
        // 全球に置いていた頃、前に置いた音まで背後から聞こえていた(2026-08-30 テスター報告)。
        // 畳んだ後は 90° 以内なので、真後ろ用の音色(isBehind)にも到達しない
        let deg = frontHemisphereOnly
            ? SoundPlacement.foldToFrontDeg(relativeBearingDeg ?? 0)
            : (relativeBearingDeg ?? 0)
        // 前後は定位では伝わらない(2026-08-18 実測)。畳まない場合は音色で分ける
        let useBehind = Self.isBehind(deg, thresholdDeg: behindThresholdDeg)
        let variant = useShipped ? shippedBuffers[e] : nil
        guard let b = variant ?? (useBehind ? behindBuffers[e] : nil) ?? buffers[e] else { return }
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

    /// Core が作った標本列を AVAudioPCMBuffer に載せる。
    /// **波形の作り方は Core(ToneRenderer)に置く** — 紹介用の書き出し(Sources/Demo)と
    /// 同じ音を鳴らすため。ここは容れ物を用意するだけ
    static func render(_ tone: AppParameters.ToneSpec, format: AVAudioFormat,
                       gain: Double, leadSilenceSec: Double = 0) -> AVAudioPCMBuffer? {
        // **先頭に無音を足す。** 定位は再生ノードの値で付くが、その値は鳴り始めてから
        // 目標へ滑らかに移る。前の音と向きが大きく違うと、その移動が音の頭に乗って
        // 「鳴り出しは右、鳴り終わりは左」になる(2026-08-25 実測)
        let samples = ToneRenderer.withLeadSilence(
            ToneRenderer.samples(tone, sampleRate: format.sampleRate, gain: gain),
            seconds: leadSilenceSec, sampleRate: format.sampleRate)
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        // モノラル 1 チャンネル。定位は再生時に位置(またはパン)で付ける
        for (i, s) in samples.enumerated() { ch[0][i] = s }
        return buf
    }
}
