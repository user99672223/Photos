import Foundation

enum CacheManager {
    static var cachesDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static var thumbsDir: URL { cachesDir.appendingPathComponent("thumbs", isDirectory: true) }
    static var originalsDir: URL { cachesDir.appendingPathComponent("originals", isDirectory: true) }
    static var tmpDir: URL { FileManager.default.temporaryDirectory }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
    }

    static func thumbURL(assetId: String) -> URL {
        thumbsDir.appendingPathComponent(assetId + ".jpg")
    }

    static func originalURL(assetId: String, filename: String) -> URL {
        let ext = (filename as NSString).pathExtension
        let name = ext.isEmpty ? assetId : assetId + "." + ext.lowercased()
        return originalsDir.appendingPathComponent(name)
    }

    static func hasThumb(assetId: String) -> Bool {
        FileManager.default.fileExists(atPath: thumbURL(assetId: assetId).path)
    }

    // One directory listing instead of one stat per asset.
    static func thumbCacheIds() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: thumbsDir.path)) ?? []
        var ids = Set<String>()
        ids.reserveCapacity(names.count)
        for name in names where name.hasSuffix(".jpg") {
            ids.insert(String(name.dropLast(4)))
        }
        return ids
    }

    static func clearThumbnails() {
        try? FileManager.default.removeItem(at: thumbsDir)
        ensureDirectories()
    }

    static func cachedOriginal(assetId: String, filename: String) -> URL? {
        let url = originalURL(assetId: assetId, filename: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeCachedFiles(assetId: String, filename: String) {
        try? FileManager.default.removeItem(at: thumbURL(assetId: assetId))
        try? FileManager.default.removeItem(at: originalURL(assetId: assetId, filename: filename))
    }

    static func originalsCacheSize() -> Int64 {
        contentsWithSize(of: originalsDir).reduce(0) { $0 + $1.1 }
    }

    private static func contentsWithSize(of dir: URL) -> [(URL, Int64, Date)] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return []
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }

    // LRU eviction for the originals cache; lastViewed is mirrored into the file mtime on access.
    static func enforceOriginalsCap(_ capBytes: Int64) {
        var files = contentsWithSize(of: originalsDir).sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        while total > capBytes, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.1
            files.removeFirst()
        }
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
