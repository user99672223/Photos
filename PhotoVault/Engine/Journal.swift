import Foundation

struct JournalMeta: Codable {
    var filename: String
    var kind: String
    var mime: String
    var captured: Date
    var width: Int
    var height: Int
    var duration: Double
    var bytes: Int64
    var sha256: String
    var sourceAssetId: String
}

struct JournalEntry: Codable {
    var op: String // add | delete | restore | favorite | unfavorite | purge
    var id: String
    var ts: Date
    var device: String
    var meta: JournalMeta?
}

// Pending (not yet uploaded) journal entries, persisted so a crash cannot lose ops.
enum PendingJournal {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pendingJournal.json")
    }

    static func load() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([JournalEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [JournalEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func append(_ entry: JournalEntry) {
        var entries = load()
        entries.append(entry)
        save(entries)
    }

    // Drops only the uploaded prefix; ops appended while the upload was in flight stay pending.
    static func removeFirst(_ count: Int) {
        var entries = load()
        entries.removeFirst(min(count, entries.count))
        save(entries)
    }
}

enum JournalCoding {
    static func encode(_ entries: [JournalEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    static func decode(_ data: Data) throws -> [JournalEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([JournalEntry].self, from: data)
    }

    // "<seq 6 digits>-<uuid>.enc"
    static func journalFilename(seq: Int, blobId: UUID) -> String {
        String(format: "%06d-", seq) + blobId.uuidString.lowercased() + ".enc"
    }

    static func parseJournalFilename(_ name: String) -> (seq: Int, blobId: UUID)? {
        guard name.hasSuffix(".enc") else { return nil }
        let stem = String(name.dropLast(4))
        guard stem.count > 7 else { return nil }
        let seqPart = String(stem.prefix(6))
        let uuidPart = String(stem.dropFirst(7))
        guard let seq = Int(seqPart), let uuid = UUID(uuidString: uuidPart) else { return nil }
        return (seq, uuid)
    }
}
