import Darwin
import DoryVMContracts
import Foundation

public typealias DoryMachineUSBOpenMode = DoryUSBControlV1.OpenMode

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
    case timedOut(String)
    case malformedResponse
    /// The complete request frame reached the socket, but no trustworthy terminal response did.
    /// The helper may therefore have changed host or guest USB state.
    case outcomeUnknown(operation: String, detail: String)
    case rejected(String)

    public var description: String {
        switch self {
        case .invalidBusID:
            return "USB bus identifier is invalid"
        case .invalidSocketPath:
            return "USB control socket path is invalid"
        case .untrustedSocket:
            return "USB control socket identity is not trusted"
        case let .syscall(name, code):
            return "USB control \(name) failed: \(String(cString: strerror(code)))"
        case let .timedOut(operation):
            return "USB control \(operation) timed out"
        case .malformedResponse:
            return "USB control returned a malformed response"
        case let .outcomeUnknown(operation, detail):
            return "USB control \(operation) outcome is unknown: \(detail)"
        case let .rejected(message):
            return "USB control rejected the request: \(message)"
        }
    }

    var mayHaveChangedDeviceState: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }
}

/// The exact daemon-side view of the engine's private newline-delimited USB control contract.
/// Keeping framing, path, and bus-ID validation here prevents discovery and mutation callers from
/// quietly accepting different identifiers.
enum DoryMachineUSBWireContract {
    static let maximumFrameBytes = DoryUSBControlV1.maximumFrameBytes
    static let usbipVsockPort = DoryUSBControlV1.usbipVsockPort

    static var maximumSocketPathBytes: Int {
        let address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path) - 1
    }

    static func validatedBusID(_ value: String) throws -> DoryUSBControlV1.BusID {
        guard let busID = try? DoryUSBControlV1.BusID(value) else {
            throw DoryMachineUSBControlError.invalidBusID
        }
        return busID
    }

    static func isValidBusID(_ value: String) -> Bool {
        (try? validatedBusID(value)) != nil
    }

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let standardized = NSString(string: path).standardizingPath
        guard path.hasPrefix("/"),
              path == standardized,
              !bytes.isEmpty,
              !bytes.contains(0),
              bytes.count <= maximumSocketPathBytes else {
            throw DoryMachineUSBControlError.invalidSocketPath
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        return address
    }
}

private struct DoryMachineUSBFilesystemIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
    var generation: UInt32
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var owner: uid_t
    var permissions: mode_t
}

enum DoryMachineUSBClientSocketIO {
    typealias ReadOperation = (Int32, UnsafeMutableRawPointer?, Int) -> Int
    typealias WriteOperation = (Int32, UnsafeRawPointer?, Int) -> Int

