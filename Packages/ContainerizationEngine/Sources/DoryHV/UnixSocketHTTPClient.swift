import Darwin
import Foundation

public struct UnixSocketHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// A bounded HTTP/1.1 GET used by engine-internal Unix-socket probes (gvproxy health, Docker
/// `/_ping`, and published-port inventory).
///
/// Keeping this in-process avoids spawning `curl` for every probe interval. Responses are capped
/// before allocation growth, and malformed/truncated/chunked bodies fail closed.
public enum UnixSocketHTTPClient {
    public static func get(
        socketPath: String,
        path: String,
        timeout: TimeInterval = 2,
        maximumBodyBytes: Int = 32 * 1_024
    ) -> UnixSocketHTTPResponse? {
        guard path.first == "/", !path.contains("\r"), !path.contains("\n"),
              maximumBodyBytes > 0 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(timeout, on: fd)

        guard var address = unixAddress(path: socketPath) else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let request = Data(
            "GET \(path) HTTP/1.1\r\nHost: dory-health\r\nConnection: close\r\n\r\n".utf8
        )
        guard writeAll(request, to: fd) else { return nil }
        guard let wire = readBounded(from: fd, maximumBytes: maximumBodyBytes + 16 * 1_024) else {
            return nil
        }
        return parseResponse(wire, maximumBodyBytes: maximumBodyBytes)
    }

    private static func setTimeout(_ timeout: TimeInterval, on fd: Int32) {
        let bounded = max(0.001, timeout)
        var value = timeval(
            tv_sec: Int(bounded),
            tv_usec: Int32((bounded - floor(bounded)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func unixAddress(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        return address
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readBounded(from fd: Int32, maximumBytes: Int) -> Data? {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let capacity = buffer.count
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!, capacity)
            }
            if readCount > 0 {
                guard output.count + readCount <= maximumBytes else { return nil }
                output.append(contentsOf: buffer.prefix(readCount))
            } else if readCount == 0 {
                return output
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    private static func parseResponse(
        _ wire: Data,
        maximumBodyBytes: Int
    ) -> UnixSocketHTTPResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = wire.range(of: separator) else { return nil }
        let headerData = wire[..<headerRange.lowerBound]
        guard let headers = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headers.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        let body = Data(wire[headerRange.upperBound...])
        let decoded: Data
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let chunked = decodeChunked(body, maximumBodyBytes: maximumBodyBytes) else { return nil }
            decoded = chunked
        } else if let rawLength = fields["content-length"], let length = Int(rawLength) {
            guard length >= 0, length <= maximumBodyBytes, body.count >= length else { return nil }
            decoded = Data(body.prefix(length))
        } else {
            guard body.count <= maximumBodyBytes else { return nil }
            decoded = body
        }
        return UnixSocketHTTPResponse(statusCode: statusCode, body: decoded)
    }

    private static func decodeChunked(_ body: Data, maximumBodyBytes: Int) -> Data? {
        let crlf = Data("\r\n".utf8)
        var cursor = body.startIndex
        var output = Data()
        while true {
            guard let lineRange = body.range(of: crlf, in: cursor..<body.endIndex),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .utf8) else {
                return nil
            }
            let sizeText = line.split(separator: ";", maxSplits: 1)[0]
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            cursor = lineRange.upperBound
            if size == 0 { return output }
            guard size <= maximumBodyBytes - output.count,
                  let end = body.index(cursor, offsetBy: size, limitedBy: body.endIndex),
                  body.distance(from: end, to: body.endIndex) >= 2,
                  body[end..<body.index(end, offsetBy: 2)] == crlf else {
                return nil
            }
            output.append(body[cursor..<end])
            cursor = body.index(end, offsetBy: 2)
        }
    }
}
