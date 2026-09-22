import Foundation
import Photos
import UIKit
import AVFoundation
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

    // PhotoKit applies the date predicate itself, so older parts of the library are never enumerated.
    static func fetchAssets(createdAfter cutoff: Date, includeVideos: Bool, newestFirst: Bool) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        let image = NSNumber(value: PHAssetMediaType.image.rawValue)
        let video = NSNumber(value: PHAssetMediaType.video.rawValue)
        if includeVideos {
            options.predicate = NSPredicate(format: "creationDate > %@ AND (mediaType == %@ OR mediaType == %@)",
                                            cutoff as NSDate, image, video)
        } else {
            options.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %@", cutoff as NSDate, image)
        }
        return PHAsset.fetchAssets(with: options)
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

// Media for device items (camera-roll assets not yet in the vault), read straight from the library.
enum DeviceMedia {
    static let thumbnails = PHCachingImageManager()

    static func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: side, height: side)
        let handle = ImageRequestHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                handle.start(continuation) {
                    DeviceMedia.thumbnails.requestImage(for: asset, targetSize: size, contentMode: .aspectFill,
                                                        options: options) { image, _ in
                        handle.finish(image)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    static func fullImage(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let once = ResumeGuard()
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard once.tryResume() else { return }
                continuation.resume(returning: data.flatMap { UIImage(data: $0) })
            }
        }
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        options.version = .current
        return await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let once = ResumeGuard()
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard once.tryResume() else { return }
                continuation.resume(returning: item)
            }
        }
    }
}

// Bridges a cancellable PHImageManager request to one continuation resume. The handler may fire
// synchronously inside requestImage, and cancellation may race the start, hence the lock.
final class ImageRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<UIImage?, Never>, request: () -> PHImageRequestID) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
        let id = request()
        lock.lock()
        requestID = id
        lock.unlock()
    }

    func finish(_ image: UIImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id {
            DeviceMedia.thumbnails.cancelImageRequest(id)
        }
        finish(nil)
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