    static func configureOwnedSocket(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw DoryMachineUSBControlError.syscall("configure close-on-exec", errno)
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw DoryMachineUSBControlError.syscall("configure no-SIGPIPE", errno)
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw DoryMachineUSBControlError.syscall("configure nonblocking I/O", errno)
        }
    }

    static func connect(
        descriptor: Int32,
        address: inout sockaddr_un,
        deadline: TimeInterval
    ) throws {
        while true {
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if result == 0 { return }
            let code = errno
            if code == EISCONN { return }
            if code == EINTR {
                try requireTime(until: deadline, operation: "connect")
                continue
            }
            guard code == EINPROGRESS || code == EALREADY || code == EAGAIN else {
                throw DoryMachineUSBControlError.syscall("connect", code)
            }
            try wait(
                descriptor: descriptor,
                events: Int16(POLLOUT),
                deadline: deadline,
                operation: "connect"
            )
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &length
            ) == 0 else {
                throw DoryMachineUSBControlError.syscall("inspect connect", errno)
            }
            guard socketError == 0 else {
                throw DoryMachineUSBControlError.syscall("connect", socketError)
            }
            return
        }
    }

    static func writeAll(
        descriptor: Int32,
        bytes: Data,
        deadline: TimeInterval,
        writeOperation: WriteOperation = { Darwin.write($0, $1, $2) }
    ) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try requireTime(until: deadline, operation: "request write")
                let count = writeOperation(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    guard count <= buffer.count - offset else {
                        throw DoryMachineUSBControlError.syscall("write", EIO)
                    }
                    offset += count
                    continue
                }
                if count == 0 {
                    throw DoryMachineUSBControlError.syscall("write", EPIPE)
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try wait(
                        descriptor: descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        operation: "request write"
                    )
                    continue
                }
                throw DoryMachineUSBControlError.syscall("write", code)
            }
        }
    }

    static func readFrame(
        descriptor: Int32,
        deadline: TimeInterval,
        readOperation: ReadOperation = { Darwin.read($0, $1, $2) }
    ) throws -> Data {
        var frame = Data()
        var completedFrame: Data?
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            try requireTime(until: deadline, operation: "response read")
            let remainingCapacity = completedFrame == nil
                ? DoryMachineUSBWireContract.maximumFrameBytes - frame.count + 1
                : 1
            guard remainingCapacity > 0 else {
                throw DoryMachineUSBControlError.malformedResponse
            }
            let requested = min(buffer.count, remainingCapacity)
            let count = buffer.withUnsafeMutableBytes {
                readOperation(descriptor, $0.baseAddress, requested)
            }
            if count > 0 {
                guard count <= requested else {
                    throw DoryMachineUSBControlError.syscall("read", EIO)
                }
                guard completedFrame == nil else {
                    throw DoryMachineUSBControlError.malformedResponse
                }
                let bytes = buffer[0..<count]
                if let newline = bytes.firstIndex(of: 0x0a) {
                    guard newline == bytes.index(before: bytes.endIndex) else {
                        throw DoryMachineUSBControlError.malformedResponse
                    }
                    frame.append(contentsOf: bytes[..<newline])
                    guard frame.count <= DoryMachineUSBWireContract.maximumFrameBytes else {
                        throw DoryMachineUSBControlError.malformedResponse
                    }
                    completedFrame = frame
                    // The engine serves one request per connection and closes after its response.
                    // Requiring EOF makes bytes delivered after the newline unambiguously invalid,
                    // even when the stream splits them across separate reads.
                    continue
                }
                frame.append(contentsOf: bytes)
                guard frame.count <= DoryMachineUSBWireContract.maximumFrameBytes else {
                    throw DoryMachineUSBControlError.malformedResponse
                }
                continue
            }
            if count == 0 {
                if let completedFrame { return completedFrame }
                throw DoryMachineUSBControlError.syscall("read", ECONNRESET)
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    operation: "response read"
                )
                continue
            }
            throw DoryMachineUSBControlError.syscall("read", code)
        }
    }

    private static func requireTime(
        until deadline: TimeInterval,
        operation: String
    ) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw DoryMachineUSBControlError.timedOut(operation)
        }
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        deadline: TimeInterval,
        operation: String
    ) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw DoryMachineUSBControlError.timedOut(operation)
            }
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = max(1, min(50, Int32(ceil(remaining * 1_000))))
            let result = poll(&readiness, 1, milliseconds)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw DoryMachineUSBControlError.syscall("poll", errno)
            }
            if readiness.revents & Int16(POLLNVAL) != 0 {
                throw DoryMachineUSBControlError.syscall("poll", EBADF)
            }
            return
        }
    }
}

/// Daemon-side client for the private per-machine raw-HV USB socket. The helper owns host-device
/// claims; doryd selects an authorized live machine and forwards one bounded request.
public struct UnixDoryMachineUSBController: DoryMachineUSBControlling, Sendable {
    private static let defaultOperationTimeout: TimeInterval = 15

    private let operationTimeout: TimeInterval
    private let beforeEndpointRevalidation: @Sendable () -> Void

    public init() {
        operationTimeout = Self.defaultOperationTimeout
        beforeEndpointRevalidation = {}
    }

    init(
        operationTimeout: TimeInterval,
        beforeEndpointRevalidation: @escaping @Sendable () -> Void = {}
    ) {
        precondition(operationTimeout.isFinite && operationTimeout > 0)
        self.operationTimeout = operationTimeout
        self.beforeEndpointRevalidation = beforeEndpointRevalidation
    }

    public func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment {
        let busID = try DoryMachineUSBWireContract.validatedBusID(busID)
        let response = try send(
            .attach(busID: busID, mode: mode),
            socketPath: socketPath
        )
        guard case .attachSuccess(let attachment) = response else {
            try Self.throwFailureIfPresent(response, operation: .attach)
            throw Self.uncertain(.attach, underlying: .malformedResponse)
        }
        return DoryMachineUSBAttachment(
            machineID: machineID,
            busID: busID.rawValue,
            port: attachment.port,
            vsockPort: attachment.vsockPort,
            deviceID: attachment.deviceID,
            speed: attachment.speed
        )
    }

    public func detach(socketPath: String, busID: String) throws {
        let busID = try DoryMachineUSBWireContract.validatedBusID(busID)
        let response = try send(
            .detach(busID: busID),
            socketPath: socketPath
        )
        guard case .detachSuccess = response else {
            try Self.throwFailureIfPresent(response, operation: .detach)
            throw Self.uncertain(.detach, underlying: .malformedResponse)
        }
    }

