import SwiftUI

/// この画面はセットアップとデバッグのためのもの。
/// 散歩が始まったら iPhone はポケットに入れ、以後は音とジェスチャだけで完結するのが本来の体験。
struct ContentView: View {
    @ObservedObject var controller: WalkSessionController

    var body: some View {
        NavigationStack {
            Form {
                // **時間到来の応答。** うなずき・首振りはモーション対応の AirPods を
                // 着けている人しか使えないので、着けていない人が答えられる道を画面にも用意する。
                // 一番上に置くのは、ポケットから出して開いた人が最初に見る場所だから
                if controller.state == .promptingReturn {
                    Section("時間になりました") {
                        Text("そろそろ帰りますか?")
                            .font(.title3.bold())
                        Button("帰る") { controller.answerReturnNow() }
                        if controller.extensionsLeft > 0 {
                            Button("もう少し歩く(あと \(controller.extensionsLeft) 回)") {
                                controller.answerExtend()
                            }
                        } else {
                            Text("延長の上限に達しています")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("AirPods を着けている場合は、うなずく=帰る / "
                             + "首を横に振る=もう少し歩く でも答えられます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("設定") {
                    if controller.home == nil {
                        LabeledContent("自宅", value: "未設定")
                        Text("散歩を開始すると、その場所を自宅として記録します")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("自宅", value: "設定済み")
                        Button("自宅を現在地に更新") {
                            controller.setHomeHere()
                        }
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
                    // 開始し忘れに気づけるよう、状態は他より大きく出す
                    Text(stateLabel)
                        .font(.title3.bold())
                        .foregroundStyle(controller.state == .idle ? .secondary : .primary)
                    Text(controller.statusLine).font(.caption)
                    Text(controller.motionStatusLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if controller.state == .idle || controller.state == .arrived {
                        Button(controller.home == nil ? "ここを自宅にして散歩を開始" : "散歩を開始") {
                            controller.start()
                        }
                    } else {
                        Button("終了", role: .destructive) {
                            controller.stopManually()
                        }
                    }
                }

                // 歩いている最中は書き留められないので、帰ってから振り返るための画面。
                // 見せる範囲は開発中の判断(一般の利用者向けは未決・docs/06)
                if let s = controller.lastSummary {
                    Section("前回の散歩(開発用)") {
                        LabeledContent("距離", value: String(format: "%.0f m", s.pathLengthM))
                        LabeledContent("時間", value: String(format: "%.0f 分", s.durationSec / 60))
                        LabeledContent("イベント", value: "\(s.guidanceEvents.count) 件")
                        NavigationLink("経路図とイベントを見る") {
                            WalkSummaryView(summary: s,
                                            marginM: controller.params.summary.mapMarginM,
                                            minSpanM: controller.params.summary.mapMinSpanM,
                                            roadsProvider: { controller.roadSegments(in: $0) })
                        }
                    }
                }

                // 歩かずに符号と手応えを決めるための机上テスト。
                // 姿勢(yaw)の系統は散歩 1 回を丸ごと潰した前科があるので、
                // 角速度の系統は先にここで確かめる(docs/08)
                Section("頭の追従の確認(机上・AirPods 装着)") {
                    if controller.headCheckActive {
                        Text(controller.headCheckLine)
                            .font(.caption.monospaced())
                        Text("正面を向いた時の方向に音が置かれています。"
                             + "首を右に向けると音は左へ動くのが正しい動作です")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("確認を終了", role: .destructive) { controller.stopHeadCheck() }
                    } else {
                        Button("頭の追従を確認する") { controller.startHeadCheck() }
                        Text("歩かずに確認できます。動かない・逆に動く場合は "
                             + "head_rate_sign を反転させてください")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("デバッグ(シミュレータ・モーション非対応時の代替)") {
                    Button("時間到来を発火") { controller.debugTimeUp() }
                    // 帰る / 延長はデバッグ専用ではなくなったので、上の「時間になりました」に移した
                }

                Section("earcon の試聴") {
                    Button("提案音(左 90°)") { controller.debugPlay(.suggestion, relativeBearingDeg: -90) }
                    Button("提案音(右 90°)") { controller.debugPlay(.suggestion, relativeBearingDeg: 90) }
                    // 3D が効いていれば、正面と真後ろが聴き分けられる(パンでは同じに聞こえる)
                    Button("ビーコン(正面)") { controller.debugPlay(.homeBeacon, relativeBearingDeg: 0) }
                    Button("ビーコン(真後ろ)") { controller.debugPlay(.homeBeacon, relativeBearingDeg: 180) }
                    Button("時間到来") { controller.debugPlay(.timeUpPrompt) }
                    Button("帰路の確認音") { controller.debugPlay(.returnAck) }
                    Button("到着音") { controller.debugPlay(.arrival) }
                }

                // 経路データを配信先から入れる。**手で入れる道は残す**
                // (ファイルを置ける人はそのままでよい)。→ docs/12
                if controller.params.mapDownload.isConfigured {
                    Section("地図を取得") {
                        Button {
                            Task { await controller.downloadMapHere() }
                        } label: {
                            HStack {
                                Text("この辺りの地図を取得(5 km 圏)")
                                if controller.mapDownloading {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(controller.mapDownloading)
                        if !controller.mapDownloadLine.isEmpty {
                            Text(controller.mapDownloadLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("送るのは取得する区画(約 5 km 角)の番号だけです。"
                             + "正確な位置・歩いた経路・自宅は送りません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

                // 経路データは OpenStreetMap 由来。**ODbL は出典表示を求める**ので、
                // 地図を読み込んでいるかによらず常に出す(docs/04「OSM データの持ち方」)
                Section("経路データの出典") {
                    Text("© OpenStreetMap contributors")
                        .font(.caption)
                    Text("この経路データは OpenStreetMap から作成しました。"
                         + "OpenStreetMap のデータは Open Database License (ODbL) の下で提供されています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("openstreetmap.org/copyright",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption)
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
            // 出発の一言。**画面を見るのは開始の瞬間だけ**なので、ここで出して閉じてもらう
            .alert(controller.greeting ?? "",
                   isPresented: Binding(get: { controller.greeting != nil },
                                        set: { if !$0 { controller.greeting = nil } })) {
                Button("はい", role: .cancel) {}
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
