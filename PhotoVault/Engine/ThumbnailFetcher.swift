import Foundation
import UIKit
import ImageIO

// Decoded, downsampled thumbnails ready for cells. Bounded by memory cost.
final class ThumbnailMemoryCache {
    static let shared = ThumbnailMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func image(_ id: String) -> UIImage? {
        cache.object(forKey: id as NSString)
    }

    func set(_ image: UIImage, for id: String) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        cache.setObject(image, forKey: id as NSString, cost: max(cost, 1))
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

enum ThumbPriority: Int, Comparable {
    case warmup = 0
    case prefetch = 1
    case visible = 2

    static func < (lhs: ThumbPriority, rhs: ThumbPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// One bounded downloader for all thumbnail traffic: visible cells first (LIFO), then the prefetch
// window, then the warm-up pass. Download, decrypt, disk write and decode all happen in worker tasks.
actor ThumbnailFetcher {
    static let shared = ThumbnailFetcher()
    static let maxWorkers = 7
    static let maxWarmupWorkers = 4
    static let decodedMaxPixel = 320

    struct FetchResult {
        var image: UIImage?
        var onDisk: Bool
        var fromNetwork: Bool
        var missing: Bool
    }

    private struct Job {
        var priority: ThumbPriority
        var seq: Int
        var wantsImage: Bool
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<UIImage?, Never>
    }

    private var pending: [String: Job] = [:]
    private var running: [String: ThumbPriority] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var missing: Set<String> = []
    private var seq = 0
    private var masterKey: Data?
    private var basePath: String?
    private var onDiskCached: (@Sendable (String) -> Void)?
    private(set) var fetchedFromNetwork = 0
    private(set) var failures = 0

    func configure(masterKey: Data?, basePath: String?) {
        self.masterKey = masterKey
        self.basePath = basePath
        pump()
    }

    func setOnDiskCached(_ handler: @escaping @Sendable (String) -> Void) {
        onDiskCached = handler
    }

    var queuedCount: Int { pending.count }
    var runningCount: Int { running.count }

    func reset() {
        for (id, list) in waiters {
            for waiter in list { waiter.continuation.resume(returning: nil) }
            waiters[id] = nil
        }
        pending.removeAll()
        missing.removeAll()
    }

    // Resolves to a decoded image (memory cache, disk, or network). Cancelling the caller's task
    // withdraws the request; a job nobody waits for is dropped or demoted.
    func image(for id: String, priority: ThumbPriority) async -> UIImage? {
        if let cached = ThumbnailMemoryCache.shared.image(id) { return cached }
        if Task.isCancelled { return nil }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                self.addWaiter(id: id, priority: priority, wantsImage: true, token: token, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, token: token) }
        }
    }

