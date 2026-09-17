import SwiftUI

/// ホットペッパーグルメ Webサービスの**提供元表示**。
///
/// 利用規約が「利用者のアプリケーション上またはアプリケーション内に表示される本サイト内の
/// 情報が、リクルートより提供されたものである旨を表示すること」を求めている
/// (2026-09-17 に規約を確認)。**店舗の情報を出す画面にはこれを添える。**
///
/// 文言を 1 か所に置くのは、画面ごとに違う名前で出さないため
/// (地図の上では `ShopMapView` が同じ文字を丸い背景に載せて出す)。
struct ShopCreditLabel: View {
    /// 表示する文言。地図の上の表示と共通
    static let text = "Powered by ホットペッパーグルメ Webサービス"

    var body: some View {
        Text(Self.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
