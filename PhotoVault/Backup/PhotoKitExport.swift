import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import CryptoKit

enum ExportError: Error {
    case noResource
    case thumbnailFailed
}

enum PhotoKitExport {
    static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func currentAuthorization() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func fetchAllAssets(includeVideos: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if includeVideos {
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    static func fetchAssets(localIdentifiers: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first { $0.type == .video } ?? resources.first
        }
        // Live Photos: back up the still image only (v1).
        return resources.first { $0.type == .photo } ?? resources.first
    }

    static func exportOriginal(_ asset: PHAsset, to url: URL) async throws -> (filename: String, mime: String) {
        guard let resource = primaryResource(for: asset) else { throw ExportError.noResource }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try? FileManager.default.removeItem(at: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        return (resource.originalFilename, mime)
    }

    static func generateThumbnail(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let size = CGSize(width: 512, height: 512)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let resumed = ResumeGuard()
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                if resumed.tryResume() {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    static func sha256OfFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (() -> Void)?

    func register() {
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}
