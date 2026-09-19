import Foundation

public struct WalkReceiptShopItem: Equatable, Identifiable, Sendable {
    public var shopID: String
    public var name: String
    public var category: String?
    public var passedAt: Date
    public var distanceM: Double
    public var passNumber: Int
    public var isResolved: Bool

    public var id: String { shopID }
    public var isNew: Bool { passNumber == 1 }
    public var passageLabel: String { isNew ? "NEW" : "\(passNumber)回目" }

    public init(shopID: String,
                name: String,
                category: String?,
                passedAt: Date,
                distanceM: Double,
                passNumber: Int,
                isResolved: Bool) {
        self.shopID = shopID
        self.name = name
        self.category = category
        self.passedAt = passedAt
        self.distanceM = distanceM
        self.passNumber = passNumber
        self.isResolved = isResolved
    }
}

/// 直近 1 回の散歩を、ユーザー向けの「レシート」として表示するための薄い形。
/// 経路そのものは `WalkSummary`、発見した店舗は `WalkDiscoverySummary` を正とし、
/// 店名などの店舗情報だけを累積履歴から解決する。
public struct WalkReceiptContent: Equatable {
    public var summary: WalkSummary
    public var discoverySummary: WalkDiscoverySummary
    public var shopItems: [WalkReceiptShopItem]

    public init?(summary: WalkSummary,
                 discoverySummary: WalkDiscoverySummary?,
                 shopHistoryRecords: [ShopHistoryRecord]) {
        guard let discoverySummary,
              discoverySummary.walkID == summary.walkID else {
            return nil
        }
        self.summary = summary
        self.discoverySummary = discoverySummary
        shopItems = Self.shopItems(from: discoverySummary.shopDiscoveries,
                                   shopHistoryRecords: shopHistoryRecords)
    }

    public var newShopCount: Int {
        shopItems.filter(\.isNew).count
    }

    public var hasTrack: Bool {
        !summary.track.isEmpty
    }

    public var hasShops: Bool {
        !shopItems.isEmpty
    }

    public static func shopItems(from discoveries: [WalkShopDiscovery],
                                 shopHistoryRecords: [ShopHistoryRecord])
        -> [WalkReceiptShopItem] {
        let recordsByID = Dictionary(uniqueKeysWithValues:
            ShopMapContent.uniqueRecords(shopHistoryRecords).map { ($0.shop.shopID, $0) })
        return discoveries.map { discovery in
            if let record = recordsByID[discovery.shopID] {
                return WalkReceiptShopItem(
                    shopID: discovery.shopID,
                    name: record.shop.name,
                    category: record.shop.category.isEmpty ? nil : record.shop.category,
                    passedAt: discovery.passedAt,
                    distanceM: discovery.distanceM,
                    passNumber: discovery.passNumber,
                    isResolved: true)
            }
            return WalkReceiptShopItem(
                shopID: discovery.shopID,
                name: discovery.shopID,
                category: "店舗情報を取得できません",
                passedAt: discovery.passedAt,
                distanceM: discovery.distanceM,
                passNumber: discovery.passNumber,
                isResolved: false)
        }
    }
}
