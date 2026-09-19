import SwiftUI

/// 左上のメニュー(2026-09-19 利用者依頼)。
///
/// **毎回設定するものは主画面、そうでないものはここ**、という分け方にする。
/// 散歩の前に触るのは「散歩時間」「音楽スポット」「お店の記録」だけで、
/// 音色や左右の合わせ方は一度決めたら変えない。主画面に並べると、
/// 出発前に見るものが埋もれる。
///
/// ログもここへ置く(主画面は「出発前に見るだけ」に保つ)。
struct MenuView: View {
    @ObservedObject var controller: WalkSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("音の設定") {
                    NavigationLink("案内音") {
                        GuidanceSoundView(controller: controller)
                    }
                    NavigationLink("真横に聞こえる角度") {
                        EarAngleMapView(controller: controller)
                    }
                    Text(controller.earAngleMap == nil
                         ? "未設定(置きたい角度をそのまま置きます)"
                         : "設定済み(合わせた角度へ置きます)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // **前後の手がかりの比較用**(2026-09-18)。一度決めたら変えない類なのでここへ
                    Toggle("後ろの音を暗くする", isOn: $controller.rearDarkening)
                    Text("後ろから鳴っている時だけ高い音を少し落とします。"
                         + "前後が分かりやすくなるかを確かめるための試みです")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("記録") {
                    NavigationLink("フィールドログ") {
                        FieldLogView(controller: controller)
                    }
                    #if DEBUG
                    NavigationLink("イベントログ") {
                        EventLogView(controller: controller)
                    }
                    #endif
                }

                // **散歩に出てよいかの判定**(→ docs/05 の前提条件)。実験ビルドだけに出す
                if controller.params.headMount.enabled {
                    Section("左右の聴き比べ(実験・AirPods 装着)") {
                        Button("ビーコンで聴き比べる") {
                            controller.debugPlayABComparison(.homeBeacon)
                        }
                        Button("提案音で聴き比べる") {
                            controller.debugPlayABComparison(.suggestion)
                        }
                        Text("後半で左右がはっきり分かれないなら、散歩に出ないでください。")
                            .font(.caption.bold())
                        Text("前半 4 音が配布版(純音)、後半 4 音が実験値(倍音とアタック)。"
                             + "各 左・右・左・右")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("クレジット") {
                    // 経路データは OpenStreetMap 由来。**ODbL は出典表示を求める**
                    // (docs/04「OSM データの持ち方」)。主画面にも 1 行残してある
                    Text("© OpenStreetMap contributors")
                        .font(.caption)
                    Text("この経路データは OpenStreetMap から作成しました。"
                         + "OpenStreetMap のデータは Open Database License (ODbL) の下で"
                         + "提供されています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("openstreetmap.org/copyright",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption)
                    ShopCreditLabel()
                }
            }
            .navigationTitle("メニュー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// フィールドログの画面(2026-09-19 に主画面から分けた)
struct FieldLogView: View {
    @ObservedObject var controller: WalkSessionController

    var body: some View {
        Form {
            Section {
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
            } footer: {
                Text("提案・ビーコン・ジェスチャ検出を端末内のファイルに追記します"
                     + "(送信しません)。Finder の「iPhone > ファイル」からも取り出せます")
            }
        }
        .navigationTitle("フィールドログ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 直近のイベントの生表示(開発用。テスターはログの書き出しで送る)
struct EventLogView: View {
    @ObservedObject var controller: WalkSessionController

    var body: some View {
        List {
            ForEach(Array(controller.eventLog.suffix(200).reversed().enumerated()),
                    id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        }
        .navigationTitle("イベントログ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
