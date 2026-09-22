import Foundation
import SwiftData

@Model
final class Asset {
    @Attribute(.unique) var id: String
    var filename: String
    var kind: String // "photo" | "video"
    var mime: String
    var captured: Date
    var width: Int
    var height: Int
    var duration: Double
    var bytes: Int64
    var sha256: String
    var sourceAssetId: String
    var isFavorite: Bool
    var isDeleted: Bool
    var deletedAt: Date?
    var backedUp: Bool
    var thumbCached: Bool
    var lastViewed: Date?
    var lastJournalTs: Date

    init(id: String, filename: String, kind: String, mime: String, captured: Date,
         width: Int, height: Int, duration: Double, bytes: Int64, sha256: String,
         sourceAssetId: String, lastJournalTs: Date) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.mime = mime
        self.captured = captured
        self.width = width
        self.height = height
        self.duration = duration
        self.bytes = bytes
        self.sha256 = sha256
        self.sourceAssetId = sourceAssetId
        self.isFavorite = false
        self.isDeleted = false
        self.deletedAt = nil
        self.backedUp = false
        self.thumbCached = false
        self.lastViewed = nil
        self.lastJournalTs = lastJournalTs
    }

    var isVideo: Bool { kind == "video" }
}

@Model
final class SeenJournalFile {
    @Attribute(.unique) var name: String // "<deviceId>/<filename>"

    init(name: String) {
        self.name = name
    }
}

@Model
final class UploadJob {
    @Attribute(.unique) var assetId: String
    var state: String // "queued" | "uploading" | "done" | "failed"
    var attempts: Int

    init(assetId: String) {
        self.assetId = assetId
        self.state = "queued"
        self.attempts = 0
    }
}
