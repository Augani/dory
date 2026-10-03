import CryptoKit
import Darwin
import Foundation

/// Network identity supplied by Apple's supported-restore-image API, not an arbitrary mirror.
/// A local SHA-256 receipt detects cache mutation; it is not a vendor-published checksum or
/// proof of a supported IPSW. The caller must validate the finished image with Virtualization.
public struct DoryRestoreImageDownloadRequest: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let build: String
    public let version: String

    public init(sourceURL: URL, build: String, version: String) throws {
        self.sourceURL = sourceURL
        self.build = build
        self.version = version
        try validate()
    }

    public func validate() throws {
        guard Self.isAppleImageURL(sourceURL), !build.isEmpty, build.utf8.count <= 64,
              !version.isEmpty, version.utf8.count <= 64,
              build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              version.range(of: #"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"#, options: .regularExpression) != nil else {
            throw DoryRestoreImageDownloadError.invalidSource
        }
    }

    static func isAppleImageURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.fragment == nil, url.pathExtension.lowercased() == "ipsw" else { return false }
        return true
    }

    var cacheKey: String {
        Self.digest(Data((sourceURL.absoluteString + "\n" + build + "\n" + version).utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DoryRestoreImageDownloadError: Error, Sendable, Equatable, LocalizedError {
    case invalidSource
    case unsafeCache
    case busy
    case invalidResponse
    case changedSource
    case damagedPartial
    case truncated
    case filesystem(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSource: "The restore image must come from Apple's supported-image service over HTTPS."
        case .unsafeCache: "The restore-image cache is indirect, shared, or no longer owned by this app user."
        case .busy: "Another restore-image download is using this cache."
        case .invalidResponse: "Apple's server returned an invalid image size, encoding, or byte range."
        case .changedSource: "The image changed on the server. Start over rather than mixing two restore images."
        case .damagedPartial: "The saved partial image changed or its download receipt is invalid. Start over to download a clean copy."
        case .truncated: "The image transfer ended before all declared bytes arrived. Its verified partial file can be resumed."
        case .filesystem(let code): "The restore-image cache could not be written (errno \(code))."
        }
    }
}

public struct DoryRestoreImageDownloadProgress: Sendable, Equatable {
    public let completedBytes: UInt64
    public let totalBytes: UInt64
}

public struct DoryRestoreImageDownloadReceipt: Codable, Equatable, Sendable {
    public let schema: String
    public let request: DoryRestoreImageDownloadRequest
    public let byteCount: UInt64
    public let sha256: String
    public let entityTag: String?
}

private struct RestoreImagePartial: Codable {
    let schema: String
    let request: DoryRestoreImageDownloadRequest
    let totalBytes: UInt64
    let entityTag: String?
    let committedBytes: UInt64
    let committedSHA256: String
    let transferComplete: Bool
}

private final class RestoreImageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(DoryRestoreImageDownloadRequest.isAppleImageURL) == true ? request : nil)
    }
}

