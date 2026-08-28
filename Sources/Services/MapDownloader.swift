import Foundation

/// 配信先から経路データを取ってきて Documents に置く。
///
/// **このアプリで唯一、外へ出る通信。** 何を送るかを狭く保つ:
///
/// - 送るのは**利用者が自分で選んだ都市のファイル名**だけ
/// - **位置・歩いた経路・自宅・フィールドログは送らない**
/// - 一覧(`index.json`)の取得も、位置を含まない
///
/// 「記録は端末から出ない」という約束は維持される(→ docs/12)。
///
/// 置き場所は `MapStore` と同じ Documents。**手で入れたファイルと同じ扱い**にして、
/// 読み込み側(`MapStore.load`)に分岐を持ち込まない。
enum MapDownloader {

    enum Failure: LocalizedError {
        case badURL(String)
        case http(Int)
        case emptyCatalog

        var errorDescription: String? {
            switch self {
            case .badURL(let s): "配信先の URL が正しくありません: \(s)"
            case .http(let code): "配信先から取得できませんでした(HTTP \(code))"
            case .emptyCatalog: "配信されている地図がありません"
            }
        }
    }

    /// 一覧を取る。**位置は送らない**
    static func catalog(baseURL: String, timeoutSec: Double) async throws -> MapCatalog {
        let data = try await get(url(baseURL, "index.json"), timeoutSec: timeoutSec)
        let catalog = try JSONDecoder().decode(MapCatalog.self, from: data)
        guard !catalog.cities.isEmpty else { throw Failure.emptyCatalog }
        return catalog
    }

    /// 1 都市ぶんを落として Documents に置く。**成功したときだけ置き換える**
    /// (途中で切れた地図を残すと、次の起動で壊れた地図を読むことになる)
    static func download(_ entry: MapCatalog.Entry, baseURL: String,
                         timeoutSec: Double) async throws {
        let data = try await get(url(baseURL, entry.file), timeoutSec: timeoutSec)
        // 中身が読めることを確かめてから置く。壊れた JSON を置かない
        _ = try JSONDecoder().decode(WalkMap.self, from: data)
        guard let dest = MapStore.fileURL() else { throw Failure.badURL(baseURL) }
        try data.write(to: dest, options: .atomic)
    }

    // MARK: - 内部

    private static func url(_ base: String, _ path: String) throws -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        // 都市名は日本語なので、そのままでは URL に載らない
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let u = URL(string: "\(trimmed)/\(escaped)") else { throw Failure.badURL(base) }
        return u
    }

    private static func get(_ url: URL, timeoutSec: Double) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSec
        // 端末の識別に使えるものを足さない。既定の User-Agent のみ
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        return data
    }
}
