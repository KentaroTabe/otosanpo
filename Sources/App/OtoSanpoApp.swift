import SwiftUI

@main
struct OtoSanpoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            if let controller = model.controller {
                ContentView(controller: controller)
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
