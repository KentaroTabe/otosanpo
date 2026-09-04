import Foundation

/// 店舗通過の判定に使う既定値。設定ファイルから上書きして使う。
public enum ShopPassageRules {
    public static let defaultPassageRadiusM = 30.0
    public static let defaultSearchRadiusM = 120.0
    public static let defaultMaxHorizontalAccuracyM = 50.0
}

/// 店舗そのものの情報。通過履歴とは分けて保存する。
public struct Shop: Codable, Equatable, Sendable {
    public var shopID: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var category: String

    public init(shopID: String, name: String, latitude: Double, longitude: Double,
                category: String) {
        self.shopID = shopID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
    }

    public var location: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }
}

/// ユーザーがその店舗の前を通った履歴。店舗名や座標は `Shop` 側に持つ。
public struct ShopPassageHistory: Codable, Equatable, Sendable {
    public var shopID: String
    public var firstPassedAt: Date
    public var lastPassedAt: Date
    public var passCount: Int

    public init(shopID: String, firstPassedAt: Date, lastPassedAt: Date, passCount: Int) {
        self.shopID = shopID
        self.firstPassedAt = firstPassedAt
        self.lastPassedAt = lastPassedAt
        self.passCount = passCount
    }
}

/// 表示や書き出しで使う、店舗情報と通過履歴を合わせた読み取り用の形。
public struct ShopHistoryRecord: Equatable, Sendable {
    public var shop: Shop
    public var history: ShopPassageHistory
}

/// 1 回の散歩内で、すでに通過として数えた店舗を覚える。
public struct ShopPassageSession: Equatable, Sendable {
    private var passedShopIDs: Set<String>

    public init(passedShopIDs: Set<String> = []) {
        self.passedShopIDs = passedShopIDs
    }

    public func hasPassed(_ shopID: String) -> Bool {
        passedShopIDs.contains(shopID)
    }

    public mutating func markPassed(_ shopID: String) {
        passedShopIDs.insert(shopID)
    }
}

/// 通過記録を更新した結果。初回通過かどうかを呼び出し側で判定できる。
public struct ShopPassageUpdate: Equatable, Sendable {
    public var shopID: String
    public var isFirstPassage: Bool
    public var passedAt: Date
    public var distanceM: Double
}

/// 位置と、その位置を実際に通った時刻。終了時の一括判定でも通過時刻を近似する。
public struct TimedGeoPoint: Equatable, Sendable {
    public var point: GeoPoint
    public var date: Date

    public init(point: GeoPoint, date: Date) {
        self.point = point
        self.date = date
    }
}

/// 店舗データと通過履歴を分けて保持する端末内アーカイブ。
public struct ShopHistory: Codable, Equatable, Sendable {
    public var shopsByID: [String: Shop]
    public var historiesByShopID: [String: ShopPassageHistory]

    public init(shopsByID: [String: Shop] = [:],
                historiesByShopID: [String: ShopPassageHistory] = [:]) {
        self.shopsByID = shopsByID
        self.historiesByShopID = historiesByShopID
    }

    public var records: [ShopHistoryRecord] {
        historiesByShopID.keys.sorted().compactMap { shopID in
            guard let shop = shopsByID[shopID],
                  let history = historiesByShopID[shopID] else { return nil }
            return ShopHistoryRecord(shop: shop, history: history)
        }
    }

    @discardableResult
    public mutating func recordPassages(near position: GeoPoint,
                                        horizontalAccuracyM: Double? = 0,
                                        candidates: [Shop],
                                        session: inout ShopPassageSession,
                                        at date: Date,
                                        radiusM: Double = ShopPassageRules.defaultPassageRadiusM,
                                        maxHorizontalAccuracyM: Double =
                                            ShopPassageRules.defaultMaxHorizontalAccuracyM)
        -> [ShopPassageUpdate] {
        guard Self.isUsable(horizontalAccuracyM: horizontalAccuracyM,
                            maxHorizontalAccuracyM: maxHorizontalAccuracyM) else {
            return []
        }
        let nearby = candidates.compactMap { shop -> (shop: Shop, distanceM: Double, date: Date)? in
            let distance = Geo.distanceM(position, shop.location)
            guard distance <= radiusM else { return nil }
            return (shop, distance, date)
        }
        return record(nearby, session: &session, at: date)
    }