/// One bounded streaming transfer. Every resume rehashes the committed prefix and uses a
/// strong ETag + exact Content-Range. Crash-only trailing bytes are never silently trusted.
/// Disk descriptors and a per-image flock remain owned until cancellation/network completion.
public actor DoryRestoreImageDownloadStore {
    public static let maximumImageBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
    private let directory: URL
    private let session: URLSession
    private var active = false

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// Recover the frozen request from an earlier app run instead of silently switching a
    /// partial file to whatever build Apple's "latest" endpoint now selects.
    public func pendingRequest() throws -> DoryRestoreImageDownloadRequest? {
        guard !active else { throw DoryRestoreImageDownloadError.busy }
        let root = try openDirectory()
        defer { close(root) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 1024 else { throw DoryRestoreImageDownloadError.unsafeCache }
        try checkDirectory(root)
        for name in names.sorted() where name.range(of: #"^[0-9a-f]{64}\.partial\.json$"#, options: .regularExpression) != nil {
            let saved: RestoreImagePartial = try decode(name, root: root)
            try saved.request.validate()
            guard name == saved.request.cacheKey + ".partial.json", saved.schema == "dory.restore-image-partial@1",
                  saved.totalBytes > 0, saved.totalBytes <= Self.maximumImageBytes,
                  saved.committedBytes <= saved.totalBytes else { throw DoryRestoreImageDownloadError.damagedPartial }
            let part = try openPrivate(saved.request.cacheKey + ".partial", root: root, flags: O_RDONLY)
            close(part)
            return saved.request
        }
        return nil
    }

    public func download(
        _ request: DoryRestoreImageDownloadRequest,
        progress: @escaping @Sendable (DoryRestoreImageDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        try request.validate()
        guard !active else { throw DoryRestoreImageDownloadError.busy }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        let root = try openDirectory()
        defer { close(root) }
        let lock = try lockImage(request.cacheKey, root: root)
        defer { close(lock) }
        let imageName = request.cacheKey + ".ipsw"
        if try exists(imageName, root: root) {
            let receipt: DoryRestoreImageDownloadReceipt = try decode(imageName + ".json", root: root)
            try request.validate()
            let file = try openPrivate(imageName, root: root, flags: O_RDONLY)
            defer { close(file) }
            let (count, hash) = try hashFile(file)
            guard receipt.schema == "dory.restore-image-download@1", receipt.request == request,
                  count > 0, count <= Self.maximumImageBytes, count == receipt.byteCount,
                  hex(hash) == receipt.sha256 else { throw DoryRestoreImageDownloadError.damagedPartial }
            try checkDirectory(root)
            progress(.init(completedBytes: count, totalBytes: count))
            return directory.appendingPathComponent(imageName)
        }
        let partName = request.cacheKey + ".partial"
        let journalName = partName + ".json"
        let hasPart = try exists(partName, root: root)
        let hasJournal = try exists(journalName, root: root)
        guard hasPart == hasJournal else { throw DoryRestoreImageDownloadError.damagedPartial }
        let file = try openPrivate(partName, root: root, flags: O_RDWR | (hasPart ? 0 : O_CREAT | O_EXCL))
        defer { close(file) }
        var received: UInt64 = 0
        var total: UInt64 = 0
        var tag: String?
        var hasher = SHA256()
        var transferComplete = false
        if hasJournal {
            let saved: RestoreImagePartial = try decode(journalName, root: root)
            guard saved.schema == "dory.restore-image-partial@1", saved.request == request,
                  saved.totalBytes > 0, saved.totalBytes <= Self.maximumImageBytes,
                  saved.committedBytes <= saved.totalBytes else { throw DoryRestoreImageDownloadError.damagedPartial }
            let (count, hash) = try hashFile(file, prefix: saved.committedBytes)
            guard count == saved.committedBytes, hex(hash) == saved.committedSHA256 else {
                throw DoryRestoreImageDownloadError.damagedPartial
            }
            guard ftruncate(file, off_t(count)) == 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
            received = count
            total = saved.totalBytes
            tag = saved.entityTag
            hasher = hash
            transferComplete = saved.transferComplete
            guard !transferComplete || received == total else { throw DoryRestoreImageDownloadError.damagedPartial }
            if received == total && !transferComplete {
                // All declared bytes arrived, but EOF/response completion did not. Reacquire
                // the final byte under If-Range rather than treating a failed stream as done.
                received -= 1
                (_, hasher) = try hashFile(file, prefix: received)
            }
        }
        func checkpoint() throws {
            guard fsync(file) == 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
            try publish(RestoreImagePartial(schema: "dory.restore-image-partial@1", request: request,
                         totalBytes: total, entityTag: tag, committedBytes: received, committedSHA256: hex(hasher),
                         transferComplete: transferComplete),
                        as: journalName, root: root)
        }
        if hasJournal { try checkpoint() }
        // A fully received file may have been interrupted between durable checkpoint and
        // final publication. Complete it locally, without requiring a server's 416 behavior.
        if received != total || total == 0 {
            var networkRequest = URLRequest(url: request.sourceURL)
            networkRequest.cachePolicy = .reloadIgnoringLocalCacheData
            networkRequest.timeoutInterval = 120
            networkRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if received > 0 {
                guard let tag, Self.strongTag(tag) else { throw DoryRestoreImageDownloadError.changedSource }
                networkRequest.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
                networkRequest.setValue(tag, forHTTPHeaderField: "If-Range")
            }
            do {
                let (bytes, response) = try await session.bytes(for: networkRequest, delegate: RestoreImageRedirectPolicy())
                let responseInfo = try Self.validateResponse(response, request: request, offset: received,
                                                             priorTotal: total, priorTag: tag)
                total = responseInfo.total
                tag = responseInfo.tag
                try checkpoint()
                progress(.init(completedBytes: received, totalBytes: total))
                guard ftruncate(file, off_t(received)) == 0, lseek(file, off_t(received), SEEK_SET) >= 0 else {
                    throw DoryRestoreImageDownloadError.filesystem(errno)
                }
                var buffer = Data()
                buffer.reserveCapacity(256 * 1_024)
                var lastCheckpoint = received
                func flush() throws {
                    guard !buffer.isEmpty else { return }
                    guard UInt64(buffer.count) <= total - received else { throw DoryRestoreImageDownloadError.invalidResponse }
                    try writeAll(buffer, to: file)
                    hasher.update(data: buffer)
                    received += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if received - lastCheckpoint >= 4 * 1_024 * 1_024 {
                        try checkpoint()
                        lastCheckpoint = received
                    }
                    progress(.init(completedBytes: received, totalBytes: total))
                }
                do {
                    for try await byte in bytes {
                        if buffer.isEmpty { try Task.checkCancellation() }
                        buffer.append(byte)
                        if buffer.count == 256 * 1_024 { try flush() }
                    }
                    try flush()
                    guard received == total else { throw DoryRestoreImageDownloadError.truncated }
                    transferComplete = true
                    try checkpoint()
                    try Task.checkCancellation()
                } catch {
                    // Preserve only bytes successfully committed to the file; an interrupted
                    // network buffer can be redownloaded. Durability errors must not be hidden.
                    try checkpoint()
                    throw error
                }
            } catch {
                // Failure before any response leaves a zero-byte file without a journal.
                // Retire only that exclusive file so the next attempt is not falsely corrupt.
                if !hasPart, total == 0 {
                    _ = unlinkat(root, partName, 0)
                }
                throw error
            }
        }
        try Task.checkCancellation()
        let (count, diskHash) = try hashFile(file)
        guard count == total, hex(diskHash) == hex(hasher) else { throw DoryRestoreImageDownloadError.damagedPartial }
        try checkDirectory(root)
        let receipt = DoryRestoreImageDownloadReceipt(schema: "dory.restore-image-download@1", request: request,
                                                      byteCount: total, sha256: hex(diskHash), entityTag: tag)
        // Publish the receipt first. A crash before the image rename leaves the resumable
        // journal intact; neither a partial IPSW nor an unreceipted file is returned to the UI.
        try publish(receipt, as: imageName + ".json", root: root)
        guard renameatx_np(root, partName, root, imageName, UInt32(RENAME_EXCL)) == 0, fsync(root) == 0 else {
            throw DoryRestoreImageDownloadError.filesystem(errno)
        }
        guard unlinkat(root, journalName, 0) == 0, fsync(root) == 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
        progress(.init(completedBytes: total, totalBytes: total))
        return directory.appendingPathComponent(imageName)
    }

    /// Explicit user-requested restart. Never remove a completed IPSW, another image, or
    /// an indirect/shared entry, and never discard a transfer that is still cancelling.
    public func discardPartial(_ request: DoryRestoreImageDownloadRequest) throws {
        try request.validate()
        guard !active else { throw DoryRestoreImageDownloadError.busy }
        let root = try openDirectory()
        defer { close(root) }
        let lock = try lockImage(request.cacheKey, root: root)
        defer { close(lock) }
        for name in [request.cacheKey + ".partial", request.cacheKey + ".partial.json"] {
            if try exists(name, root: root) {
                let fd = try openPrivate(name, root: root, flags: O_RDONLY)
                close(fd)
                guard unlinkat(root, name, 0) == 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
            }
        }
        guard fsync(root) == 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
    }

    static func strongTag(_ value: String) -> Bool {
        value.utf8.count >= 2 && value.utf8.count <= 512 && value.first == "\"" && value.last == "\""
            && !value.hasPrefix("W/") && !value.contains("\r") && !value.contains("\n")
    }

    static func validateResponse(_ response: URLResponse, request: DoryRestoreImageDownloadRequest,
                                 offset: UInt64, priorTotal: UInt64, priorTag: String?) throws -> (total: UInt64, tag: String?) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              DoryRestoreImageDownloadRequest.isAppleImageURL(url),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
              lengthString.range(of: #"^[0-9]{1,12}$"#, options: .regularExpression) != nil,
              let length = UInt64(lengthString), length > 0, length <= maximumImageBytes else {
            throw DoryRestoreImageDownloadError.invalidResponse
        }
        let tag = http.value(forHTTPHeaderField: "ETag").flatMap { strongTag($0) ? $0 : nil }
        if offset == 0 {
            guard http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw DoryRestoreImageDownloadError.invalidResponse
            }
            return (length, tag)
        }
        guard http.statusCode == 206, let priorTag, strongTag(priorTag), tag == priorTag else {
            throw DoryRestoreImageDownloadError.changedSource
        }
        guard priorTotal > offset, priorTotal <= maximumImageBytes,
              http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(priorTotal - 1)/\(priorTotal)",
              length == priorTotal - offset else { throw DoryRestoreImageDownloadError.invalidResponse }
        return (priorTotal, tag)
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.standardizedFileURL == directory,
              directory.resolvingSymlinksInPath() == directory else { throw DoryRestoreImageDownloadError.unsafeCache }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
        do { try checkDirectory(fd) } catch { close(fd); throw error }
        return fd
    }

    private func checkDirectory(_ fd: Int32) throws {
        var descriptor = stat(), path = stat()
        guard fstat(fd, &descriptor) == 0, lstat(directory.path, &path) == 0,
              descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino,
              descriptor.st_mode & S_IFMT == S_IFDIR, descriptor.st_uid == getuid(),
              descriptor.st_mode & 0o077 == 0 else { throw DoryRestoreImageDownloadError.unsafeCache }
    }

    private func exists(_ name: String, root: Int32) throws -> Bool {
        var info = stat()
        if fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw DoryRestoreImageDownloadError.filesystem(errno) }
        return false
    }

    private func openPrivate(_ name: String, root: Int32, flags: Int32) throws -> Int32 {
        let fd = openat(root, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DoryRestoreImageDownloadError.unsafeCache }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw DoryRestoreImageDownloadError.unsafeCache
        }
        return fd
    }

    private func lockImage(_ key: String, root: Int32) throws -> Int32 {
        let fd = try openPrivate(key + ".lock", root: root, flags: O_RDWR | O_CREAT)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw DoryRestoreImageDownloadError.busy }
        return fd
    }

    private func decode<T: Decodable>(_ name: String, root: Int32) throws -> T {
        let fd = try openPrivate(name, root: root, flags: O_RDONLY)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 16 * 1_024 else { throw DoryRestoreImageDownloadError.damagedPartial }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 16 * 1_024), data.count == info.st_size,
              let value = try? JSONDecoder().decode(T.self, from: data) else { throw DoryRestoreImageDownloadError.damagedPartial }
        return value
    }

    private func publish<T: Encodable>(_ value: T, as name: String, root: Int32) throws {
        if try exists(name, root: root) { let old = try openPrivate(name, root: root, flags: O_RDONLY); close(old) }
        let temporary = ".restore-download-" + UUID().uuidString
        let fd = try openPrivate(temporary, root: root, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); _ = unlinkat(root, temporary, 0) }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1_024 else { throw DoryRestoreImageDownloadError.damagedPartial }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0, renameat(root, temporary, root, name) == 0, fsync(root) == 0 else {
            throw DoryRestoreImageDownloadError.filesystem(errno)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DoryRestoreImageDownloadError.filesystem(errno) }
                offset += count
            }
        }
    }

    private func hashFile(_ fd: Int32, prefix: UInt64? = nil) throws -> (UInt64, SHA256) {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0, UInt64(before.st_size) <= Self.maximumImageBytes else {
            throw DoryRestoreImageDownloadError.damagedPartial
        }
        let limit = prefix ?? UInt64(before.st_size)
        guard limit <= UInt64(before.st_size) else { throw DoryRestoreImageDownloadError.damagedPartial }
        var hash = SHA256(), offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while offset < limit {
            try Task.checkCancellation()
            let count = pread(fd, &buffer, min(buffer.count, Int(limit - offset)), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DoryRestoreImageDownloadError.damagedPartial }
            hash.update(data: Data(buffer.prefix(count)))
            offset += UInt64(count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw DoryRestoreImageDownloadError.damagedPartial }
        return (offset, hash)
    }

    private func hex(_ hash: SHA256) -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
