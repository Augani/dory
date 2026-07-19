import Darwin
import Foundation

public enum DockerAPIPingResult: Sendable, Equatable {
    case ok
    case badPing(statusCode: Int, body: String)
    case unreachable(String)
}

public enum DockerAPISystemDFResult: Sendable, Equatable {
    case ok
    case badResponse(statusCode: Int, body: String)
    case unreachable(String)
}

public enum DockerAPIResourceInventoryResult: Sendable, Equatable {
    case ok(body: String)
    case badResponse(statusCode: Int, body: String)
    case unreachable(String)
}

public protocol DockerAPIProbing: Sendable {
    func ping(socketPath: String) -> DockerAPIPingResult
    func systemDF(socketPath: String) -> DockerAPISystemDFResult
    func resourceInventory(socketPath: String) -> DockerAPIResourceInventoryResult
}

public extension DockerAPIProbing {
    func resourceInventory(socketPath: String) -> DockerAPIResourceInventoryResult {
        .unreachable("full Docker resource inventory probe is unavailable")
    }
}

public final class UnixDockerAPIProbe: DockerAPIProbing, @unchecked Sendable {
    private static let pingResponseLimit = 64 * 1024
    // `/system/df?type=container` is intentionally much smaller than the unfiltered inventory,
    // but a developer can still accumulate hundreds of stopped containers. Read the complete
    // response before closing the socket: truncating it cancels dockerd's snapshot walk and can
    // leave the daemon emitting `context canceled` image-resolution warnings indefinitely.
    private static let systemDFResponseLimit = 16 * 1024 * 1024
    private static let systemDFMinimumTimeout: TimeInterval = 10

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1) {
        self.timeout = timeout
    }

    public func ping(socketPath: String) -> DockerAPIPingResult {
        switch request(
            path: "/_ping",
            socketPath: socketPath,
            timeout: timeout,
            maxBytes: Self.pingResponseLimit
        ) {
        case let .response(statusCode, body):
            if statusCode == 200 && body.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" {
                return .ok
            }
            return .badPing(statusCode: statusCode, body: body)
        case let .unreachable(detail):
            return .unreachable(detail)
        }
    }

    public func systemDF(socketPath: String) -> DockerAPISystemDFResult {
        // Container metadata is the portion that exposes missing rw-layer snapshots. Avoid asking
        // dockerd to enumerate every image, volume, and BuildKit record for a passive health check.
        switch request(
            path: "/system/df?type=container",
            socketPath: socketPath,
            timeout: max(timeout, Self.systemDFMinimumTimeout),
            maxBytes: Self.systemDFResponseLimit
        ) {
        case let .response(statusCode, body):
            if statusCode == 200 {
                return .ok
            }
            return .badResponse(statusCode: statusCode, body: body)
        case let .unreachable(detail):
            return .unreachable(detail)
        }
    }

    public func resourceInventory(socketPath: String) -> DockerAPIResourceInventoryResult {
        switch request(
            path: "/system/df",
            socketPath: socketPath,
            timeout: max(timeout, Self.systemDFMinimumTimeout),
            maxBytes: Self.systemDFResponseLimit
        ) {
        case let .response(statusCode, body):
            return statusCode == 200
                ? .ok(body: body)
                : .badResponse(statusCode: statusCode, body: body)
        case let .unreachable(detail):
            return .unreachable(detail)
        }
    }

    private func request(
        path: String,
        socketPath: String,
        timeout: TimeInterval,
        maxBytes: Int
    ) -> DockerAPIHTTPResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .unreachable(errnoMessage("socket"))
        }
        defer { close(fd) }
        // A readiness probe commonly races dockerd startup or proxy teardown. On Darwin, writing
        // to that closed stream raises SIGPIPE and can terminate doryd/dory-vmm unless the socket
        // explicitly suppresses it; the EPIPE result below is the intended unreachable outcome.
        var noSignal: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return .unreachable(errnoMessage("setsockopt(SO_NOSIGPIPE)"))
        }
        setTimeouts(fd, timeout: timeout)

        do {
            var address = try unixAddress(path: socketPath)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                return .unreachable(errnoMessage("connect"))
            }
            guard writeAll(httpRequest(path: path), to: fd) else {
                return .unreachable(errnoMessage("write"))
            }
            let response = readResponse(from: fd, maxBytes: maxBytes)
            guard let parsed = parseHTTPResponse(response) else {
                return .unreachable(response.isEmpty ? "empty Docker API response" : response)
            }
            return .response(statusCode: parsed.statusCode, body: parsed.body)
        } catch {
            return .unreachable("\(error)")
        }
    }

    private func setTimeouts(_ fd: Int32, timeout: TimeInterval) {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

private enum DockerAPIHTTPResult {
    case response(statusCode: Int, body: String)
    case unreachable(String)
}

private func httpRequest(path: String) -> [UInt8] {
    Array(
        "GET \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: doryd-health\r\nConnection: close\r\n\r\n".utf8
    )
}

private enum UnixSocketAddressError: Error, CustomStringConvertible {
    case pathTooLong(String)

    var description: String {
        switch self {
        case let .pathTooLong(path):
            return "unix socket path is too long: \(path)"
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw UnixSocketAddressError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

private func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

private func readResponse(from fd: Int32, maxBytes: Int = 64 * 1024) -> String {
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while output.count < maxBytes {
        let capacity = min(buffer.count, maxBytes - output.count)
        let got = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, capacity)
        }
        if got > 0 {
            output.append(contentsOf: buffer.prefix(got))
            continue
        }
        if got == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            break
        }
        return errnoMessage("read")
    }
    return String(decoding: output, as: UTF8.self)
}

private func parseHTTPResponse(_ response: String) -> (statusCode: Int, body: String)? {
    guard let firstLineEnd = response.range(of: "\r\n"),
          let headerEnd = response.range(of: "\r\n\r\n") else {
        return nil
    }
    let firstLine = response[..<firstLineEnd.lowerBound]
    let parts = firstLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
    return (status, String(response[headerEnd.upperBound...]))
}

private func errnoMessage(_ operation: String) -> String {
    "\(operation): \(String(cString: strerror(errno)))"
}