    @discardableResult
    public mutating func recordPassages(along route: [GeoPoint],
                                        candidates: [Shop],
                                        session: inout ShopPassageSession,
                                        at date: Date,
                                        radiusM: Double = ShopPassageRules.defaultPassageRadiusM)
        -> [ShopPassageUpdate] {
        let timedRoute = route.map { TimedGeoPoint(point: $0, date: date) }
        return recordPassages(along: timedRoute, candidates: candidates,
                              session: &session, fallbackDate: date, radiusM: radiusM)
    }

    @discardableResult
    public mutating func recordPassages(along route: [TimedGeoPoint],
                                        candidates: [Shop],
                                        session: inout ShopPassageSession,
                                        fallbackDate: Date,
                                        radiusM: Double = ShopPassageRules.defaultPassageRadiusM)
        -> [ShopPassageUpdate] {
        let nearby = candidates.compactMap { shop -> (shop: Shop, distanceM: Double, date: Date)? in
            guard let distance = Self.distanceM(from: shop.location, to: route),
                  distance <= radiusM else { return nil }
            let date = Self.passageDate(for: shop.location, along: route) ?? fallbackDate
            return (shop, distance, date)
        }
        return record(nearby, session: &session, fallbackDate: fallbackDate)
    }

    public static func distanceM(from point: GeoPoint, to route: [GeoPoint]) -> Double? {
        guard let first = route.first else { return nil }
        guard route.count >= 2 else { return Geo.distanceM(point, first) }

        var best = Double.greatestFiniteMagnitude
        for i in 0..<(route.count - 1) {
            let d = Geo.nearestPointOnSegment(point, from: route[i], to: route[i + 1]).distanceM
            best = min(best, d)
        }
        return best
    }

    public static func distanceM(from point: GeoPoint, to route: [TimedGeoPoint]) -> Double? {
        distanceM(from: point, to: route.map(\.point))
    }

    public static func passageDate(for point: GeoPoint, along route: [TimedGeoPoint]) -> Date? {
        guard let first = route.first else { return nil }
        guard route.count >= 2 else { return first.date }

        var best: (distanceM: Double, index: Int, t: Double)?
        for i in 0..<(route.count - 1) {
            let nearest = Geo.nearestPointOnSegment(point, from: route[i].point, to: route[i + 1].point)
            if best == nil || nearest.distanceM < best!.distanceM {
                best = (nearest.distanceM, i, nearest.t)
            }
        }
        guard let best else { return first.date }
        let start = route[best.index].date
        let end = route[best.index + 1].date
        return start.addingTimeInterval(end.timeIntervalSince(start) * best.t)
    }

    public static func isUsable(horizontalAccuracyM: Double?,
                                maxHorizontalAccuracyM: Double) -> Bool {
        guard let horizontalAccuracyM,
              horizontalAccuracyM >= 0,
              maxHorizontalAccuracyM >= 0 else { return false }
        return horizontalAccuracyM <= maxHorizontalAccuracyM
    }

    private mutating func record(_ passages: [(shop: Shop, distanceM: Double, date: Date)],
                                 session: inout ShopPassageSession,
                                 at date: Date) -> [ShopPassageUpdate] {
        record(passages.map { (shop: $0.shop, distanceM: $0.distanceM, date: date) },
               session: &session, fallbackDate: date)
    }

    private mutating func record(_ passages: [(shop: Shop, distanceM: Double, date: Date)],
                                 session: inout ShopPassageSession,
                                 fallbackDate: Date) -> [ShopPassageUpdate] {
        passages
            .sorted {
                if $0.distanceM != $1.distanceM { return $0.distanceM < $1.distanceM }
                return $0.shop.shopID < $1.shop.shopID
            }
            .reduce(into: []) { updates, passage in
                let shop = passage.shop
                guard !session.hasPassed(shop.shopID) else { return }

                session.markPassed(shop.shopID)
                shopsByID[shop.shopID] = shop
                let isFirstPassage = historiesByShopID[shop.shopID] == nil
                let date = passage.date

                if var history = historiesByShopID[shop.shopID] {
                    history.lastPassedAt = date
                    history.passCount += 1
                    historiesByShopID[shop.shopID] = history
                } else {
                    historiesByShopID[shop.shopID] = ShopPassageHistory(
                        shopID: shop.shopID,
                        firstPassedAt: date,
                        lastPassedAt: date,
                        passCount: 1)
                }

                updates.append(ShopPassageUpdate(shopID: shop.shopID,
                                                 isFirstPassage: isFirstPassage,
                                                 passedAt: date,
                                                 distanceM: passage.distanceM))
            }
    }
}
