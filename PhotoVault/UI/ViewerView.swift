import SwiftUI
import AVKit
import Photos

// Pages through the timeline's flat order; only a window of pages around the current one exists,
// widened as the user swipes, so a 50k-item library never materialises 50k pages.
struct ViewerView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    let items: [TimelineItem]

    @State private var currentIndex: Int
    @State private var windowLow: Int
    @State private var windowHigh: Int
    @State private var dragOffset: CGFloat = 0
    @State private var showInfo = false
    @State private var cellularPrompt: [PHAsset]?
    @State private var favoriteOverrides: [String: Bool] = [:]

    init(items: [TimelineItem], startIndex: Int) {
        self.items = items
        let last = max(items.count - 1, 0)
        let start = min(max(startIndex, 0), last)
        _currentIndex = State(initialValue: start)
        _windowLow = State(initialValue: max(0, start - 8))
        _windowHigh = State(initialValue: min(last, start + 8))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !items.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(Array(windowLow...windowHigh), id: \.self) { index in
                        page(for: items[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: dragOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            if abs(value.translation.height) > abs(value.translation.width) && value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { _ in
                            if dragOffset > 120 {
                                dismiss()
                            } else {
                                dragOffset = 0
                            }
                        }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .overlay(alignment: .bottom) { bottomBar }
        .sheet(isPresented: $showInfo) {
            if let item = currentItem {
                InfoSheet(item: item)
                    .presentationDetents([.medium])
            }
        }
        .cellularBackupPrompt($cellularPrompt)
        .onAppear { prefetchAround(currentIndex) }
        .onChange(of: currentIndex) { _, newIndex in
            if newIndex - windowLow < 3 { windowLow = max(0, windowLow - 12) }
            if windowHigh - newIndex < 3 { windowHigh = min(items.count - 1, windowHigh + 12) }
            prefetchAround(newIndex)
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private func page(for item: TimelineItem) -> some View {
        if let phAsset = item.phAsset {
            DevicePageView(asset: phAsset)
        } else {
            AssetPageView(item: item)
        }
    }

    private var currentItem: TimelineItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var bottomBar: some View {
        HStack(spacing: 44) {
            if let item = currentItem {
                if let phAsset = item.phAsset {
                    DeviceButtons(asset: phAsset, showInfo: $showInfo, cellularPrompt: $cellularPrompt)
                } else {
                    vaultButtons(item)
                }
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func vaultButtons(_ item: TimelineItem) -> some View {
        let favorite = favoriteOverrides[item.assetId] ?? item.isFavorite
        if let url = CacheManager.cachedOriginal(assetId: item.assetId, filename: item.filename) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            Image(systemName: "square.and.arrow.up").opacity(0.3)
        }
        Button {
            favoriteOverrides[item.assetId] = !favorite
            store.setFavorite(ids: [item.assetId], !favorite)
        } label: {
            Image(systemName: favorite ? "heart.fill" : "heart")
        }
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
        }
        Button(role: .destructive) {
            store.moveToTrash(ids: [item.assetId])
            dismiss()
        } label: {
            Image(systemName: "trash")
        }
    }

    private func prefetchAround(_ index: Int) {
        guard AppSettings.cellularPolicy != .ask else { return }
        let allowsCellular = AppSettings.cellularPolicy == .always
        for offset in [-2, -1, 1, 2] {
            let neighbor = index + offset
            guard items.indices.contains(neighbor), !items[neighbor].isDevice else { continue }
            let item = items[neighbor]
            guard CacheManager.cachedOriginal(assetId: item.assetId, filename: item.filename) == nil else { continue }
            guard let asset = store.asset(byId: item.assetId) else { continue }
            Task {
                _ = try? await store.downloadOriginal(asset, allowsCellular: allowsCellular)
            }
        }
    }
}

struct DeviceButtons: View {
    @EnvironmentObject var store: VaultStore
    let asset: PHAsset
    @Binding var showInfo: Bool
    @Binding var cellularPrompt: [PHAsset]?
    @State private var inVault = false

    var body: some View {
        let id = asset.localIdentifier
        let queued = store.queuedSourceIds.contains(id)
        Group {
            if inVault {
                Label("Backed up", systemImage: "checkmark.icloud")
            } else if queued {
                ProgressView().tint(.white)
            } else {
                Button {
                    requestManualBackup([asset], store: store, prompt: $cellularPrompt)
                } label: {
                    Label("Back up", systemImage: "icloud.and.arrow.up")
                }
            }
        }
        .task(id: "\(id)|\(queued)") {
            inVault = await store.index.isKnownSource(id)
        }
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
        }
    }
}

// Vault page: shows the thumbnail immediately, swaps in the decrypted original.
struct AssetPageView: View {
    @EnvironmentObject var store: VaultStore
    let item: TimelineItem

    @State private var thumb: UIImage?
    @State private var fullImage: UIImage?
    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var loading = false
    @State private var failed = false
    @State private var showCellularPrompt = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let fullImage {
                ZoomableImage(image: fullImage)
            } else if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            if loading {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Download failed").font(.caption)
                    Button("Retry") {
                        failed = false
                        Task { await loadOriginal(allowsCellular: AppSettings.cellularPolicy == .always) }
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .task(id: item.id) {
            if let cached = ThumbnailMemoryCache.shared.image(item.assetId) {
                thumb = cached
            } else {
                let path = CacheManager.thumbURL(assetId: item.assetId).path
                thumb = await Task.detached { UIImage(contentsOfFile: path) }.value
            }
            await startLoad()
        }
        .onDisappear { player?.pause() }
        .confirmationDialog("Download original over cellular?", isPresented: $showCellularPrompt, titleVisibility: .visible) {
            Button("Download") {
                Task { await loadOriginal(allowsCellular: true) }
            }
            Button("Wi-Fi only") {
                Task { await loadOriginal(allowsCellular: false) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startLoad() async {
        if CacheManager.cachedOriginal(assetId: item.assetId, filename: item.filename) == nil
            && AppSettings.cellularPolicy == .ask {
            showCellularPrompt = true
            return
        }
        await loadOriginal(allowsCellular: AppSettings.cellularPolicy == .always)
    }

    private func loadOriginal(allowsCellular: Bool) async {
        guard !loading else { return }
        guard let asset = store.asset(byId: item.assetId) else {
            failed = true
            return
        }
        loading = true
        defer { loading = false }
        do {
            let url = try await store.downloadOriginal(asset, allowsCellular: allowsCellular) { value in
                Task { @MainActor in progress = value }
            }
            if item.isVideo {
                player = AVPlayer(url: url)
            } else {
                let loaded = await Task.detached { UIImage(contentsOfFile: url.path) }.value
                fullImage = loaded
            }
        } catch {
            failed = true
        }
    }
}

// Device page: full-quality image or video straight from the photo library, no cloud involved.
struct DevicePageView: View {
    let asset: PHAsset

    @State private var preview: UIImage?
    @State private var fullImage: UIImage?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let fullImage {
                ZoomableImage(image: fullImage)
            } else if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            if loading {
                ProgressView().tint(.white)
            }
            if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Could not load from the photo library").font(.caption)
                }
                .foregroundStyle(.white)
            }
        }
        .task(id: asset.localIdentifier) { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        preview = await DeviceMedia.thumbnail(for: asset, side: 512)
        loading = true
        defer { loading = false }
        if asset.mediaType == .video {
            if let item = await DeviceMedia.playerItem(for: asset) {
                player = AVPlayer(playerItem: item)
            } else {
                failed = true
            }
        } else if let image = await DeviceMedia.fullImage(for: asset) {
            fullImage = image
        } else {
            failed = true
        }
    }
}

struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, lastScale * value)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 {
                            withAnimation { resetZoom() }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1 {
                        resetZoom()
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

struct InfoSheet: View {
    @EnvironmentObject var store: VaultStore
    let item: TimelineItem
    @State private var asset: Asset?

    var body: some View {
        NavigationStack {
            List {
                if let phAsset = item.phAsset {
                    LabeledContent("Date", value: phAsset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                    LabeledContent("Resolution", value: "\(phAsset.pixelWidth) × \(phAsset.pixelHeight)")
                    if phAsset.mediaType == .video {
                        LabeledContent("Duration", value: formatDuration(phAsset.duration))
                    }
                } else {
                    LabeledContent("Date", value: item.date.formatted(date: .abbreviated, time: .shortened))
                    if let asset {
                        LabeledContent("Resolution", value: "\(asset.width) × \(asset.height)")
                    }
                    if item.isVideo {
                        LabeledContent("Duration", value: formatDuration(item.duration))
                    }
                    if let asset {
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                    }
                    LabeledContent("Filename", value: item.filename)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: item.id) {
            if !item.isDevice {
                asset = store.asset(byId: item.assetId)
            }
        }
    }
}
