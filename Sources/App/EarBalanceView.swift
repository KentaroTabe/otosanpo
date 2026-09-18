import SwiftUI

/// **左右の音量差の初期設定**(2026-09-18 利用者依頼)。
///
/// ## なぜこの画面が要るか
///
/// 2026-09-18 の散歩の感想:
///
/// - 「前後は 1 も 2 も成り立たず、左右に顔を振らないと分からない」
/// - 「左右のイヤホンから聞こえる音量の合計値がほぼ一定な影響で、
///   左右に偏った時のみはっきり分かる。実際に人間が聞くときの、耳の形による影響や
///   脳の意識の向け方などから決まる値をもとに割り振っても良い」
///
/// 汎用 HRTF の左右差は「平均的な頭」のもので、**その人にとって 90° に聞こえる保証は無い**。
/// **真横(90°)に感じる左右差**だけを本人に合わせてもらい、その 1 点から間を作る。
///
/// ## 使い方(この画面の流れ)
///
/// 1. 「右で鳴らす」を押すと、いまのつまみの左右差で音が繰り返し鳴る
/// 2. **真横(右 90°)から聞こえる**と感じる所へつまみを動かす
/// 3. 左も同じように合わせる(耳は左右対称ではないので、鏡写しにしない)
/// 4. 「この設定で使う」で確定
///
/// 合わせた後は、**音楽は HRTF を通さず、この左右比で鳴る**(→ EarconSynth)。
struct EarBalanceView: View {
    @ObservedObject var controller: WalkSessionController

    @State private var rightDb: Double
    @State private var leftDb: Double
    @State private var playing: Side?
    @State private var ticker: Timer?
    @State private var saved = false

    private enum Side { case right, left }

    /// 校正音の間隔 [秒]。**繰り返し鳴らす**ので、つまみを動かしながら比べられる
    private let repeatSec = 0.8

    init(controller: WalkSessionController) {
        self.controller = controller
        let current = controller.earBalance
        _rightDb = State(initialValue: current?.rightDb ?? 6)
        _leftDb = State(initialValue: current?.leftDb ?? 6)
    }

    var body: some View {
        Form {
            Section("これは何か") {
                Text("音が真横(90°)から聞こえると感じる左右差を、ご自分で合わせる設定です。"
                     + "合わせた値は音楽スポットの鳴り方に使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("イヤホンを着けて、静かな場所で行ってください。"
                     + "iPhone のスピーカーでは左右がほとんど分かりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("右 90°") {
                slider(value: $rightDb, side: .right)
            }

            Section("左 90°") {
                slider(value: $leftDb, side: .left)
            }

            Section {
                Button("この設定で使う") {
                    saved = controller.saveEarBalance(rightDb: rightDb, leftDb: leftDb)
                    stop()
                }
                if controller.earBalance != nil {
                    Button("初期設定を消す(元の聞こえ方に戻す)", role: .destructive) {
                        controller.clearEarBalance()
                        saved = false
                    }
                }
            } footer: {
                if saved {
                    Text("保存しました。次に音声を用意する時から、この左右比で鳴ります。")
                } else if controller.earBalance == nil {
                    Text("まだ合わせていません。この設定を保存するまでは、"
                         + "従来どおりの聞こえ方(汎用の 3D 音響)で鳴ります。")
                } else {
                    Text("保存済みの設定があります。つまみを動かして「この設定で使う」を押すと"
                         + "置き換わります。")
                }
            }

            Section("覚えておくこと") {
                // Text の markdown はリテラルにしか効かない(連結すると記号がそのまま出る)
                Text("合わせられるのは左右だけです。前後の聞き分けはこの設定では直りません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("散歩の途中で変えても、その散歩の音には効きません(音声の経路を"
                     + "用意する時に決まるため)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("左右の音量差")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    @ViewBuilder
    private func slider(value: Binding<Double>, side: Side) -> some View {
        HStack {
            Text(String(format: "%.0f dB", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)
            Slider(value: value, in: EarBalance.minDb...EarBalance.maxDb, step: 1)
                .onChange(of: value.wrappedValue) { _, _ in
                    if playing == side { play(side) }
                }
        }
        Button(playing == side ? "止める" : (side == .right ? "右で鳴らす" : "左で鳴らす")) {
            if playing == side { stop() } else { start(side) }
        }
        Text(side == .right
             ? "右の真横から聞こえると感じる所へ動かしてください"
             : "左の真横から聞こえると感じる所へ動かしてください")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func start(_ side: Side) {
        stop()
        playing = side
        play(side)
        // **繰り返し鳴らす。** 1 回きりだと、つまみを動かした結果を比べられない
        let t = Timer.scheduledTimer(withTimeInterval: repeatSec, repeats: true) { _ in
            Task { @MainActor in play(side) }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func play(_ side: Side) {
        let db = side == .right ? rightDb : -leftDb
        controller.playBalanceTone(differenceDb: db)
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        playing = nil
    }
}
