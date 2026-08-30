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
/// PC 側で `scripts/build_map.sh` / `build_maps.sh` が作り、
/// 「ファイル」アプリか Finder で Documents に入れる想定
/// (docs/04「OSM データの持ち方」)。無ければグリッドのみで動く。
///
/// **ファイル名は問わない。** Documents 直下の `.json` を順に試す(→ `MapFiles`)。
/// 名前を固定していたせいで、都市名のまま置いたテスターの端末で
/// 読まれなかった(2026-08-30)。
enum MapStore {
    /// 以前から使っている名前。読む順で最優先されるだけで、**必須ではない**
    static let fileName = MapFiles.preferredName

    static func documentsURL() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    /// Documents 直下に置かれた `.json`。下位ディレクトリ(`map-tiles/`)は見ない
    static func candidates() -> [MapFiles.Candidate] {
        guard let dir = documentsURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey,
                                               .isRegularFileKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json" else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                           .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { return nil }
            return MapFiles.Candidate(name: url.lastPathComponent,
                                      modified: values?.contentModificationDate ?? .distantPast,
                                      sizeBytes: values?.fileSize ?? 0)
        }
    }

    /// 置かれたファイルの指紋。**前面に戻るたびに解き直さない**ための印
    static func fingerprint() -> String { MapFiles.fingerprint(candidates()) }

    enum Outcome {
        case loaded(WalkMap, name: String)
        case failed(MapFiles.Failure)

        var map: WalkMap? {
            if case .loaded(let m, _) = self { return m }
            return nil
        }
    }

    /// 手で入れた地図そのもの。**タイル(TileStore)とどちらを読むかは呼び出し側が決める**。
    ///
    /// 読む順は `MapFiles.order`(正式名 → 新しい順)で、
    /// **最初に解けたもの**を返す。解けなければ理由を返す(画面に出すため)。
    static func loadMap() -> Outcome {
        guard let dir = documentsURL() else { return .failed(.noFile) }
        let ordered = MapFiles.order(candidates())
        if ordered.isEmpty { return .failed(.noFile) }

        var rejected: [String] = []
        for c in ordered {
            let url = dir.appendingPathComponent(c.name)
            guard let data = try? Data(contentsOf: url),
                  let map = try? JSONDecoder().decode(WalkMap.self, from: data) else {
                rejected.append(c.name)
                continue
            }
            return .loaded(map, name: c.name)
        }
        return .failed(.undecodable(rejected))
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
