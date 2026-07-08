import Darwin
import Foundation

public enum DockerAPIPingResult: Sendable, Equatable {
    case ok
    case badPing(statusCode: Int, body: String)
    case unreachable(String)
}

public protocol DockerAPIProbing: Sendable {
    func ping(socketPath: String) -> DockerAPIPingResult
}

public final class UnixDockerAPIProbe: DockerAPIProbing, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1) {
        self.timeout = timeout
    }

    public func ping(socketPath: String) -> DockerAPIPingResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .unreachable(errnoMessage("socket"))
        }
        defer { close(fd) }
        setTimeouts(fd)

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
            guard writeAll(httpPingRequest, to: fd) else {
                return .unreachable(errnoMessage("write"))
            }
            let response = readResponse(from: fd)
            guard let parsed = parseHTTPResponse(response) else {
                return .unreachable(response.isEmpty ? "empty Docker API response" : response)
            }
            if parsed.statusCode == 200 && parsed.body.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" {
                return .ok
            }
            return .badPing(statusCode: parsed.statusCode, body: parsed.body)
        } catch {
            return .unreachable("\(error)")
        }
    }

    private func setTimeouts(_ fd: Int32) {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

private let httpPingRequest = Array(
    "GET /_ping HTTP/1.1\r\nHost: docker\r\nUser-Agent: doryd-health\r\nConnection: close\r\n\r\n".utf8
)

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