    // Warm-up: download, decrypt and write to disk only; no decode, no memory cache.
    func warm(_ id: String) async -> Bool {
        if missing.contains(id) { return false }
        if FileManager.default.fileExists(atPath: CacheManager.thumbURL(assetId: id).path) { return true }
        if Task.isCancelled { return false }
        let token = UUID()
        _ = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                self.addWaiter(id: id, priority: .warmup, wantsImage: false, token: token, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, token: token) }
        }
        return FileManager.default.fileExists(atPath: CacheManager.thumbURL(assetId: id).path)
    }

    // Enqueues ids for the scroll-direction window and drops out-of-window prefetches nobody awaits.
    func prefetch(_ ids: [String], keepOnly: Set<String>) {
        for (id, job) in pending where job.priority == .prefetch && !keepOnly.contains(id) && waiters[id] == nil {
            pending[id] = nil
        }
        for id in ids {
            guard ThumbnailMemoryCache.shared.image(id) == nil, !missing.contains(id),
                  running[id] == nil, pending[id] == nil else { continue }
            seq += 1
            pending[id] = Job(priority: .prefetch, seq: seq, wantsImage: true)
        }
        pump()
    }

    private func addWaiter(id: String, priority: ThumbPriority, wantsImage: Bool, token: UUID,
                           continuation: CheckedContinuation<UIImage?, Never>) {
        if wantsImage, let cached = ThumbnailMemoryCache.shared.image(id) {
            continuation.resume(returning: cached)
            return
        }
        if missing.contains(id) {
            continuation.resume(returning: nil)
            return
        }
        waiters[id, default: []].append(Waiter(token: token, continuation: continuation))
        if running[id] != nil { return }
        seq += 1
        if var job = pending[id] {
            if priority > job.priority {
                job.priority = priority
                job.seq = seq
            }
            job.wantsImage = job.wantsImage || wantsImage
            pending[id] = job
        } else {
            pending[id] = Job(priority: priority, seq: seq, wantsImage: wantsImage)
        }
        pump()
    }

    private func cancelWaiter(id: String, token: UUID) {
        guard var list = waiters[id], let index = list.firstIndex(where: { $0.token == token }) else { return }
        let waiter = list.remove(at: index)
        waiters[id] = list.isEmpty ? nil : list
        waiter.continuation.resume(returning: nil)
        if list.isEmpty, running[id] == nil, let job = pending[id] {
            if job.priority == .visible {
                pending[id] = Job(priority: .prefetch, seq: job.seq, wantsImage: true)
            } else if job.priority == .warmup {
                pending[id] = nil
            }
        }
    }

    private func popNext() -> (String, Job)? {
        var best: (String, Job)?
        let warmupRunning = running.values.filter { $0 == .warmup }.count
        for (id, job) in pending {
            if job.priority == .warmup && warmupRunning >= ThumbnailFetcher.maxWarmupWorkers { continue }
            guard let current = best else {
                best = (id, job)
                continue
            }
            if job.priority != current.1.priority {
                if job.priority > current.1.priority { best = (id, job) }
            } else if job.priority == .visible {
                if job.seq > current.1.seq { best = (id, job) }
            } else if job.seq < current.1.seq {
                best = (id, job)
            }
        }
        return best
    }

    private func pump() {
        while running.count < ThumbnailFetcher.maxWorkers, let next = popNext() {
            let id = next.0
            let job = next.1
            pending[id] = nil
            if job.priority == .warmup && waiters[id] == nil { continue }
            running[id] = job.priority
            let key = masterKey
            let base = basePath
            let wantsImage = job.wantsImage
            let taskPriority: TaskPriority = job.priority == .visible ? .userInitiated : .utility
            Task.detached(priority: taskPriority) {
                let result = await ThumbnailFetcher.perform(id: id, masterKey: key, basePath: base, wantsImage: wantsImage)
                await self.finish(id: id, result: result)
            }
        }
    }

    private func finish(id: String, result: FetchResult) {
        running[id] = nil
        if let image = result.image {
            ThumbnailMemoryCache.shared.set(image, for: id)
        }
        if result.missing { missing.insert(id) }
        if result.fromNetwork {
            if result.onDisk {
                fetchedFromNetwork += 1
                onDiskCached?(id)
            } else if !result.missing {
                failures += 1
            }
        }
        // A cell started waiting while a warm-up download was running: decode now that it is on disk.
        if result.image == nil, result.onDisk, let list = waiters[id], !list.isEmpty {
            seq += 1
            pending[id] = Job(priority: .visible, seq: seq, wantsImage: true)
            pump()
            return
        }
        let list = waiters.removeValue(forKey: id) ?? []
        for waiter in list {
            waiter.continuation.resume(returning: result.image)
        }
        pump()
    }

    nonisolated static func perform(id: String, masterKey: Data?, basePath: String?, wantsImage: Bool) async -> FetchResult {
        let url = CacheManager.thumbURL(assetId: id)
        var jpeg = try? Data(contentsOf: url)
        var fromNetwork = false
        if jpeg == nil {
            guard let masterKey, let basePath, let blobId = UUID(uuidString: id) else {
                return FetchResult(image: nil, onDisk: false, fromNetwork: false, missing: false)
            }
            do {
                let encrypted = try await HiDriveClient.shared.downloadSmall(path: basePath + "/thumbs/" + id + ".enc")
                let plain = try BlobCrypto.decryptData(encrypted, masterKey: masterKey, blobId: blobId)
                try plain.write(to: url, options: .atomic)
                jpeg = plain
                fromNetwork = true
            } catch let error as HiDriveError where error.statusCode == 404 {
                return FetchResult(image: nil, onDisk: false, fromNetwork: true, missing: true)
            } catch {
                return FetchResult(image: nil, onDisk: false, fromNetwork: true, missing: false)
            }
        }
        let image = wantsImage ? jpeg.flatMap { decodeDownsampled($0, maxPixel: decodedMaxPixel) } : nil
        return FetchResult(image: image, onDisk: true, fromNetwork: fromNetwork, missing: false)
    }

    // ImageIO decodes straight to the target size; UIImage(data:) would hold the full 512 px bitmap.
    nonisolated static func decodeDownsampled(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// Turns cell visibility into a prefetch window of about two screens in the scroll direction.
@MainActor
final class PrefetchPlanner {
    private var visible = Set<Int>()
    private var lastCenter = -1
    private var direction = 1
    private var planTask: Task<Void, Never>?
    var flatProvider: () -> [TimelineItem] = { [] }

    func appeared(_ index: Int) {
        visible.insert(index)
        schedule()
    }

    func disappeared(_ index: Int) {
        visible.remove(index)
        schedule()
    }

    private func schedule() {
        guard planTask == nil else { return }
        planTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.planTask = nil
            self.plan()
        }
    }

    private func plan() {
        guard let low = visible.min(), let high = visible.max() else { return }
        let center = (low + high) / 2
        if center != lastCenter {
            direction = center >= lastCenter ? 1 : -1
            lastCenter = center
        }
        let flat = flatProvider()
        guard !flat.isEmpty else { return }
        let span = max(high - low + 1, 12) * 2
        let range: ClosedRange<Int>
        if direction > 0 {
            guard high + 1 <= flat.count - 1 else { return }
            range = (high + 1)...min(flat.count - 1, high + span)
        } else {
            guard low - 1 >= 0 else { return }
            range = max(0, low - span)...(low - 1)
        }
        var ids: [String] = []
        for item in flat[range] where !item.isDevice && ThumbnailMemoryCache.shared.image(item.assetId) == nil {
            ids.append(item.assetId)
        }
        if direction < 0 { ids.reverse() }
        let keep = Set(ids)
        Task {
            await ThumbnailFetcher.shared.prefetch(ids, keepOnly: keep)
        }
    }
}

