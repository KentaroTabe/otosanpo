import Foundation

/// 店舗候補の取得口。Hot Pepper API などの本接続はこの protocol の実装として差し替える。
protocol ShopCandidateProviding {
    func shops(near position: GeoPoint, radiusM: Double) -> [Shop]
    func shops(along route: [GeoPoint], radiusM: Double) -> [Shop]
}

/// API 未接続の間に使う空の候補取得。既存の散歩機能には影響しない。
struct EmptyShopCandidateProvider: ShopCandidateProviding {
    func shops(near position: GeoPoint, radiusM: Double) -> [Shop] { [] }
    func shops(along route: [GeoPoint], radiusM: Double) -> [Shop] { [] }
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
final class ShopHistoryService {
    private let provider: ShopCandidateProviding
    private let store: ShopHistoryStoring
    let passageRadiusM: Double
    private(set) var history: ShopHistory

    init(provider: ShopCandidateProviding,
         store: ShopHistoryStoring,
         passageRadiusM: Double = ShopPassageRules.defaultPassageRadiusM) {
        self.provider = provider
        self.store = store
        self.passageRadiusM = passageRadiusM
        history = store.load()
    }

    func startSession() -> ShopPassageSession {
        ShopPassageSession()
    }

    @discardableResult
    func recordPassages(near position: GeoPoint,
                        session: inout ShopPassageSession,
                        at date: Date = Date()) -> [ShopPassageUpdate] {
        let candidates = provider.shops(near: position, radiusM: passageRadiusM)
        let updates = history.recordPassages(near: position,
                                             candidates: candidates,
                                             session: &session,
                                             at: date,
                                             radiusM: passageRadiusM)
        if !updates.isEmpty { store.save(history) }
        return updates
    }

    @discardableResult
    func recordPassages(along route: [GeoPoint],
                        session: inout ShopPassageSession,
                        at date: Date = Date()) -> [ShopPassageUpdate] {
        let candidates = provider.shops(along: route, radiusM: passageRadiusM)
        let updates = history.recordPassages(along: route,
                                             candidates: candidates,
                                             session: &session,
                                             at: date,
                                             radiusM: passageRadiusM)
        if !updates.isEmpty { store.save(history) }
        return updates
    }
}
