import Foundation
import SwiftData
import Photos
import UIKit

struct DiagnosticsSnapshot {
    var liveAssets = 0
    var deletedAssets = 0
    var sections = 0
    var thumbsCached = 0
    var lastSyncDuration: TimeInterval = 0
    var lastSyncFiles = 0
    var thumbQueued = 0
    var thumbRunning = 0
    var thumbFetched = 0
    var thumbFailures = 0
    var backupQueue = 0
    var warmupDone = 0
    var indexLoadTime: TimeInterval = 0
    var timelineBuildTime: TimeInterval = 0
}

@MainActor
final class VaultStore: ObservableObject {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let client = HiDriveClient.shared
    let dataActor: VaultDataActor
    let index: LibraryIndex
    let planner = PrefetchPlanner()
    let warmup: ThumbnailWarmup

    @Published var hasVault: Bool
    @Published var onboarded: Bool
    @Published var isConnected = false
    @Published var accountAlias: String?
    @Published var isSyncing = false
    @Published var syncDone = 0
    @Published var syncTotal = 0
    @Published var isBackingUp = false
    @Published var backupRemaining = 0
    @Published var isRebuilding = false
    @Published var indexReady = false
    @Published var lastError: String?
    // Precomputed off-main by LibraryIndex; the grid reads these arrays only.
    @Published private(set) var timeline = Timeline()
    // Local identifiers waiting in (or being processed by) the backup queue.
    @Published private(set) var queuedSourceIds: Set<String> = []

    private(set) var lastSyncDuration: TimeInterval = 0
    private(set) var lastSyncFiles = 0
    private(set) var indexLoadTime: TimeInterval = 0

    private let libraryObserver = PhotoLibraryObserver()
    private var observingLibrary = false
    private var libraryChangeTask: Task<Void, Never>?
    private var backupQueue: [PHAsset] = []
    private var queueAllowsCellular: [String: Bool] = [:]
    private var isFlushing = false
    private var flushRequested = false

    init(container: ModelContainer) {
        self.container = container
        self.dataActor = VaultDataActor(modelContainer: container)
        let index = LibraryIndex()
        self.index = index
        self.warmup = ThumbnailWarmup(index: index)
        self.hasVault = VaultKeys.masterKey != nil
        self.onboarded = AppSettings.onboardingComplete
        CacheManager.ensureDirectories()
        planner.flatProvider = { [weak self] in self?.timeline.flat ?? [] }
        libraryObserver.onChange = { [weak self] in
            Task { @MainActor in self?.libraryDidChange() }
        }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let index = self.index
        await index.setPublisher { [weak self] timeline in
            Task { @MainActor in self?.timeline = timeline }
        }
        await ThumbnailFetcher.shared.setOnDiskCached { id in
            Task { await index.markThumbCached(id) }
        }
        await refreshConnectionState()
        await loadIndex()
        await configureFetcher()
        await refreshDeviceItems()
        indexReady = true
    }

    private func loadIndex() async {
        let start = Date()
        let thumbs = await Task.detached { CacheManager.thumbCacheIds() }.value
        do {
            let entries = try await dataActor.loadIndex(thumbCache: thumbs)
            await index.setDuplicateSources(duplicateSourceIds)
            await index.replaceAll(entries)
        } catch {
            lastError = "Could not load the local index: \(error.localizedDescription)"
        }
        indexLoadTime = Date().timeIntervalSince(start)
    }

    func configureFetcher() async {
        var base: String?
        if await HiDriveAuth.shared.isConnected {
            base = try? await client.basePath()
        }
        await ThumbnailFetcher.shared.configure(masterKey: VaultKeys.masterKey, basePath: base)
    }

    func refreshConnectionState() async {
        isConnected = await HiDriveAuth.shared.isConnected
        accountAlias = await HiDriveAuth.shared.accountAlias()
    }

    func startObservingLibraryIfAuthorized() {
        guard !observingLibrary, PhotoKitExport.currentAuthorization() else { return }
        observingLibrary = true
        libraryObserver.register()
    }

