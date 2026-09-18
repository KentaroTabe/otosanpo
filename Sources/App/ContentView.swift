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
                    // **出発前にしか選べない**(歩き出したら画面は見えない)。
                    // 音源が置かれていない端末には出さない
                    if controller.musicFileAvailable {
                        Toggle("音楽スポットを 1 つ作る(実験)", isOn: $controller.musicSpotWanted)
                        if controller.musicSpotWanted {
                            Text("出発したら散歩時間に応じた距離に 1 つだけ音楽の鳴る場所を作り、"
                                 + "そこから聞こえるように鳴らします。"
                                 + "連続音で方向が伝わるかを試すための実験です")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // **音の向きの基準を、ここで選ぶ**(2026-09-18 利用者依頼)。
                            // 実験ビルドは設定によらず頭部固定を使うので、選択肢を出さずに伝える
                            if controller.params.headMount.enabled {
                                Text("頭部固定: 有効(実験ビルド)。"
                                     + "頭の向きが定まってから鳴り始めます")
                                    .font(.caption.bold())
                            } else {
                                Picker("音の向きの基準", selection: $controller.orientationMode) {
                                    Text("進む向き").tag(OrientationMode.travelDirection)
                                    Text("頭の向き").tag(OrientationMode.phoneHeadMounted)
                                }
                                if controller.orientationMode == .phoneHeadMounted {
                                    Text("スマホを頭に固定してください。"
                                         + "頭の向きが定まってから音楽が鳴り始めます(数分かかることがあります)。"
                                         + "立ち止まっても左右が消えません")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("進む向きを基準にします。"
                                         + "音楽は待たずにすぐ鳴り始めますが、立ち止まると左右が保持値になります")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            // **前後の手がかりの比較用**(2026-09-18)。同じ散歩の中で
                            // 切り替えて聴き比べられるようにする
                            Toggle("後ろの音を暗くする", isOn: $controller.rearDarkening)
                            Text("後ろから鳴っている時だけ高い音を少し落とします。"
                                 + "前後が分かりやすくなるかを確かめるための試みです")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("通勤路の学習モード", isOn: $controller.commuteLearning)
                    if controller.commuteLearning {
                        Text("ON の間の移動経路は「日常の道」として記録され、以後の提案から除外されます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // **既定は OFF。** ON の間だけ現在地が外へ出るので、それを明記する
                    // (2026-09-17 利用者判断)
                    Toggle("通りかかったお店を記録する", isOn: $controller.shopSearchWanted)
                    if controller.shopSearchWanted {
                        Text("ON の間は、周りのお店を調べるために現在地(緯度・経度)を"
                             + "ホットペッパーグルメのサーバへ送ります。"
                             + "歩いた経路・自宅・ログは送りません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("OFF の間は、お店を調べません。現在地が外へ送られることもありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("案内音") {
                        GuidanceSoundView(controller: controller)
                    }
                    // **真横に聞こえる角度は人によって違う**(2026-09-18 利用者依頼)。
                    // つまみ 1 本で周りを回し、真横に感じた所を印にしてもらう。
                    // **入れ子の HStack を label に置かない** — この body は既に大きく、
                    // 型検査が重くなる(SourceKit が時間切れを警告した)
                    NavigationLink("真横に聞こえる角度") {
                        EarAngleMapView(controller: controller)
                    }
                    Text(controller.earAngleMap == nil
                         ? "未設定(置きたい角度をそのまま置きます)"
                         : "設定済み(合わせた角度へ置きます)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                // 歩いている最中は見ない体験なので、帰ってから 1 回分を振り返る。
                if let s = controller.lastSummary {
                    if let receipt = WalkReceiptContent(
                        summary: s,
                        discoverySummary: controller.lastDiscoverySummary,
                        shopHistoryRecords: controller.shopHistoryRecords) {
                        WalkReceiptView(content: receipt,
                                        shopSearchOn: controller.shopSearchWanted,
                                        marginM: controller.params.summary.mapMarginM,
                                        minSpanM: controller.params.summary.mapMinSpanM,
                                        roadsProvider: { controller.roadSegments(in: $0) })
                    } else {
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
                }

                Section("街の発見MAP") {
                    LabeledContent("通った店", value: "\(controller.shopHistoryRecords.count) 軒")
                    NavigationLink("通った店をMAPで見る") {
                        ShopMapView(records: controller.shopHistoryRecords)
                    }
                }

                // 「頭の追従の確認(机上)」と「時間到来の発火」は削除した
                // (2026-09-17 利用者判断: もう要らない)。earcon の試聴は
                // 「案内音」の画面へ移した(上の「設定」から開く)

                // **散歩に出てよいかの判定**(→ docs/05 の前提条件)。実験ビルドだけに出す。
                // build-demo/ab-*.wav でも同じ並びを聴けるが、あちらは等パワーのパンによる
                // 近似で、実機の HRTF とは経路が違う。**判定は判定したい経路で行う**
                if controller.params.headMount.enabled {
                    Section("左右の聴き比べ(実験・AirPods 装着)") {
                        Button("ビーコンで聴き比べる") {
                            controller.debugPlayABComparison(.homeBeacon)
                        }
                        Button("提案音で聴き比べる") {
                            controller.debugPlayABComparison(.suggestion)
                        }
                        // Text の markdown はリテラルにしか効かない。連結した文字列では
                        // 記号がそのまま出るので、強調は行を分けて font で付ける
                        Text("後半で左右がはっきり分かれないなら、散歩に出ないでください。")
                            .font(.caption.bold())
                        Text("前半 4 音が配布版(純音)、後半 4 音が実験値(倍音とアタック)。"
                             + "各 左・右・左・右。方向が聴き取れない音のままでは、"
                             + "頭部固定の良否と音素材の良否を分けられません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        Text("地図取得で送るのは取得する区画(約 5 km 角)の番号だけです。"
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

                // 直近のイベントの生表示も開発用(テスターはログの書き出しで送る)
                #if DEBUG
                Section("イベントログ") {
                    ForEach(Array(controller.eventLog.suffix(12).reversed().enumerated()),
                            id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                #endif

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
