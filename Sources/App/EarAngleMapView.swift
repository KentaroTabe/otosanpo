import SwiftUI

/// **真横に聞こえる角度の初期設定**(2026-09-18 利用者依頼)。
///
/// > 「音を左後ろから正面を経由して右後ろまでのいずれかで流せる 1 本のつまみを用意し、
/// > それを元に校正する」
///
/// ## 使い方(この画面の流れ)
///
/// 1. 「鳴らす」を押すと、つまみの角度に音が繰り返し置かれる
/// 2. つまみを動かすと音が周りを回る(左後ろ → 正面 → 右後ろ)
/// 3. **真右から聞こえた所**で止めて「ここが真右」を押す。真左も同じ
/// 4. 「この設定で使う」で確定
///
/// 以後、音楽を真横へ置きたい時はその角度へ置く。間の角度も一緒に開く(→ `EarAngleMap`)。
///
/// ## なぜ角度で合わせるか
///
/// 左右のレベル差を直に触る形も試したが、それだと**音楽だけ環境ノードを通らない経路**に
/// する必要があり、近づいた時に下から鳴る手がかりと、遠いほど広がる手がかりを失う。
/// 角度の写像なら同じ経路のままなので、どちらも残る。
struct EarAngleMapView: View {
    @ObservedObject var controller: WalkSessionController

    @State private var angle: Double = 90
    @State private var rightAnchor: Double
    @State private var leftAnchor: Double
    @State private var playing = false
    @State private var ticker: Timer?
    @State private var saved = false

    /// 校正音の間隔 [秒]。**繰り返し鳴らす**ので、つまみを動かしながら比べられる
    private let repeatSec = 0.8

    init(controller: WalkSessionController) {
        self.controller = controller
        let current = controller.earAngleMap
        _rightAnchor = State(initialValue: current?.rightAnchorDeg ?? 90)
        _leftAnchor = State(initialValue: current?.leftAnchorDeg ?? 90)
    }

    var body: some View {
        Form {
            Section("これは何か") {
                Text("つまみを動かすと、音が左後ろから正面を通って右後ろまで動きます。"
                     + "真右・真左から聞こえた所で印をつけてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("イヤホンを着けて、静かな場所で行ってください。"
                     + "iPhone のスピーカーでは左右がほとんど分かりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("つまみ") {
                Text(angleLabel)
                    .font(.title3.monospacedDigit())
                Slider(value: $angle, in: -180...180, step: 5)
                    .onChange(of: angle) { _, _ in if playing { play() } }
                Button(playing ? "止める" : "鳴らす") { playing ? stop() : start() }
                Text("左端が左後ろ、真ん中が正面、右端が右後ろです")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("印をつける") {
                Button("ここが真右(いま \(Int(angle.rounded()))°)") {
                    rightAnchor = clampAnchor(abs(angle))
                }
                Button("ここが真左(いま \(Int(angle.rounded()))°)") {
                    leftAnchor = clampAnchor(abs(angle))
                }
                Text("右 \(Int(rightAnchor.rounded()))° / 左 \(Int(leftAnchor.rounded()))°")
                    .font(.callout)
                Text("どちらも 90° のままなら、校正しないのと同じです")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("この設定で使う") {
                    saved = controller.saveEarAngleMap(rightAnchorDeg: rightAnchor,
                                                       leftAnchorDeg: leftAnchor)
                    stop()
                }
                if controller.earAngleMap != nil {
                    Button("初期設定を消す(そのままの角度で置く)", role: .destructive) {
                        controller.clearEarAngleMap()
                        saved = false
                    }
                }
            } footer: {
                if saved {
                    Text("保存しました。音楽を真横へ置く時は、この角度へ置きます。")
                } else if controller.earAngleMap == nil {
                    Text("まだ合わせていません。保存するまでは、置きたい角度をそのまま置きます。")
                } else {
                    Text("保存済みの設定があります。合わせ直して「この設定で使う」を押すと"
                         + "置き換わります。")
                }
            }

            Section("覚えておくこと") {
                // Text の markdown はリテラルにしか効かない(連結すると記号がそのまま出る)
                Text("合わせられるのは左右の開き方です。前後の聞き分けはこの設定では直りません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("正面と真後ろは動きません。その 2 つを固定したまま、途中の角度が開きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("真横に聞こえる角度")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    private var angleLabel: String {
        let a = Int(angle.rounded())
        if a == 0 { return "正面(0°)" }
        if abs(a) == 180 { return "真後ろ(180°)" }
        return a > 0 ? "右 \(a)°" : "左 \(-a)°"
    }

    private func clampAnchor(_ v: Double) -> Double {
        min(EarAngleMap.maxAnchorDeg, max(EarAngleMap.minAnchorDeg, v))
    }

    private func start() {
        stop()
        playing = true
        play()
        // **繰り返し鳴らす。** 1 回きりだと、つまみを動かした結果を比べられない
        let t = Timer.scheduledTimer(withTimeInterval: repeatSec, repeats: true) { _ in
            Task { @MainActor in play() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func play() {
        controller.playCalibrationTone(relativeBearingDeg: angle)
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        playing = false
    }
}
