import Darwin
import Foundation

public enum DockerContainerActivity: Equatable, Sendable {
    case active(Int)
    case empty
    case unknown(String)

    public var hasActiveContainers: Bool {
        if case .active = self { return true }
        return false
    }
}

public enum DockerContainerList: Equatable, Sendable {
    case ok([DockerContainerSummary])
    case unavailable(String)
}

public struct DockerContainerPort: Decodable, Equatable, Sendable {
    public var privatePort: Int?
    public var publicPort: Int?
    public var ip: String?
    public var type: String?

    enum CodingKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case ip = "IP"
        case type = "Type"
    }
}

public struct DockerContainerSummary: Decodable, Equatable, Sendable {
    public var id: String
    public var names: [String]
    public var state: String?
    public var status: String?
    public var ports: [DockerContainerPort]
    public var labels: [String: String]

    public var displayName: String {
        let name = names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return name.isEmpty ? String(id.prefix(12)) : name
    }

    public var isRunning: Bool {
        state?.lowercased() == "running"
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        names = (try? container.decode([String].self, forKey: .names)) ?? []
        state = try? container.decode(String.self, forKey: .state)
        status = try? container.decode(String.self, forKey: .status)
        ports = (try? container.decode([DockerContainerPort].self, forKey: .ports)) ?? []
        labels = (try? container.decode([String: String].self, forKey: .labels)) ?? [:]
    }
}

public enum DockerEngineProbe {
    public static func containerSummaries(
        socketPath: String,
        timeout: TimeInterval = 2
    ) -> DockerContainerList {
        do {
            let response = try request(
                path: "/containers/json?all=1",
                socketPath: socketPath,
                timeout: timeout,
                maxBytes: 2 * 1024 * 1024
            )
            guard (200..<300).contains(response.status) else {
                return .unavailable("docker returned HTTP \(response.status)")
            }
            return .ok(try JSONDecoder().decode([DockerContainerSummary].self, from: response.body))
        } catch {
            return .unavailable("\(error)")
        }
    }

    public static func containerSummaries(
        forwardSocketPath: String,
        cid: UInt32,
        dockerPort: UInt32,
        timeout: TimeInterval = 2
    ) -> DockerContainerList {
        do {
            let response = try request(
                path: "/containers/json?all=1",
                forwardSocketPath: forwardSocketPath,
                cid: cid,
                port: dockerPort,
                timeout: timeout,
                maxBytes: 2 * 1024 * 1024
            )
            guard (200..<300).contains(response.status) else {
                return .unavailable("docker returned HTTP \(response.status)")
            }
            return .ok(try JSONDecoder().decode([DockerContainerSummary].self, from: response.body))
        } catch {
            return .unavailable("\(error)")
        }
    }

    public static func containerActivity(
        socketPath: String,
        timeout: TimeInterval = 2
    ) -> DockerContainerActivity {
        switch containerSummaries(socketPath: socketPath, timeout: timeout) {
        case let .ok(entries):
            let active = entries.filter { entry in
                guard let state = entry.state?.lowercased() else { return false }
                return state == "running" || state == "restarting" || state == "paused"
            }.count
            return active > 0 ? .active(active) : .empty
        case let .unavailable(reason):
            return .unknown(reason)
        }
    }

    public static func containerActivity(
        forwardSocketPath: String,
        cid: UInt32,
        dockerPort: UInt32,
        timeout: TimeInterval = 2
    ) -> DockerContainerActivity {
        switch containerSummaries(
            forwardSocketPath: forwardSocketPath,
            cid: cid,
            dockerPort: dockerPort,
            timeout: timeout
        ) {
        case let .ok(entries):
            let active = entries.filter { entry in
                guard let state = entry.state?.lowercased() else { return false }
                return state == "running" || state == "restarting" || state == "paused"
            }.count
            return active > 0 ? .active(active) : .empty
        case let .unavailable(reason):
            return .unknown(reason)
        }
    }

