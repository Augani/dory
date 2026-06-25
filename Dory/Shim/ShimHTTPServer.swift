import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class ShimStreamWriter: @unchecked Sendable {
    private let fd: Int32
    private let chunked: Bool
    private var finished = false

    init(fd: Int32, chunked: Bool = false) {
        self.fd = fd
        self.chunked = chunked
    }

    @discardableResult func write(_ data: Data) -> Bool {
        guard !finished else { return false }
        guard !data.isEmpty else { return true }
        guard chunked else {
            return (try? UnixSocketHTTP.writeAll(fd, data)) != nil
        }
        var frame = Data(String(data.count, radix: 16).utf8)
        frame.append(HTTPCodec.crlf)
        frame.append(data)
        frame.append(HTTPCodec.crlf)
        return (try? UnixSocketHTTP.writeAll(fd, frame)) != nil
    }

    @discardableResult func finish() -> Bool {
        guard !finished else { return true }
        finished = true
        guard chunked else { return true }
        return (try? UnixSocketHTTP.writeAll(fd, Data("0\r\n\r\n".utf8))) != nil
    }
}

struct ShimResponse: Sendable {
    var status: Int
    var headers: [(name: String, value: String)]
    var body: Data
    var stream: (@Sendable (ShimStreamWriter) async -> Void)?
    var hijack: (@Sendable (Int32, Data) -> Void)?

    init(status: Int, headers: [(name: String, value: String)], body: Data,
         stream: (@Sendable (ShimStreamWriter) async -> Void)? = nil,
         hijack: (@Sendable (Int32, Data) -> Void)? = nil) {
        self.status = status; self.headers = headers; self.body = body; self.stream = stream; self.hijack = hijack
    }

    /// `proxy` receives the raw client fd and the bytes already read from it (request + any
    /// initial payload the client pipelined after the headers), which must be forwarded verbatim.
    static func hijacked(_ proxy: @escaping @Sendable (Int32, Data) -> Void) -> ShimResponse {
        ShimResponse(status: 200, headers: [], body: Data(), hijack: proxy)
    }

    static func streaming(contentType: String, _ producer: @escaping @Sendable (ShimStreamWriter) async -> Void) -> ShimResponse {
        ShimResponse(status: 200, headers: [(name: "Content-Type", value: contentType)], body: Data(), stream: producer)
    }

    static func json(_ data: Data, status: Int = 200) -> ShimResponse {
        ShimResponse(status: status, headers: [(name: "Content-Type", value: "application/json")], body: data)
    }
    static func text(_ string: String, status: Int = 200) -> ShimResponse {
        ShimResponse(status: status, headers: [(name: "Content-Type", value: "text/plain")], body: Data(string.utf8))
    }
    static func empty(status: Int) -> ShimResponse {
        ShimResponse(status: status, headers: [], body: Data())
    }
}

