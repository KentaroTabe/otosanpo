import Foundation

public struct ShopMapRegion: Equatable, Sendable {
    public var center: GeoPoint
    public var latitudinalMeters: Double
    public var longitudinalMeters: Double

    public init(center: GeoPoint, latitudinalMeters: Double, longitudinalMeters: Double) {
        self.center = center
        self.latitudinalMeters = latitudinalMeters
        self.longitudinalMeters = longitudinalMeters
    }
}

public struct ShopMapContent: Equatable, Sendable {
    public static let minSpanM = 800.0
    public static let paddingRatio = 1.25

    public var records: [ShopHistoryRecord]
    public var region: ShopMapRegion?

    public init(records: [ShopHistoryRecord],
                minSpanM: Double = Self.minSpanM,
                paddingRatio: Double = Self.paddingRatio) {
        self.records = Self.uniqueRecords(records)
        region = Self.region(for: self.records, minSpanM: minSpanM, paddingRatio: paddingRatio)
    }

    public static func uniqueRecords(_ records: [ShopHistoryRecord]) -> [ShopHistoryRecord] {
        var byID: [String: ShopHistoryRecord] = [:]
        for record in records {
            if let current = byID[record.shop.shopID] {
                byID[record.shop.shopID] = preferredRecord(current, record)
            } else {
                byID[record.shop.shopID] = record
            }
        }
        return byID.values.sorted {
            if $0.history.lastPassedAt != $1.history.lastPassedAt {
                return $0.history.lastPassedAt > $1.history.lastPassedAt
            }
            return $0.shop.name < $1.shop.name
        }
    }

    public static func region(for records: [ShopHistoryRecord],
                              minSpanM: Double = Self.minSpanM,
                              paddingRatio: Double = Self.paddingRatio) -> ShopMapRegion? {
        guard !records.isEmpty else { return nil }
        let points = records.map(\.shop.location)
        guard let minLat = points.map(\.latitude).min(),
              let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(),
              let maxLon = points.map(\.longitude).max() else {
            return nil
        }

        let center = GeoPoint(latitude: (minLat + maxLat) / 2,
                              longitude: (minLon + maxLon) / 2)
        let rawLatSpan = Geo.distanceM(GeoPoint(latitude: minLat, longitude: center.longitude),
                                       GeoPoint(latitude: maxLat, longitude: center.longitude))
        let rawLonSpan = Geo.distanceM(GeoPoint(latitude: center.latitude, longitude: minLon),
                                       GeoPoint(latitude: center.latitude, longitude: maxLon))
        return ShopMapRegion(center: center,
                             latitudinalMeters: max(rawLatSpan * paddingRatio, minSpanM),
                             longitudinalMeters: max(rawLonSpan * paddingRatio, minSpanM))
    }

    private static func preferredRecord(_ lhs: ShopHistoryRecord,
                                        _ rhs: ShopHistoryRecord) -> ShopHistoryRecord {
        if lhs.history.lastPassedAt != rhs.history.lastPassedAt {
            return lhs.history.lastPassedAt > rhs.history.lastPassedAt ? lhs : rhs
        }
        if lhs.history.passCount != rhs.history.passCount {
            return lhs.history.passCount > rhs.history.passCount ? lhs : rhs
        }
        return lhs.shop.name <= rhs.shop.name ? lhs : rhs
    }
}
