import Foundation

/// 店舗候補の取得口。Hot Pepper API などの本接続はこの protocol の実装として差し替える。
protocol ShopCandidateProviding {
    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop]
    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop]
}

/// API 未接続の間に使う空の候補取得。既存の散歩機能には影響しない。
struct EmptyShopCandidateProvider: ShopCandidateProviding {
    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] { [] }
    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] { [] }
}

protocol ShopHistoryStoring {
    func load() -> ShopHistory
    func save(_ history: ShopHistory)
}

/// 店舗履歴の永続化。端末内(Application Support)にのみ保存し、外部へ送信しない。
struct LocalShopHistoryStore: ShopHistoryStoring {
    private let overrideURL: URL?

    init(fileURL: URL? = nil) {
        overrideURL = fileURL
    }

    func fileURL() throws -> URL {
        if let overrideURL { return overrideURL }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true)
        return dir.appendingPathComponent("shop_history.json")
    }

    func load() -> ShopHistory {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(ShopHistory.self, from: data) else {
            return ShopHistory()
        }
        return history
    }

    func save(_ history: ShopHistory) {
        guard let url = try? fileURL(),
              let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 店舗候補の取得と通過履歴の更新をつなぐサービス層。
final class ShopHistoryService: @unchecked Sendable {
    struct Settings: Equatable, Sendable {
        var passageRadiusM: Double
        var searchRadiusM: Double
        var maxHorizontalAccuracyM: Double

        init(passageRadiusM: Double = ShopPassageRules.defaultPassageRadiusM,
             searchRadiusM: Double = ShopPassageRules.defaultSearchRadiusM,
             maxHorizontalAccuracyM: Double = ShopPassageRules.defaultMaxHorizontalAccuracyM) {
            self.passageRadiusM = passageRadiusM
            self.searchRadiusM = searchRadiusM
            self.maxHorizontalAccuracyM = maxHorizontalAccuracyM
        }
    }

    struct CacheArea: Hashable, Sendable {
        var latIndex: Int
        var lonIndex: Int
    }

    private let provider: ShopCandidateProviding
    private let store: ShopHistoryStoring
    let settings: Settings
    private let lock = NSLock()
    private var state: State

    var history: ShopHistory {
        lock.withLock { state.history }
    }

    private struct State {
        var history: ShopHistory
        var cacheByArea: [CacheArea: [Shop]] = [:]
        var routeCache: [String: Shop] = [:]
    }

    init(provider: ShopCandidateProviding,
         store: ShopHistoryStoring,
         settings: Settings = Settings()) {
        self.provider = provider
        self.store = store
        self.settings = settings
        state = State(history: store.load())
    }

    func startSession() -> ShopPassageSession {
        ShopPassageSession()
    }

    func refreshCache(around position: GeoPoint) async {
        let area = Self.cacheArea(containing: position, searchRadiusM: settings.searchRadiusM)
        if lock.withLock({ state.cacheByArea[area] != nil }) { return }
        guard let shops = try? await provider.shops(near: position,
                                                    searchRadiusM: settings.searchRadiusM) else {
            return
        }
        lock.withLock {
            state.cacheByArea[area] = shops
        }
    }

    func refreshCache(along route: [GeoPoint]) async {
        guard !route.isEmpty else { return }
        guard let shops = try? await provider.shops(along: route,
                                                    searchRadiusM: settings.searchRadiusM) else {
            return
        }
        lock.withLock {
            for shop in shops { state.routeCache[shop.shopID] = shop }
        }
    }

    @discardableResult
    func recordCachedPassages(near position: GeoPoint,
                              horizontalAccuracyM: Double?,
                              session: inout ShopPassageSession,
                              at date: Date = Date()) -> [ShopPassageUpdate] {
        let candidates = cachedCandidates()
        return updateHistory { history in
            history.recordPassages(near: position,
                                   horizontalAccuracyM: horizontalAccuracyM,
                                   candidates: candidates,
                                   session: &session,
                                   at: date,
                                   radiusM: settings.passageRadiusM,
                                   maxHorizontalAccuracyM: settings.maxHorizontalAccuracyM)
        }
    }

    @discardableResult
    func recordCachedPassages(along route: [TimedGeoPoint],
                              session: inout ShopPassageSession,
                              fallbackDate: Date = Date()) -> [ShopPassageUpdate] {
        let candidates = cachedCandidates()
        return updateHistory { history in
            history.recordPassages(along: route,
                                   candidates: candidates,
                                   session: &session,
                                   fallbackDate: fallbackDate,
                                   radiusM: settings.passageRadiusM)
        }
    }

    private func cachedCandidates() -> [Shop] {
        lock.withLock {
            var byID = state.routeCache
            for shops in state.cacheByArea.values {
                for shop in shops { byID[shop.shopID] = shop }
            }
            return Array(byID.values)
        }
    }

    private func updateHistory(_ body: (inout ShopHistory) -> [ShopPassageUpdate])
        -> [ShopPassageUpdate] {
        let result = lock.withLock { () -> (updates: [ShopPassageUpdate], history: ShopHistory?) in
            let updates = body(&state.history)
            return (updates, updates.isEmpty ? nil : state.history)
        }
        if let history = result.history { store.save(history) }
        return result.updates
    }

    static func cacheArea(containing position: GeoPoint, searchRadiusM: Double) -> CacheArea {
        let cellM = max(searchRadiusM, 1)
        let latIndex = Int(floor(position.latitude * Geo.metersPerDegreeLat / cellM))
        let lonScale = Geo.metersPerDegreeLat * cos(position.latitude * .pi / 180)
        let lonIndex = Int(floor(position.longitude * max(lonScale, 1) / cellM))
        return CacheArea(latIndex: latIndex, lonIndex: lonIndex)
    }
}
