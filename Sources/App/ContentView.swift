import SwiftUI
import UniformTypeIdentifiers

/// この画面はセットアップとデバッグのためのもの。
/// 散歩が始まったら iPhone はポケットに入れ、以後は音とジェスチャだけで完結するのが本来の体験。
struct ContentView: View {
    @ObservedObject var controller: WalkSessionController
    /// 左上のメニュー(2026-09-19 利用者依頼)。毎回は触らない設定とログを入れてある
    @State private var showMenu = false
    /// 音楽スポットに使う曲を選ぶピッカー
    @State private var showMusicPicker = false

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
                    // 曲が選ばれていない端末には、選ぶ導線だけを出す
                    if let name = controller.musicSourceName {
                        Toggle("音楽スポットを 1 つ作る(実験)", isOn: $controller.musicSpotWanted)
                        LabeledContent("曲", value: name)
                        Button("曲を選び直す") { showMusicPicker = true }
                        if controller.musicSpotWanted {
                            Text("出発したら散歩時間に応じた距離に 1 つだけ音楽の鳴る場所を作り、"
                                 + "そこから聞こえるように鳴らします。"
                                 + "連続音で方向が伝わるかを試すための実験です")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // **向きの基準は進む向きだけ**(2026-09-19 利用者判断)。
                            // 頭の向きを使う道は画面から外した(実験はビルドの設定から)
                            if controller.params.headMount.enabled {
                                Text("頭部固定: 有効(実験ビルド)。"
                                     + "頭の向きが定まってから鳴り始めます")
                                    .font(.caption.bold())
                            }
                        }
                    } else {
                        Button("音楽スポットに使う曲を選ぶ") { showMusicPicker = true }
                        Text("端末に入っている曲を 1 つ選びます。"
                             + "選んだ曲はアプリの中へ写すので、あとで元を消しても鳴ります")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // **通勤路の学習モードは画面から外した**(2026-09-19 利用者判断)。
                    // 実験できていない機能を出しておくと、試された時に結果を読めない
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
                    // 案内音・真横に聞こえる角度は**左上のメニュー**へ移した
                    // (2026-09-19 利用者依頼。毎回は触らないため)
                }

                Section {
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

                // 試聴・聴き比べ・ログ・クレジットは**左上のメニュー**へ移した
                // (2026-09-19 利用者依頼)

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

                // ログは**左上のメニュー**の「記録」へ移した(2026-09-19 利用者依頼)。
                // 経路データは OpenStreetMap 由来で、**ODbL は出典表示を求める**ので、
                // 詳しい文面はメニューの「クレジット」に置きつつ、ここに 1 行だけ残す
                // (docs/04「OSM データの持ち方」)
                Section {
                    Text("© OpenStreetMap contributors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button("OK", role: .cancel) {}
            }
            // 左上のメニュー(2026-09-19 利用者依頼)。毎回は触らない設定とログを入れてある
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMenu = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("メニュー")
                }
            }
            .sheet(isPresented: $showMenu) {
                MenuView(controller: controller)
            }
            // **選んだ曲はその場でアプリの中へ写す**(→ MusicStore.importFile)
            .fileImporter(isPresented: $showMusicPicker,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    controller.chooseMusicSource(url)
                }
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