// Low-priority pass that fills the disk cache newest first, under the backup rules, pausable.
@MainActor
final class ThumbnailWarmup {
    private let index: LibraryIndex
    private var task: Task<Void, Never>?
    private var attempted = Set<String>()
    private(set) var isRunning = false
    private(set) var completedThisSession = 0

    init(index: LibraryIndex) {
        self.index = index
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(limit: nil)
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // Used by the background task: a bounded slice that returns when done or cancelled.
    func runSlice(limit: Int) async {
        guard task == nil else { return }
        await run(limit: limit)
    }

    private func run(limit: Int?) async {
        isRunning = true
        defer { isRunning = false }
        let ids = await index.uncachedThumbIdsNewestFirst().filter { !attempted.contains($0) }
        var done = 0
        var batchesSinceCheck = 0
        var position = 0
        while position < ids.count && !Task.isCancelled {
            if batchesSinceCheck == 0 {
                guard await conditionsAllow() else { break }
            }
            batchesSinceCheck = (batchesSinceCheck + 1) % 5
            let end = min(position + 24, ids.count)
            let batch = Array(ids[position..<end])
            position = end
            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask { _ = await ThumbnailFetcher.shared.warm(id) }
                }
            }
            for id in batch { attempted.insert(id) }
            done += batch.count
            completedThisSession += batch.count
            if let limit, done >= limit { break }
        }
    }

    private func conditionsAllow() async -> Bool {
        if AppSettings.chargingOnlyBackup {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            if state != .charging && state != .full { return false }
        }
        if AppSettings.wifiOnlyBackup, await NetworkProbe.isCellularOnly() {
            return false
        }
        return true
    }
}
