import SwiftUI
import Photos

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

    @State private var columnCount = 3
    @State private var selecting = false
    @State private var selected: [String: TimelineItem] = [:]
    @State private var viewer: ViewerContext?
    @State private var scrubLabel: String?
    @State private var cellularPrompt: [PHAsset]?

    private let columnSteps = [2, 3, 5]
    private let spacing: CGFloat = 2

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                grid(width: geo.size.width)
            }
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

    // The timeline arrives precomputed; nothing here groups, sorts or filters.
    private func grid(width: CGFloat) -> some View {
        let side = max(1, (width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
        let timeline = store.timeline
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount),
                          spacing: spacing,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(timeline.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                cell(for: item, side: side)
                            }
                        } header: {
                            DayHeader(section: section) { assets in
                                requestManualBackup(assets, store: store, prompt: $cellularPrompt)
                            }
                        }
                    }
                }
                if timeline.flat.isEmpty {
                    emptyState
                }
            }
            .overlay(alignment: .trailing) {
                DateScrubber(months: timeline.months, label: $scrubLabel) { sectionId in
                    proxy.scrollTo(sectionId, anchor: .top)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            if !store.indexReady {
                ProgressView()
                Text("Loading library…").foregroundStyle(.secondary)
            } else if store.isSyncing {
                ProgressView()
                Text("Syncing \(store.syncDone)/\(store.syncTotal)").foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("No photos yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private func cell(for item: TimelineItem, side: CGFloat) -> some View {
        TimelineCell(item: item, side: side, isSelected: selected[item.id] != nil,
                     selecting: selecting, reportsVisibility: true)
            .onTapGesture {
                if selecting {
                    if selected[item.id] != nil {
                        selected[item.id] = nil
                    } else {
                        selected[item.id] = item
                    }
                } else {
                    viewer = ViewerContext(id: item.id, items: store.timeline.flat, index: item.flatIndex)
                }
            }
            .onLongPressGesture {
                if !selecting {
                    selecting = true
                    selected[item.id] = item
                }
            }
    }

    private func endSelection() {
        selecting = false
        selected.removeAll()
    }

    // Share / Favorite / Delete act on vault items only; "Back up" appears when device items are selected.
    private var selectionBar: some View {
        let chosen = Array(selected.values)
        let vaultIds = chosen.filter { !$0.isDevice }.map(\.assetId)
        let deviceChosen = chosen.compactMap(\.phAsset)
        let shareURLs: [URL] = chosen.filter { !$0.isDevice }.compactMap { item in
            CacheManager.cachedOriginal(assetId: item.assetId, filename: item.filename)
                ?? (CacheManager.hasThumb(assetId: item.assetId) ? CacheManager.thumbURL(assetId: item.assetId) : nil)
        }
        return HStack(spacing: 36) {
            ShareLink(items: shareURLs) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(shareURLs.isEmpty)
            Button {
                store.setFavorite(ids: vaultIds, true)
                endSelection()
            } label: {
                Image(systemName: "heart")
            }
            .disabled(vaultIds.isEmpty)
            Button(role: .destructive) {
                store.moveToTrash(ids: vaultIds)
                endSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(vaultIds.isEmpty)
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

struct DayHeader: View {
    @EnvironmentObject var store: VaultStore
    let section: DaySection
    let onBackUp: ([PHAsset]) -> Void

    var body: some View {
        HStack {
            Text(section.title).font(.subheadline.bold())
            Spacer()
            if !section.deviceAssets.isEmpty {
                if section.deviceAssets.allSatisfy({ store.queuedSourceIds.contains($0.localIdentifier) }) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Back up") { onBackUp(section.deviceAssets) }
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

struct TimelineCell: View {
    let item: TimelineItem
    let side: CGFloat
    let isSelected: Bool
    let selecting: Bool
    let reportsVisibility: Bool

    var body: some View {
        Group {
            if let phAsset = item.phAsset {
                DeviceThumbCell(asset: phAsset, side: side)
            } else {
                ThumbCell(item: item, side: side, reportsVisibility: reportsVisibility)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if selecting {
                SelectionMark(isSelected: isSelected)
            }
        }
    }
}

// Vault thumbnail cell: memory cache first, otherwise the bounded fetcher (disk or network).
// Fixed size, no GeometryReader, placeholder until the image arrives.
struct ThumbCell: View {
    @EnvironmentObject var store: VaultStore
    let item: TimelineItem
    let side: CGFloat
    let reportsVisibility: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                Color(uiColor: .secondarySystemFill)
                    .frame(width: side, height: side)
            }
            HStack(spacing: 4) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.caption2)
                    Text(formatDuration(item.duration)).font(.caption2)
                }
                if item.isFavorite {
                    Image(systemName: "heart.fill").font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        }
        .frame(width: side, height: side)
        .task(id: item.id) {
            if let cached = ThumbnailMemoryCache.shared.image(item.assetId) {
                image = cached
                return
            }
            let fetched = await ThumbnailFetcher.shared.image(for: item.assetId, priority: .visible)
            if !Task.isCancelled, let fetched {
                image = fetched
            }
        }
        .onAppear {
            if reportsVisibility { store.planner.appeared(item.flatIndex) }
        }
        .onDisappear {
            if reportsVisibility { store.planner.disappeared(item.flatIndex) }
        }
    }
}

// Camera-roll item that is not in the vault yet; thumbnail comes from PHCachingImageManager at cell size.
struct DeviceThumbCell: View {
    let asset: PHAsset
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                Color(uiColor: .secondarySystemFill)
                    .frame(width: side, height: side)
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
        .frame(width: side, height: side)
        .task(id: asset.localIdentifier) {
            image = await DeviceMedia.thumbnail(for: asset, side: side * displayScale)
        }
    }
}

struct BackupIndicator: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        if store.isSyncing {
            HStack(spacing: 6) {
                ProgressView()
                Text("Syncing \(store.syncDone)/\(store.syncTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if store.isBackingUp {
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

// Right-edge drag scrubber over the precomputed month markers; jumps straight to a section id.
struct DateScrubber: View {
    let months: [MonthMarker]
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
                            guard !months.isEmpty else { return }
                            let fraction = min(max(value.location.y / max(geo.size.height, 1), 0), 0.999)
                            let index = Int(fraction * CGFloat(months.count))
                            let month = months[index]
                            if label != month.label {
                                label = month.label
                                onScrub(month.sectionId)
                            }
                        }
                        .onEnded { _ in label = nil }
                )
        }
        .frame(width: 28)
    }
}
