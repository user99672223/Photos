import SwiftUI
import AVKit
import Photos

struct ViewerView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    let items: [TimelineItem]

    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var showInfo = false
    @State private var cellularPrompt: [PHAsset]?

    init(items: [TimelineItem], startIndex: Int) {
        self.items = items
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(items.indices, id: \.self) { index in
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
            prefetchAround(newIndex)
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private func page(for item: TimelineItem) -> some View {
        switch item {
        case .vault(let asset):
            AssetPageView(asset: asset)
        case .device(let asset):
            DevicePageView(asset: asset)
        }
    }

    private var currentItem: TimelineItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var bottomBar: some View {
        HStack(spacing: 44) {
            switch currentItem {
            case .vault(let asset)?:
                vaultButtons(asset)
            case .device(let asset)?:
                deviceButtons(asset)
            case nil:
                EmptyView()
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func vaultButtons(_ asset: Asset) -> some View {
        if let url = CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            Image(systemName: "square.and.arrow.up").opacity(0.3)
        }
        Button {
            store.setFavorite(asset, !asset.isFavorite)
        } label: {
            Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
        }
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
        }
        Button(role: .destructive) {
            store.moveToTrash([asset])
            dismiss()
        } label: {
            Image(systemName: "trash")
        }
    }

    @ViewBuilder
    private func deviceButtons(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        if store.isInVault(sourceId: id) {
            Label("Backed up", systemImage: "checkmark.icloud")
        } else if store.queuedSourceIds.contains(id) {
            ProgressView().tint(.white)
        } else {
            Button {
                requestManualBackup([asset], store: store, prompt: $cellularPrompt)
            } label: {
                Label("Back up", systemImage: "icloud.and.arrow.up")
            }
        }
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
        }
    }

    private func prefetchAround(_ index: Int) {
        guard AppSettings.cellularPolicy != .ask else { return }
        let allowsCellular = AppSettings.cellularPolicy == .always
        for offset in [-2, -1, 1, 2] {
            let neighbor = index + offset
            guard items.indices.contains(neighbor), case .vault(let asset) = items[neighbor] else { continue }
            guard CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) == nil else { continue }
            Task {
                _ = try? await store.downloadOriginal(asset, allowsCellular: allowsCellular)
            }
        }
    }
}

// Vault page: shows the cached thumbnail immediately, swaps in the decrypted original.
struct AssetPageView: View {
    @EnvironmentObject var store: VaultStore
    let asset: Asset

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
        .task(id: asset.id) {
            thumb = UIImage(contentsOfFile: CacheManager.thumbURL(assetId: asset.id).path)
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
        if CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) == nil
            && AppSettings.cellularPolicy == .ask {
            showCellularPrompt = true
            return
        }
        await loadOriginal(allowsCellular: AppSettings.cellularPolicy == .always)
    }

    private func loadOriginal(allowsCellular: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let url = try await store.downloadOriginal(asset, allowsCellular: allowsCellular) { value in
                Task { @MainActor in progress = value }
            }
            if asset.isVideo {
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
    let item: TimelineItem

    var body: some View {
        NavigationStack {
            List {
                switch item {
                case .vault(let asset):
                    LabeledContent("Date", value: asset.captured.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Resolution", value: "\(asset.width) × \(asset.height)")
                    if asset.isVideo {
                        LabeledContent("Duration", value: formatDuration(asset.duration))
                    }
                    LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                    LabeledContent("Filename", value: asset.filename)
                case .device(let asset):
                    LabeledContent("Date", value: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                    LabeledContent("Resolution", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    if asset.mediaType == .video {
                        LabeledContent("Duration", value: formatDuration(asset.duration))
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
