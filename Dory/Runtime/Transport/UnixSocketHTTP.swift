import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct UnixSocketHTTP: Sendable {
    let path: String
    var readChunk: Int = 64 * 1024
    var ioTimeout: TimeInterval? = nil

    private static let ioQueue = DispatchQueue(label: "com.pythonxi.Dory.socket", attributes: .concurrent)

    nonisolated init(path: String, readChunk: Int = 64 * 1024, ioTimeout: TimeInterval? = nil) {
        self.path = path
        self.readChunk = readChunk
        self.ioTimeout = ioTimeout
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = self.path
        let chunk = self.readChunk
        let timeout = self.ioTimeout
        return try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do { continuation.resume(returning: try Self.blockingSend(path: path, request: request, readChunk: chunk, ioTimeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Sends a request body incrementally using HTTP/1.1 chunked transfer encoding. This keeps
    /// large image/build archives out of the app heap while still speaking Docker's Unix-socket API.
    func sendChunked(_ request: HTTPRequest, body: AsyncStream<Data>) async throws -> HTTPResponse {
        let path = self.path
        let readChunk = self.readChunk
        return try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path)
            defer { Darwin.close(fd) }
            try Self.writeAll(fd, HTTPCodec.serializeChunkedRequest(request))
            for await chunk in body where !chunk.isEmpty {
                try Self.writeAll(fd, Data(String(chunk.count, radix: 16).utf8))
                try Self.writeAll(fd, HTTPCodec.crlf)
                try Self.writeAll(fd, chunk)
                try Self.writeAll(fd, HTTPCodec.crlf)
            }
            try Self.writeAll(fd, Data("0\r\n\r\n".utf8))
            return try Self.readResponse(fd: fd, readChunk: readChunk)
        }.value
    }

    /// Owns the single file descriptor for a stream and is the only thing that closes it, so
    /// `close()` is idempotent and cannot double-close (which could otherwise close a reused fd).
    nonisolated final class StreamHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var closed = false
        private var pendingClose = false
        func set(_ value: Int32) {
            lock.lock(); defer { lock.unlock() }
            fd = value
            if pendingClose { performClose() }
        }
        func close() {
            lock.lock(); defer { lock.unlock() }
            if fd < 0 { pendingClose = true; return }
            performClose()
        }
        private func performClose() {
            if !closed, fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
            closed = true
        }
    }

    /// Streams a response body (after headers) chunk-by-chunk. If the upstream response uses
    /// `Transfer-Encoding: chunked`, the framing is decoded so consumers receive the payload only.
    /// The returned handle's `close()` stops the stream. `onComplete` fires exactly once at the end.
    func stream(_ request: HTTPRequest,
                onChunk: @escaping @Sendable (Data) -> Void,
                onComplete: @escaping @Sendable () -> Void = {}) -> StreamHandle {
        let handle = StreamHandle()
        let path = self.path
        let chunk = self.readChunk
        Self.ioQueue.async {
            defer { handle.close(); onComplete() }
            guard let fd = try? Self.connectSocket(path) else { return }
            handle.set(fd)
            guard (try? Self.writeAll(fd, HTTPCodec.serialize(request))) != nil else { return }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: chunk)
            var headersDone = false
            var decoder: ChunkedStreamDecoder?
            func emit(_ data: Data) {
                if let decoder { onChunk(decoder.feed(data)) } else { onChunk(data) }
            }
            while true {
                let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
                if count <= 0 { break }
                if headersDone {
                    emit(Data(bytes[0..<count]))
                } else {
                    buffer.append(contentsOf: bytes[0..<count])
                    if let range = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: buffer) {
                        headersDone = true
                        let headerText = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                        if headerText.lowercased().contains("transfer-encoding:") && headerText.lowercased().contains("chunked") {
                            decoder = ChunkedStreamDecoder()
                        }
                        let body = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                        if !body.isEmpty { emit(body) }
                    }
                }
            }
        }
        return handle
    }

    nonisolated static func blockingSend(path: String, request: HTTPRequest, readChunk: Int, ioTimeout: TimeInterval? = nil) throws -> HTTPResponse {
        let fd = try connectSocket(path)
        defer { close(fd) }
        if let ioTimeout { try configureTimeout(fd, seconds: ioTimeout) }
        try writeAll(fd, HTTPCodec.serialize(request))
        return try readResponse(fd: fd, readChunk: readChunk)
    }

    nonisolated static func configureTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        let clamped = max(seconds, 0.001)
        var timeout = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - floor(clamped)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0 else {
            throw HTTPError.socket(errnoMessage("setsockopt(SO_RCVTIMEO)"))
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
            throw HTTPError.socket(errnoMessage("setsockopt(SO_SNDTIMEO)"))
        }
    }

    nonisolated private static func readResponse(fd: Int32, readChunk: Int) throws -> HTTPResponse {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: readChunk)
        while true {
            if let response = try HTTPCodec.parseResponse(buffer) { return response }
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, readChunk) }
            if count < 0 { throw HTTPError.socket(errnoMessage("read")) }
            if count == 0 {
                if let response = try HTTPCodec.parseResponse(buffer, connectionClosed: true) { return response }
                throw HTTPError.connectionClosed
            }
            buffer.append(contentsOf: bytes[0..<count])
        }
    }

    nonisolated static func connectSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socket(errnoMessage("socket")) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HTTPError.socket("socket path too long (\(pathBytes.count) >= \(capacity))")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard result == 0 else {
            let message = errnoMessage("connect(\(path))")
            close(fd)
            throw HTTPError.socket(message)
        }
        return fd
    }

    nonisolated static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { throw HTTPError.socket(errnoMessage("write")) }
                offset += written
            }
        }
    }

    /// Owns both fds for a hijacked session and tears it down correctly without leaking threads/fds.
    /// Half-close semantics matter for interactive streams (exec/attach): a client that finishes
    /// sending stdin must NOT kill the upstream→client direction — the command still has output and
    /// an exit code to deliver. So:
    ///   • client→upstream pump ends (stdin EOF)  → half-close upstream's write side; keep draining.
    ///   • upstream→client pump ends (stream done) → the session is over: fully shut down the client
    ///     so the still-blocked client→upstream read returns instead of leaking forever.
    /// Each fd is closed exactly once, only after both pumps have drained.
    nonisolated private final class ProxyConnection: @unchecked Sendable {
        private let lock = NSLock()
        private let client: Int32
        private let upstream: Int32
        private var finished = 0
        private var closed = false
        init(client: Int32, upstream: Int32) { self.client = client; self.upstream = upstream }

        func clientPumpFinished() {
            shutdown(upstream, SHUT_WR)
            settle()
        }
        func upstreamPumpFinished() {
            shutdown(client, SHUT_RDWR)
            shutdown(upstream, SHUT_RDWR)
            settle()
        }
        private func settle() {
            lock.lock(); defer { lock.unlock() }
            finished += 1
            if finished >= 2, !closed {
                closed = true
                Darwin.close(client)
                Darwin.close(upstream)
            }
        }
    }

    /// Copies bytes in both directions between a hijacked client connection and an upstream
    /// connection. Non-blocking: spawns the pumps on dedicated threads (so a long-lived session
    /// never parks a shared worker) and takes ownership of BOTH fds, closing each exactly once.
    nonisolated static func bidirectionalCopy(client: Int32, upstream: Int32) {
        let connection = ProxyConnection(client: client, upstream: upstream)
        func pump(_ from: Int32, _ to: Int32, onFinish: @escaping @Sendable () -> Void) {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, 32 * 1024) }
                    if count <= 0 { break }
                    var offset = 0
                    var ok = true
                    while offset < count {
                        let written = buffer.withUnsafeBytes { write(to, $0.baseAddress!.advanced(by: offset), count - offset) }
                        if written <= 0 { ok = false; break }
                        offset += written
                    }
                    if !ok { break }
                }
                onFinish()
            }
        }
        pump(client, upstream, onFinish: { connection.clientPumpFinished() })
        pump(upstream, client, onFinish: { connection.upstreamPumpFinished() })
    }

    nonisolated static func errnoMessage(_ context: String) -> String {
        "\(context): \(String(cString: strerror(errno))) (\(errno))"
    }
}
