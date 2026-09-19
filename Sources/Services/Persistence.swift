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

/// 音楽スポットで鳴らす音源(→ Core の MusicSpot・docs/08)。
///
/// **リポジトリにもアプリにも同梱しない。** 地図と同じく Documents
/// (Finder の「iPhone > ファイル」)に置いたものを読む。理由は 2 つ:
///
/// - **権利の話をリポジトリに持ち込まない**(→ docs/15)。実験用の BGM は
///   その場で差し替わるもので、コミットして配るものではない
/// - 曲を変えるのにビルドが要らない
///
/// 名前は問わない(地図の `MapFiles` と同じ考え方)。**並びを名前順に固定する**ので、
/// 同じ端末なら毎回同じ曲が選ばれる
enum MusicStore {
    static func documentsURL() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    /// Documents にある音源のうち、名前順で最初のもの。無ければ nil。
    ///
    /// **読める拡張子は設定から渡す**(2026-09-19)。Swift と Kotlin で別々に持つと
    /// 必ずずれるので、`config/parameters.json` の `audio.music_source_extensions`
    /// 1 か所だけに置く(→ docs/08「音源の形式」)。
    /// 再生そのものは `AVAudioFile` 任せで形式に依存しない
    static func firstFile(extensions: [String]) -> URL? {
        guard let dir = documentsURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        let allowed = Set(extensions.map { $0.lowercased() })
        return names
            .filter { allowed.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .first
            .map { dir.appendingPathComponent($0) }
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

/// 直近の散歩で見つけたものの永続化。`WalkSummary` と同じライフサイクルで 1 件だけ残す。
enum DiscoverySummaryStore {
    static func fileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("walk_discovery_summary.json")
    }

    static func load() -> WalkDiscoverySummary? {
        guard let url = try? fileURL() else { return nil }
        return load(from: url)
    }

    static func load(from url: URL) -> WalkDiscoverySummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkDiscoverySummary.self, from: data)
    }

    static func save(_ s: WalkDiscoverySummary) {
        guard let url = try? fileURL() else { return }
        save(s, to: url)
    }

    static func save(_ s: WalkDiscoverySummary, to url: URL) {
        guard let data = try? JSONEncoder().encode(s) else { return }
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
    /// **最初に受け入れられたもの**を返す。受け入れの条件は 3 つ:
    ///
    /// 1. **サイズが上限以内**(`maxBytes`)。名前を問わず読むので、巨大な無関係の
    ///    JSON を全部メモリへ読んでから捨てる、をしない(読む前に候補の実測サイズで拒む)
    /// 2. `WalkMap` として解けること
    /// 3. **中身が健全なこと**(`WalkMap.integrityIssue`)。形だけ合う別物の JSON が
    ///    「存在しない節点を指す道」を持っていると、散歩開始の場の構築で落ちる
    ///
    /// 受け入れられなければ理由つきで返す(画面に出すため)。
    static func loadMap(maxBytes: Int) -> Outcome {
        guard let dir = documentsURL() else { return .failed(.noFile) }
        let ordered = MapFiles.order(candidates())
        if ordered.isEmpty { return .failed(.noFile) }

        var rejected: [String] = []
        for c in ordered {
            if c.sizeBytes > maxBytes {
                rejected.append("\(c.name)(\(c.sizeBytes / 1_000_000)MB・上限超)")
                continue
            }
            let url = dir.appendingPathComponent(c.name)
            guard let data = try? Data(contentsOf: url),
                  let map = try? JSONDecoder().decode(WalkMap.self, from: data) else {
                rejected.append(c.name)
                continue
            }
            if let issue = map.integrityIssue() {
                rejected.append("\(c.name)(\(issue))")
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

/// 画面で選ぶ設定の永続化(端末内・UserDefaults)。
///
/// 散歩ごとに選び直させないためのもの。**外へ何かを送る設定は、既定を「送らない」側に置く**
enum SettingStore {
    /// 通りかかった店を調べるか。**既定は false**(現在地を外へ送らない側・2026-09-17 利用者判断)
    private static let shopSearchKey = "shop_search_enabled"
    /// 案内音に倍音を足すか。**未設定(nil)ならビルドの既定に従う**
    private static let guidanceToneKey = "guidance_tone_experimental"
    /// 音の向きの基準(→ Core の OrientationMode)。**既定は進む向き**(配布版の従来どおり)
    private static let orientationModeKey = "orientation_mode"
    /// 後ろの音を暗くするか。前後の手がかりの比較用(2026-09-18)
    private static let rearDarkeningKey = "rear_darkening"
    /// 真横に聞こえる角度の初期設定(→ Core の EarAngleMap・2026-09-18)
    private static let earAngleMapKey = "ear_angle_map"

    /// 保存先を差し替えられるようにしてあるのは、テストが**本物の設定を汚さない**ため
    static func loadShopSearchEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: shopSearchKey)   // 未設定は false
    }

    static func saveShopSearchEnabled(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: shopSearchKey)
    }

    /// nil = まだ選んでいない(実験ビルドなら倍音、配布ビルドなら元の音)
    static func loadGuidanceToneExperimental(from defaults: UserDefaults = .standard) -> Bool? {
        guard defaults.object(forKey: guidanceToneKey) != nil else { return nil }
        return defaults.bool(forKey: guidanceToneKey)
    }

    static func saveGuidanceToneExperimental(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: guidanceToneKey)
    }

    /// **既定は進む向き。** 頭部固定は利用者が選んだ時だけ使う(2026-09-18 利用者依頼)
    static func loadOrientationMode(from defaults: UserDefaults = .standard) -> OrientationMode {
        guard let raw = defaults.string(forKey: orientationModeKey),
              let mode = OrientationMode(rawValue: raw) else { return .travelDirection }
        return mode
    }

    static func saveOrientationMode(_ mode: OrientationMode,
                                    to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: orientationModeKey)
    }

    /// **既定は暗くする。** 前後が分からないという感想への手当て(2026-09-18)。
    /// 比較のために画面から切れる
    static func loadRearDarkening(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: rearDarkeningKey) != nil else { return true }
        return defaults.bool(forKey: rearDarkeningKey)
    }

    static func saveRearDarkening(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: rearDarkeningKey)
    }

    /// **真横に聞こえる角度の初期設定**(→ Core の EarAngleMap・2026-09-18 利用者依頼)。
    ///
    /// **未校正は nil。** その時は置きたい角度をそのまま置く。
    /// 範囲外・壊れた値は校正済みとして扱わない
    static func loadEarAngleMap(from defaults: UserDefaults = .standard) -> EarAngleMap? {
        guard let data = defaults.data(forKey: earAngleMapKey),
              let cal = try? JSONDecoder().decode(EarAngleMap.self, from: data),
              cal.isValid else { return nil }
        return cal
    }

    /// 保存する。**範囲外は保存しない**(端に張り付いた値を成功として残さない)
    @discardableResult
    static func saveEarAngleMap(_ cal: EarAngleMap,
                                to defaults: UserDefaults = .standard) -> Bool {
        guard cal.isValid, let data = try? JSONEncoder().encode(cal) else { return false }
        defaults.set(data, forKey: earAngleMapKey)
        return true
    }

    /// 校正を捨てる(そのままの角度で置く形へ戻す)
    static func clearEarAngleMap(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: earAngleMapKey)
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