    private func send(
        _ request: DoryUSBControlV1.Request,
        socketPath: String
    ) throws -> DoryUSBControlV1.Response {
        var address = try DoryMachineUSBWireContract.address(for: socketPath)
        let parentPath = NSString(string: socketPath).deletingLastPathComponent
        let parentBefore = try Self.trustedParentIdentity(at: parentPath)
        let before = try Self.trustedEndpointIdentity(at: socketPath)
        let deadline = ProcessInfo.processInfo.systemUptime + operationTimeout

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DoryMachineUSBControlError.syscall("socket", errno)
        }
        defer { close(descriptor) }
        try DoryMachineUSBClientSocketIO.configureOwnedSocket(descriptor)
        try DoryMachineUSBClientSocketIO.connect(
            descriptor: descriptor,
            address: &address,
            deadline: deadline
        )

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            throw DoryMachineUSBControlError.untrustedSocket
        }
        beforeEndpointRevalidation()
        guard try Self.trustedParentIdentityIfPresent(at: parentPath) == parentBefore,
              try Self.trustedEndpointIdentityIfPresent(at: socketPath) == before else {
            throw DoryMachineUSBControlError.untrustedSocket
        }

        var payload: Data
        do {
            payload = try DoryUSBControlV1.encodeRequest(request)
        } catch {
            throw DoryMachineUSBControlError.syscall("encode request", EINVAL)
        }
        payload.append(0x0a)

        try DoryMachineUSBClientSocketIO.writeAll(
            descriptor: descriptor,
            bytes: payload,
            deadline: deadline
        )
        // From this point the engine may have decoded and committed the operation. Any transport
        // or protocol failure must retain that uncertainty instead of looking like a safe retry.
        do {
            let frame = try DoryMachineUSBClientSocketIO.readFrame(
                descriptor: descriptor,
                deadline: deadline
            )
            return try DoryUSBControlV1.decodeResponse(frame)
        } catch let error as DoryMachineUSBControlError {
            throw Self.uncertain(request.operation, underlying: error)
        } catch {
            throw Self.uncertain(request.operation, underlying: .malformedResponse)
        }
    }

    private static func trustedEndpointIdentity(
        at path: String
    ) throws -> DoryMachineUSBFilesystemIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw DoryMachineUSBControlError.syscall("lstat", errno)
        }
        guard let identity = trustedEndpointIdentity(info) else {
            throw DoryMachineUSBControlError.untrustedSocket
        }
        return identity
    }

    private static func trustedEndpointIdentityIfPresent(
        at path: String
    ) throws -> DoryMachineUSBFilesystemIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw DoryMachineUSBControlError.untrustedSocket
        }
        return trustedEndpointIdentity(info)
    }

    private static func trustedEndpointIdentity(
        _ info: stat
    ) -> DoryMachineUSBFilesystemIdentity? {
        let permissions = info.st_mode & mode_t(0o777)
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              info.st_uid == geteuid(),
              permissions == mode_t(0o600) else {
            return nil
        }
        return filesystemIdentity(info, permissions: permissions)
    }

    private static func trustedParentIdentity(
        at path: String
    ) throws -> DoryMachineUSBFilesystemIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw DoryMachineUSBControlError.syscall("lstat parent directory", errno)
        }
        guard let identity = trustedParentIdentity(info) else {
            throw DoryMachineUSBControlError.untrustedSocket
        }
        return identity
    }

    private static func trustedParentIdentityIfPresent(
        at path: String
    ) throws -> DoryMachineUSBFilesystemIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw DoryMachineUSBControlError.untrustedSocket
        }
        return trustedParentIdentity(info)
    }

    private static func trustedParentIdentity(
        _ info: stat
    ) -> DoryMachineUSBFilesystemIdentity? {
        let permissions = info.st_mode & mode_t(0o777)
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              permissions == mode_t(0o700) else {
            return nil
        }
        return filesystemIdentity(info, permissions: permissions)
    }

    private static func filesystemIdentity(
        _ info: stat,
        permissions: mode_t
    ) -> DoryMachineUSBFilesystemIdentity {
        DoryMachineUSBFilesystemIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            owner: info.st_uid,
            permissions: permissions
        )
    }

    private static func throwFailureIfPresent(
        _ response: DoryUSBControlV1.Response,
        operation: DoryUSBControlV1.Operation
    ) throws {
        guard case let .failure(disposition, message) = response else { return }
        switch disposition {
        case .rejected:
            throw DoryMachineUSBControlError.rejected(message)
        case .outcomeUnknown:
            throw DoryMachineUSBControlError.outcomeUnknown(
                operation: operation.rawValue,
                detail: message
            )
        }
    }

    private static func uncertain(
        _ operation: DoryUSBControlV1.Operation,
        underlying: DoryMachineUSBControlError
    ) -> DoryMachineUSBControlError {
        .outcomeUnknown(operation: operation.rawValue, detail: underlying.description)
    }
}