    public static func waitUntilReady(
        socketPath: String,
        timeout: TimeInterval = 45,
        pollInterval: TimeInterval = 0.25,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, shouldContinue() {
            if (try? versionIsReady(
                socketPath: socketPath,
                timeout: min(2, max(0.25, pollInterval * 2))
            )) == true {
                return true
            }
            guard shouldContinue() else { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    public static func waitUntilReady(
        forwardSocketPath: String,
        cid: UInt32,
        dockerPort: UInt32,
        timeout: TimeInterval = 45,
        pollInterval: TimeInterval = 0.25,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, shouldContinue() {
            if (try? versionIsReady(
                forwardSocketPath: forwardSocketPath,
                cid: cid,
                dockerPort: dockerPort,
                timeout: min(2, max(0.25, pollInterval * 2))
            )) == true {
                return true
            }
            guard shouldContinue() else { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    private static func versionIsReady(
        socketPath: String,
        timeout: TimeInterval
    ) throws -> Bool {
        let response = try request(
            path: "/version",
            socketPath: socketPath,
            timeout: timeout,
            maxBytes: 64 * 1024
        )
        return try dockerVersionIsReady(response)
    }

    private static func versionIsReady(
        forwardSocketPath: String,
        cid: UInt32,
        dockerPort: UInt32,
        timeout: TimeInterval
    ) throws -> Bool {
        let response = try request(
            path: "/version",
            forwardSocketPath: forwardSocketPath,
            cid: cid,
            port: dockerPort,
            timeout: timeout,
            maxBytes: 64 * 1024
        )
        return try dockerVersionIsReady(response)
    }

    private static func dockerVersionIsReady(_ response: HTTPResponse) throws -> Bool {
        guard (200..<300).contains(response.status) else { return false }
        let version = try JSONDecoder().decode(DockerVersionProbe.self, from: response.body)
        return version.operatingSystem.lowercased() == "linux"
            && !version.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func request(
        path: String,
        socketPath: String,
        timeout: TimeInterval,
        maxBytes: Int
    ) throws -> HTTPResponse {
        let fd = try connectUnix(path: socketPath, timeout: timeout)
        defer { close(fd) }
        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        try writeAll(Array(request.utf8), to: fd)
        shutdown(fd, SHUT_WR)
        let data = try readHTTPResponseData(from: fd, maxBytes: maxBytes)
        return try HTTPResponse(data: data)
    }

    private static func request(
        path: String,
        forwardSocketPath: String,
        cid: UInt32,
        port: UInt32,
        timeout: TimeInterval,
        maxBytes: Int
    ) throws -> HTTPResponse {
        let fd = try connectUnix(path: forwardSocketPath, timeout: timeout)
        defer { close(fd) }
        try writeAll(forwardPreamble(cid: cid, port: port), to: fd)
        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        try writeAll(Array(request.utf8), to: fd)
        shutdown(fd, SHUT_WR)
        let data = try readHTTPResponseData(from: fd, maxBytes: maxBytes)
        return try HTTPResponse(data: data)
    }
}

private struct DockerVersionProbe: Decodable {
    var version: String
    var operatingSystem: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case operatingSystem = "Os"
    }
}

private struct HTTPResponse {
    var status: Int
    var body: Data

    init(data: Data) throws {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = headerText.split(separator: "\r\n", maxSplits: 1).first else {
            throw ProbeError.malformedHTTP
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ProbeError.malformedHTTP
        }
        self.status = status
        let headers = headerFields(headerText)
        let rawBody = Data(data[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            self.body = try decodeChunkedBody(rawBody)
        } else {
            self.body = rawBody
        }
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case pathTooLong
    case syscall(String, Int32)
    case malformedHTTP
    case tooLarge

    var description: String {
        switch self {
        case .pathTooLong:
            return "unix socket path is too long"
        case .syscall(let name, let error):
            return "\(name) failed: \(String(cString: strerror(error)))"
        case .malformedHTTP:
            return "malformed HTTP response"
        case .tooLarge:
            return "HTTP response exceeded probe limit"
        }
    }
}

private func connectUnix(path: String, timeout: TimeInterval) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProbeError.syscall("socket", errno) }
    do {
        try setTimeouts(fd: fd, timeout: timeout)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ProbeError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ProbeError.syscall("connect", errno) }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func setTimeouts(fd: Int32, timeout: TimeInterval) throws {
    var timeval = timeval(
        tv_sec: Int(timeout),
        tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
    )
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout.size(ofValue: timeval))) == 0 else {
        throw ProbeError.syscall("setsockopt(SO_RCVTIMEO)", errno)
    }
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout.size(ofValue: timeval))) == 0 else {
        throw ProbeError.syscall("setsockopt(SO_SNDTIMEO)", errno)
    }
}

private func forwardPreamble(cid: UInt32, port: UInt32) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.append(contentsOf: UInt32(9).littleEndianBytes)
    bytes.append(1)
    bytes.append(contentsOf: cid.littleEndianBytes)
    bytes.append(contentsOf: port.littleEndianBytes)
    return bytes
}

private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written > 0 {
            offset += written
        } else if written < 0 && errno == EINTR {
            continue
        } else {
            throw ProbeError.syscall("write", errno)
        }
    }
}

