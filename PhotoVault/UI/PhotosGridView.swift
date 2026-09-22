import SwiftUI
import SwiftData
import Photos

// One cell of the Photos timeline: a vault asset, or a camera-roll asset that is not backed up yet.
enum TimelineItem: Identifiable {
    case vault(Asset)
    case device(PHAsset)

    var id: String {
        switch self {
        case .vault(let asset): return "v:" + asset.id
        case .device(let asset): return "d:" + asset.localIdentifier
        }
    }

    var date: Date {
        switch self {
        case .vault(let asset): return asset.captured
        case .device(let asset): return asset.creationDate ?? .distantPast
        }
    }

    var vaultAsset: Asset? {
        if case .vault(let asset) = self { return asset }
        return nil
    }

    var deviceAsset: PHAsset? {
        if case .device(let asset) = self { return asset }
        return nil
    }
}

// Both inputs are sorted newest first; so is the result.
func mergeTimeline(vault: [Asset], device: [PHAsset]) -> [TimelineItem] {
    var merged: [TimelineItem] = []
    merged.reserveCapacity(vault.count + device.count)
    var v = 0
    var d = 0
    while v < vault.count || d < device.count {
        let takeVault = d >= device.count
            || (v < vault.count && vault[v].captured >= (device[d].creationDate ?? .distantPast))
        if takeVault {
            merged.append(.vault(vault[v]))
            v += 1
        } else {
            merged.append(.device(device[d]))
            d += 1
        }
    }
    return merged
}

struct DaySection: Identifiable {
    var id: Date
    var title: String
    var items: [TimelineItem]

    var deviceAssets: [PHAsset] { items.compactMap(\.deviceAsset) }
}

func makeDaySections(_ items: [TimelineItem]) -> [DaySection] {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    var order: [Date] = []
    var groups: [Date: [TimelineItem]] = [:]
    for item in items {
        let day = calendar.startOfDay(for: item.date)
        if groups[day] == nil { order.append(day) }
        groups[day, default: []].append(item)
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
        return DaySection(id: day, title: title, items: groups[day] ?? [])
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct ViewerContext: Identifiable {
    var id: String
    var items: [TimelineItem]
    var index: Int
}

// Starts a manual backup, first asking before cellular is used while Wi-Fi only is on.
@MainActor
func requestManualBackup(_ assets: [PHAsset], store: VaultStore, prompt: Binding<[PHAsset]?>) {
    guard !assets.isEmpty else { return }
    Task {
        if await store.manualBackupNeedsCellularConsent() {
            prompt.wrappedValue = assets
        } else {
            store.backup(phAssets: assets)
        }
    }
}

struct CellularBackupPrompt: ViewModifier {
    @EnvironmentObject var store: VaultStore
    @Binding var pending: [PHAsset]?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Upload on cellular anyway?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { assets in
            Button("Upload on cellular") {
                store.backup(phAssets: assets, allowCellular: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Wi-Fi only is on and this iPhone is not connected to Wi-Fi.")
        }
    }
}

extension View {
    func cellularBackupPrompt(_ pending: Binding<[PHAsset]?>) -> some View {
        modifier(CellularBackupPrompt(pending: pending))
    }
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
    @State private var cellularPrompt: [PHAsset]?

    private let columnSteps = [2, 3, 5]

    var body: some View {
        let timeline = mergeTimeline(vault: assets, device: store.deviceItems)
        NavigationStack {
            gridBody(timeline: timeline)
                .navigationTitle("Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BackupIndicator()
                    }
                    if selecting {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { endSelection() }
                        }
                    }
                }
                .fullScreenCover(item: $viewer) { context in
                    ViewerView(items: context.items, startIndex: context.index)
                }
        }
        .cellularBackupPrompt($cellularPrompt)
    }

    private func gridBody(timeline: [TimelineItem]) -> some View {
        let sections = makeDaySections(timeline)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
                          spacing: 2,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                cell(for: item, timeline: timeline)
                            }
                        } header: {
                            header(for: section)
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
                    selectionBar(timeline: timeline)
                }
            }
        }
    }

    private func header(for section: DaySection) -> some View {
        let pending = section.deviceAssets
        return HStack {
            Text(section.title).font(.subheadline.bold())
            Spacer()
            if !pending.isEmpty {
                if pending.allSatisfy({ store.queuedSourceIds.contains($0.localIdentifier) }) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Back up") {
                        requestManualBackup(pending, store: store, prompt: $cellularPrompt)
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .id(section.id)
    }

    private func cell(for item: TimelineItem, timeline: [TimelineItem]) -> some View {
        let isSelected = selected.contains(item.id)
        return Group {
            switch item {
            case .vault(let asset):
                ThumbCell(asset: asset, isSelected: isSelected, selecting: selecting)
            case .device(let asset):
                DeviceThumbCell(asset: asset, isSelected: isSelected, selecting: selecting)
            }
        }
        .onTapGesture {
            if selecting {
                if selected.contains(item.id) {
                    selected.remove(item.id)
                } else {
                    selected.insert(item.id)
                }
            } else {
                let index = timeline.firstIndex { $0.id == item.id } ?? 0
                viewer = ViewerContext(id: item.id, items: timeline, index: index)
            }
        }
        .onLongPressGesture {
            if !selecting {
                selecting = true
                selected.insert(item.id)
            }
        }
    }

    private func endSelection() {
        selecting = false
        selected.removeAll()
    }

    // Share / Favorite / Delete act on vault items only; "Back up" appears when device items are selected.
    private func selectionBar(timeline: [TimelineItem]) -> some View {
        let chosen = timeline.filter { selected.contains($0.id) }
        let vaultChosen = chosen.compactMap(\.vaultAsset)
        let deviceChosen = chosen.compactMap(\.deviceAsset)
        let shareURLs: [URL] = vaultChosen.compactMap { asset in
            CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename)
                ?? (CacheManager.hasThumb(assetId: asset.id) ? CacheManager.thumbURL(assetId: asset.id) : nil)
        }
        return HStack(spacing: 36) {
            ShareLink(items: shareURLs) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(shareURLs.isEmpty)
            Button {
                for asset in vaultChosen {
                    store.setFavorite(asset, true)
                }
                endSelection()
            } label: {
                Image(systemName: "heart")
            }
            .disabled(vaultChosen.isEmpty)
            Button(role: .destructive) {
                store.moveToTrash(vaultChosen)
                endSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(vaultChosen.isEmpty)
            if !deviceChosen.isEmpty {
                Button {
                    requestManualBackup(deviceChosen, store: store, prompt: $cellularPrompt)
                    endSelection()
                } label: {
                    Label("Back up", systemImage: "icloud.and.arrow.up")
                }
            }
        }
        .font(.title3)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .shadow(radius: 2)
            .padding(6)
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
                    SelectionMark(isSelected: isSelected)
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

// Camera-roll item that is not in the vault yet; thumbnail comes from PHCachingImageManager at cell size.
struct DeviceThumbCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let selecting: Bool
    @Environment(\.displayScale) private var displayScale
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
                }
                HStack(spacing: 4) {
                    Image(systemName: "icloud.slash").font(.caption2)
                    if asset.mediaType == .video {
                        Image(systemName: "play.fill").font(.caption2)
                        Text(formatDuration(asset.duration)).font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    SelectionMark(isSelected: isSelected)
                }
            }
            .task(id: "\(asset.localIdentifier)|\(Int(geo.size.width))") {
                guard geo.size.width > 0 else { return }
                image = await DeviceMedia.thumbnail(for: asset, side: geo.size.width * displayScale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
