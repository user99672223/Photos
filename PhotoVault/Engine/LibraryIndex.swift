import Foundation
import Photos

// Lightweight mirror of one Asset row; the UI never touches SwiftData objects for the timeline.
struct IndexEntry {
    let id: String
    let captured: Date
    let day: Date
    let isVideo: Bool
    let duration: Double
    let filename: String
    let bytes: Int64
    var sourceAssetId: String
    var isFavorite: Bool
    var isDeleted: Bool
    var backedUp: Bool
    var thumbCached: Bool

    init(asset: Asset, thumbCached: Bool, calendar: Calendar) {
        id = asset.id
        captured = asset.captured
        day = calendar.startOfDay(for: asset.captured)
        isVideo = asset.kind == "video"
        duration = asset.duration
        filename = asset.filename
        bytes = asset.bytes
        sourceAssetId = asset.sourceAssetId
        isFavorite = asset.isFavorite
        isDeleted = asset.isDeleted
        backedUp = asset.backedUp
        self.thumbCached = thumbCached
    }
}

// One cell of the Photos timeline: a vault asset, or a camera-roll asset that is not backed up yet.
struct TimelineItem: Identifiable {
    let id: String              // "v:<assetId>" or "d:<localIdentifier>"
    let assetId: String
    let isDevice: Bool
    let date: Date
    let day: Date
    let isVideo: Bool
    let duration: Double
    let isFavorite: Bool
    let filename: String
    let flatIndex: Int
    let phAsset: PHAsset?

    static func vault(_ entry: IndexEntry, flatIndex: Int) -> TimelineItem {
        TimelineItem(id: "v:" + entry.id, assetId: entry.id, isDevice: false, date: entry.captured, day: entry.day,
                     isVideo: entry.isVideo, duration: entry.duration, isFavorite: entry.isFavorite,
                     filename: entry.filename, flatIndex: flatIndex, phAsset: nil)
    }

    static func vault(_ asset: Asset, flatIndex: Int) -> TimelineItem {
        TimelineItem(id: "v:" + asset.id, assetId: asset.id, isDevice: false, date: asset.captured,
                     day: Calendar.current.startOfDay(for: asset.captured), isVideo: asset.isVideo,
                     duration: asset.duration, isFavorite: asset.isFavorite, filename: asset.filename,
                     flatIndex: flatIndex, phAsset: nil)
    }

    static func device(_ asset: PHAsset, flatIndex: Int, calendar: Calendar) -> TimelineItem {
        let date = asset.creationDate ?? .distantPast
        return TimelineItem(id: "d:" + asset.localIdentifier, assetId: asset.localIdentifier, isDevice: true,
                            date: date, day: calendar.startOfDay(for: date), isVideo: asset.mediaType == .video,
                            duration: asset.duration, isFavorite: false, filename: "", flatIndex: flatIndex,
                            phAsset: asset)
    }
}

struct DaySection: Identifiable {
    let id: Date
    let title: String
    let items: [TimelineItem]
    let deviceAssets: [PHAsset]
}

struct MonthMarker: Identifiable {
    let id: Date
    let label: String
    let sectionId: Date
}

struct Timeline {
    var sections: [DaySection] = []
    var flat: [TimelineItem] = []
    var months: [MonthMarker] = []
    var vaultCount = 0
    var deviceCount = 0
    var buildTime: TimeInterval = 0
    var generation = 0
}

enum LibraryFilter {
    case favorites
    case videos
}

