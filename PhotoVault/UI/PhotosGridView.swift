import SwiftUI
import SwiftData

struct DaySection: Identifiable {
    var id: Date
    var title: String
    var assets: [Asset]
}

func makeDaySections(_ assets: [Asset]) -> [DaySection] {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    var order: [Date] = []
    var groups: [Date: [Asset]] = [:]
    for asset in assets {
        let day = calendar.startOfDay(for: asset.captured)
        if groups[day] == nil { order.append(day) }
        groups[day, default: []].append(asset)
    }
    return order.map { day in
        let title: String
        if calendar.isDateInToday(day) {
            title = "Today"
        } else if calendar.isDateInYesterday(day) {
            title = "Yesterday"
        } else {
            title = formatter.string(from: day)
        }
        return DaySection(id: day, title: title, assets: groups[day] ?? [])
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct ViewerContext: Identifiable {
    var id: String
    var assets: [Asset]
    var index: Int
}

struct PhotosGridView: View {
    @EnvironmentObject var store: VaultStore
    @Query(filter: #Predicate<Asset> { $0.isDeleted == false }, sort: \Asset.captured, order: .reverse)
    private var assets: [Asset]

    @State private var columnCount = 3
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var viewer: ViewerContext?
    @State private var scrubLabel: String?

    private let columnSteps = [2, 3, 5]

    var body: some View {
        NavigationStack {
            gridBody
                .navigationTitle("Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BackupIndicator()
                    }
                    if selecting {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") {
                                selecting = false
                                selected.removeAll()
                            }
                        }
                    }
                }
                .fullScreenCover(item: $viewer) { context in
                    ViewerView(assets: context.assets, startIndex: context.index)
                }
        }
    }

    private var sections: [DaySection] { makeDaySections(assets) }

    private var gridBody: some View {
        let sections = self.sections
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
                          spacing: 2,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.assets, id: \.id) { asset in
                                cell(for: asset)
                            }
                        } header: {
                            HStack {
                                Text(section.title).font(.subheadline.bold())
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial)
                            .id(section.id)
                        }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                DateScrubber(sections: sections, label: $scrubLabel) { day in
                    proxy.scrollTo(day, anchor: .top)
                }
            }
            .overlay {
                if let scrubLabel {
                    Text(scrubLabel)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .simultaneousGesture(
                MagnificationGesture().onEnded { value in
                    guard let idx = columnSteps.firstIndex(of: columnCount) else { return }
                    if value > 1.2 && idx > 0 {
                        columnCount = columnSteps[idx - 1]
                    } else if value < 0.8 && idx < columnSteps.count - 1 {
                        columnCount = columnSteps[idx + 1]
                    }
                }
            )
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    selectionBar
                }
            }
        }
    }

    private func cell(for asset: Asset) -> some View {
        ThumbCell(asset: asset, isSelected: selected.contains(asset.id), selecting: selecting)
            .onTapGesture {
                if selecting {
                    if selected.contains(asset.id) {
                        selected.remove(asset.id)
                    } else {
                        selected.insert(asset.id)
                    }
                } else {
                    let flat = sections.flatMap(\.assets)
                    let index = flat.firstIndex { $0.id == asset.id } ?? 0
                    viewer = ViewerContext(id: asset.id, assets: flat, index: index)
                }
            }
            .onLongPressGesture {
                if !selecting {
                    selecting = true
                    selected.insert(asset.id)
                }
            }
    }

    private var selectedAssets: [Asset] {
        assets.filter { selected.contains($0.id) }
    }

    private var shareURLs: [URL] {
        selectedAssets.compactMap { asset in
            CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename)
                ?? (CacheManager.hasThumb(assetId: asset.id) ? CacheManager.thumbURL(assetId: asset.id) : nil)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 40) {
            ShareLink(items: shareURLs) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(shareURLs.isEmpty)
            Button {
                for asset in selectedAssets {
                    store.setFavorite(asset, true)
                }
                selecting = false
                selected.removeAll()
            } label: {
                Image(systemName: "heart")
            }
            Button(role: .destructive) {
                store.moveToTrash(selectedAssets)
                selecting = false
                selected.removeAll()
            } label: {
                Image(systemName: "trash")
            }
        }
        .font(.title3)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

struct ThumbCell: View {
    let asset: Asset
    let isSelected: Bool
    let selecting: Bool
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: geo.size.width, height: geo.size.width)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
                HStack(spacing: 4) {
                    if asset.isVideo {
                        Image(systemName: "play.fill").font(.caption2)
                        Text(formatDuration(asset.duration)).font(.caption2)
                    }
                    if asset.isFavorite {
                        Image(systemName: "heart.fill").font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.id) {
            let url = CacheManager.thumbURL(assetId: asset.id)
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

struct BackupIndicator: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        if store.isBackingUp {
            HStack(spacing: 6) {
                ProgressView()
                Text("\(store.backupRemaining) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }
}

// Right-edge drag scrubber showing month/year of the section under the finger.
struct DateScrubber: View {
    let sections: [DaySection]
    @Binding var label: String?
    let onScrub: (Date) -> Void

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: 28)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !sections.isEmpty else { return }
                            let fraction = min(max(value.location.y / max(geo.size.height, 1), 0), 0.999)
                            let index = Int(fraction * CGFloat(sections.count))
                            let section = sections[index]
                            let formatter = DateFormatter()
                            formatter.dateFormat = "MMM yyyy"
                            label = formatter.string(from: section.id)
                            onScrub(section.id)
                        }
                        .onEnded { _ in label = nil }
                )
        }
        .frame(width: 28)
    }
}
