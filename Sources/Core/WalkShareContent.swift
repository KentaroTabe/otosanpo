import Foundation

/// SNS 共有カードに渡す、表示専用の散歩データ。
/// 店舗選択は保存せず、共有画面の一時状態からこの形を作る。
public struct WalkShareContent: Equatable {
    public static let maxSelectedShopCount = 2

    public var date: Date
    public var durationSec: Double
    public var distanceM: Double
    public var newShopCount: Int
    public var selectedShops: [WalkReceiptShopItem]
    public var walkSummary: WalkSummary

    public init(receipt: WalkReceiptContent,
                selectedShopIDs: [String],
                maxSelectedShopCount: Int = Self.maxSelectedShopCount) {
        date = receipt.summary.startedAt
        durationSec = receipt.summary.durationSec
        distanceM = receipt.summary.pathLengthM
        newShopCount = receipt.newShopCount
        walkSummary = receipt.summary

        let selected = Set(selectedShopIDs)
        selectedShops = receipt.shopItems
            .filter { selected.contains($0.shopID) }
            .prefix(max(0, maxSelectedShopCount))
            .map { $0 }
    }

    public var durationMinutes: Int {
        Int((durationSec / 60).rounded())
    }

    public var distanceKilometers: Double {
        distanceM / 1_000
    }
}
