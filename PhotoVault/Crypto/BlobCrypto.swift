import Foundation
import CryptoKit

enum BlobCryptoError: Error {
    case badHeader
    case truncated
    case ioFailure
}

// Chunked AES-256-GCM container, streamable file-to-file.
// Header (24 bytes): "PVLT" | version u8=1 | 3 reserved | chunkSize u32 LE | plaintextLength u64 LE | nonceBase (4 random bytes).
// Chunk i: AES-GCM(nonce = nonceBase || i as u64 LE, aad = header || i as u64 LE) -> ciphertext || 16-byte tag.
enum BlobCrypto {
    static let chunkSize: UInt32 = 65536
    private static let magic: [UInt8] = [0x50, 0x56, 0x4C, 0x54] // "PVLT"

    static func blobKey(masterKey: Data, blobId: UUID) -> SymmetricKey {
        let salt = withUnsafeBytes(of: blobId.uuid) { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: salt,
            info: Data("photovault-blob-v1".utf8),
            outputByteCount: 32)
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func encryptFile(at source: URL, to destination: URL, masterKey: Data, blobId: UUID) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let plaintextLength = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        var nonceBase = Data(count: 4)
        let status = nonceBase.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BlobCryptoError.ioFailure }

        var header = Data(magic)
        header.append(1)
        header.append(contentsOf: [0, 0, 0])
        header.append(le(chunkSize))
        header.append(le(plaintextLength))
        header.append(nonceBase)

        let key = blobKey(masterKey: masterKey, blobId: blobId)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try output.write(contentsOf: header)
        var index: UInt64 = 0
        var remaining = plaintextLength
        while remaining > 0 {
            let want = Int(min(UInt64(chunkSize), remaining))
            guard let chunk = try input.read(upToCount: want), chunk.count == want else {
                throw BlobCryptoError.truncated
            }
            var nonceData = nonceBase
            nonceData.append(le(index))
            var aad = header
            aad.append(le(index))
            let box = try AES.GCM.seal(chunk, using: key, nonce: AES.GCM.Nonce(data: nonceData), authenticating: aad)
            try output.write(contentsOf: box.ciphertext)
            try output.write(contentsOf: box.tag)
            index += 1
            remaining -= UInt64(want)
        }
    }

    static func decryptFile(at source: URL, to destination: URL, masterKey: Data, blobId: UUID) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: 24), header.count == 24,
              Array(header.prefix(4)) == magic, header[4] == 1 else {
            throw BlobCryptoError.badHeader
        }
        let storedChunkSize: UInt32 = header.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let plaintextLength: UInt64 = header.subdata(in: 12..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let nonceBase = header.subdata(in: 20..<24)
        guard storedChunkSize > 0 else { throw BlobCryptoError.badHeader }

        let key = blobKey(masterKey: masterKey, blobId: blobId)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var index: UInt64 = 0
        var remaining = plaintextLength
        while remaining > 0 {
            let want = Int(min(UInt64(storedChunkSize), remaining))
            guard let sealed = try input.read(upToCount: want + 16), sealed.count == want + 16 else {
                throw BlobCryptoError.truncated
            }
            var nonceData = nonceBase
            nonceData.append(le(index))
            var aad = header
            aad.append(le(index))
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: sealed.prefix(want),
                tag: sealed.suffix(16))
            let plain = try AES.GCM.open(box, using: key, authenticating: aad)
            try output.write(contentsOf: plain)
            index += 1
            remaining -= UInt64(want)
        }
    }

    // In-memory variant for small blobs (thumbnails, journal files).
    static func decryptData(_ input: Data, masterKey: Data, blobId: UUID) throws -> Data {
        let data = Data(input)
        guard data.count >= 24 else { throw BlobCryptoError.badHeader }
        let header = data.subdata(in: 0..<24)
        guard Array(header.prefix(4)) == magic, header[4] == 1 else { throw BlobCryptoError.badHeader }
        let storedChunkSize: UInt32 = header.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let plaintextLength: UInt64 = header.subdata(in: 12..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let nonceBase = header.subdata(in: 20..<24)
        guard storedChunkSize > 0 else { throw BlobCryptoError.badHeader }

        let key = blobKey(masterKey: masterKey, blobId: blobId)
        var output = Data()
        output.reserveCapacity(Int(min(plaintextLength, UInt64(Int32.max))))
        var index: UInt64 = 0
        var remaining = plaintextLength
        var offset = 24
        while remaining > 0 {
            let want = Int(min(UInt64(storedChunkSize), remaining))
            guard data.count >= offset + want + 16 else { throw BlobCryptoError.truncated }
            var nonceData = nonceBase
            nonceData.append(le(index))
            var aad = header
            aad.append(le(index))
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: data.subdata(in: offset..<(offset + want)),
                tag: data.subdata(in: (offset + want)..<(offset + want + 16)))
            output.append(try AES.GCM.open(box, using: key, authenticating: aad))
            index += 1
            remaining -= UInt64(want)
            offset += want + 16
        }
        return output
    }

    static func decryptToData(at source: URL, masterKey: Data, blobId: UUID) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try decryptFile(at: source, to: tmp, masterKey: masterKey, blobId: blobId)
        return try Data(contentsOf: tmp)
    }

    static func encryptData(_ data: Data, to destination: URL, masterKey: Data, blobId: UUID) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        try encryptFile(at: tmp, to: destination, masterKey: masterKey, blobId: blobId)
    }
}
