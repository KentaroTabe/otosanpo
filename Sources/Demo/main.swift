import Foundation

/// 紹介用の音を書き出す開発ツール(macOS)。
///
/// なぜ要るか: **このアプリは見るものが無い。** 画面を見ずに歩くのが前提なので、
/// スクリーンショットでは何も伝わらない。人に見せるには音そのものを渡すしかない。
///
/// 作り方の要点: **アプリと同じコードで鳴らす。**
/// 音色は `ToneRenderer`(Core)、誘導の組み立ては `TurnGuidance`(Core)、
/// ビーコンの間隔と音量は `BeaconRhythm`(Core)。設定値も同じ parameters.json を読む。
/// ここが独自に音を作ると、紹介した音と実物が食い違う。
///
/// 実機との違いは定位だけ。実機は HRTF で 3D に置くが、ここはステレオパンで書き出す。
/// 左右・音量・間隔は忠実で、前後だけ再現しない
/// (前後は実機でも判別できないと 2026-08-18 に確定しているので、失うものは無い)。
///
/// **座標・地図・経路は一切出力しない。** 出るのは時刻・向き・音量から作った波形だけ。
///
/// 使い方: scripts/build_demo.sh [出力先ディレクトリ]

// MARK: - WAV の書き出し

/// 16 bit PCM の WAV を書く。外部ライブラリを使わずに済ませるための最小実装
func writeWAV(_ channels: [[Float]], sampleRate: Int, to url: URL) throws {
    let channelCount = channels.count
    let frameCount = channels.map(\.count).max() ?? 0
    let bytesPerSample = 2
    let dataBytes = frameCount * channelCount * bytesPerSample

    var out = Data()
    func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }

    ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(channelCount)
    u32(sampleRate); u32(sampleRate * channelCount * bytesPerSample)
    u16(channelCount * bytesPerSample); u16(8 * bytesPerSample)
    ascii("data"); u32(dataBytes)

    for i in 0..<frameCount {
        for ch in channels {
            let v = i < ch.count ? ch[i] : 0
            let clipped = max(-1, min(1, v))
            u16(Int(UInt16(bitPattern: Int16(clipped * 32_767))))
        }
    }
    try out.write(to: url)
}

// MARK: - 音を並べる台

/// 鳴らした 1 音の記録。紹介ページで「いつ・どちら側・どれくらいの大きさ」を図に描くために出す
struct ToneEvent: Encodable {
    let t: Double     // 秒
    let pan: Double   // -1(左) 〜 +1(右)
    let gain: Double  // 0..1
}

/// 時刻を指定して音を置いていく器。最後にステレオの標本列にする
struct Timeline {
    let sampleRate: Double
    private(set) var events: [ToneEvent] = []
    private var left: [Float] = []
    private var right: [Float] = []

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// `atSec` の位置に、相対方位 `relDeg`・音量 `gain` で 1 音を置く
    mutating func place(_ tone: AppParameters.ToneSpec, atSec: Double,
                        relDeg rawRelDeg: Double, gain: Double, behind: AppParameters.Audio) {
        // **実機と同じ規則で置く**(このツールの存在理由)。
        // 前半球へ畳むのも実機と同じ(docs/03「前後からの撤退」)。
        // 畳んでいる間は真後ろの音色に到達しない
        let relDeg = behind.frontHemisphereOnly
            ? SoundPlacement.foldToFrontDeg(rawRelDeg) : rawRelDeg
        let spec = abs(Geo.angularDiffDeg(relDeg, 0)) > behind.behindThresholdDeg
            ? ToneRenderer.darken(tone, by: behind.behindDarkness) : tone
        let mono = ToneRenderer.samples(spec, sampleRate: sampleRate,
                                        gain: gain * behind.earconGain)
        // 等パワーのステレオパン。実機の HRTF に対する近似(左右は忠実)
        let pan = SoundPlacement.pan(relativeBearingDeg: relDeg)
        let angle = (pan + 1) * .pi / 4
        let gl = Float(cos(angle)), gr = Float(sin(angle))
        events.append(ToneEvent(t: atSec, pan: pan, gain: gain))

        let start = Int(atSec * sampleRate)
        let end = start + mono.count
        if left.count < end {
            left.append(contentsOf: repeatElement(0, count: end - left.count))
            right.append(contentsOf: repeatElement(0, count: end - right.count))
        }
        for (i, s) in mono.enumerated() {
            left[start + i] += s * gl
            right[start + i] += s * gr
        }
    }

    /// 末尾に余韻ぶんの無音を足す
    mutating func pad(toSec: Double) {
        let n = Int(toSec * sampleRate)
        if left.count < n {
            left.append(contentsOf: repeatElement(0, count: n - left.count))
            right.append(contentsOf: repeatElement(0, count: n - right.count))
        }
    }

