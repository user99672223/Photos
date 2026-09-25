import Foundation
import SwiftData

struct MergeOutcome {
    var upserts: [IndexEntry] = []
    var purged: [String] = []
}

// All heavy SwiftData work runs here, on its own context, never on the main thread.
@ModelActor
actor VaultDataActor {
    func loadIndex(thumbCache: Set<String>) throws -> [IndexEntry] {
        let calendar = Calendar.current
        var out: [IndexEntry] = []
        var descriptor = FetchDescriptor<Asset>(sortBy: [SortDescriptor(\Asset.captured)])
        let pageSize = 4000
        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = try modelContext.fetch(descriptor)
            if page.isEmpty { break }
            out.reserveCapacity(out.count + page.count)
            for asset in page {
                out.append(IndexEntry(asset: asset, thumbCached: thumbCache.contains(asset.id), calendar: calendar))
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        return out
    }

    func seenJournalNames() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<SeenJournalFile>()).map(\.name))
    }

    // Decrypts one journal file and applies it with a single fetch and a single save.
    // Newest ts wins per asset; a "delete" is a tombstone, "purge" removes entirely.
    func mergeJournalFile(encrypted: Data, blobId: UUID, masterKey: Data, seenName: String,
                          thumbCache: Set<String>) throws -> MergeOutcome {
        let data = try BlobCrypto.decryptData(encrypted, masterKey: masterKey, blobId: blobId)
        let entries = try JournalCoding.decode(data).sorted { $0.ts < $1.ts }

        var existing: [String: Asset] = [:]
        let ids = Array(Set(entries.map(\.id)))
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 300, ids.count)])
            let descriptor = FetchDescriptor<Asset>(predicate: #Predicate { chunk.contains($0.id) })
            for asset in try modelContext.fetch(descriptor) {
                existing[asset.id] = asset
            }
            start += 300
        }

        var outcome = MergeOutcome()
        var touched = Set<String>()
        for entry in entries {
            let current = existing[entry.id]
            switch entry.op {
            case "add":
                guard current == nil, let meta = entry.meta else { continue }
                let model = Asset(id: entry.id, filename: meta.filename, kind: meta.kind, mime: meta.mime,
                                  captured: meta.captured, width: meta.width, height: meta.height,
                                  duration: meta.duration, bytes: meta.bytes, sha256: meta.sha256,
                                  sourceAssetId: meta.sourceAssetId, lastJournalTs: entry.ts)
                model.backedUp = true
                model.thumbCached = thumbCache.contains(entry.id)
                modelContext.insert(model)
                existing[entry.id] = model
                touched.insert(entry.id)
            case "delete":
                guard let current, entry.ts >= current.lastJournalTs else { continue }
                current.isDeleted = true
                current.deletedAt = entry.ts
                current.lastJournalTs = entry.ts
                touched.insert(entry.id)
            case "restore":
                guard let current, entry.ts >= current.lastJournalTs else { continue }
                current.isDeleted = false
                current.deletedAt = nil
                current.lastJournalTs = entry.ts
                touched.insert(entry.id)
            case "favorite", "unfavorite":
                guard let current, entry.ts >= current.lastJournalTs else { continue }
                current.isFavorite = entry.op == "favorite"
                current.lastJournalTs = entry.ts
                touched.insert(entry.id)
            case "purge":
                guard let current else { continue }
                CacheManager.removeCachedFiles(assetId: current.id, filename: current.filename)
                modelContext.delete(current)
                existing[entry.id] = nil
                touched.remove(entry.id)
                outcome.purged.append(entry.id)
            default:
                continue
            }
        }
        modelContext.insert(SeenJournalFile(name: seenName))
        try modelContext.save()

        let calendar = Calendar.current
        outcome.upserts.reserveCapacity(touched.count)
        for id in touched {
            if let asset = existing[id] {
                outcome.upserts.append(IndexEntry(asset: asset, thumbCached: thumbCache.contains(id), calendar: calendar))
            }
        }
        return outcome
    }

    func wipeAll() throws {
        try modelContext.delete(model: Asset.self)
        try modelContext.delete(model: SeenJournalFile.self)
        try modelContext.delete(model: UploadJob.self)
        try modelContext.save()
    }
}