// In-memory index of every asset plus the post-cutoff camera-roll items. Rebuilds the precomputed
// timeline off-main, coalesced to at most one publish per second.
actor LibraryIndex {
    private var entries: [String: IndexEntry] = [:]
    private var sourceIndex: [String: String] = [:]   // sourceAssetId -> asset id
    private var duplicateSources: Set<String> = []
    private var deviceItems: [PHAsset] = []
    private var rebuildTask: Task<Void, Never>?
    private var lastPublish = Date.distantPast
    private var generation = 0
    private var publish: (@Sendable (Timeline) -> Void)?
    private(set) var lastBuildTime: TimeInterval = 0
    private(set) var lastSectionCount = 0

    func setPublisher(_ handler: @escaping @Sendable (Timeline) -> Void) {
        publish = handler
    }

    // MARK: - Mutations

    func replaceAll(_ list: [IndexEntry]) {
        entries = Dictionary(minimumCapacity: list.count)
        sourceIndex = Dictionary(minimumCapacity: list.count)
        for entry in list {
            entries[entry.id] = entry
            if !entry.sourceAssetId.isEmpty { sourceIndex[entry.sourceAssetId] = entry.id }
        }
        scheduleRebuild(immediate: true)
    }

    func upsert(_ list: [IndexEntry]) {
        guard !list.isEmpty else { return }
        for entry in list {
            if let old = entries[entry.id], !old.sourceAssetId.isEmpty, old.sourceAssetId != entry.sourceAssetId {
                sourceIndex[old.sourceAssetId] = nil
            }
            entries[entry.id] = entry
            if !entry.sourceAssetId.isEmpty { sourceIndex[entry.sourceAssetId] = entry.id }
        }
        scheduleRebuild(immediate: false)
    }

    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let old = entries.removeValue(forKey: id), !old.sourceAssetId.isEmpty {
                sourceIndex[old.sourceAssetId] = nil
            }
        }
        scheduleRebuild(immediate: false)
    }

    func update(id: String, favorite: Bool? = nil, deleted: Bool? = nil, backedUp: Bool? = nil, sourceAssetId: String? = nil) {
        guard var entry = entries[id] else { return }
        if let favorite { entry.isFavorite = favorite }
        if let deleted { entry.isDeleted = deleted }
        if let backedUp { entry.backedUp = backedUp }
        if let sourceAssetId {
            if !entry.sourceAssetId.isEmpty { sourceIndex[entry.sourceAssetId] = nil }
            entry.sourceAssetId = sourceAssetId
            if !sourceAssetId.isEmpty { sourceIndex[sourceAssetId] = id }
        }
        entries[id] = entry
        scheduleRebuild(immediate: false)
    }

    // Thumbnail arrivals never trigger a timeline rebuild; cells manage their own image state.
    func markThumbCached(_ id: String) {
        entries[id]?.thumbCached = true
    }

    func setDuplicateSources(_ ids: Set<String>) {
        duplicateSources = ids
        scheduleRebuild(immediate: false)
    }

    func setDeviceItems(_ items: [PHAsset]) {
        deviceItems = items
        scheduleRebuild(immediate: false)
    }

    // MARK: - Queries

    func entry(_ id: String) -> IndexEntry? {
        entries[id]
    }

    func isKnownSource(_ localId: String) -> Bool {
        sourceIndex[localId] != nil || duplicateSources.contains(localId)
    }

    func knownSourceIds() -> Set<String> {
        var ids = duplicateSources
        ids.formUnion(sourceIndex.keys)
        return ids
    }

    func assetId(forSource localId: String) -> String? {
        sourceIndex[localId]
    }

    func filtered(_ filter: LibraryFilter) -> [TimelineItem] {
        var picked: [IndexEntry] = []
        for entry in entries.values where !entry.isDeleted {
            switch filter {
            case .favorites: if entry.isFavorite { picked.append(entry) }
            case .videos: if entry.isVideo { picked.append(entry) }
            }
        }
        picked.sort { $0.captured > $1.captured }
        var items: [TimelineItem] = []
        items.reserveCapacity(picked.count)
        for (i, entry) in picked.enumerated() {
            items.append(TimelineItem.vault(entry, flatIndex: i))
        }
        return items
    }

    // Backed-up assets that still map to a camera-roll item, with their sizes.
    func backedUpSources() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for entry in entries.values where entry.backedUp && !entry.isDeleted && !entry.sourceAssetId.isEmpty {
            out[entry.sourceAssetId] = entry.bytes
        }
        return out
    }

    func uncachedThumbIdsNewestFirst() -> [String] {
        var picked: [IndexEntry] = []
        for entry in entries.values where !entry.thumbCached && !entry.isDeleted {
            picked.append(entry)
        }
        picked.sort { $0.captured > $1.captured }
        return picked.map(\.id)
    }

    func counts() -> (total: Int, deleted: Int, thumbsCached: Int) {
        var deleted = 0
        var cached = 0
        for entry in entries.values {
            if entry.isDeleted { deleted += 1 }
            if entry.thumbCached { cached += 1 }
        }
        return (entries.count, deleted, cached)
    }

    // MARK: - Timeline

    private func scheduleRebuild(immediate: Bool) {
        guard rebuildTask == nil else { return }
        let wait = immediate ? 0 : max(0.25, 1.0 - Date().timeIntervalSince(lastPublish))
        rebuildTask = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            await self?.performRebuild()
        }
    }

    private func performRebuild() {
        rebuildTask = nil
        let timeline = buildTimeline()
        lastPublish = Date()
        lastBuildTime = timeline.buildTime
        lastSectionCount = timeline.sections.count
        publish?(timeline)
    }

    private func buildTimeline() -> Timeline {
        let start = Date()
        let calendar = Calendar.current

        var vault: [IndexEntry] = []
        vault.reserveCapacity(entries.count)
        for entry in entries.values where !entry.isDeleted {
            vault.append(entry)
        }
        vault.sort { $0.captured > $1.captured }
        let device = deviceItems.filter { sourceIndex[$0.localIdentifier] == nil && !duplicateSources.contains($0.localIdentifier) }

        // Both inputs are newest first; merge into one flat order.
        var flat: [TimelineItem] = []
        flat.reserveCapacity(vault.count + device.count)
        var v = 0
        var d = 0
        while v < vault.count || d < device.count {
            let takeVault: Bool
            if d >= device.count {
                takeVault = true
            } else if v >= vault.count {
                takeVault = false
            } else {
                takeVault = vault[v].captured >= (device[d].creationDate ?? .distantPast)
            }
            if takeVault {
                flat.append(TimelineItem.vault(vault[v], flatIndex: flat.count))
                v += 1
            } else {
                flat.append(TimelineItem.device(device[d], flatIndex: flat.count, calendar: calendar))
                d += 1
            }
        }

        // Flat is time-sorted, so each day's items are contiguous.
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d MMM yyyy"
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"
        var sections: [DaySection] = []
        var months: [MonthMarker] = []
        var lastMonth: Date?
        var i = 0
        while i < flat.count {
            let day = flat[i].day
            var j = i
            var deviceAssets: [PHAsset] = []
            while j < flat.count && flat[j].day == day {
                if let asset = flat[j].phAsset { deviceAssets.append(asset) }
                j += 1
            }
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = dayFormatter.string(from: day)
            }
            sections.append(DaySection(id: day, title: title, items: Array(flat[i..<j]), deviceAssets: deviceAssets))
            let components = calendar.dateComponents([.year, .month], from: day)
            if let month = calendar.date(from: components), month != lastMonth {
                months.append(MonthMarker(id: month, label: monthFormatter.string(from: month), sectionId: day))
                lastMonth = month
            }
            i = j
        }

        generation += 1
        return Timeline(sections: sections, flat: flat, months: months,
                        vaultCount: vault.count, deviceCount: device.count,
                        buildTime: Date().timeIntervalSince(start), generation: generation)
    }
}
