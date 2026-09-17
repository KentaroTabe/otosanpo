import SwiftUI

/// 案内音の設定(2026-09-17 利用者依頼)。
///
/// 実験ビルドでは、方向を担う 2 音(提案音・ビーコン)に**倍音とアタック**を足した音を使う。
/// 「元の音も選べるように」という依頼でこの画面を作った。
///
/// 試聴もここへ集めた。主画面は**出発前に見るだけ**のものに保ちたいので、
/// 音を確かめる操作はこちらへ寄せる(テスターの手順書 docs/09 からもここを案内する)。
struct GuidanceSoundView: View {
    @ObservedObject var controller: WalkSessionController

    var body: some View {
        Form {
            Section("音色") {
                Picker("案内音", selection: $controller.guidanceToneExperimental) {
                    Text("元の音").tag(false)
                    Text("倍音を足した音").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(controller.guidanceToneExperimental
                     ? "倍音とアタックを足した音です。高い成分が増えるぶん、"
                       + "左右の手がかりが強くなることを狙っています"
                     : "配布版と同じ、倍音を持たない音です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Text の markdown はリテラルにしか効かない(連結すると記号がそのまま出る)
                Text("変わるのは、方向を伝える 2 音(提案音・ビーコン)だけです。"
                     + "時間到来・帰路の確認音・到着音は変わりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("試聴") {
                Button("提案音(左 90°)") {
                    controller.debugPlay(.suggestion, relativeBearingDeg: -90)
                }
                Button("提案音(右 90°)") {
                    controller.debugPlay(.suggestion, relativeBearingDeg: 90)
                }
                // 「真後ろ」の試聴ボタンは置かない(2026-08-31 利用者判断)。
                // 定位は前半球のみで、後ろから鳴ることは無い(docs/03「前後からの撤退」)。
                // 鳴らない音を試聴に並べると「後ろから鳴ることがある」という誤解を教えてしまう
                Button("ビーコン(正面)") { controller.debugPlay(.homeBeacon, relativeBearingDeg: 0) }
                Button("ビーコン(左 90°)") { controller.debugPlay(.homeBeacon, relativeBearingDeg: -90) }
                Button("ビーコン(右 90°)") { controller.debugPlay(.homeBeacon, relativeBearingDeg: 90) }
                Button("時間到来") { controller.debugPlay(.timeUpPrompt) }
                Button("帰路の確認音") { controller.debugPlay(.returnAck) }
                Button("到着音") { controller.debugPlay(.arrival) }
                Text("イヤホンで聴いてください。iPhone のスピーカーでは左右がほとんど分かりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("案内音")
        .navigationBarTitleDisplayMode(.inline)
    }
}
