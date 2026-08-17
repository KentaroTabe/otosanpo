import Foundation

/// config/parameters.json の読み込み。
/// フォールバック値をコードに持たない(数値の二重管理を避ける)。失敗時は UI にエラー表示。
enum ConfigLoader {
    enum ConfigError: LocalizedError {
        case missingResource
        var errorDescription: String? { "parameters.json がバンドルに見つかりません" }
    }

    static func load() throws -> AppParameters {
        guard let url = Bundle.main.url(forResource: "parameters", withExtension: "json") else {
            throw ConfigError.missingResource
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> AppParameters {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AppParameters.self, from: data)
    }
}

/// 通過履歴グリッドの永続化。端末内(Application Support)にのみ保存し、送信しない。
enum GridStore {
    static func fileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("visit_grid.json")
    }

    static func load(cellSizeM: Double, halfLifeDays: Double) -> VisitGrid {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let grid = try? JSONDecoder().decode(VisitGrid.self, from: data) else {
            return VisitGrid(cellSizeM: cellSizeM, halfLifeDays: halfLifeDays)
        }
        return grid
    }

    static func save(_ grid: VisitGrid) {
        guard let url = try? fileURL(),
              let data = try? JSONEncoder().encode(grid) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 自宅座標の永続化(UserDefaults)
/// 経路データ(WalkMap)の読み込み。
/// Documents に置かれたファイルを読むだけで、取得も生成も行わない。
/// PC 側で `scripts/build_map.sh` が作り、Finder で Documents に入れる想定
/// (docs/04「OSM データの持ち方」)。無ければグリッドのみで動く。
enum MapStore {
    static let fileName = "otosanpo-map.json"

    static func fileURL() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
            .appendingPathComponent(fileName)
    }

    static func load(cellSizeM: Double) -> WalkGraph? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode(WalkMap.self, from: data) else { return nil }
        return WalkGraph(map: map, cellSizeM: cellSizeM)
    }
}

enum HomeStore {
    private static let key = "home_point"

    static func load() -> GeoPoint? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GeoPoint.self, from: data)
    }

    static func save(_ p: GeoPoint) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
