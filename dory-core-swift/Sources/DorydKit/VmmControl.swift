import Darwin
import DoryCore
import DoryOperations
import Foundation

/// The minimal daemon-to-helper authority needed to replace the backing directory of an
/// existing VirtioFS device. Persistent bookmarks and guest paths never cross this runtime
/// control boundary: the device tag is already the guest-visible mount identity.
public struct VmmDirectoryShareReplacement: Sendable, Equatable, Codable {
    public static let maximumCount = 64

    public var tag: String
    public var hostPath: String
    public var readOnly: Bool

    public init(tag: String, hostPath: String, readOnly: Bool) {
        self.tag = tag
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    public var isValid: Bool {
        !tag.isEmpty
            && tag.utf8.count < 36
            && tag.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            }
            && hostPath.hasPrefix("/")
            && !hostPath.contains("\0")
            && hostPath.utf8.count < Int(PATH_MAX)
    }
}

public struct VmmControlRequest: Sendable, Equatable, Codable {
    public var command: String
    public var targetMB: UInt64?
    public var statePath: String?
    public var lifecycleAction: DoryLifecycleReceiptAction?
    public var operationID: String?
    public var directoryShares: [VmmDirectoryShareReplacement]?
    public var reconnectChallenge: String?

    public init(
        command: String,
        targetMB: UInt64? = nil,
        statePath: String? = nil,
        lifecycleAction: DoryLifecycleReceiptAction? = nil,
        operationID: String? = nil,
        directoryShares: [VmmDirectoryShareReplacement]? = nil,
        reconnectChallenge: String? = nil
    ) {
        self.command = command
        self.targetMB = targetMB
        self.statePath = statePath
        self.lifecycleAction = lifecycleAction
        self.operationID = operationID
        self.directoryShares = directoryShares
        self.reconnectChallenge = reconnectChallenge
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

    public static func replaceDirectoryShares(
        _ shares: [VmmDirectoryShareReplacement]
    ) -> VmmControlRequest {
        VmmControlRequest(command: "replaceDirectoryShares", directoryShares: shares)
    }

    public static func authenticateRuntime(challenge: String) -> VmmControlRequest {
        VmmControlRequest(command: "authenticateRuntime", reconnectChallenge: challenge)
    }
}

public struct VmmControlResponse: Sendable, Equatable, Codable {
    public var ok: Bool
    public var message: String
    public var targetMB: UInt64?
    public var lifecycleAction: DoryLifecycleReceiptAction?
    public var operationID: String?
    public var deviceTelemetry: DoryDeviceTelemetrySnapshot?
    public var reconnect: DoryRuntimeReconnectResponse?

    public init(
        ok: Bool,
        message: String = "",
        targetMB: UInt64? = nil,
        lifecycleAction: DoryLifecycleReceiptAction? = nil,
        operationID: String? = nil,
        deviceTelemetry: DoryDeviceTelemetrySnapshot? = nil,
        reconnect: DoryRuntimeReconnectResponse? = nil
    ) {
        self.ok = ok
        self.message = message
        self.targetMB = targetMB
        self.lifecycleAction = lifecycleAction
        self.operationID = operationID
        self.deviceTelemetry = deviceTelemetry
        self.reconnect = reconnect
    }
}

public protocol MachineDeviceTelemetryControlling: Sendable {
    func snapshot(socketPath: String) throws -> DoryDeviceTelemetrySnapshot
}

public struct UnixMachineDeviceTelemetryController: MachineDeviceTelemetryControlling {
    public init() {}

