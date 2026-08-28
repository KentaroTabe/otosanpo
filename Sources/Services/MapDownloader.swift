import Foundation

/// 端末に落としたタイルの置き場(Documents/map-tiles)。
///
/// **手で入れる地図(`otosanpo-map.json`)とは別の場所に置く。**
/// 20 km 円のファイルを配っていた時期があり、それを持つ端末で取得しても
/// **上書きの衝突が起きない**ようにするため(どちらを読むかは `MapSource` が決める)。
enum TileStore {
    static let directoryName = "map-tiles"
    static let metaFileName = "meta.json"

    /// 配信の約束ごと。**タイル角は配信側(meta.json)が宣言する。**
    /// アプリ側に同じ数値を持つと、配信を作り直した時に黙って食い違う
    struct Meta: Codable, Equatable {
        var tileSizeDeg: Double
        var generated: String

        enum CodingKeys: String, CodingKey {
            case tileSizeDeg = "tile_size_deg"
            case generated
        }
    }

    static func directory() -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        let dir = docs.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveMeta(_ meta: Meta) {
        guard let dir = directory(),
              let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: dir.appendingPathComponent(metaFileName), options: .atomic)
    }

    static func loadMeta() -> Meta? {
        guard let dir = directory(),
              let data = try? Data(contentsOf: dir.appendingPathComponent(metaFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func save(_ data: Data, id: MapTiles.TileID) throws {
        guard let dir = directory() else { return }
        try data.write(to: dir.appendingPathComponent(MapTiles.fileName(id)), options: .atomic)
    }

    /// 端末にあるタイルの番号一覧(ファイル名から復元する)
    static func storedIDs() -> [MapTiles.TileID] {
        guard let dir = directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.compactMap { MapTiles.id(fromFileName: $0) }
    }

    /// 端末にあるタイルを全部読んで 1 つの地図に組む。無ければ nil。
    /// **壊れたタイルは黙って飛ばす**(1 枚のために全体を失わない)
    static func loadAssembled() -> WalkMap? {
        guard let dir = directory() else { return nil }
        let maps: [WalkMap] = storedIDs().compactMap { id in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(MapTiles.fileName(id)))
            else { return nil }
            return try? JSONDecoder().decode(WalkMap.self, from: data)
        }
        return MapTiles.assemble(maps)
    }
}

/// 配信先からタイルを取ってくる。**このアプリで唯一、外へ出る通信。**
///
/// 何を送るか(→ docs/12):
///
/// - **取得する区画(タイル)の番号。** 粒度は約 5 km 角。
///   ここから「その辺りに居る」ことは配信先に分かる。**正確な座標は載らない**
/// - 一覧や認証は無い。`meta.json` とタイルの GET だけ
///
/// 送らないもの: **正確な位置・歩いた経路・自宅・フィールドログ。**
/// 端末を識別できるヘッダも足さない(既定の User-Agent のみ)。
enum MapDownloader {

    enum Failure: LocalizedError {
        case badURL(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badURL(let s): "配信先の URL が正しくありません: \(s)"
            case .http(let code): "配信先から取得できませんでした(HTTP \(code))"
            }
        }
    }

    struct Result {
        var saved: Int
        /// 404 だった枚数 = その区画に道のデータが無い(海・データ範囲外)。失敗ではない
        var empty: Int
    }

    /// 配信の約束ごとを取る。タイル角はここで決まる
    static func meta(baseURL: String, timeoutSec: Double) async throws -> TileStore.Meta {
        let data = try await get(url(baseURL, TileStore.metaFileName), timeoutSec: timeoutSec)
        let meta = try JSONDecoder().decode(TileStore.Meta.self, from: data)
        TileStore.saveMeta(meta)
        return meta
    }

    /// タイルを順に落として保存する。
    ///
    /// - **404 は「その区画に道が無い」**(海・データ範囲外)。失敗として扱わない
    /// - 中身が `WalkMap` として読めたものだけ保存する。壊れた JSON を端末に残さない
    static func download(_ ids: [MapTiles.TileID], baseURL: String, timeoutSec: Double,
                         onProgress: @MainActor (Int, Int) -> Void) async throws -> Result {
        var result = Result(saved: 0, empty: 0)
        for (i, id) in ids.enumerated() {
            await onProgress(i, ids.count)
            do {
                let data = try await get(url(baseURL, MapTiles.fileName(id)),
                                         timeoutSec: timeoutSec)
                _ = try JSONDecoder().decode(WalkMap.self, from: data)
                try TileStore.save(data, id: id)
                result.saved += 1
            } catch Failure.http(404) {
                result.empty += 1
            }
        }
        await onProgress(ids.count, ids.count)
        return result
    }

    // MARK: - 内部

    private static func url(_ base: String, _ path: String) throws -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let u = URL(string: "\(trimmed)/\(path)") else { throw Failure.badURL(base) }
        return u
    }

    private static func get(_ url: URL, timeoutSec: Double) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSec
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        return data
    }
}
