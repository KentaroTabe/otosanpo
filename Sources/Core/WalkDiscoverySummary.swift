import Foundation

public struct WalkID: Codable, Equatable, Hashable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct WalkShopDiscovery: Codable, Equatable, Sendable {
    public var shopID: String
    public var passedAt: Date
    public var distanceM: Double
    public var passNumber: Int

    public init(shopID: String, passedAt: Date, distanceM: Double, passNumber: Int) {
        self.shopID = shopID
        self.passedAt = passedAt
        self.distanceM = distanceM
        self.passNumber = passNumber
    }

    public var isNew: Bool { passNumber == 1 }
}

/// 1 回の散歩で街と何が起きたかを残す記録。
/// 経路や誘導イベントを持つ `WalkSummary` とは分け、店舗以外の発見も後から足せる形にする。
public struct WalkDiscoverySummary: Codable, Equatable, Sendable {
    public var walkID: WalkID
    public var startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var shopDiscoveries: [WalkShopDiscovery]

    public init(walkID: WalkID,
                startedAt: Date,
                endedAt: Date? = nil,
                shopDiscoveries: [WalkShopDiscovery] = []) {
        self.walkID = walkID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.shopDiscoveries = Self.uniqueShopDiscoveries(shopDiscoveries)
    }

    public var isFinished: Bool { endedAt != nil }
    public var shopCount: Int { shopDiscoveries.count }
    public var newShopCount: Int { newShops.count }
    public var revisitedShopCount: Int { revisitedShops.count }
    public var newShops: [WalkShopDiscovery] { shopDiscoveries.filter(\.isNew) }
    public var revisitedShops: [WalkShopDiscovery] { shopDiscoveries.filter { !$0.isNew } }

    public mutating func record(_ updates: [ShopPassageUpdate]) {
        guard !updates.isEmpty else { return }
        shopDiscoveries = Self.uniqueShopDiscoveries(
            shopDiscoveries + updates.map {
                WalkShopDiscovery(shopID: $0.shopID,
                                  passedAt: $0.passedAt,
                                  distanceM: $0.distanceM,
                                  passNumber: $0.passNumber)
            })
    }

    public mutating func finish(at date: Date) {
        endedAt = date
    }

    public static func uniqueShopDiscoveries(_ discoveries: [WalkShopDiscovery])
        -> [WalkShopDiscovery] {
        var byID: [String: WalkShopDiscovery] = [:]
        for discovery in discoveries {
            if let current = byID[discovery.shopID] {
                byID[discovery.shopID] = preferredDiscovery(current, discovery)
            } else {
                byID[discovery.shopID] = discovery
            }
        }
        return byID.values.sorted {
            if $0.passedAt != $1.passedAt { return $0.passedAt < $1.passedAt }
            return $0.shopID < $1.shopID
        }
    }

    private static func preferredDiscovery(_ lhs: WalkShopDiscovery,
                                           _ rhs: WalkShopDiscovery) -> WalkShopDiscovery {
        if lhs.passedAt != rhs.passedAt { return lhs.passedAt < rhs.passedAt ? lhs : rhs }
        if lhs.passNumber != rhs.passNumber { return lhs.passNumber < rhs.passNumber ? lhs : rhs }
        if lhs.distanceM != rhs.distanceM { return lhs.distanceM < rhs.distanceM ? lhs : rhs }
        return lhs.shopID <= rhs.shopID ? lhs : rhs
    }
}