    public func snapshot(socketPath: String) throws -> DoryDeviceTelemetrySnapshot {
        let response = try VmmControlClient.send(
            socketPath: socketPath,
            request: VmmControlRequest(command: "deviceTelemetry")
        )
        guard response.ok,
              let snapshot = response.deviceTelemetry,
              snapshot.isValid else {
            throw VmmControlError.rejected(
                response.message.isEmpty
                    ? "VMM helper returned invalid device telemetry"
                    : response.message
            )
        }
        return snapshot
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

public protocol MachineDirectoryShareControlling: Sendable {
    func replaceDirectoryShares(
        socketPath: String,
        shares: [VmmDirectoryShareReplacement]
    ) throws
}

public struct UnixMachineDirectoryShareController: MachineDirectoryShareControlling {
    public init() {}

    public func replaceDirectoryShares(
        socketPath: String,
        shares: [VmmDirectoryShareReplacement]
    ) throws {
        guard shares.count <= VmmDirectoryShareReplacement.maximumCount,
              shares.allSatisfy(\.isValid),
              Set(shares.map(\.tag)).count == shares.count else {
            throw VmmControlError.rejected("invalid runtime directory-share replacement")
        }
        let response = try VmmControlClient.send(
            socketPath: socketPath,
            request: .replaceDirectoryShares(shares)
        )
        guard response.ok else {
            throw VmmControlError.rejected(response.message)
        }
    }
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
    public static func authenticateRuntime(
        socketPath: String,
        launchIdentity: DoryRuntimeReconnectLaunchIdentity,
        timeoutSeconds: TimeInterval = 5
    ) throws -> DoryRuntimeReconnectResponse {
        var challengeBytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in challengeBytes.indices {
            challengeBytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        let challenge = challengeBytes.map { String(format: "%02x", $0) }.joined()
        let response = try send(
            socketPath: socketPath,
            request: .authenticateRuntime(challenge: challenge),
            timeoutSeconds: timeoutSeconds
        )
        guard response.ok,
              let reconnect = response.reconnect,
              reconnect.matches(launchIdentity, challenge: challenge) else {
            throw VmmControlError.rejected("VMM runtime reconnect authentication failed")
        }
        return reconnect
    }

    public static func send(
        socketPath: String,
        request: VmmControlRequest,
        timeoutSeconds: TimeInterval = 5
    ) throws -> VmmControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        defer { close(fd) }

        // One monotonic budget covers connect, request publication and the complete response.
        let deadline = try VmmControlSocketIO.deadline(after: timeoutSeconds)
        var address = try unixAddress(path: socketPath)
        try VmmControlSocketIO.connect(fd, address: &address, deadline: deadline)
        let payload = try JSONEncoder().encode(request)
        try VmmControlSocketIO.writeData(payload, to: fd, deadline: deadline)
        guard shutdown(fd, SHUT_WR) == 0 else {
            throw VmmControlError.syscall("shutdown", errno)
        }
        let responseData = try VmmControlSocketIO.readData(from: fd, deadline: deadline)
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
            guard let destinationBase = destination.baseAddress,
                  let sourceBase = source.baseAddress else { return }
            destinationBase.copyMemory(from: sourceBase, byteCount: bytes.count)
        }
    }
    return address
}

/// Raw-HV helper-side control endpoint. Lifecycle requests prove that the exact operation identity
/// reached the live helper around the daemon-owned signal transition. A helper may also retire
/// runner-owned host resources before acknowledging a stop; guest state remains daemon-owned.
public final class VmmLifecycleReceiptServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "dev.dory.helper-lifecycle-receipt")
    private let lock = NSLock()
    private var socketOwner: VmmControlSocketListener?
    private let clientSlots = DispatchSemaphore(value: 8)
    private let deviceTelemetryProvider: (@Sendable () throws -> DoryDeviceTelemetrySnapshot)?
    private let lifecycleHandler: (@Sendable (DoryLifecycleReceiptAction) throws -> Void)?
    private let reconnectIdentity: DoryRuntimeReconnectLaunchIdentity?
    private let executionStateProvider: @Sendable () -> DoryVirtualMachineState
    private let executionLifecycleHandler: (@Sendable (DoryLifecycleReceiptAction) throws -> Void)?

    public init(
        socketPath: String,
        deviceTelemetryProvider: (@Sendable () throws -> DoryDeviceTelemetrySnapshot)? = nil,
        lifecycleHandler: (@Sendable (DoryLifecycleReceiptAction) throws -> Void)? = nil,
        reconnectIdentity: DoryRuntimeReconnectLaunchIdentity? = nil,
        executionStateProvider: @escaping @Sendable () -> DoryVirtualMachineState = { .running },
        executionLifecycleHandler: (@Sendable (DoryLifecycleReceiptAction) throws -> Void)? = nil
    ) {
        self.socketPath = socketPath
        self.deviceTelemetryProvider = deviceTelemetryProvider
        self.lifecycleHandler = lifecycleHandler
        self.reconnectIdentity = reconnectIdentity
        self.executionStateProvider = executionStateProvider
        self.executionLifecycleHandler = executionLifecycleHandler
    }