    var stereo: [[Float]] { [left, right] }
    var durationSec: Double { Double(left.count) / sampleRate }
}

// MARK: - 設定の読み込み

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count >= 2 ? args[1] : "build-demo")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let params: AppParameters
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: "config/parameters.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    params = try decoder.decode(AppParameters.self, from: data)
} catch {
    FileHandle.standardError.write(Data("設定を読めません: \(error)\n".utf8))
    exit(1)
}

/// 書き出しの標本化周波数。音は最高 1175 Hz なので 11.025 kHz で足りる
/// (必要なのは 2350 Hz 以上)。紹介ページに埋め込むためファイルを小さく保つ
let sr = 11_025.0
let audio = params.audio

// MARK: - 語彙(5 種)を 1 つずつ

let vocabulary: [(String, AppParameters.ToneSpec)] = [
    ("suggestion", audio.tones.suggestion),
    ("time-up", audio.tones.timeUpPrompt),
    ("return-ack", audio.tones.returnAck),
    ("home-beacon", audio.tones.homeBeacon),
    ("arrival", audio.tones.arrival),
]
for (name, spec) in vocabulary {
    let mono = ToneRenderer.samples(spec, sampleRate: sr, gain: audio.earconGain)
    try writeWAV([mono], sampleRate: Int(sr), to: outDir.appendingPathComponent("\(name).wav"))
}
print("語彙 \(vocabulary.count) 種を書き出しました")

// MARK: - 左右の聴き比べ(2026-09-01)
//
// 「音の向きが分からず従えなかった」への対策(倍音 + 鋭いアタック)が
// **実際に左右を聴き分けられるようにしたか**を、歩かずに確かめるための素材。
// 従来の純音と、いまの設定を、同じ角度で交互に鳴らす。
//
// **イヤホンで聴くこと。** ここでの定位は等パワーのパンによる近似で、
// 実機の HRTF とは別物だが、**素材が左右の手がかりを持つかどうか**は判定できる。
func abTrack(_ tone: AppParameters.ToneSpec, label: String) throws {
    var legacy = tone           // 従来: 純音・左右対称の窓
    legacy.harmonics = 1
    legacy.attackRatio = 0.5

    var t = Timeline(sampleRate: sr)
    var at = 0.5
    // 左 → 右 → 左 → 右 を、旧 → 新 の順で
    for spec in [legacy, tone] {
        for deg in [-70.0, 70.0, -70.0, 70.0] {
            t.place(spec, atSec: at, relDeg: deg, gain: 1.0, behind: audio)
            at += 0.7
        }
        at += 1.0   // 旧と新の間に間を置く
    }
    try writeWAV(t.stereo, sampleRate: Int(sr),
                 to: outDir.appendingPathComponent("ab-\(label).wav"))
    print("左右の聴き比べ(\(label)): 前半 4 音 = 従来の純音 / 後半 4 音 = いまの設定"
          + "(各 左右左右・±70°)")
}
try abTrack(audio.tones.homeBeacon, label: "beacon")
try abTrack(audio.tones.suggestion, label: "suggestion")

// MARK: - 場面 1: 散策で 1 つ角を曲がる

/// 北へ進み、35 m 先の角で東へ曲がる。歩く速さは実測の 68 m/min(= 1.13 m/s)
func wanderingScene() -> Timeline {
    let speed = 1.13
    let origin = GeoPoint(latitude: 35.0, longitude: 137.0)
    let corner = Geo.destination(from: origin, bearingDeg: 0, distanceM: 35)
    let branchDeg = 90.0

    var g = TurnGuidance(corner: corner, branchBearingDeg: branchDeg, distanceM: 35)
    let p = TurnGuidance.Params(
        startDistanceM: params.route.intersectionLookaheadM,
        peakBeforeM: audio.guidancePeakBeforeM, intervalSec: audio.guidanceIntervalSec,
        gainFar: audio.guidanceGainFar, gainNear: audio.guidanceGainNear,
        endDistanceM: audio.guidanceEndDistanceM, leftBehindM: audio.guidanceLeftBehindM,
        turnedWithinDeg: params.route.branchStraightDeg,
        closingTones: audio.guidanceClosingTones, announceTones: audio.guidanceAnnounceTones,
        abandonBehindDeg: audio.guidanceAbandonBehindDeg)

    var t = Timeline(sampleRate: sr)
    var elapsed = 1.5      // 鳴り始めるまでの間
    var travelled = 0.0    // 角までの残りを縮めていく
    var afterCorner = 0.0  // 角を過ぎてから東へ進んだ距離

    while elapsed < 34 {
        // 角の手前は北へ、角を過ぎたら東へ歩く
        let position: GeoPoint
        let travel: Double
        if travelled < 35 {
            position = Geo.destination(from: origin, bearingDeg: 0, distanceM: travelled)
            travel = 0
        } else {
            position = Geo.destination(from: corner, bearingDeg: branchDeg, distanceM: afterCorner)
            travel = branchDeg
        }
        guard case .play(let step) = g.next(position: position, travelBearingDeg: travel, p: p) else {
            break
        }
        let rel = Geo.angularDiffDeg(step.targetBearingDeg, travel)
        t.place(audio.tones.suggestion, atSec: elapsed, relDeg: rel,
                gain: step.gain, behind: audio)
        elapsed += step.intervalSec
        if travelled < 35 {
            travelled += speed * step.intervalSec
        } else {
            afterCorner += speed * step.intervalSec
        }
    }
    t.pad(toSec: elapsed + 1.5)
    return t
}

