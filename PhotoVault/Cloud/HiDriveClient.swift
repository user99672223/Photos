import Foundation

struct HiDriveItem {
    var name: String
    var type: String // "dir" | "file"
    var size: Int64
}

struct HiDriveError: LocalizedError {
    var statusCode: Int
    var message: String

    var errorDescription: String? {
        message.isEmpty ? "HiDrive error \(statusCode)" : "HiDrive error \(statusCode): \(message.prefix(200))"
    }
}

// REST client for the HiDrive API. Control-plane calls use a shared session;
// file payloads go through a background URLSession so transfers survive suspension.
final class HiDriveClient: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    static let shared = HiDriveClient()

    static let singleRequestLimit: Int64 = 32 * 1024 * 1024
    static let patchChunkSize = 32 * 1024 * 1024

    private let lock = NSLock()
    private var uploadContinuations: [Int: CheckedContinuation<(Int, Data), Error>] = [:]
    private var downloadContinuations: [Int: CheckedContinuation<(Int, URL), Error>] = [:]
    private var responseData: [Int: Data] = [:]
    private var downloadedFiles: [Int: URL] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]

    private lazy var transferSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.example.photovault.transfer")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Small blobs (thumbnails, journal files) use a normal session with bounded parallelism;
    // the background session stays reserved for uploads and original downloads.
    private lazy var smallSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func downloadSmall(path: String, allowsCellular: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            let token = try await HiDriveAuth.shared.validAccessToken()
            var request = URLRequest(url: makeURL("/file", query: ["path": path]))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.allowsCellularAccess = allowsCellular
            do {
                let (data, response) = try await smallSession.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                if status == 401 && attempt == 0 {
                    await HiDriveAuth.shared.invalidateAccessToken()
                    attempt += 1
                    continue
                }
                throw HiDriveError(statusCode: status, message: "")
            } catch let error as HiDriveError where error.statusCode == 404 || error.statusCode == 401 {
                throw error
            } catch {
                attempt += 1
                if attempt >= 3 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    // MARK: - Paths

    private var cachedBase: String?

    func basePath() async throws -> String {
        if let cachedBase { return cachedBase }
        let home = try await HiDriveAuth.shared.homePath()
        let base = home == "/" ? "/PhotoVault" : home + "/PhotoVault"
        cachedBase = base
        return base
    }

    func resetPathCache() {
        cachedBase = nil
    }

    func ensureLayout(deviceId: String) async throws {
        let base = try await basePath()
        for dir in [base, base + "/journal", base + "/journal/" + deviceId, base + "/thumbs", base + "/originals"] {
            try await mkdir(path: dir)
        }
    }

    // MARK: - Control plane

    private func makeURL(_ endpoint: String, query: [String: String]) -> URL {
        var components = URLComponents(string: hidriveAPIBase + endpoint)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func authorizedRequest(_ method: String, _ endpoint: String, query: [String: String]) async throws -> URLRequest {
        let token = try await HiDriveAuth.shared.validAccessToken()
        var request = URLRequest(url: makeURL(endpoint, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private func call(_ method: String, _ endpoint: String, query: [String: String],
                      okStatus: Set<Int> = [200, 201, 204]) async throws -> Data {
        var attempt = 0
        while true {
            let request = try await authorizedRequest(method, endpoint, query: query)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if okStatus.contains(status) { return data }
                if status == 401 && attempt == 0 {
                    await HiDriveAuth.shared.invalidateAccessToken()
                    attempt += 1
                    continue
                }
                throw HiDriveError(statusCode: status, message: String(data: data, encoding: .utf8) ?? "")
            } catch let error as HiDriveError {
                throw error
            } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
    }

    func mkdir(path: String) async throws {
        do {
            try await call("POST", "/dir", query: ["path": path])
        } catch let error as HiDriveError where error.statusCode == 409 {
            // already exists
        }
    }

    private struct DirListing: Codable {
        struct Member: Codable {
            var name: String
            var type: String
            var size: Int64?
        }
        var members: [Member]?
    }

    func list(path: String) async throws -> [HiDriveItem] {
        let data = try await call("GET", "/dir", query: [
            "path": path,
            "members": "all",
            "fields": "members.name,members.type,members.size"
        ])
        let listing = try JSONDecoder().decode(DirListing.self, from: data)
        return (listing.members ?? []).map { member in
            // The API percent-encodes member names.
            HiDriveItem(name: member.name.removingPercentEncoding ?? member.name,
                        type: member.type,
                        size: member.size ?? 0)
        }
    }

    func deleteFile(path: String) async throws {
        do {
            try await call("DELETE", "/file", query: ["path": path])
        } catch let error as HiDriveError where error.statusCode == 404 {
            // already gone; purge is idempotent
        }
    }

    func fileSize(path: String) async throws -> Int64? {
        do {
            let data = try await call("GET", "/meta", query: ["path": path, "fields": "size,type"])
            struct Meta: Codable { var size: Int64? }
            return (try JSONDecoder().decode(Meta.self, from: data)).size
        } catch let error as HiDriveError where error.statusCode == 404 {
            return nil
        }
    }

    // MARK: - Uploads

    func uploadFile(localURL: URL, directory: String, name: String, allowsCellular: Bool) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size < HiDriveClient.singleRequestLimit {
            try await uploadSingle(localURL: localURL, directory: directory, name: name, allowsCellular: allowsCellular)
        } else {
            try await uploadChunked(localURL: localURL, directory: directory, name: name, size: size, allowsCellular: allowsCellular)
        }
    }

    private func uploadSingle(localURL: URL, directory: String, name: String, allowsCellular: Bool) async throws {
        let token = try await HiDriveAuth.shared.validAccessToken()
        var request = URLRequest(url: makeURL("/file", query: ["dir": directory, "name": name]))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.allowsCellularAccess = allowsCellular
        let (status, body) = try await runUpload(request: request, file: localURL)
        if status == 409 {
            // Blob ids are unique per content, so an existing file is the same bytes: done.
            return
        }
        guard status == 200 || status == 201 else {
            throw HiDriveError(statusCode: status, message: String(data: body, encoding: .utf8) ?? "")
        }
    }

    private func uploadChunked(localURL: URL, directory: String, name: String, size: Int64, allowsCellular: Bool) async throws {
        let path = directory + "/" + name
        // Restarting a partial upload: drop any previous attempt, create empty file, PATCH sequential chunks.
        try await deleteFile(path: path)
        try await call("POST", "/file", query: ["dir": directory, "name": name], okStatus: [200, 201])

        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        var offset: Int64 = 0
        while offset < size {
            guard let chunk = try input.read(upToCount: HiDriveClient.patchChunkSize), !chunk.isEmpty else {
                throw HiDriveError(statusCode: 0, message: "short read during chunked upload")
            }
            let chunkFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try chunk.write(to: chunkFile)
            defer { try? FileManager.default.removeItem(at: chunkFile) }

            let token = try await HiDriveAuth.shared.validAccessToken()
            var request = URLRequest(url: makeURL("/file", query: ["path": path, "offset": String(offset)]))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.allowsCellularAccess = allowsCellular
            let (status, body) = try await runUpload(request: request, file: chunkFile)
            guard status == 200 || status == 204 else {
                throw HiDriveError(statusCode: status, message: String(data: body, encoding: .utf8) ?? "")
            }
            offset += Int64(chunk.count)
        }
    }

    private func runUpload(request: URLRequest, file: URL) async throws -> (Int, Data) {
        var attempt = 0
        while true {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    let task = transferSession.uploadTask(with: request, fromFile: file)
                    lock.lock()
                    uploadContinuations[task.taskIdentifier] = continuation
                    responseData[task.taskIdentifier] = Data()
                    lock.unlock()
                    task.resume()
                }
            } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
    }

    // MARK: - Downloads

    func downloadFile(path: String, to destination: URL, allowsCellular: Bool,
                      progress: ((Double) -> Void)? = nil) async throws {
        let token = try await HiDriveAuth.shared.validAccessToken()
        var request = URLRequest(url: makeURL("/file", query: ["path": path]))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = allowsCellular

        var attempt = 0
        while true {
            do {
                let (status, tempURL) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, URL), Error>) in
                    let task = transferSession.downloadTask(with: request)
                    lock.lock()
                    downloadContinuations[task.taskIdentifier] = continuation
                    if let progress { progressHandlers[task.taskIdentifier] = progress }
                    lock.unlock()
                    task.resume()
                }
                guard status == 200 || status == 206 else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw HiDriveError(statusCode: status, message: "download failed")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                return
            } catch let error as HiDriveError where error.statusCode == 404 {
                throw error
            } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
    }

    // Set by the app delegate when iOS relaunches us for background transfer events.
    static var backgroundCompletionHandler: (() -> Void)?

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            HiDriveClient.backgroundCompletionHandler?()
            HiDriveClient.backgroundCompletionHandler = nil
        }
    }

    // MARK: - URLSession delegates

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let uploadCont = uploadContinuations.removeValue(forKey: task.taskIdentifier)
        let downloadCont = downloadContinuations.removeValue(forKey: task.taskIdentifier)
        let body = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        let file = downloadedFiles.removeValue(forKey: task.taskIdentifier)
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let uploadCont {
            if let error {
                uploadCont.resume(throwing: error)
            } else {
                uploadCont.resume(returning: (status, body))
            }
        }
        if let downloadCont {
            if let error {
                downloadCont.resume(throwing: error)
            } else if let file {
                downloadCont.resume(returning: (status, file))
            } else if status == 404 {
                downloadCont.resume(throwing: HiDriveError(statusCode: 404, message: "not found"))
            } else {
                downloadCont.resume(throwing: HiDriveError(statusCode: status, message: "no file received"))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move out of the system temp location before the delegate returns, or the file is gone.
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: holding)
        lock.lock()
        downloadedFiles[downloadTask.taskIdentifier] = holding
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = progressHandlers[downloadTask.taskIdentifier]
        lock.unlock()
        handler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

enum NetworkProbe {
    // A request barred from cellular fails at once with networkUnavailableReason == .cellular when
    // cellular is the only route; any HTTP response means Wi-Fi (or wired) is available.
    static func isCellularOnly() async -> Bool {
        var request = URLRequest(url: URL(string: hidriveAPIBase)!, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.allowsCellularAccess = false
        do {
            _ = try await URLSession.shared.data(for: request)
            return false
        } catch let error as URLError {
            return error.networkUnavailableReason == .cellular
        } catch {
            return false
        }
    }
}