    public func start() throws {
        let listener = try lock.withLock { () throws -> VmmControlSocketListener? in
            guard socketOwner == nil else { return nil }
            let owner = try VmmControlSocketListener(path: socketPath)
            socketOwner = owner
            return owner
        }
        guard let listener else { return }
        queue.async { [weak self] in self?.acceptLoop(listener: listener) }
    }

    public func stop() {
        let owner = lock.withLock { () -> VmmControlSocketListener? in
            let owner = socketOwner
            socketOwner = nil
            return owner
        }
        owner?.stop()
    }

    private func acceptLoop(listener: VmmControlSocketListener) {
        while true {
            let client: Int32
            do {
                switch try listener.acceptClient() {
                case .client(let descriptor): client = descriptor
                case .retry: continue
                case .stopped: return
                }
            } catch { return }
            guard lock.withLock({ socketOwner === listener }) else {
                close(client)
                return
            }
            let slots = clientSlots
            guard slots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { slots.signal() }
                guard let self else { close(client); return }
                self.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        let response: VmmControlResponse
        do {
            let data = try VmmControlSocketIO.readRequestData(from: clientFD)
            let request = try JSONDecoder().decode(VmmControlRequest.self, from: data)
            if request.command == "authenticateRuntime" {
                guard request.targetMB == nil,
                      request.statePath == nil,
                      request.lifecycleAction == nil,
                      request.operationID == nil,
                      request.directoryShares == nil,
                      let challenge = request.reconnectChallenge,
                      let reconnectIdentity,
                      reconnectIdentity.isValid else {
                    throw VmmControlError.rejected("invalid helper runtime authentication request")
                }
                let processIdentity = try DoryHostProcessIdentity.capture()
                response = VmmControlResponse(
                    ok: true,
                    reconnect: try DoryRuntimeReconnectResponse(
                        launchIdentity: reconnectIdentity,
                        challenge: challenge,
                        processIdentity: processIdentity,
                        runtimeState: executionStateProvider()
                    )
                )
                if let encoded = try? JSONEncoder().encode(response) {
                    try? VmmControlSocketIO.writeResponseData(encoded, to: clientFD)
                }
                return
            }
            if request.command == "deviceTelemetry" {
                guard request.targetMB == nil,
                      request.statePath == nil,
                      request.lifecycleAction == nil,
                      request.operationID == nil,
                      request.directoryShares == nil,
                      request.reconnectChallenge == nil else {
                    throw VmmControlError.rejected("invalid helper device telemetry request")
                }
                guard let deviceTelemetryProvider else {
                    throw VmmControlError.rejected("helper device telemetry is unavailable")
                }
                let snapshot = try deviceTelemetryProvider()
                guard snapshot.isValid else {
                    throw VmmControlError.rejected("helper produced invalid device telemetry")
                }
                response = VmmControlResponse(ok: true, deviceTelemetry: snapshot)
                if let encoded = try? JSONEncoder().encode(response) {
                    try? VmmControlSocketIO.writeResponseData(encoded, to: clientFD)
                }
                return
            }
            guard ["acknowledgeLifecycle", "pauseMachine", "resumeMachine"].contains(request.command),
                  let action = request.lifecycleAction,
                  let operationID = request.operationID,
                  request.targetMB == nil,
                  request.statePath == nil,
                  request.directoryShares == nil,
                  request.reconnectChallenge == nil,
                  DoryOperationIdentity.parseCanonical(operationID) != nil,
                  operationID != "00000000-0000-0000-0000-000000000000" else {
                throw VmmControlError.rejected("invalid helper lifecycle receipt request")
            }
            if request.command == "acknowledgeLifecycle" {
                try lifecycleHandler?(action)
            } else {
                guard let executionLifecycleHandler,
                      (request.command == "pauseMachine" && action == .preparePause)
                        || (request.command == "resumeMachine" && action == .resumed) else {
                    throw VmmControlError.rejected("unsupported helper execution lifecycle request")
                }
                try executionLifecycleHandler(action)
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
            try? VmmControlSocketIO.writeResponseData(encoded, to: clientFD)
        }
    }

    deinit { stop() }
}
