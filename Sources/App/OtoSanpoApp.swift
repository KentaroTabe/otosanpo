import SwiftUI

@main
struct OtoSanpoApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let controller = model.controller {
                ContentView(controller: controller)
                    // **「ファイル」アプリから戻ってきた時に地図を読み直す。**
                    // 地図は起動時にしか読んでいなかったので、アプリを開いたまま
                    // ファイルを保存した人は、完全に終了して開き直すまで
                    // 「未読込」のままだった(2026-08-30)。
                    // 実際に読み直すのはファイルが変わっていた時だけ(→ 同名の関数)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { controller.refreshMapIfFilesChanged() }
                    }
            } else {
                VStack(spacing: 12) {
                    Text("起動エラー").font(.headline)
                    Text(model.errorText).font(.caption)
                }
                .padding()
            }
        }
    }
}

/// 設定の読み込みに失敗した場合はフォールバックせずエラーを表示する
/// (数値をコード側に二重に持たないため)。
@MainActor
final class AppModel: ObservableObject {
    let controller: WalkSessionController?
    let errorText: String

    init() {
        do {
            let params = try ConfigLoader.load()
            controller = WalkSessionController(params: params)
            errorText = ""
        } catch {
            controller = nil
            errorText = "config/parameters.json の読み込みに失敗しました: \(error.localizedDescription)"
        }
    }
}
