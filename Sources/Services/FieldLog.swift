import Foundation

/// フィールドテスト用の追記ログ。
/// 散歩中は画面を見られないため、閾値調整の材料は後から取り出せる形で残す必要がある。
/// - 保存先は Documents。Info.plist の UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace により
///   Finder(iPhone のファイル)や Files アプリから取り出せる。ContentView の共有ボタンでも書き出せる
/// - 端末内にのみ保存し、送信はしない(docs/04 プライバシー)
/// - TSV: 時刻 / 状態 / 緯度 / 経度 / メッセージ
final class FieldLog {
    static let fileName = "otosanpo-field-log.tsv"
    private static let header = "time\tstate\tlat\tlon\tmessage\n"

    private let queue = DispatchQueue(label: "dev.otosanpo.fieldlog")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func fileURL() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }

    func append(state: String, position: GeoPoint?, message: String, date: Date = Date()) {
        let line = [
            formatter.string(from: date),
            state,
            position.map { String(format: "%.6f", $0.latitude) } ?? "",
            position.map { String(format: "%.6f", $0.longitude) } ?? "",
            message.replacingOccurrences(of: "\t", with: " ")
        ].joined(separator: "\t") + "\n"

        queue.async {
            guard let url = Self.fileURL(), let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? (Self.header + line).data(using: .utf8)?.write(to: url, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// 次のテストのために消す(セッション間の切り分けを楽にする)
    func clear() {
        queue.async {
            guard let url = Self.fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
