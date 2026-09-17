import MapKit
import SwiftUI

struct ShopMapView: View {
    private let content: ShopMapContent
    @State private var position: MapCameraPosition
    @State private var selectedShopID: String?

    init(records: [ShopHistoryRecord]) {
        let content = ShopMapContent(records: records)
        self.content = content
        let initialPosition: MapCameraPosition
        if let region = content.region {
            initialPosition = .region(MKCoordinateRegion(shopMapRegion: region))
        } else {
            initialPosition = .automatic
        }
        _position = State(initialValue: initialPosition)
    }

    var body: some View {
        Group {
            if content.records.isEmpty {
                emptyState
            } else {
                mapContent
            }
        }
        .navigationTitle("街の発見")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text("まだすれ違った店はありません。")
                    .font(.headline)
                Text("音さんぽをすると、近くを通った店がここに残ります")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            creditText
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var mapContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Map(position: $position, selection: $selectedShopID) {
                    ForEach(content.records, id: \.shop.shopID) { record in
                        Marker(record.shop.name,
                               coordinate: CLLocationCoordinate2D(
                                latitude: record.shop.latitude,
                                longitude: record.shop.longitude))
                        .tag(record.shop.shopID)
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }

                creditText
                    .padding(.bottom, 12)
            }

            if let selectedRecord {
                ShopDetailPanel(record: selectedRecord)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedShopID)
    }

    private var selectedRecord: ShopHistoryRecord? {
        guard let selectedShopID else { return nil }
        return content.records.first { $0.shop.shopID == selectedShopID }
    }

    private var creditText: some View {
        Text("Powered by ホットペッパーグルメ Webサービス")
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct ShopDetailPanel: View {
    var record: ShopHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.shop.name)
                .font(.headline)
            if !record.shop.category.isEmpty {
                Text(record.shop.category)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("初めて")
                        .foregroundStyle(.secondary)
                    Text(record.history.firstPassedAt, format: .dateTime.year().month().day().hour().minute())
                }
                GridRow {
                    Text("最後")
                        .foregroundStyle(.secondary)
                    Text(record.history.lastPassedAt, format: .dateTime.year().month().day().hour().minute())
                }
                GridRow {
                    Text("通過回数")
                        .foregroundStyle(.secondary)
                    Text("\(record.history.passCount) 回")
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
    }
}

private extension MKCoordinateRegion {
    init(shopMapRegion region: ShopMapRegion) {
        self.init(center: CLLocationCoordinate2D(latitude: region.center.latitude,
                                                longitude: region.center.longitude),
                  latitudinalMeters: region.latitudinalMeters,
                  longitudinalMeters: region.longitudinalMeters)
    }
}

#Preview("店舗0件") {
    NavigationStack {
        ShopMapView(records: [])
    }
}

#Preview("店舗1件") {
    NavigationStack {
        ShopMapView(records: [ShopHistoryRecord.previewRecords[0]])
    }
}

#Preview("店舗複数件") {
    NavigationStack {
        ShopMapView(records: ShopHistoryRecord.previewRecords)
    }
}

private extension ShopHistoryRecord {
    static let previewRecords: [ShopHistoryRecord] = {
        let first = Date(timeIntervalSince1970: 1_820_000_000)
        let second = first.addingTimeInterval(86_400)
        return [
            ShopHistoryRecord(
                shop: Shop(shopID: "hp-1", name: "喫茶 こみち", latitude: 35.6812,
                           longitude: 139.7671, category: "カフェ"),
                history: ShopPassageHistory(shopID: "hp-1", firstPassedAt: first,
                                            lastPassedAt: second, passCount: 3)),
            ShopHistoryRecord(
                shop: Shop(shopID: "hp-2", name: "音坂ベーカリー", latitude: 35.684,
                           longitude: 139.7704, category: "パン"),
                history: ShopPassageHistory(shopID: "hp-2", firstPassedAt: first,
                                            lastPassedAt: first, passCount: 1)),
            ShopHistoryRecord(
                shop: Shop(shopID: "hp-3", name: "路地裏食堂", latitude: 35.6786,
                           longitude: 139.763, category: "和食"),
                history: ShopPassageHistory(shopID: "hp-3", firstPassedAt: second,
                                            lastPassedAt: second, passCount: 2))
        ]
    }()
}
