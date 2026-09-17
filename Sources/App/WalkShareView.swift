import SwiftUI
import UIKit

struct WalkShareView: View {
    let receipt: WalkReceiptContent
    let marginM: Double
    let minSpanM: Double
    let roadsProvider: (MapFrame) -> [RoadSegment]

    @State private var selectedShopIDs: [String] = []
    @State private var roads: [RoadSegment] = []
    @State private var shareImage: ShareImage?

    private var frame: MapFrame? {
        receipt.summary.frame(marginM: marginM, minSpanM: minSpanM)
    }

    private var shareContent: WalkShareContent {
        WalkShareContent(receipt: receipt, selectedShopIDs: selectedShopIDs)
    }

    var body: some View {
        List {
            Section("Preview") {
                WalkShareCardPreview(content: shareContent,
                                     roads: roads,
                                     marginM: marginM,
                                     minSpanM: minSpanM)
                    .padding(.vertical, 8)
            }

            if !receipt.shopItems.isEmpty {
                Section("今日見つけた店") {
                    ForEach(receipt.shopItems) { shop in
                        Button {
                            toggle(shop)
                        } label: {
                            HStack {
                                Image(systemName: selectedShopIDs.contains(shop.shopID)
                                      ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedShopIDs.contains(shop.shopID)
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shop.name)
                                        .foregroundStyle(.primary)
                                    if let category = shop.category {
                                        Text(category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(shop.passageLabel)
                                    .font(.caption.bold())
                                    .foregroundStyle(shop.isNew ? Color.accentColor : Color.secondary)
                            }
                        }
                        .disabled(!selectedShopIDs.contains(shop.shopID)
                                  && selectedShopIDs.count >= WalkShareContent.maxSelectedShopCount)
                    }
                    Text("共有画像に載せる店は2件まで選べます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    renderAndShare()
                } label: {
                    Label("共有する", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("シェア用画像")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let frame, roads.isEmpty else { return }
            roads = roadsProvider(frame)
        }
        .sheet(item: $shareImage) { item in
            ActivityView(items: [item.image])
        }
    }

    private func toggle(_ shop: WalkReceiptShopItem) {
        if let index = selectedShopIDs.firstIndex(of: shop.shopID) {
            selectedShopIDs.remove(at: index)
        } else if selectedShopIDs.count < WalkShareContent.maxSelectedShopCount {
            selectedShopIDs.append(shop.shopID)
        }
    }

    @MainActor
    private func renderAndShare() {
        let card = WalkShareCardView(content: shareContent,
                                     roads: roads,
                                     marginM: marginM,
                                     minSpanM: minSpanM)
            .frame(width: WalkShareCardView.logicalSize.width,
                   height: WalkShareCardView.logicalSize.height)
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(WalkShareCardView.logicalSize)
        renderer.scale = WalkShareCardView.renderScale
        guard let image = renderer.uiImage else { return }
        shareImage = ShareImage(image: image)
    }
}

private struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct WalkShareCardPreview: View {
    let content: WalkShareContent
    let roads: [RoadSegment]
    let marginM: Double
    let minSpanM: Double

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 12
            let availableWidth = max(1, proxy.size.width - inset * 2)
            let availableHeight = max(1, proxy.size.height - inset * 2)
            let scale = min(availableWidth / WalkShareCardView.logicalSize.width,
                            availableHeight / WalkShareCardView.logicalSize.height)
            let scaledSize = CGSize(width: WalkShareCardView.logicalSize.width * scale,
                                    height: WalkShareCardView.logicalSize.height * scale)

            WalkShareCardView(content: content,
                              roads: roads,
                              marginM: marginM,
                              minSpanM: minSpanM)
                .frame(width: WalkShareCardView.logicalSize.width,
                       height: WalkShareCardView.logicalSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: scaledSize.width, height: scaledSize.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(WalkShareCardView.logicalSize.width / WalkShareCardView.logicalSize.height,
                     contentMode: .fit)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview("42分 3.2km NEW2") {
    NavigationStack {
        WalkShareView.preview(.mixed)
    }
}

#Preview("店舗0件") {
    NavigationStack {
        WalkShareView.preview(.empty)
    }
}

#Preview("店舗あり・未選択") {
    NavigationStack {
        WalkShareView.preview(.mixed)
    }
}

#Preview("店舗2件選択済み") {
    NavigationStack {
        WalkShareView.preview(.mixed, selectedShopIDs: ["coffee", "bakery"])
    }
}

private extension WalkShareView {
    static func preview(_ previewCase: WalkSharePreviewData.PreviewCase,
                        selectedShopIDs: [String] = []) -> WalkShareView {
        var view = WalkShareView(receipt: WalkSharePreviewData.receipt(previewCase),
                                 marginM: 40,
                                 minSpanM: 150,
                                 roadsProvider: { _ in [] })
        view._selectedShopIDs = State(initialValue: selectedShopIDs)
        return view
    }
}
