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
        let handle = StreamHandle()
        let task = Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path)
            handle.set(fd)
            defer { handle.close() }
            if let timeout { try Self.configureTimeout(fd, seconds: timeout) }
            try Self.writeAll(fd, HTTPCodec.serialize(request))
            return try Self.readResponse(fd: fd, readChunk: chunk)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            handle.close()
            task.cancel()
        }
    }

    /// Sends a request body incrementally using HTTP/1.1 chunked transfer encoding. This keeps
    /// large image/build archives out of the app heap while still speaking Docker's Unix-socket API.
    func sendChunked(_ request: HTTPRequest, body: AsyncStream<Data>) async throws -> HTTPResponse {
        let path = self.path
        let readChunk = self.readChunk
        let timeout = self.ioTimeout
        let handle = StreamHandle()
        let task = Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path)
            handle.set(fd)
            defer { handle.close() }
            if let timeout { try Self.configureTimeout(fd, seconds: timeout) }
            try Self.writeAll(fd, HTTPCodec.serializeChunkedRequest(request))
            for await chunk in body where !chunk.isEmpty {
                try Task.checkCancellation()
                try Self.writeAll(fd, Data(String(chunk.count, radix: 16).utf8))
                try Self.writeAll(fd, HTTPCodec.crlf)
                try Self.writeAll(fd, chunk)
                try Self.writeAll(fd, HTTPCodec.crlf)
            }
            try Self.writeAll(fd, Data("0\r\n\r\n".utf8))
            return try Self.readResponse(fd: fd, readChunk: readChunk)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            handle.close()
            task.cancel()
        }
    }

    /// Throwing archive streams must terminate the HTTP upload without writing the final chunk.
    /// Otherwise a truncated source archive can be presented to the receiving daemon as a complete
    /// request, obscuring the real source-side failure behind a later image/volume error.
    func sendChunked(
        _ request: HTTPRequest,
        body: AsyncThrowingStream<Data, Error>
    ) async throws -> HTTPResponse {
        let path = self.path
        let readChunk = self.readChunk
        let timeout = self.ioTimeout
        let handle = StreamHandle()
        let task = Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path)
            handle.set(fd)
            defer { handle.close() }
            if let timeout { try Self.configureTimeout(fd, seconds: timeout) }
            try Self.writeAll(fd, HTTPCodec.serializeChunkedRequest(request))
            for try await chunk in body where !chunk.isEmpty {
                try Task.checkCancellation()
                try Self.writeAll(fd, Data(String(chunk.count, radix: 16).utf8))
                try Self.writeAll(fd, HTTPCodec.crlf)
                try Self.writeAll(fd, chunk)
                try Self.writeAll(fd, HTTPCodec.crlf)
            }
            try Task.checkCancellation()
            try Self.writeAll(fd, Data("0\r\n\r\n".utf8))
            return try Self.readResponse(fd: fd, readChunk: readChunk)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            handle.close()
            task.cancel()
        }
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
        let timeout = self.ioTimeout
        Self.ioQueue.async {
            defer { handle.close(); onComplete() }
            guard let fd = try? Self.connectSocket(path) else { return }
            handle.set(fd)
            if let timeout, (try? Self.configureTimeout(fd, seconds: timeout)) == nil { return }
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
                if count < 0, errno == EINTR { continue }
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

    /// Streams only successful response bodies. Non-2xx responses complete with an HTTP status error
    /// instead of yielding the daemon's JSON error as if it were archive bytes.
    func streamSuccessful(_ request: HTTPRequest,
                          onChunk: @escaping @Sendable (Data) -> Void,
                          onComplete: @escaping @Sendable (Result<Void, Error>) -> Void) -> StreamHandle {
        let handle = StreamHandle()
        let path = self.path
        let chunk = self.readChunk
        let timeout = self.ioTimeout
        Self.ioQueue.async {
            var completion: Result<Void, Error> = .success(())
            defer { handle.close(); onComplete(completion) }
            do {
                let fd = try Self.connectSocket(path)
                handle.set(fd)
                if let timeout { try Self.configureTimeout(fd, seconds: timeout) }
                try Self.writeAll(fd, HTTPCodec.serialize(request))
                var buffer = Data()
                var bytes = [UInt8](repeating: 0, count: chunk)
                var headersDone = false
                var decoder: ChunkedStreamDecoder?
                var expectedContentLength: Int?
                var emittedBytes = 0
                func emit(_ data: Data) {
                    let payload = decoder?.feed(data) ?? data
                    emittedBytes += payload.count
                    if !payload.isEmpty { onChunk(payload) }
                }
                while true {
                    let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
                    if count < 0, errno == EINTR { continue }
                    if count < 0 { throw HTTPError.socket(Self.errnoMessage("read")) }
                    if count == 0 {
                        if let decoder { try decoder.validateComplete() }
                        if let expectedContentLength, emittedBytes != expectedContentLength {
                            throw HTTPError.incomplete
                        }
                        break
                    }
                    if headersDone {
                        emit(Data(bytes[0..<count]))
                    } else {
                        buffer.append(contentsOf: bytes[0..<count])
                        if let range = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: buffer) {
                            let headerText = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                            let (statusCode, headers) = Self.parseResponseHead(headerText)
                            guard (200..<300).contains(statusCode) else {
                                completion = .failure(HTTPError.status(code: statusCode, message: "stream request failed"))
                                return
                            }
                            headersDone = true
                            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                                decoder = ChunkedStreamDecoder()
                            } else if let rawLength = headers["content-length"], let length = Int(rawLength), length >= 0 {
                                expectedContentLength = length
                            }
                            let body = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                            if !body.isEmpty { emit(body) }
                        }
                    }
                    if decoder?.completed == true { break }
                    if let expectedContentLength, emittedBytes >= expectedContentLength {
                        if emittedBytes > expectedContentLength { throw HTTPError.incomplete }
                        break
                    }
                }
            } catch {
                completion = .failure(error)
            }
        }
        return handle
    }

    /// A demand-driven successful response body. Unlike callback-backed `AsyncStream`, this reads
    /// from the Unix socket only when the downstream iterator requests its next element. That
    /// gives multi-gigabyte image and volume transfers real kernel backpressure instead of an
    /// unbounded in-process queue.
    func successfulBodyStream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let reader = PullBodyReader(
            path: path,
            request: request,
            readChunk: readChunk,
            ioTimeout: ioTimeout
        )
        return AsyncThrowingStream(unfolding: {
            return try await withTaskCancellationHandler {
                try reader.nextBlocking()
            } onCancel: {
                reader.cancel()
            }
        })
    }

    private final class PullBodyReader: @unchecked Sendable {
        private let path: String
        private let request: HTTPRequest
        private let readChunk: Int
        private let ioTimeout: TimeInterval?
        private let handle = StreamHandle()
        private var fd: Int32 = -1
        private var opened = false
        private var finished = false
        private var decoder: ChunkedStreamDecoder?
        private var expectedContentLength: Int?
        private var emittedBytes = 0
        private var pending = Data()
        private var bytes: [UInt8]

        init(path: String, request: HTTPRequest, readChunk: Int, ioTimeout: TimeInterval?) {
            self.path = path
            self.request = request
            self.readChunk = readChunk
            self.ioTimeout = ioTimeout
            bytes = [UInt8](repeating: 0, count: readChunk)
        }

        deinit { cancel() }

        func cancel() {
            handle.close()
        }

        private func finish() {
            finished = true
            handle.close()
        }

        func nextBlocking() throws -> Data? {
            try Task.checkCancellation()
            if !opened { try open() }
            if !pending.isEmpty {
                let result = pending
                pending.removeAll(keepingCapacity: true)
                return result
            }
            if finished { return nil }

            while true {
                try Task.checkCancellation()
                let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, readChunk) }
                if count < 0 {
                    if errno == EINTR { continue }
                    finish()
                    throw HTTPError.socket(UnixSocketHTTP.errnoMessage("read"))
                }
                if count == 0 {
                    if let decoder { try decoder.validateComplete() }
                    if let expectedContentLength, emittedBytes != expectedContentLength {
                        finish()
                        throw HTTPError.incomplete
                    }
                    finish()
                    return nil
                }
                let payload = try consume(Data(bytes[0..<count]))
                if !payload.isEmpty { return payload }
                if finished { return nil }
            }
        }

        private func open() throws {
            fd = try UnixSocketHTTP.connectSocket(path)
            handle.set(fd)
            if let ioTimeout { try UnixSocketHTTP.configureTimeout(fd, seconds: ioTimeout) }
            try UnixSocketHTTP.writeAll(fd, HTTPCodec.serialize(request))
            opened = true

            var headerBuffer = Data()
            while true {
                try Task.checkCancellation()
                let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, readChunk) }
                if count < 0 {
                    if errno == EINTR { continue }
                    finish()
                    throw HTTPError.socket(UnixSocketHTTP.errnoMessage("read"))
                }
                guard count > 0 else {
                    finish()
                    throw HTTPError.connectionClosed
                }
                headerBuffer.append(contentsOf: bytes[0..<count])
                guard headerBuffer.count <= 1_048_576 else {
                    finish()
                    throw HTTPError.incomplete
                }
                guard let range = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: headerBuffer) else {
                    continue
                }
                let headerText = String(
                    data: headerBuffer.subdata(in: headerBuffer.startIndex..<range.lowerBound),
                    encoding: .utf8
                ) ?? ""
                let (statusCode, headers) = UnixSocketHTTP.parseResponseHead(headerText)
                guard (200..<300).contains(statusCode) else {
                    finish()
                    throw HTTPError.status(code: statusCode, message: "stream request failed")
                }
                if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                    decoder = ChunkedStreamDecoder()
                } else if let rawLength = headers["content-length"],
                          let length = Int(rawLength), length >= 0 {
                    expectedContentLength = length
                }
                let initialBody = headerBuffer.subdata(in: range.upperBound..<headerBuffer.endIndex)
                if !initialBody.isEmpty { pending = try consume(initialBody) }
                if expectedContentLength == 0 { finish() }
                return
            }
        }

        private func consume(_ data: Data) throws -> Data {
            if let decoder {
                let payload = decoder.feed(data)
                if decoder.malformed {
                    finish()
                    throw HTTPError.malformedChunk
                }
                if decoder.completed { finish() }
                return payload
            }
            if let expectedContentLength {
                emittedBytes += data.count
                guard emittedBytes <= expectedContentLength else {
                    finish()
                    throw HTTPError.incomplete
                }
                if emittedBytes == expectedContentLength { finish() }
            }
            return data
        }
    }

    nonisolated private static func parseResponseHead(_ text: String) -> (Int, [String: String]) {
        var lines = text.components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let status = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 0) : 0
        if !lines.isEmpty { lines.removeFirst() }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (status, headers)
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
            if count < 0, errno == EINTR { continue }
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
                if written < 0, errno == EINTR { continue }
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
