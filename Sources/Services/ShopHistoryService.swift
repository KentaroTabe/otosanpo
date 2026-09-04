import Foundation

/// 店舗候補の取得口。Hot Pepper API などの本接続はこの protocol の実装として差し替える。
protocol ShopCandidateProviding: Sendable {
    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop]
    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop]
}

/// API 未接続の間に使う空の候補取得。既存の散歩機能には影響しない。
struct EmptyShopCandidateProvider: ShopCandidateProviding {
    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] { [] }
    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] { [] }
}

protocol ShopHistoryStoring: Sendable {
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
actor ShopHistoryService {
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

    struct SearchRegion: Equatable, Sendable {
        var center: GeoPoint
        var searchRadiusM: Double

        func covers(_ position: GeoPoint, passageRadiusM: Double) -> Bool {
            Geo.distanceM(center, position) < searchRadiusM - passageRadiusM
        }
    }

    private struct CachedRegion: Sendable {
        var region: SearchRegion
        var shops: [Shop]
    }

    private struct PendingRegion: Sendable {
        var region: SearchRegion
        var task: Task<[Shop], Error>
    }

    private let provider: ShopCandidateProviding
    private let store: ShopHistoryStoring
    let settings: Settings

    private var history: ShopHistory
    private var session = ShopPassageSession()
    private var verifiedRoute: [TimedGeoPoint] = []
    private var cachedRegions: [CachedRegion] = []
    private var pendingRegions: [PendingRegion] = []

    init(provider: ShopCandidateProviding,
         store: ShopHistoryStoring,
         settings: Settings = Settings()) {
        self.provider = provider
        self.store = store
        self.settings = settings
        history = store.load()
    }

    func currentHistory() -> ShopHistory {
        history
    }

    func startSession() {
        session = ShopPassageSession()
        verifiedRoute = []
    }

    @discardableResult
    func recordPosition(_ position: GeoPoint,
                        horizontalAccuracyM: Double?,
                        at date: Date = Date()) -> [ShopPassageUpdate] {
        guard ShopHistory.isUsable(horizontalAccuracyM: horizontalAccuracyM,
                                   maxHorizontalAccuracyM: settings.maxHorizontalAccuracyM)
        else { return [] }

        verifiedRoute.append(TimedGeoPoint(point: position, date: date))
        return recordNear(position, horizontalAccuracyM: horizontalAccuracyM, at: date)
    }

    func refreshCacheIfNeeded(around position: GeoPoint) async -> [ShopPassageUpdate] {
        guard !isCoveredByCachedRegion(position) else { return [] }
        if let pending = pendingCovering(position) {
            return await finishPending(pending)
        }

        let region = SearchRegion(center: position, searchRadiusM: settings.searchRadiusM)
        let provider = provider
        let radius = settings.searchRadiusM
        let task = Task<[Shop], Error> {
            try await provider.shops(near: position, searchRadiusM: radius)
        }
        let pending = PendingRegion(region: region, task: task)
        pendingRegions.append(pending)
        return await finishPending(pending)
    }

    func finishSession(finalRoute: [TimedGeoPoint], fallbackDate: Date = Date()) async
        -> [ShopPassageUpdate] {
        verifiedRoute = finalRoute
        var updates: [ShopPassageUpdate] = []
        for pending in pendingRegions {
            updates.append(contentsOf: await finishPending(pending))
        }
        updates.append(contentsOf: recordRoute(fallbackDate: fallbackDate))
        return updates
    }

    private func finishPending(_ pending: PendingRegion) async -> [ShopPassageUpdate] {
        do {
            let shops = try await pending.task.value
            guard let index = pendingRegions.firstIndex(where: { $0.region == pending.region })
            else { return [] }
            pendingRegions.remove(at: index)
            cachedRegions.append(CachedRegion(region: pending.region, shops: shops))
            return recordRoute(fallbackDate: Date())
        } catch {
            pendingRegions.removeAll { $0.region == pending.region }
            return []
        }
    }

    private func recordNear(_ position: GeoPoint,
                            horizontalAccuracyM: Double?,
                            at date: Date) -> [ShopPassageUpdate] {
        let updates = history.recordPassages(near: position,
                                             horizontalAccuracyM: horizontalAccuracyM,
                                             candidates: cachedCandidates(),
                                             session: &session,
                                             at: date,
                                             radiusM: settings.passageRadiusM,
                                             maxHorizontalAccuracyM: settings.maxHorizontalAccuracyM)
        saveIfNeeded(updates)
        return updates
    }

    private func recordRoute(fallbackDate: Date) -> [ShopPassageUpdate] {
        let updates = history.recordPassages(along: verifiedRoute,
                                             candidates: cachedCandidates(),
                                             session: &session,
                                             fallbackDate: fallbackDate,
                                             radiusM: settings.passageRadiusM,
                                             maxHorizontalAccuracyM:
                                                settings.maxHorizontalAccuracyM)
        saveIfNeeded(updates)
        return updates
    }

    private func saveIfNeeded(_ updates: [ShopPassageUpdate]) {
        if !updates.isEmpty { store.save(history) }
    }

    private func cachedCandidates() -> [Shop] {
        var byID: [String: Shop] = [:]
        for region in cachedRegions {
            for shop in region.shops { byID[shop.shopID] = shop }
        }
        return Array(byID.values)
    }

    private func isCoveredByCachedRegion(_ position: GeoPoint) -> Bool {
        cachedRegions.contains {
            $0.region.covers(position, passageRadiusM: settings.passageRadiusM)
        }
    }

    private func pendingCovering(_ position: GeoPoint) -> PendingRegion? {
        pendingRegions.first {
            $0.region.covers(position, passageRadiusM: settings.passageRadiusM)
        }
    }
}
