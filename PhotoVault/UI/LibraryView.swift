import SwiftUI
import SwiftData
import Photos

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    FilteredGridView(title: "Favorites", filter: .favorites)
                } label: {
                    Label("Favorites", systemImage: "heart")
                }
                NavigationLink {
                    FilteredGridView(title: "Videos", filter: .videos)
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

// Filtered lists come from the in-memory index, recomputed off-main when the timeline changes.
struct FilteredGridView: View {
    @EnvironmentObject var store: VaultStore
    let title: String
    let filter: LibraryFilter
    @State private var items: [TimelineItem] = []
    @State private var viewer: ViewerContext?

    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let side = max(1, (geo.size.width - spacing * 2) / 3)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: 3), spacing: spacing) {
                    ForEach(items) { item in
                        TimelineCell(item: item, side: side, isSelected: false, selecting: false, reportsVisibility: false)
                            .onTapGesture {
                                viewer = ViewerContext(id: item.id, items: items, index: item.flatIndex)
                            }
                    }
                }
                if items.isEmpty {
                    Text("Nothing here yet")
                        .foregroundStyle(.secondary)
                        .padding(.top, 80)
                }
            }
        }
        .navigationTitle(title)
        .task(id: store.timeline.generation) {
            items = await store.index.filtered(filter)
        }
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
                    ThumbCell(item: TimelineItem.vault(asset, flatIndex: 0), side: 56, reportsVisibility: false)
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
        .task { await refresh() }
    }

    private func refresh() async {
        let bytesBySource = await store.index.backedUpSources()
        let ids = Array(bytesBySource.keys)
        let found = await Task.detached { PhotoKitExport.fetchAssets(localIdentifiers: ids) }.value
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
                await refresh()
            }
        }
    }
}