    func startWarmupIfAllowed() {
        guard onboarded, isConnected, hasVault, !isRebuilding else { return }
        warmup.start()
    }

    // PhotoKit posts bursts of changes (e.g. while iCloud downloads); coalesce them.
    private func libraryDidChange() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.onboarded else { return }
            await self.refreshDeviceItems()
            if AppSettings.autoBackupEnabled {
                // Separate task: cancelling the debounce must not cancel uploads in flight.
                Task { await self.backupNow() }
            }
        }
    }

    // MARK: - Index access

    func asset(byId id: String) -> Asset? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func asset(sha256 hash: String) -> Asset? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.sha256 == hash })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func seenJournalNames() -> Set<String> {
        let files = (try? context.fetch(FetchDescriptor<SeenJournalFile>())) ?? []
        return Set(files.map(\.name))
    }

    // Byte-identical camera-roll duplicates of an asset already linked to another local item. Local only.
    private var duplicateSourceIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "duplicateSourceIds") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "duplicateSourceIds") }
    }

    // MARK: - Device items

    func refreshDeviceItems() async {
        guard PhotoKitExport.currentAuthorization() else {
            await index.setDeviceItems([])
            return
        }
        let cutoff = AppSettings.autoBackupCutoff
        let items = await Task.detached { () -> [PHAsset] in
            var out: [PHAsset] = []
            PhotoKitExport.fetchAssets(createdAfter: cutoff, includeVideos: true, newestFirst: true)
                .enumerateObjects { asset, _, _ in out.append(asset) }
            return out
        }.value
        await index.setDeviceItems(items)
    }

    // MARK: - Sync

    // Journal files are merged one at a time on the data actor; only progress reaches the main thread.
    func syncNow() async {
        guard !isSyncing, !isRebuilding, let masterKey = VaultKeys.masterKey else { return }
        guard await HiDriveAuth.shared.isConnected else { return }
        isSyncing = true
        let start = Date()
        var merged = 0
        defer {
            isSyncing = false
            syncTotal = 0
            syncDone = 0
        }
        do {
            try await client.ensureLayout(deviceId: VaultKeys.deviceId)
            let base = try await client.basePath()
            await configureFetcher()
            let seen = try await dataActor.seenJournalNames()
            var files: [(dir: String, name: String)] = []
            let deviceDirs = try await client.list(path: base + "/journal").filter { $0.type == "dir" }
            for dir in deviceDirs {
                let names = try await client.list(path: base + "/journal/" + dir.name)
                    .filter { $0.type == "file" }
                    .map(\.name)
                    .sorted()
                for name in names where !seen.contains(dir.name + "/" + name) {
                    files.append((dir.name, name))
                }
            }
            syncTotal = files.count
            syncDone = 0
            var thumbs = Set<String>()
            if !files.isEmpty {
                thumbs = await Task.detached { CacheManager.thumbCacheIds() }.value
            }
            for file in files {
                if Task.isCancelled { break }
                guard let parsed = JournalCoding.parseJournalFilename(file.name) else {
                    syncDone += 1
                    continue
                }
                let path = base + "/journal/" + file.dir + "/" + file.name
                let encrypted = try await client.downloadSmall(path: path)
                let outcome = try await dataActor.mergeJournalFile(
                    encrypted: encrypted, blobId: parsed.blobId, masterKey: masterKey,
                    seenName: file.dir + "/" + file.name, thumbCache: thumbs)
                await index.remove(ids: outcome.purged)
                await index.upsert(outcome.upserts)
                merged += 1
                syncDone = merged
            }
        } catch {
            lastError = "Sync failed: \(error.localizedDescription)"
        }
        lastSyncDuration = Date().timeIntervalSince(start)
        lastSyncFiles = merged
        await refreshDeviceItems()
    }

    // Drops the local SwiftData rows and thumbnail cache, keeps Keychain and settings, then re-syncs.
    func rebuildLocalIndex() async {
        guard !isRebuilding, !isSyncing, !isBackingUp else { return }
        isRebuilding = true
        indexReady = false
        warmup.stop()
        await ThumbnailFetcher.shared.reset()
        ThumbnailMemoryCache.shared.removeAll()
        do {
            try await dataActor.wipeAll()
        } catch {
            lastError = "Could not clear the local index: \(error.localizedDescription)"
        }
        await Task.detached { CacheManager.clearThumbnails() }.value
        duplicateSourceIds = []
        await index.setDuplicateSources([])
        await index.replaceAll([])
        isRebuilding = false
        indexReady = true
        await syncNow()
        startWarmupIfAllowed()
    }

    // MARK: - Journal writing

    private func nextJournalSeq() -> Int {
        let prefix = VaultKeys.deviceId + "/"
        let seqs = seenJournalNames()
            .filter { $0.hasPrefix(prefix) }
            .compactMap { JournalCoding.parseJournalFilename(String($0.dropFirst(prefix.count)))?.seq }
        return (seqs.max() ?? 0) + 1
    }

    // Returns ids of "add" entries once the journal file is safely uploaded.
    private func flushJournal() async throws -> [String] {
        guard let masterKey = VaultKeys.masterKey else { return [] }
        let pending = PendingJournal.load()
        guard !pending.isEmpty else { return [] }
        let base = try await client.basePath()
        let blobId = UUID()
        let name = JournalCoding.journalFilename(seq: nextJournalSeq(), blobId: blobId)
        let data = try JournalCoding.encode(pending)
        let tmpEnc = CacheManager.tmpDir.appendingPathComponent(UUID().uuidString)
        try BlobCrypto.encryptData(data, to: tmpEnc, masterKey: masterKey, blobId: blobId)
        defer { try? FileManager.default.removeItem(at: tmpEnc) }
        try await client.uploadFile(localURL: tmpEnc, directory: base + "/journal/" + VaultKeys.deviceId,
                                    name: name, allowsCellular: true)
        context.insert(SeenJournalFile(name: VaultKeys.deviceId + "/" + name))
        try? context.save()
        PendingJournal.removeFirst(pending.count)
        return pending.filter { $0.op == "add" }.map(\.id)
    }

    private func markBackedUp(_ ids: [String]) async {
        for id in ids {
            asset(byId: id)?.backedUp = true
            await index.update(id: id, backedUp: true)
        }
        try? context.save()
    }

    // One flush at a time; a request arriving mid-flush makes the running flush loop once more.
    private func flushAndMark() async {
        if isFlushing {
            flushRequested = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushRequested = false
            do {
                let ids = try await flushJournal()
                await markBackedUp(ids)
            } catch {
                lastError = "Journal upload failed: \(error.localizedDescription)"
                return
            }
        } while flushRequested
    }

    // MARK: - Backup

    private func backupAllowedNow() -> Bool {
        if AppSettings.chargingOnlyBackup {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            if state != .charging && state != .full { return false }
        }
        return true
    }

    // Automatic backup: camera-roll assets created after the cutoff, only when enabled.
    func backupNow(force: Bool = false) async {
        guard AppSettings.autoBackupEnabled, VaultKeys.masterKey != nil, !isRebuilding else { return }
        guard await HiDriveAuth.shared.isConnected else { return }
        guard PhotoKitExport.currentAuthorization() else { return }
        guard force || backupAllowedNow() else { return }
        // Not starting on cellular: a Wi-Fi-only upload would hold the queue until Wi-Fi returns.
        if AppSettings.wifiOnlyBackup, await NetworkProbe.isCellularOnly() { return }
        let known = await index.knownSourceIds()
        let cutoff = AppSettings.autoBackupCutoff
        let includeVideos = AppSettings.includeVideos
        let todo = await Task.detached { () -> [PHAsset] in
            var out: [PHAsset] = []
            PhotoKitExport.fetchAssets(createdAfter: cutoff, includeVideos: includeVideos, newestFirst: false)
                .enumerateObjects { asset, _, _ in
                    if !known.contains(asset.localIdentifier) { out.append(asset) }
                }
            return out
        }.value
        enqueueBackup(todo, allowsCellular: !AppSettings.wifiOnlyBackup, first: false)
        await drainBackupQueue()
    }

    func manualBackupNeedsCellularConsent() async -> Bool {
        guard AppSettings.wifiOnlyBackup else { return false }
        return await NetworkProbe.isCellularOnly()
    }

    // Manual backup: ignores the automatic toggle and charging rule, and goes ahead of queued automatic items.
    func backup(phAssets: [PHAsset], allowCellular: Bool = false) {
        guard VaultKeys.masterKey != nil, isConnected, !isRebuilding else {
            lastError = "Connect STRATO HiDrive before backing up."
            return
        }
        enqueueBackup(phAssets, allowsCellular: allowCellular || !AppSettings.wifiOnlyBackup, first: true)
        Task { await drainBackupQueue() }
    }

    private func enqueueBackup(_ assets: [PHAsset], allowsCellular: Bool, first: Bool) {
        var batch: [PHAsset] = []
        for asset in assets {
            let id = asset.localIdentifier
            if queuedSourceIds.contains(id) {
                // Already waiting (or in progress): only a manual request moves a waiting item forward.
                guard first, let index = backupQueue.firstIndex(where: { $0.localIdentifier == id }) else { continue }
                backupQueue.remove(at: index)
                if allowsCellular { queueAllowsCellular[id] = true }
            } else {
                queuedSourceIds.insert(id)
                queueAllowsCellular[id] = allowsCellular
            }
            batch.append(asset)
        }
        if first {
            backupQueue.insert(contentsOf: batch, at: 0)
        } else {
            backupQueue.append(contentsOf: batch)
        }
        backupRemaining = queuedSourceIds.count
    }

    private func drainBackupQueue() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        var addsSinceFlush = 0
        while let phAsset = backupQueue.first {
            if Task.isCancelled {
                backupQueue.removeAll()
                queueAllowsCellular.removeAll()
                queuedSourceIds.removeAll()
                break
            }
            backupQueue.removeFirst()
            let id = phAsset.localIdentifier
            let allowsCellular = queueAllowsCellular.removeValue(forKey: id) ?? false
            do {
                let known = await index.isKnownSource(id)
                if !known, try await backupOne(phAsset, allowsCellular: allowsCellular) {
                    addsSinceFlush += 1
                }
            } catch {
                lastError = "Backup failed for an item: \(error.localizedDescription)"
            }
            queuedSourceIds.remove(id)
            backupRemaining = queuedSourceIds.count
            if addsSinceFlush >= 50 {
                await flushAndMark()
                addsSinceFlush = 0
            }
        }
        // Also retries journal entries left pending by an earlier failed upload.
        await flushAndMark()
        isBackingUp = false
        backupRemaining = queuedSourceIds.count
        await refreshDeviceItems()
        // Items enqueued during the final flush saw isBackingUp and returned; pick them up now.
        if !backupQueue.isEmpty && !Task.isCancelled {
            await drainBackupQueue()
        }
    }

    // Returns true when an "add" entry is now pending; false when the bytes are already in the vault.
    private func backupOne(_ phAsset: PHAsset, allowsCellular: Bool) async throws -> Bool {
        guard let masterKey = VaultKeys.masterKey else { return false }
        let base = try await client.basePath()
        let assetId = UUID().uuidString.lowercased()
        let blobId = UUID(uuidString: assetId)!

        let tmpOriginal = CacheManager.tmpDir.appendingPathComponent(assetId + ".orig")
        defer { try? FileManager.default.removeItem(at: tmpOriginal) }
        let (filename, mime) = try await PhotoKitExport.exportOriginal(phAsset, to: tmpOriginal)
        let sha = try await Task.detached { try PhotoKitExport.sha256OfFile(tmpOriginal) }.value

        if let existing = asset(sha256: sha) {
            await linkDuplicate(existing, to: phAsset.localIdentifier)
            return false
        }

        guard let thumbImage = await PhotoKitExport.generateThumbnail(phAsset),
              let thumbJPEG = thumbImage.jpegData(compressionQuality: 0.7) else {
            throw ExportError.thumbnailFailed
        }
        try thumbJPEG.write(to: CacheManager.thumbURL(assetId: assetId))

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: tmpOriginal.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let tmpEncOriginal = CacheManager.tmpDir.appendingPathComponent(assetId + ".enc")
        let tmpEncThumb = CacheManager.tmpDir.appendingPathComponent(assetId + ".thumb.enc")
        defer {
            try? FileManager.default.removeItem(at: tmpEncOriginal)
            try? FileManager.default.removeItem(at: tmpEncThumb)
        }
        try await Task.detached {
            try BlobCrypto.encryptFile(at: tmpOriginal, to: tmpEncOriginal, masterKey: masterKey, blobId: blobId)
            try BlobCrypto.encryptData(thumbJPEG, to: tmpEncThumb, masterKey: masterKey, blobId: blobId)
        }.value

        try await client.uploadFile(localURL: tmpEncOriginal, directory: base + "/originals",
                                    name: assetId + ".enc", allowsCellular: allowsCellular)
        try await client.uploadFile(localURL: tmpEncThumb, directory: base + "/thumbs",
                                    name: assetId + ".enc", allowsCellular: allowsCellular)

        let now = Date()
        let kind = phAsset.mediaType == .video ? "video" : "photo"
        let model = Asset(id: assetId, filename: filename, kind: kind, mime: mime,
                          captured: phAsset.creationDate ?? now,
                          width: phAsset.pixelWidth, height: phAsset.pixelHeight,
                          duration: phAsset.duration, bytes: bytes, sha256: sha,
                          sourceAssetId: phAsset.localIdentifier, lastJournalTs: now)
        model.thumbCached = true
        context.insert(model)
        try? context.save()
        await index.upsert([IndexEntry(asset: model, thumbCached: true, calendar: Calendar.current)])

        let meta = JournalMeta(filename: filename, kind: kind, mime: mime,
                               captured: phAsset.creationDate ?? now,
                               width: phAsset.pixelWidth, height: phAsset.pixelHeight,
                               duration: phAsset.duration, bytes: bytes, sha256: sha,
                               sourceAssetId: phAsset.localIdentifier)
        PendingJournal.append(JournalEntry(op: "add", id: assetId, ts: now,
                                           device: VaultKeys.deviceId, meta: meta))
        return true
    }

    // Same bytes already in the vault (e.g. a Takeout import, or an upload from another phone): link the
    // asset to this local item without a journal entry. If its link still resolves to a different item on
    // this phone, the two are camera-roll duplicates; re-pointing would make them take the link from each
    // other on every run, so the newcomer is remembered as a duplicate instead.
    private func linkDuplicate(_ existing: Asset, to localId: String) async {
        let current = existing.sourceAssetId
        if !current.isEmpty, current != localId,
           PHAsset.fetchAssets(withLocalIdentifiers: [current], options: nil).count > 0 {
            var duplicates = duplicateSourceIds
            duplicates.insert(localId)
            duplicateSourceIds = duplicates
            await index.setDuplicateSources(duplicates)
        } else {
            existing.sourceAssetId = localId
            try? context.save()
            await index.update(id: existing.id, sourceAssetId: localId)
        }
    }

    // MARK: - User operations

    private func appendUserOp(_ op: String, asset: Asset) {
        let now = Date()
        asset.lastJournalTs = now
        PendingJournal.append(JournalEntry(op: op, id: asset.id, ts: now,
                                           device: VaultKeys.deviceId, meta: nil))
    }

    func setFavorite(ids: [String], _ favorite: Bool) {
        for id in ids {
            guard let asset = asset(byId: id) else { continue }
            asset.isFavorite = favorite
            appendUserOp(favorite ? "favorite" : "unfavorite", asset: asset)
        }
        try? context.save()
        Task {
            for id in ids { await index.update(id: id, favorite: favorite) }
            await flushAndMark()
        }
    }

    func moveToTrash(ids: [String]) {
        for id in ids {
            guard let asset = asset(byId: id) else { continue }
            asset.isDeleted = true
            asset.deletedAt = Date()
            appendUserOp("delete", asset: asset)
        }
        try? context.save()
        Task {
            for id in ids { await index.update(id: id, deleted: true) }
            await flushAndMark()
        }
    }

    func restoreFromTrash(_ asset: Asset) {
        asset.isDeleted = false
        asset.deletedAt = nil
        appendUserOp("restore", asset: asset)
        try? context.save()
        let id = asset.id
        Task {
            await index.update(id: id, deleted: false)
            await flushAndMark()
        }
    }

    func purge(_ asset: Asset) async {
        do {
            let base = try await client.basePath()
            try await client.deleteFile(path: base + "/originals/" + asset.id + ".enc")
            try await client.deleteFile(path: base + "/thumbs/" + asset.id + ".enc")
            PendingJournal.append(JournalEntry(op: "purge", id: asset.id, ts: Date(),
                                               device: VaultKeys.deviceId, meta: nil))
            let id = asset.id
            CacheManager.removeCachedFiles(assetId: id, filename: asset.filename)
            context.delete(asset)
            try? context.save()
            await index.remove(ids: [id])
            await flushAndMark()
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
    }

    func purgeOldTombstones() async {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.isDeleted == true })
        let tombstones = (try? context.fetch(descriptor)) ?? []
        for asset in tombstones where (asset.deletedAt ?? .distantFuture) < cutoff {
            await purge(asset)
        }
    }

    // MARK: - Originals

    func downloadOriginal(_ asset: Asset, allowsCellular: Bool,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = CacheManager.cachedOriginal(assetId: asset.id, filename: asset.filename) {
            asset.lastViewed = Date()
            CacheManager.touch(cached)
            try? context.save()
            return cached
        }
        guard let masterKey = VaultKeys.masterKey else { throw AuthError.notConnected }
        let base = try await client.basePath()
        let tmpEnc = CacheManager.tmpDir.appendingPathComponent(asset.id + ".dl.enc")
        defer { try? FileManager.default.removeItem(at: tmpEnc) }
        try await client.downloadFile(path: base + "/originals/" + asset.id + ".enc",
                                      to: tmpEnc, allowsCellular: allowsCellular, progress: progress)
        let destination = CacheManager.originalURL(assetId: asset.id, filename: asset.filename)
        let blobId = UUID(uuidString: asset.id)!
        try await Task.detached {
            try BlobCrypto.decryptFile(at: tmpEnc, to: destination, masterKey: masterKey, blobId: blobId)
        }.value
        asset.lastViewed = Date()
        CacheManager.touch(destination)
        try? context.save()
        await Task.detached { CacheManager.enforceOriginalsCap(AppSettings.originalsCacheCapBytes) }.value
        return destination
    }

    // MARK: - Diagnostics

    func diagnostics() async -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot()
        let counts = await index.counts()
        snapshot.liveAssets = counts.total - counts.deleted
        snapshot.deletedAssets = counts.deleted
        snapshot.thumbsCached = counts.thumbsCached
        snapshot.sections = timeline.sections.count
        snapshot.lastSyncDuration = lastSyncDuration
        snapshot.lastSyncFiles = lastSyncFiles
        snapshot.thumbQueued = await ThumbnailFetcher.shared.queuedCount
        snapshot.thumbRunning = await ThumbnailFetcher.shared.runningCount
        snapshot.thumbFetched = await ThumbnailFetcher.shared.fetchedFromNetwork
        snapshot.thumbFailures = await ThumbnailFetcher.shared.failures
        snapshot.backupQueue = queuedSourceIds.count
        snapshot.warmupDone = warmup.completedThisSession
        snapshot.indexLoadTime = indexLoadTime
        snapshot.timelineBuildTime = timeline.buildTime
        return snapshot
    }

    // MARK: - Account

    func disconnect() async {
        await HiDriveAuth.shared.disconnect()
        client.resetPathCache()
        warmup.stop()
        await refreshConnectionState()
        await configureFetcher()
    }
}
