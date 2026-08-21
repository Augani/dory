import Darwin
import DoryCore
import Foundation

public struct VmmControlRequest: Sendable, Equatable, Codable {
    public var command: String
    public var targetMB: UInt64?
    public var statePath: String?
    public var lifecycleAction: DoryLifecycleReceiptAction?
    public var operationID: String?

    public init(
        command: String,
        targetMB: UInt64? = nil,
        statePath: String? = nil,
        lifecycleAction: DoryLifecycleReceiptAction? = nil,
        operationID: String? = nil
    ) {
        self.command = command
        self.targetMB = targetMB
        self.statePath = statePath
        self.lifecycleAction = lifecycleAction
        self.operationID = operationID
    }

    public static func setBalloonTarget(_ targetMB: UInt64) -> VmmControlRequest {
        VmmControlRequest(command: "setBalloonTarget", targetMB: targetMB)
    }

    public static func pauseMachine(operationID: UUID) -> VmmControlRequest {
        VmmControlRequest(
            command: "pauseMachine",
            lifecycleAction: .preparePause,
            operationID: DoryOperationIdentity.canonical(operationID)
        )
    }

    public static func resumeMachine(operationID: UUID) -> VmmControlRequest {
        VmmControlRequest(
            command: "resumeMachine",
            lifecycleAction: .resumed,
            operationID: DoryOperationIdentity.canonical(operationID)
        )
    }

    public static func acknowledgeLifecycle(
        _ action: DoryLifecycleReceiptAction,
        operationID: UUID
    ) -> VmmControlRequest {
        VmmControlRequest(
            command: "acknowledgeLifecycle",
            lifecycleAction: action,
            operationID: DoryOperationIdentity.canonical(operationID)
        )
    }

    public static func saveMachineState(to statePath: String) -> VmmControlRequest {
        VmmControlRequest(command: "saveMachineState", statePath: statePath)
    }
}

public struct VmmControlResponse: Sendable, Equatable, Codable {
    public var ok: Bool
    public var message: String
    public var targetMB: UInt64?
    public var lifecycleAction: DoryLifecycleReceiptAction?
    public var operationID: String?