let scene1 = wanderingScene()
try writeWAV(scene1.stereo, sampleRate: Int(sr),
             to: outDir.appendingPathComponent("scene-wandering.wav"))
print(String(format: "場面 1(散策で角を曲がる): %.1f 秒", scene1.durationSec))

// MARK: - 場面 2: 帰路

/// 帰路のビーコンを書き出す。
///
/// **遠いときと近いときを別の場面に分ける。** 音量は自宅までの距離を表すが、
/// 240 m を歩き切るには 3 分以上かかり、そのまま録ると差が伝わる前に飽きる。
/// 短い 2 本を並べて聴いてもらうほうが、音量の違いははっきり分かる。
///
/// - Parameters:
///   - startDistanceM: 開始時の自宅までの距離
///   - toneCount: 鳴らす数
///   - turning: 途中で角を曲がる(自宅の方位が左右に振れる)か
///   - arriving: 最後に到着音を鳴らすか
func returnScene(startDistanceM: Double, toneCount: Int,
                 turning: Bool, arriving: Bool) -> Timeline {
    var t = Timeline(sampleRate: sr)
    let rhythm = audio.beaconRhythm
    let cadence = 1.74  // 実測の歩調 [歩/秒]
    let speed = 1.13

    var elapsed = 1.0
    var distance = startDistanceM
    var homeBearing = 55.0   // 自宅の方位(絶対)
    var travel = 0.0         // 進行方位(絶対)

    for i in 0..<toneCount {
        let rel = Geo.angularDiffDeg(homeBearing, travel)
        let gain = BeaconRhythm.gain(distanceM: distance, p: rhythm)
        t.place(audio.tones.homeBeacon, atSec: elapsed, relDeg: rel, gain: gain, behind: audio)
        let interval = BeaconRhythm.intervalSec(cadenceStepsPerSec: cadence, p: rhythm)
        elapsed += interval
        distance = max(8, distance - speed * interval)
        // 半ばで角を右へ曲がる。自宅が左前方へ回り込み、左右が入れ替わる
        if turning, i >= toneCount / 2, travel < 90 { travel = min(90, travel + 22) }
    }
    if arriving {
        t.place(audio.tones.arrival, atSec: elapsed + 0.5, relDeg: 0, gain: 1.0, behind: audio)
        elapsed += 1.5
    }
    t.pad(toSec: elapsed + 1.0)
    return t
}

// 帰り始め: 自宅は遠く(音量は小さい)、途中で角を曲がって左右が入れ替わる
let far = returnScene(startDistanceM: 420, toneCount: 8, turning: true, arriving: false)
try writeWAV(far.stereo, sampleRate: Int(sr),
             to: outDir.appendingPathComponent("scene-return-far.wav"))
print(String(format: "場面 2(帰り始め・自宅は遠い): %.1f 秒", far.durationSec))

// 自宅の近く: 音量が上がり、最後に到着音
let near = returnScene(startDistanceM: 70, toneCount: 6, turning: false, arriving: true)
try writeWAV(near.stereo, sampleRate: Int(sr),
             to: outDir.appendingPathComponent("scene-return-near.wav"))
print(String(format: "場面 3(自宅の近く・到着): %.1f 秒", near.durationSec))

// 場面ごとの「いつ・どちら側・どれくらいの大きさ」。紹介ページが図に使う
struct SceneData: Encodable {
    let durationSec: Double
    let tones: [ToneEvent]
}
let scenes: [String: SceneData] = [
    "wandering": SceneData(durationSec: scene1.durationSec, tones: scene1.events),
    "return-far": SceneData(durationSec: far.durationSec, tones: far.events),
    "return-near": SceneData(durationSec: near.durationSec, tones: near.events),
]
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(scenes).write(to: outDir.appendingPathComponent("scenes.json"))
print("出力先: \(outDir.path)")
