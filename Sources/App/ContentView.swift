import SwiftUI

/// この画面はセットアップとデバッグのためのもの。
/// 散歩が始まったら iPhone はポケットに入れ、以後は音とジェスチャだけで完結するのが本来の体験。
struct ContentView: View {
    @ObservedObject var controller: WalkSessionController

    var body: some View {
        NavigationStack {
            Form {
                Section("設定") {
                    LabeledContent("自宅", value: controller.home == nil ? "未設定" : "設定済み")
                    Button("自宅を現在地に設定") {
                        controller.setHomeHere()
                    }
                    Stepper(value: $controller.durationMin,
                            in: controller.params.session.minDurationMin...controller.params.session.maxDurationMin,
                            step: 5) {
                        Text("散歩時間: \(Int(controller.durationMin)) 分")
                    }
                    Toggle("通勤路の学習モード", isOn: $controller.commuteLearning)
                    if controller.commuteLearning {
                        Text("ON の間の移動経路は「日常の道」として記録され、以後の提案から除外されます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("セッション") {
                    Text(stateLabel).font(.headline)
                    Text(controller.statusLine).font(.caption)
                    Text(controller.motionStatusLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if controller.state == .idle || controller.state == .arrived {
                        Button("散歩を開始") {
                            controller.start()
                        }
                    } else {
                        Button("終了", role: .destructive) {
                            controller.stopManually()
                        }
                    }
                }

                Section("デバッグ(シミュレータ・モーション非対応時の代替)") {
                    Button("時間到来を発火") { controller.debugTimeUp() }
                    Button("うなずきを発火(帰路開始)") { controller.debugNod() }
                    Button("首振りを発火(延長)") { controller.debugShake() }
                }

                Section("earcon の試聴") {
                    Button("提案音(左)") { controller.debugPlay(.suggestion, pan: -1) }
                    Button("提案音(右)") { controller.debugPlay(.suggestion, pan: 1) }
                    Button("時間到来") { controller.debugPlay(.timeUpPrompt) }
                    Button("帰路の確認音") { controller.debugPlay(.returnAck) }
                    Button("帰路ビーコン") { controller.debugPlay(.homeBeacon) }
                    Button("到着音") { controller.debugPlay(.arrival) }
                }

                Section("フィールドログ") {
                    if let url = controller.fieldLogURL {
                        ShareLink(item: url) {
                            Label("ログを書き出す", systemImage: "square.and.arrow.up")
                        }
                        Button("ログを消去", role: .destructive) {
                            controller.clearFieldLog()
                        }
                    } else {
                        Text("まだ記録がありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("提案・ビーコン・ジェスチャ検出を端末内のファイルに追記します(送信しません)。"
                         + "Finder の「iPhone > ファイル」からも取り出せます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("イベントログ") {
                    ForEach(Array(controller.eventLog.suffix(12).reversed().enumerated()),
                            id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("音さんぽ")
            .alert("操作できませんでした",
                   isPresented: Binding(get: { controller.alertMessage != nil },
                                        set: { if !$0 { controller.alertMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.alertMessage ?? "")
            }
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: "待機中"
        case .wandering: "散策中(音の提案あり)"
        case .promptingReturn: "帰りますか?(うなずき=帰る / 首振り=延長)"
        case .returning: "帰路(ビーコン案内中)"
        case .arrived: "到着"
        }
    }
}