    public init(
        ok: Bool,
        message: String = "",
        targetMB: UInt64? = nil,
        lifecycleAction: DoryLifecycleReceiptAction? = nil,
        operationID: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.targetMB = targetMB
        self.lifecycleAction = lifecycleAction
        self.operationID = operationID
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

/// Daemon-side client for lifecycle operations that must execute inside the VZ helper process.
/// Raw-HV helpers intentionally do not expose this socket and therefore cannot claim saved-state
/// support. Paths are daemon-owned private workspace paths, never client input.
public protocol MachineVZLifecycleControlling: Sendable {
    func pause(socketPath: String) throws
    func resume(socketPath: String) throws
    func pause(socketPath: String, operationID: UUID) throws
    func resume(socketPath: String, operationID: UUID) throws
    func acknowledgeLifecycle(
        socketPath: String,
        action: DoryLifecycleReceiptAction,
        operationID: UUID
    ) throws
    func saveMachineState(socketPath: String, statePath: String) throws
}

public extension MachineVZLifecycleControlling {
    func pause(socketPath: String, operationID: UUID) throws {
        _ = operationID
        try pause(socketPath: socketPath)
    }

    func resume(socketPath: String, operationID: UUID) throws {
        _ = operationID
        try resume(socketPath: socketPath)
    }

    func acknowledgeLifecycle(
        socketPath: String,
        action: DoryLifecycleReceiptAction,
        operationID: UUID
    ) throws {
        _ = socketPath
        _ = action
        _ = operationID
    }
}

public struct UnixMachineVZLifecycleController: MachineVZLifecycleControlling {
    public init() {}

    public func pause(socketPath: String) throws {
        throw VmmControlError.rejected("pause operation identity is required")
    }

    public func resume(socketPath: String) throws {
        throw VmmControlError.rejected("resume operation identity is required")
    }

    public func pause(socketPath: String, operationID: UUID) throws {
        try requireAccepted(
            .pauseMachine(operationID: operationID),
            socketPath: socketPath,
            expectedAction: .preparePause,
            expectedOperationID: operationID
        )
    }

    public func resume(socketPath: String, operationID: UUID) throws {
        try requireAccepted(
            .resumeMachine(operationID: operationID),
            socketPath: socketPath,
            expectedAction: .resumed,
            expectedOperationID: operationID
        )
    }

    public func acknowledgeLifecycle(
        socketPath: String,
        action: DoryLifecycleReceiptAction,
        operationID: UUID
    ) throws {
        try requireAccepted(
            .acknowledgeLifecycle(action, operationID: operationID),
            socketPath: socketPath,
            expectedAction: action,
            expectedOperationID: operationID
        )
    }

    public func saveMachineState(socketPath: String, statePath: String) throws {
        try requireAccepted(
            .saveMachineState(to: statePath),
            socketPath: socketPath,
            timeoutSeconds: 10 * 60
        )
    }

    private func requireAccepted(
        _ request: VmmControlRequest,
        socketPath: String,
        timeoutSeconds: TimeInterval = 5,
        expectedAction: DoryLifecycleReceiptAction? = nil,
        expectedOperationID: UUID? = nil
    ) throws {
        let response = try VmmControlClient.send(
            socketPath: socketPath,
            request: request,
            timeoutSeconds: timeoutSeconds
        )
        guard response.ok else { throw VmmControlError.rejected(response.message) }
        if let expectedAction, let expectedOperationID {
            let canonical = DoryOperationIdentity.canonical(expectedOperationID)
            guard response.lifecycleAction == expectedAction,
                  response.operationID == canonical else {
                throw VmmControlError.rejected(
                    "VMM helper returned a mismatched lifecycle operation receipt"
                )
            }
        }
    }
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
    public static func send(
        socketPath: String,
        request: VmmControlRequest,
        timeoutSeconds: TimeInterval = 5
    ) throws -> VmmControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        defer { close(fd) }

        // Bound write/read so a wedged dory-vmm can't block the reconcile thread forever.
        try setSocketTimeouts(fd: fd, seconds: timeoutSeconds)

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

private func setSocketTimeouts(fd: Int32, seconds: TimeInterval) throws {
    let whole = max(0, Int(seconds))
    var timeout = timeval(tv_sec: whole, tv_usec: 0)
    let length = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length) == 0 else {
        throw VmmControlError.syscall("setsockopt(SO_SNDTIMEO)", errno)
    }
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) == 0 else {
        throw VmmControlError.syscall("setsockopt(SO_RCVTIMEO)", errno)
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
            guard let destinationBase = destination.baseAddress,
                  let sourceBase = source.baseAddress else { return }
            destinationBase.copyMemory(from: sourceBase, byteCount: bytes.count)
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

/// Raw-HV helper-side receipt endpoint. Unlike the VZ control server it never mutates VM state;
/// it proves that the exact operation identity reached the live helper immediately around the
/// daemon-owned signal transition.
public final class VmmLifecycleReceiptServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "dev.dory.helper-lifecycle-receipt")
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false
    private var boundIdentity: (device: dev_t, inode: ino_t)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        lock.lock()
        guard listenerFD < 0 else {
            lock.unlock()
            return
        }
        lock.unlock()
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        do {
            var address = try unixAddress(path: socketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw VmmControlError.syscall("bind", errno) }
            guard chmod(socketPath, 0o600) == 0 else {
                throw VmmControlError.syscall("chmod", errno)
            }
            guard listen(fd, 16) == 0 else {
                throw VmmControlError.syscall("listen", errno)
            }
            var info = stat()
            guard lstat(socketPath, &info) == 0 else {
                throw VmmControlError.syscall("lstat", errno)
            }
            lock.lock()
            listenerFD = fd
            running = true
            boundIdentity = (info.st_dev, info.st_ino)
            lock.unlock()
            queue.async { [weak self] in self?.acceptLoop(listenerFD: fd) }
        } catch {
            close(fd)
            unlink(socketPath)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        let identity = boundIdentity
        listenerFD = -1
        running = false
        boundIdentity = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
        if let identity {
            var info = stat()
            if lstat(socketPath, &info) == 0,
               info.st_dev == identity.device,
               info.st_ino == identity.inode {
                unlink(socketPath)
            }
        }
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning(listenerFD: listenerFD) {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        let response: VmmControlResponse
        do {
            try setSocketTimeouts(fd: clientFD, seconds: 5)
            let data = try readAll(from: clientFD)
            let request = try JSONDecoder().decode(VmmControlRequest.self, from: data)
            guard request.command == "acknowledgeLifecycle",
                  let action = request.lifecycleAction,
                  let operationID = request.operationID,
                  DoryOperationIdentity.parseCanonical(operationID) != nil,
                  operationID != "00000000-0000-0000-0000-000000000000" else {
                throw VmmControlError.rejected("invalid helper lifecycle receipt request")
            }
            response = VmmControlResponse(
                ok: true,
                lifecycleAction: action,
                operationID: operationID
            )
        } catch {
            response = VmmControlResponse(ok: false, message: "\(error)")
        }
        if let encoded = try? JSONEncoder().encode(response) {
            try? writeAll(encoded, to: clientFD)
        }
    }

    private func isRunning(listenerFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.listenerFD == listenerFD
    }

    deinit { stop() }
}
