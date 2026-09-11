import Darwin
@testable import DoryHV
import DoryCore
import Foundation
import Testing

struct UnixSocketHTTPClientTests {
    @Test func readsBoundedContentLengthResponse() throws {
        let server = try GVHTTPFakeServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        )
        defer { server.stop() }

        #expect(UnixSocketHTTPClient.get(
            socketPath: server.path,
            path: "/_ping",
            maximumBodyBytes: 64
        ) == UnixSocketHTTPResponse(statusCode: 200, body: Data("OK".utf8)))
        #expect(server.wait())
        #expect(server.request.contains("GET /_ping HTTP/1.1"))
    }

    @Test func decodesChunkedResponseWithinLimit() throws {
        let server = try GVHTTPFakeServer(
            response: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nOK\r\n0\r\n\r\n"
        )
        defer { server.stop() }

        #expect(UnixSocketHTTPClient.get(
            socketPath: server.path,
            path: "/_ping",
            maximumBodyBytes: 2
        )?.body == Data("OK".utf8))
        #expect(server.wait())
    }

    @Test func rejectsResponseBodyOverConfiguredLimit() throws {
        let body = String(repeating: "x", count: 128)
        let server = try GVHTTPFakeServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 128\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        #expect(UnixSocketHTTPClient.get(
            socketPath: server.path,
            path: "/stats",
            maximumBodyBytes: 32
        ) == nil)
        #expect(server.wait())
    }

    @Test func rejectsHeaderInjectionAndOversizedSocketPaths() {
        #expect(UnixSocketHTTPClient.get(socketPath: "/tmp/missing", path: "/_ping\r\nInjected: yes") == nil)
        #expect(UnixSocketHTTPClient.get(socketPath: "/" + String(repeating: "x", count: 512), path: "/_ping") == nil)
    }

    @Test func readsDockerContainerListWithinInventoryBodyCap() throws {
        let body = #"[{"Id":"abc","Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":38099,"Type":"tcp"}]}]"#
        let server = try GVHTTPFakeServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        let response = try #require(UnixSocketHTTPClient.get(
            socketPath: server.path,
            path: PublishedPortForwardPlan.dockerContainerListPath,
            timeout: 3,
            maximumBodyBytes: PublishedPortForwardPlan.dockerContainerListMaximumBodyBytes
        ))
        #expect(response.statusCode == 200)
        #expect(PublishedPortForwardPlan.bindings(fromContainersJSON: response.body) == [
            PublishedPortBinding(protocol: .tcp, port: 38_099, hostIP: "127.0.0.1"),
        ])
        #expect(server.wait())
        #expect(server.request.contains("GET /containers/json HTTP/1.1"))
    }
}

private final class GVHTTPFakeServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let response: Data
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRequest = ""

    var request: String {
        lock.lock(); defer { lock.unlock() }
        return storedRequest
    }

    init(response: String) throws {
        let base = "/tmp/dory-gvproxy-http-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        path = base + "/server.sock"
        fd = try gvHTTPBindListener(path: path)
        self.response = Data(response.utf8)
        DispatchQueue.global().async { [self] in serveOne() }
    }

    func wait() -> Bool {
        done.wait(timeout: .now() + 2) == .success
    }

    func stop() {
        close(fd)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func serveOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else {
            done.signal()
            return
        }
        defer {
            close(client)
            done.signal()
        }
        var requestBytes = Data()
        var byte: UInt8 = 0
        while requestBytes.count < 8_192, Darwin.read(client, &byte, 1) == 1 {
            requestBytes.append(byte)
            if requestBytes.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        lock.lock()
        storedRequest = String(decoding: requestBytes, as: UTF8.self)
        lock.unlock()
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { break }
                offset += count
            }
        }
        shutdown(client, SHUT_WR)
    }
}

private enum GVHTTPFakeServerError: Error {
    case syscall(String, Int32)
    case pathTooLong
}

private func gvHTTPBindListener(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GVHTTPFakeServerError.syscall("socket", errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw GVHTTPFakeServerError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(fd, 1) == 0 else {
        let code = errno
        close(fd)
        throw GVHTTPFakeServerError.syscall("bind/listen", code)
    }
    return fd
}
