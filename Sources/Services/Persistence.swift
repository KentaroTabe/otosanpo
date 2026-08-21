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

    static func load(cellSizeM: Double, halfLifeM: Double) -> VisitGrid {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              var grid = try? JSONDecoder().decode(VisitGrid.self, from: data) else {
            return VisitGrid(cellSizeM: cellSizeM, halfLifeM: halfLifeM)
        }
        // 設定ファイルを正とする(保存された値は読み込み時点のもので、古くなりうる)。
        // 積算距離と各セルの記録はそのまま引き継ぐ
        grid.cellSizeM = cellSizeM
        grid.halfLifeM = halfLifeM
        return grid
    }

    static func save(_ grid: VisitGrid) {
        guard let url = try? fileURL(),
              let data = try? JSONEncoder().encode(grid) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 直近の散歩の記録の永続化。VisitGrid と同じく**端末内にのみ保存**する。
/// アプリを閉じても前回の経路図を開けるようにするため(開発中の振り返り用)
enum SummaryStore {
    static func fileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("walk_summary.json")
    }

    static func load() -> WalkSummary? {
        guard let url = try? fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkSummary.self, from: data)
    }

    static func save(_ s: WalkSummary) {
        guard let url = try? fileURL(), let data = try? JSONEncoder().encode(s) else { return }
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

/// 歩行速度の推定の永続化。VisitGrid と同じく**端末内にのみ保存**する
enum SpeedStore {
    private static let key = "speed_estimator"

    static func load() -> SpeedEstimator {
        guard let data = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode(SpeedEstimator.self, from: data) else {
            return SpeedEstimator()
        }
        return e
    }

    static func save(_ e: SpeedEstimator) {
        if let data = try? JSONEncoder().encode(e) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
