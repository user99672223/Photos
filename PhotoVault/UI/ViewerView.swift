import SwiftUI
import AVKit

struct ViewerView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    let assets: [Asset]
    @State var startIndex: Int

    @State private var currentIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var showInfo = false
    @State private var askCellular = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(assets.indices, id: \.self) { index in
                    AssetPageView(asset: assets[index], isCurrent: index == currentIndex, askCellular: $askCellular)
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
                    .onEnded { value in
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
            if let asset = currentAsset {
                InfoSheet(asset: asset)
                    .presentationDetents([.medium])
            }
        }
        .onAppear {
            if !appeared {
                appeared = true
                currentIndex = startIndex
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            prefetchAround(newIndex)
        }
        .statusBarHidden()
    }

    private var currentAsset: Asset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    private var bottomBar: some View {
        HStack(spacing: 44) {
            if let asset = currentAsset,
               let url = CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            } else {
                Image(systemName: "square.and.arrow.up").opacity(0.3)
            }
            Button {
                if let asset = currentAsset {
                    store.setFavorite(asset, !asset.isFavorite)
                }
            } label: {
                Image(systemName: currentAsset?.isFavorite == true ? "heart.fill" : "heart")
            }
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            Button(role: .destructive) {
                if let asset = currentAsset {
                    store.moveToTrash([asset])
                    dismiss()
                }
            } label: {
                Image(systemName: "trash")
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func prefetchAround(_ index: Int) {
        guard AppSettings.cellularPolicy != .ask else { return }
        let allowsCellular = AppSettings.cellularPolicy == .always
        for offset in [-2, -1, 1, 2] {
            let neighbor = index + offset
            guard assets.indices.contains(neighbor) else { continue }
            let asset = assets[neighbor]
            guard CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) == nil else { continue }
            Task {
                _ = try? await store.downloadOriginal(asset, allowsCellular: allowsCellular)
            }
        }
    }
}

// One page: shows the cached thumbnail immediately, swaps in the decrypted original.
struct AssetPageView: View {
    @EnvironmentObject var store: VaultStore
    let asset: Asset
    let isCurrent: Bool
    @Binding var askCellular: Bool

    @State private var thumb: UIImage?
    @State private var fullImage: UIImage?
    @State private var videoURL: URL?
    @State private var progress: Double = 0
    @State private var loading = false
    @State private var failed = false
    @State private var showCellularPrompt = false

    var body: some View {
        ZStack {
            if let videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
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
                videoURL = url
            } else {
                let loaded = await Task.detached { UIImage(contentsOfFile: url.path) }.value
                fullImage = loaded
            }
        } catch {
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
    let asset: Asset

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Date", value: asset.captured.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Resolution", value: "\(asset.width) × \(asset.height)")
                if asset.isVideo {
                    LabeledContent("Duration", value: formatDuration(asset.duration))
                }
                LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                LabeledContent("Filename", value: asset.filename)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