final class ShimHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (ParsedRequest) async -> ShimResponse
    /// Given the raw client fd and the bytes already read (request head + any pipelined body
    /// bytes), takes over the connection and proxies it verbatim to the engine. When set, every
    /// connection is handed off as soon as the request headers arrive — the full transparent proxy.
    typealias RawProxy = @Sendable (Int32, Data) -> Void

    let socketPath: String
    private let handler: Handler
    private let rawProxy: RawProxy?
    private let queue = DispatchQueue(label: "com.pythonxi.Dory.shim", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    init(socketPath: String, rawProxy: RawProxy? = nil, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.rawProxy = rawProxy
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("socket")) }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); throw HTTPError.socket("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { let m = UnixSocketHTTP.errnoMessage("bind"); close(fd); throw HTTPError.socket(m) }
        // Restrict the control socket to the owner — it grants full Docker-API (including destroy)
        // access, so it must not be connectable by other local users.
        chmod(socketPath, S_IRUSR | S_IWUSR)
        guard listen(fd, 32) == 0 else { let m = UnixSocketHTTP.errnoMessage("listen"); close(fd); throw HTTPError.socket(m) }

        lock.lock(); listenFD = fd; running = true; lock.unlock()
        // The accept loop runs on its own dedicated thread so it can never share — or be starved
        // by — the worker pool that services connections and long-lived proxy/stream handlers.
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock(); running = false; let fd = listenFD; listenFD = -1; lock.unlock()
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning() {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if !isRunning() { break }
                let err = errno
                if err == EINTR || err == ECONNABORTED { continue }
                if err == EBADF || err == EINVAL { break }
                // fd/buffer exhaustion: yield briefly so in-flight connections can close and free
                // descriptors instead of spinning the CPU at 100%.
                if err == EMFILE || err == ENFILE || err == ENOBUFS || err == ENOMEM { usleep(20_000) }
                continue
            }
            Self.applySendTimeout(client)
            queue.async { [weak self] in self?.handleConnection(client) }
        }
    }

    /// Bounds how long a single blocking write to a wedged client can pin its handler thread, so a
    /// dead/stalled reader aborts the stream as backpressure instead of leaking a worker forever.
    private static func applySendTimeout(_ fd: Int32) {
        var tv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleConnection(_ fd: Int32) {
        var hijacked = false
        defer { if !hijacked { shutdown(fd, SHUT_RDWR); close(fd) } }
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)

        // Read until the request headers are complete (bounded so an endless header stream can't
        // exhaust memory). For a transparent-proxy backend we hand off the moment headers arrive,
        // forwarding the raw connection verbatim without buffering large request bodies.
        var headersComplete = false
        for _ in 0..<256 {
            if HTTPCodec.range(of: HTTPCodec.headerTerminator, in: buffer) != nil { headersComplete = true; break }
            if buffer.count > 1_048_576 { break }
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
            if count <= 0 { break }
            buffer.append(contentsOf: bytes[0..<count])
        }
        guard headersComplete else {
            try? UnixSocketHTTP.writeAll(fd, HTTPCodec.serializeResponse(status: 400, body: Data("bad request".utf8)))
            return
        }

        if let rawProxy {
            hijacked = true
            rawProxy(fd, buffer)
            return
        }

        var request = try? HTTPCodec.parseRequest(buffer)
        var attempts = 0
        while request == nil, attempts < 256 {
            attempts += 1
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
            if count <= 0 { break }
            buffer.append(contentsOf: bytes[0..<count])
            request = try? HTTPCodec.parseRequest(buffer)
        }
        guard let request else {
            try? UnixSocketHTTP.writeAll(fd, HTTPCodec.serializeResponse(status: 400, body: Data("bad request".utf8)))
            return
        }
        let response = runBlocking { [handler] in await handler(request) }
        if let hijack = response.hijack {
            // Hand the raw connection + already-read bytes to the proxy; it owns and closes the fd.
            hijacked = true
            hijack(fd, buffer)
            return
        }
        if let producer = response.stream {
            var head = "HTTP/1.1 \(response.status) \(HTTPCodec.reasonPhrase(response.status))\r\n"
            for header in response.headers {
                let name = header.name.lowercased()
                guard name != "content-length", name != "transfer-encoding" else { continue }
                head += "\(header.name): \(header.value)\r\n"
            }
            head += "Transfer-Encoding: chunked\r\n"
            if !response.headers.contains(where: { $0.name.lowercased() == "connection" }) {
                head += "Connection: close\r\n"
            }
            head += "\r\n"
            guard (try? UnixSocketHTTP.writeAll(fd, Data(head.utf8))) != nil else { return }
            let writer = ShimStreamWriter(fd: fd, chunked: true)
            _ = runBlocking { await producer(writer); return ShimResponse.empty(status: 200) }
            _ = writer.finish()
        } else {
            let data = HTTPCodec.serializeResponse(status: response.status, headers: response.headers, body: response.body)
            try? UnixSocketHTTP.writeAll(fd, data)
        }
    }

    private func runBlocking(_ operation: @escaping @Sendable () async -> ShimResponse) -> ShimResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            let result = await operation()
            box.value = result
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? ShimResponse.empty(status: 500)
    }

    private final class ResponseBox: @unchecked Sendable { var value: ShimResponse? }
}
