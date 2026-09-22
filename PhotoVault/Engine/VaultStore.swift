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

    private let libraryObserver = PhotoLibraryObserver()

    init(container: ModelContainer) {
        self.container = container
        self.hasVault = VaultKeys.masterKey != nil
        self.onboarded = AppSettings.onboardingComplete
        CacheManager.ensureDirectories()
        Task { await refreshConnectionState() }
        libraryObserver.onChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.onboarded else { return }
                await self.backupNow()
            }
        }
    }

    func refreshConnectionState() async {
        isConnected = await HiDriveAuth.shared.isConnected
        accountAlias = await HiDriveAuth.shared.accountAlias()
    }

    func startObservingLibraryIfAuthorized() {
        if PhotoKitExport.currentAuthorization() {
            libraryObserver.register()
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

    private func seenJournalNames() -> Set<String> {
        let files = (try? context.fetch(FetchDescriptor<SeenJournalFile>())) ?? []
        return Set(files.map(\.name))
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
    @discardableResult
    func flushJournal() async throws -> [String] {
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
        PendingJournal.clear()
        return pending.filter { $0.op == "add" }.map(\.id)
    }

    private func markBackedUp(_ ids: [String]) {
        for id in ids {
            asset(byId: id)?.backedUp = true
        }
        try? context.save()
    }

    private func flushAndMark() async {
        do {
            let ids = try await flushJournal()
            markBackedUp(ids)
        } catch {
            lastError = "Journal upload failed: \(error.localizedDescription)"
        }
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

    func backupNow(force: Bool = false) async {
        guard !isBackingUp, VaultKeys.masterKey != nil else { return }
        guard await HiDriveAuth.shared.isConnected else { return }
        guard PhotoKitExport.currentAuthorization() else { return }
        guard force || backupAllowedNow() else { return }
        isBackingUp = true
        defer { isBackingUp = false; backupRemaining = 0 }

        let index = allAssets()
        var knownSources = Set(index.map(\.sourceAssetId).filter { !$0.isEmpty })
        var byHash: [String: Asset] = [:]
        for asset in index { byHash[asset.sha256] = asset }

        let todo = PhotoKitExport.fetchAllAssets(includeVideos: AppSettings.includeVideos)
            .filter { !knownSources.contains($0.localIdentifier) }
        backupRemaining = todo.count
        var addsSinceFlush = 0
        for phAsset in todo {
            do {
                let result = try await backupOne(phAsset, byHash: byHash)
                knownSources.insert(phAsset.localIdentifier)
                if let model = result {
                    byHash[model.sha256] = model
                    addsSinceFlush += 1
                }
                if addsSinceFlush >= 50 {
                    await flushAndMark()
                    addsSinceFlush = 0
                }
            } catch {
                lastError = "Backup failed for an item: \(error.localizedDescription)"
            }
            backupRemaining = max(0, backupRemaining - 1)
        }
        await flushAndMark()
    }

    // Returns the new Asset when an "add" entry is now pending; nil when deduplicated by hash.
    private func backupOne(_ phAsset: PHAsset, byHash: [String: Asset]) async throws -> Asset? {
        guard let masterKey = VaultKeys.masterKey else { return nil }
        let base = try await client.basePath()
        let assetId = UUID().uuidString.lowercased()
        let blobId = UUID(uuidString: assetId)!
        let allowsCellular = !AppSettings.wifiOnlyBackup

        let tmpOriginal = CacheManager.tmpDir.appendingPathComponent(assetId + ".orig")
        defer { try? FileManager.default.removeItem(at: tmpOriginal) }
        let (filename, mime) = try await PhotoKitExport.exportOriginal(phAsset, to: tmpOriginal)
        let sha = try await Task.detached { try PhotoKitExport.sha256OfFile(tmpOriginal) }.value

        if let duplicate = byHash[sha] {
            if duplicate.sourceAssetId.isEmpty {
                duplicate.sourceAssetId = phAsset.localIdentifier
                try? context.save()
            }
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
