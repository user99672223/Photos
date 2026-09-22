import SwiftUI
import SwiftData
import Photos

struct LibraryView: View {
    @Query(sort: \Asset.captured, order: .reverse) private var allAssets: [Asset]

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    FilteredGridView(title: "Favorites",
                                     assets: allAssets.filter { $0.isFavorite && !$0.isDeleted })
                } label: {
                    Label("Favorites", systemImage: "heart")
                }
                NavigationLink {
                    FilteredGridView(title: "Videos",
                                     assets: allAssets.filter { $0.isVideo && !$0.isDeleted })
                } label: {
                    Label("Videos", systemImage: "video")
                }
                NavigationLink {
                    TrashView()
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                NavigationLink {
                    FreeUpSpaceView()
                } label: {
                    Label("Free up space", systemImage: "internaldrive")
                }
            }
            .navigationTitle("Library")
        }
    }
}

struct FilteredGridView: View {
    let title: String
    let assets: [Asset]
    @State private var viewer: ViewerContext?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(assets, id: \.id) { asset in
                    ThumbCell(asset: asset, isSelected: false, selecting: false)
                        .onTapGesture {
                            let index = assets.firstIndex { $0.id == asset.id } ?? 0
                            viewer = ViewerContext(id: asset.id,
                                                   items: assets.map { TimelineItem.vault($0) },
                                                   index: index)
                        }
                }
            }
        }
        .navigationTitle(title)
        .fullScreenCover(item: $viewer) { context in
            ViewerView(items: context.items, startIndex: context.index)
        }
    }
}

struct TrashView: View {
    @EnvironmentObject var store: VaultStore
    @Query(filter: #Predicate<Asset> { $0.isDeleted == true },
           sort: [SortDescriptor(\Asset.deletedAt, order: .reverse)])
    private var trashed: [Asset]

    var body: some View {
        List {
            if trashed.isEmpty {
                Text("Trash is empty").foregroundStyle(.secondary)
            }
            ForEach(trashed, id: \.id) { asset in
                HStack(spacing: 12) {
                    ThumbCell(asset: asset, isSelected: false, selecting: false)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text(asset.filename).font(.caption).lineLimit(1)
                        Text("\(daysRemaining(asset)) days remaining")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") {
                        store.restoreFromTrash(asset)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Button(role: .destructive) {
                        Task { await store.purge(asset) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Trash")
    }

    private func daysRemaining(_ asset: Asset) -> Int {
        guard let deletedAt = asset.deletedAt else { return 30 }
        let elapsed = Date().timeIntervalSince(deletedAt)
        return max(0, 30 - Int(elapsed / 86400))
    }
}

// Backed-up assets still present in the camera roll, deletable to reclaim space.
struct FreeUpSpaceView: View {
    @EnvironmentObject var store: VaultStore
    @State private var candidates: [PHAsset] = []
    @State private var totalBytes: Int64 = 0
    @State private var working = false

    var body: some View {
        List {
            Section {
                LabeledContent("Backed-up items in camera roll", value: "\(candidates.count)")
                LabeledContent("Approximate size", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            }
            Section {
                Button(role: .destructive) {
                    deleteFromCameraRoll()
                } label: {
                    if working {
                        ProgressView()
                    } else {
                        Text("Delete from camera roll")
                    }
                }
                .disabled(candidates.isEmpty || working)
            } footer: {
                Text("Removes photos and videos from the system photo library. They stay in PhotoVault. iOS will ask you to confirm.")
            }
        }
        .navigationTitle("Free up space")
        .task { refresh() }
    }

    private func refresh() {
        let backedUp = store.allAssets().filter { $0.backedUp && !$0.sourceAssetId.isEmpty && !$0.isDeleted }
        var bytesBySource: [String: Int64] = [:]
        for asset in backedUp { bytesBySource[asset.sourceAssetId] = asset.bytes }
        let found = PhotoKitExport.fetchAssets(localIdentifiers: Array(bytesBySource.keys))
        candidates = found
        totalBytes = found.reduce(0) { $0 + (bytesBySource[$1.localIdentifier] ?? 0) }
    }

    private func deleteFromCameraRoll() {
        working = true
        let toDelete = candidates
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
        }) { _, _ in
            Task { @MainActor in
                working = false
                refresh()
            }
        }
    }
}
