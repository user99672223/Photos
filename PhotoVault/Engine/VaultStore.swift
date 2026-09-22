import Foundation
import SwiftData
import Photos
import UIKit

@MainActor
final class VaultStore: ObservableObject {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let client = HiDriveClient.shared

    @Published var hasVault: Bool
    @Published var onboarded: Bool
    @Published var isConnected = false
    @Published var accountAlias: String?
    @Published var isSyncing = false
    @Published var isBackingUp = false
    @Published var backupRemaining = 0
    @Published var restoreDone = 0
    @Published var restoreTotal = 0
    @Published var lastError: String?
    // Camera-roll assets after the cutoff that are not in the vault, newest first.
    @Published private(set) var deviceItems: [PHAsset] = []
    // Local identifiers waiting in (or being processed by) the backup queue.
    @Published private(set) var queuedSourceIds: Set<String> = []

    private let libraryObserver = PhotoLibraryObserver()
    private var observingLibrary = false
    private var libraryChangeTask: Task<Void, Never>?
    private var backupQueue: [PHAsset] = []
    private var queueAllowsCellular: [String: Bool] = [:]
    private var isFlushing = false
    private var flushRequested = false

    init(container: ModelContainer) {
        self.container = container
        self.hasVault = VaultKeys.masterKey != nil
        self.onboarded = AppSettings.onboardingComplete
        CacheManager.ensureDirectories()
        Task { await refreshConnectionState() }
        libraryObserver.onChange = { [weak self] in
            Task { @MainActor in self?.libraryDidChange() }
        }
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

    // PhotoKit posts bursts of changes (e.g. while iCloud downloads); coalesce them.
    private func libraryDidChange() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.onboarded else { return }
            self.refreshDeviceItems()
            if AppSettings.autoBackupEnabled {
                // Separate task: cancelling the debounce must not cancel uploads in flight.
                Task { await self.backupNow() }
            }
        }
    }

    // MARK: - Index access

    func allAssets() -> [Asset] {
        (try? context.fetch(FetchDescriptor<Asset>())) ?? []
    }

    func asset(byId id: String) -> Asset? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func asset(sourceId: String) -> Asset? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.sourceAssetId == sourceId })
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

    private func knownSourceIds() -> Set<String> {
        var ids = duplicateSourceIds
        for asset in allAssets() where !asset.sourceAssetId.isEmpty {
            ids.insert(asset.sourceAssetId)
        }
        return ids
    }

    func isInVault(sourceId: String) -> Bool {
        asset(sourceId: sourceId) != nil || duplicateSourceIds.contains(sourceId)
    }

    // MARK: - Device items

    func refreshDeviceItems() {
        guard PhotoKitExport.currentAuthorization() else {
            deviceItems = []
            return
        }
        let known = knownSourceIds()
        var items: [PHAsset] = []
        PhotoKitExport.fetchAssets(createdAfter: AppSettings.autoBackupCutoff, includeVideos: true, newestFirst: true)
            .enumerateObjects { asset, _, _ in
                if !known.contains(asset.localIdentifier) { items.append(asset) }
            }
        deviceItems = items
    }

    // MARK: - Sync

    func syncNow() async {
        guard !isSyncing, let masterKey = VaultKeys.masterKey else { return }
        guard await HiDriveAuth.shared.isConnected else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await client.ensureLayout(deviceId: VaultKeys.deviceId)
            let base = try await client.basePath()
            var seen = seenJournalNames()
            var newEntries: [JournalEntry] = []
            let deviceDirs = try await client.list(path: base + "/journal").filter { $0.type == "dir" }
            for dir in deviceDirs {
                let files = try await client.list(path: base + "/journal/" + dir.name)
                    .filter { $0.type == "file" }
                    .sorted { $0.name < $1.name }
                for file in files {
                    let seenKey = dir.name + "/" + file.name
                    if seen.contains(seenKey) { continue }
                    guard let parsed = JournalCoding.parseJournalFilename(file.name) else { continue }
                    let tmpEnc = CacheManager.tmpDir.appendingPathComponent(UUID().uuidString)
                    try await client.downloadFile(path: base + "/journal/" + dir.name + "/" + file.name,
                                                  to: tmpEnc, allowsCellular: true)
                    let data = try BlobCrypto.decryptToData(at: tmpEnc, masterKey: masterKey, blobId: parsed.blobId)
                    try? FileManager.default.removeItem(at: tmpEnc)
                    newEntries.append(contentsOf: try JournalCoding.decode(data))
                    context.insert(SeenJournalFile(name: seenKey))
                    seen.insert(seenKey)
                }
            }
            apply(entries: newEntries.sorted { $0.ts < $1.ts })
            try? context.save()
        } catch {
            lastError = "Sync failed: \(error.localizedDescription)"
        }
        refreshDeviceItems()
        await thumbnailBackfill()
    }

    // Newest ts wins per asset; a "delete" is a tombstone, "purge" removes entirely.
    private func apply(entries: [JournalEntry]) {
        for entry in entries {
            let existing = asset(byId: entry.id)
            switch entry.op {
            case "add":
                guard existing == nil, let meta = entry.meta else { continue }
                let model = Asset(id: entry.id, filename: meta.filename, kind: meta.kind, mime: meta.mime,
                                  captured: meta.captured, width: meta.width, height: meta.height,
                                  duration: meta.duration, bytes: meta.bytes, sha256: meta.sha256,
                                  sourceAssetId: meta.sourceAssetId, lastJournalTs: entry.ts)
                model.backedUp = true
                model.thumbCached = CacheManager.hasThumb(assetId: entry.id)
                context.insert(model)
            case "delete":
                guard let existing, entry.ts >= existing.lastJournalTs else { continue }
                existing.isDeleted = true
                existing.deletedAt = entry.ts
                existing.lastJournalTs = entry.ts
            case "restore":
                guard let existing, entry.ts >= existing.lastJournalTs else { continue }
                existing.isDeleted = false
                existing.deletedAt = nil
                existing.lastJournalTs = entry.ts
            case "favorite", "unfavorite":
                guard let existing, entry.ts >= existing.lastJournalTs else { continue }
                existing.isFavorite = entry.op == "favorite"
                existing.lastJournalTs = entry.ts
            case "purge":
                guard let existing else { continue }
                CacheManager.removeCachedFiles(assetId: existing.id, filename: existing.filename)
                context.delete(existing)
            default:
                continue
            }
        }
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

    private func markBackedUp(_ ids: [String]) {
        for id in ids {
            asset(byId: id)?.backedUp = true
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
                markBackedUp(try await flushJournal())
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
        guard AppSettings.autoBackupEnabled, VaultKeys.masterKey != nil else { return }
        guard await HiDriveAuth.shared.isConnected else { return }
        guard PhotoKitExport.currentAuthorization() else { return }
        guard force || backupAllowedNow() else { return }
        // Not starting on cellular: a Wi-Fi-only upload would hold the queue until Wi-Fi returns.
        if AppSettings.wifiOnlyBackup, await NetworkProbe.isCellularOnly() { return }
        let known = knownSourceIds()
        var todo: [PHAsset] = []
        PhotoKitExport.fetchAssets(createdAfter: AppSettings.autoBackupCutoff,
                                   includeVideos: AppSettings.includeVideos,
                                   newestFirst: false)
            .enumerateObjects { asset, _, _ in
                if !known.contains(asset.localIdentifier) { todo.append(asset) }
            }
        enqueueBackup(todo, allowsCellular: !AppSettings.wifiOnlyBackup, first: false)
        await drainBackupQueue()
    }

    func manualBackupNeedsCellularConsent() async -> Bool {
        guard AppSettings.wifiOnlyBackup else { return false }
        return await NetworkProbe.isCellularOnly()
    }

    // Manual backup: ignores the automatic toggle and charging rule, and goes ahead of queued automatic items.
    func backup(phAssets: [PHAsset], allowCellular: Bool = false) {
        guard VaultKeys.masterKey != nil, isConnected else {
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
                if !isInVault(sourceId: id), try await backupOne(phAsset, allowsCellular: allowsCellular) != nil {
                    addsSinceFlush += 1
                }
                deviceItems.removeAll { $0.localIdentifier == id }
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
        refreshDeviceItems()
        // Items enqueued during the final flush saw isBackingUp and returned; pick them up now.
        if !backupQueue.isEmpty && !Task.isCancelled {
            await drainBackupQueue()
        }
    }

    // Returns the new Asset when an "add" entry is now pending; nil when the bytes are already in the vault.
    private func backupOne(_ phAsset: PHAsset, allowsCellular: Bool) async throws -> Asset? {
        guard let masterKey = VaultKeys.masterKey else { return nil }
        let base = try await client.basePath()
        let assetId = UUID().uuidString.lowercased()
        let blobId = UUID(uuidString: assetId)!

        let tmpOriginal = CacheManager.tmpDir.appendingPathComponent(assetId + ".orig")
        defer { try? FileManager.default.removeItem(at: tmpOriginal) }
        let (filename, mime) = try await PhotoKitExport.exportOriginal(phAsset, to: tmpOriginal)
        let sha = try await Task.detached { try PhotoKitExport.sha256OfFile(tmpOriginal) }.value

        if let existing = asset(sha256: sha) {
            linkDuplicate(existing, to: phAsset.localIdentifier)
            return nil
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

        let meta = JournalMeta(filename: filename, kind: kind, mime: mime,
                               captured: phAsset.creationDate ?? now,
                               width: phAsset.pixelWidth, height: phAsset.pixelHeight,
                               duration: phAsset.duration, bytes: bytes, sha256: sha,
                               sourceAssetId: phAsset.localIdentifier)
        PendingJournal.append(JournalEntry(op: "add", id: assetId, ts: now,
                                           device: VaultKeys.deviceId, meta: meta))
        return model
    }

    // Same bytes already in the vault (e.g. a Takeout import, or an upload from another phone): link the
    // asset to this local item without a journal entry. If its link still resolves to a different item on
    // this phone, the two are camera-roll duplicates; re-pointing would make them take the link from each
    // other on every run, so the newcomer is remembered as a duplicate instead.
    private func linkDuplicate(_ existing: Asset, to localId: String) {
        let current = existing.sourceAssetId
        if !current.isEmpty, current != localId,
           PHAsset.fetchAssets(withLocalIdentifiers: [current], options: nil).count > 0 {
            duplicateSourceIds.insert(localId)
        } else {
            existing.sourceAssetId = localId
            try? context.save()
        }
    }

    // MARK: - User operations

    private func appendUserOp(_ op: String, asset: Asset) {
        let now = Date()
        asset.lastJournalTs = now
        PendingJournal.append(JournalEntry(op: op, id: asset.id, ts: now,
                                           device: VaultKeys.deviceId, meta: nil))
    }

    func setFavorite(_ asset: Asset, _ favorite: Bool) {
        asset.isFavorite = favorite
        appendUserOp(favorite ? "favorite" : "unfavorite", asset: asset)
        try? context.save()
        Task { await flushAndMark() }
    }

    func moveToTrash(_ assets: [Asset]) {
        for asset in assets {
            asset.isDeleted = true
            asset.deletedAt = Date()
            appendUserOp("delete", asset: asset)
        }
        try? context.save()
        Task { await flushAndMark() }
    }

    func restoreFromTrash(_ asset: Asset) {
        asset.isDeleted = false
        asset.deletedAt = nil
        appendUserOp("restore", asset: asset)
        try? context.save()
        Task { await flushAndMark() }
    }

    func purge(_ asset: Asset) async {
        do {
            let base = try await client.basePath()
            try await client.deleteFile(path: base + "/originals/" + asset.id + ".enc")
            try await client.deleteFile(path: base + "/thumbs/" + asset.id + ".enc")
            PendingJournal.append(JournalEntry(op: "purge", id: asset.id, ts: Date(),
                                               device: VaultKeys.deviceId, meta: nil))
            CacheManager.removeCachedFiles(assetId: asset.id, filename: asset.filename)
            context.delete(asset)
            try? context.save()
            refreshDeviceItems()
            await flushAndMark()
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
    }

    func purgeOldTombstones() async {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let expired = allAssets().filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < cutoff }
        for asset in expired {
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
        CacheManager.enforceOriginalsCap(AppSettings.originalsCacheCapBytes)
        return destination
    }

    // MARK: - Thumbnails

    func thumbnailBackfill() async {
        guard let masterKey = VaultKeys.masterKey else { return }
        let missing = allAssets().filter { !CacheManager.hasThumb(assetId: $0.id) }
        guard !missing.isEmpty else { return }
        restoreTotal = missing.count
        restoreDone = 0
        guard let base = try? await client.basePath() else { return }
        for asset in missing {
            do {
                let tmpEnc = CacheManager.tmpDir.appendingPathComponent(asset.id + ".thumb.dl")
                try await client.downloadFile(path: base + "/thumbs/" + asset.id + ".enc",
                                              to: tmpEnc, allowsCellular: true)
                let blobId = UUID(uuidString: asset.id)!
                let jpeg = try BlobCrypto.decryptToData(at: tmpEnc, masterKey: masterKey, blobId: blobId)
                try? FileManager.default.removeItem(at: tmpEnc)
                try jpeg.write(to: CacheManager.thumbURL(assetId: asset.id))
                asset.thumbCached = true
            } catch {
                // Missing thumb is non-fatal; retried on next sync.
            }
            restoreDone += 1
        }
        try? context.save()
        restoreTotal = 0
        restoreDone = 0
    }

    // MARK: - Account

    func disconnect() async {
        await HiDriveAuth.shared.disconnect()
        client.resetPathCache()
        await refreshConnectionState()
    }
}
