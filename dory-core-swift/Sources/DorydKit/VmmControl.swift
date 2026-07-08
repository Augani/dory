import Darwin
import Foundation

public struct VmmControlRequest: Sendable, Equatable, Codable {
    public var command: String
    public var targetMB: UInt64?

    public init(command: String, targetMB: UInt64? = nil) {
        self.command = command
        self.targetMB = targetMB
    }

    public static func setBalloonTarget(_ targetMB: UInt64) -> VmmControlRequest {
        VmmControlRequest(command: "setBalloonTarget", targetMB: targetMB)
    }
}

public struct VmmControlResponse: Sendable, Equatable, Codable {
    public var ok: Bool
    public var message: String
    public var targetMB: UInt64?

    public init(ok: Bool, message: String = "", targetMB: UInt64? = nil) {
        self.ok = ok
        self.message = message
        self.targetMB = targetMB
    }
}

public enum VmmControlError: Error, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)
    case emptyResponse
    case invalidJSON(String)
    case rejected(String)

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            return "VMM control socket path is too long: \(path)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        case .emptyResponse:
            return "empty VMM control response"
        case let .invalidJSON(message):
            return "invalid VMM control JSON: \(message)"
        case let .rejected(message):
            return message.isEmpty ? "VMM control request rejected" : message
        }
    }
}

public protocol MachineBalloonControlling: Sendable {
    func setBalloonTarget(socketPath: String, targetMB: UInt64) throws
}

public struct UnixMachineBalloonController: MachineBalloonControlling {
    public init() {}

    public func setBalloonTarget(socketPath: String, targetMB: UInt64) throws {
        let response = try VmmControlClient.send(
            socketPath: socketPath,
            request: .setBalloonTarget(targetMB)
        )
        guard response.ok else {
            throw VmmControlError.rejected(response.message)
        }
    }
}

public enum VmmControlClient {
    public static func send(socketPath: String, request: VmmControlRequest) throws -> VmmControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        defer { close(fd) }

        var address = try unixAddress(path: socketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VmmControlError.syscall("connect", errno)
        }

        let payload = try JSONEncoder().encode(request)
        try writeAll(payload, to: fd)
        shutdown(fd, SHUT_WR)

        let responseData = try readAll(from: fd)
        guard !responseData.isEmpty else {
            throw VmmControlError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(VmmControlResponse.self, from: responseData)
        } catch {
            throw VmmControlError.invalidJSON("\(error)")
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw VmmControlError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = write(fd, base.advanced(by: offset), data.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw VmmControlError.syscall("write", errno)
            }
            offset += written
        }
    }
}

private func readAll(from fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if count == 0 {
            return data
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw VmmControlError.syscall("read", errno)
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > 1024 * 1024 {
            throw VmmControlError.invalidJSON("response exceeded 1 MiB")
        }
    }
}