private func readHTTPResponseData(from fd: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count < maxBytes {
        let got = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, raw.count)
        }
        if got > 0 {
            data.append(contentsOf: buffer.prefix(got))
            if let complete = completeHTTPResponseLength(data), data.count >= complete {
                return Data(data.prefix(complete))
            }
        } else if got == 0 {
            return data
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            if let complete = completeHTTPResponseLength(data), data.count >= complete {
                return Data(data.prefix(complete))
            }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil, completeHTTPResponseLength(data) == nil {
                return data
            }
            throw ProbeError.syscall("read", errno)
        } else {
            throw ProbeError.syscall("read", errno)
        }
    }
    throw ProbeError.tooLarge
}

private func completeHTTPResponseLength(_ data: Data) -> Int? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
        return nil
    }
    let headers = headerFields(headerText)
    if let rawLength = headers["content-length"], let length = Int(rawLength) {
        return headerEnd.upperBound + length
    }
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
        return completeChunkedResponseLength(data, bodyStart: headerEnd.upperBound)
    }
    return nil
}

private func headerFields(_ headerText: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in headerText.split(separator: "\r\n").dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
            parts[1].trimmingCharacters(in: .whitespaces)
    }
    return result
}

private func completeChunkedResponseLength(_ data: Data, bodyStart: Int) -> Int? {
    var index = bodyStart
    let crlf = Data("\r\n".utf8)
    while index < data.count {
        guard let lineEnd = data[index...].range(of: crlf),
              let line = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8),
              let sizePart = line.split(separator: ";", maxSplits: 1).first,
              let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16) else {
            return nil
        }
        let chunkStart = lineEnd.upperBound
        let chunkEnd = chunkStart + size
        guard data.count >= chunkEnd + 2 else { return nil }
        guard data[chunkEnd] == 13, data[chunkEnd + 1] == 10 else { return nil }
        if size == 0 {
            return chunkEnd + 2
        }
        index = chunkEnd + 2
    }
    return nil
}

private func decodeChunkedBody(_ body: Data) throws -> Data {
    var index = 0
    var decoded = Data()
    let crlf = Data("\r\n".utf8)
    while index < body.count {
        guard let lineEnd = body[index...].range(of: crlf),
              let line = String(data: body[index..<lineEnd.lowerBound], encoding: .utf8),
              let sizePart = line.split(separator: ";", maxSplits: 1).first,
              let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16) else {
            throw ProbeError.malformedHTTP
        }
        let chunkStart = lineEnd.upperBound
        let chunkEnd = chunkStart + size
        guard body.count >= chunkEnd + 2,
              body[chunkEnd] == 13,
              body[chunkEnd + 1] == 10 else {
            throw ProbeError.malformedHTTP
        }
        if size == 0 {
            return decoded
        }
        decoded.append(body[chunkStart..<chunkEnd])
        index = chunkEnd + 2
    }
    throw ProbeError.malformedHTTP
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}
