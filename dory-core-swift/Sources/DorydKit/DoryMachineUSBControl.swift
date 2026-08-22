import Darwin
import Foundation

public enum DoryMachineUSBOpenMode: String, Codable, CaseIterable, Sendable {
    case userAuthorized
    case seize
    case capture
}

public struct DoryMachineUSBAttachment: Equatable, Sendable {
    public var machineID: String
    public var busID: String
    public var port: Int
    public var vsockPort: UInt32
    public var deviceID: UInt32
    public var speed: UInt32

    public init(
        machineID: String,
        busID: String,
        port: Int,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) {
        self.machineID = machineID
        self.busID = busID
        self.port = port
        self.vsockPort = vsockPort
        self.deviceID = deviceID
        self.speed = speed
    }

    var xpcDictionary: NSDictionary {
        [
            "machineID": machineID,
            "busID": busID,
            "port": port,
            "vsockPort": vsockPort,
            "deviceID": deviceID,
            "speed": speed,
        ]
    }
}

public protocol DoryMachineUSBControlling: Sendable {
    func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment
    func detach(socketPath: String, busID: String) throws
}

public enum DoryMachineUSBControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidBusID
    case invalidSocketPath
    case untrustedSocket
    case syscall(String, Int32)
    case malformedResponse
    case rejected(String)

    public var description: String {
        switch self {
        case .invalidBusID:
            return "USB bus identifier is invalid"
        case .invalidSocketPath:
            return "USB control socket path is invalid"
        case .untrustedSocket:
            return "USB control socket is not owned by the current user"
        case let .syscall(name, code):
            return "USB control \(name) failed: \(String(cString: strerror(code)))"
        case .malformedResponse:
            return "USB control returned a malformed response"
        case let .rejected(message):
            return "USB control rejected the request: \(message)"
        }
    }
}

/// Daemon-side client for the private per-machine raw-HV USB socket. The helper owns host-device
/// claims; doryd only selects the already-authorized live machine and forwards one bounded request.
public struct UnixDoryMachineUSBController: DoryMachineUSBControlling, Sendable {
    private static let usbipVsockPort: UInt32 = 1025
    private static let maximumMessageBytes = 8 * 1024
    private static let operationTimeoutSeconds = 15

    public init() {}

    public func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment {
        let busID = try Self.validatedBusID(busID)
        let response = try send(
            Request(command: "attach", busID: busID, mode: mode.rawValue),
            socketPath: socketPath
        )
        guard response.ok,
              response.error == nil,
              let port = response.port,
              (0...65_535).contains(port),
              response.vsockPort == Self.usbipVsockPort,
              let deviceID = response.deviceID,
              deviceID != 0,
              let speed = response.speed,
              speed > 0 else {
            if !response.ok, let error = response.error, !error.isEmpty {
                throw DoryMachineUSBControlError.rejected(error)
            }
            throw DoryMachineUSBControlError.malformedResponse
        }
        return DoryMachineUSBAttachment(
            machineID: machineID,
            busID: busID,
            port: port,
            vsockPort: Self.usbipVsockPort,
            deviceID: deviceID,
            speed: speed
        )
    }

    public func detach(socketPath: String, busID: String) throws {
        let busID = try Self.validatedBusID(busID)
        let response = try send(
            Request(command: "detach", busID: busID, mode: nil),
            socketPath: socketPath
        )
        guard response.ok,
              response.error == nil,
              response.port == nil,
              response.vsockPort == nil,
              response.deviceID == nil,
              response.speed == nil else {
            if !response.ok, let error = response.error, !error.isEmpty {
                throw DoryMachineUSBControlError.rejected(error)
            }
            throw DoryMachineUSBControlError.malformedResponse
        }
    }

    private func send(_ request: Request, socketPath: String) throws -> Response {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = withUnsafeBytes(of: &address.sun_path) { $0.count }
        guard socketPath.first == "/",
              !socketPath.contains("\0"),
              socketPath.utf8.count < capacity else {
            throw DoryMachineUSBControlError.invalidSocketPath
        }

        var before = stat()
        guard lstat(socketPath, &before) == 0 else {
            throw DoryMachineUSBControlError.syscall("lstat", errno)
        }
        guard before.st_mode & S_IFMT == S_IFSOCK,
              before.st_uid == geteuid() else {
            throw DoryMachineUSBControlError.untrustedSocket
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DoryMachineUSBControlError.syscall("socket", errno)
        }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: Self.operationTimeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw DoryMachineUSBControlError.syscall("setsockopt", errno)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: socketPath.utf8)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            throw DoryMachineUSBControlError.syscall("connect", errno)
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            throw DoryMachineUSBControlError.untrustedSocket
        }
        var after = stat()
        guard lstat(socketPath, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              after.st_uid == geteuid(),
              after.st_mode & S_IFMT == S_IFSOCK else {
            throw DoryMachineUSBControlError.untrustedSocket
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        try Self.writeAll(payload, descriptor: descriptor)
        var response = Data()
        var byte: UInt8 = 0
        while response.count < Self.maximumMessageBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else {
                throw DoryMachineUSBControlError.syscall("read", count < 0 ? errno : ECONNRESET)
            }
            if byte == 0x0a {
                return try JSONDecoder().decode(Response.self, from: response)
            }
            response.append(byte)
        }
        throw DoryMachineUSBControlError.malformedResponse
    }

    private static func validatedBusID(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || "_.-:/".unicodeScalars.contains(scalar)
                  )
              }) else {
            throw DoryMachineUSBControlError.invalidBusID
        }
        return value
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw DoryMachineUSBControlError.syscall(
                        "write",
                        count < 0 ? errno : EPIPE
                    )
                }
                offset += count
            }
        }
    }

    private struct Request: Encodable {
        var command: String
        var busID: String
        var mode: String?

        enum CodingKeys: String, CodingKey {
            case command = "cmd"
            case busID = "busid"
            case mode
        }
    }

    private struct Response: Decodable {
        var ok: Bool
        var port: Int?
        var vsockPort: UInt32?
        var deviceID: UInt32?
        var speed: UInt32?
        var error: String?
    }
}
