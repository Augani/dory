import Darwin
import Foundation
import Security
import DoryRendererWorkerWireContracts

/// LaunchServices deliberately does not inherit daemon-owned file descriptors. This one-shot,
/// peer-bound channel transfers those already-admitted objects only after doryd has authenticated
/// the live DoryHVRunner process. The runner blocks here before parsing a runtime envelope, so it
/// cannot consume disk, kernel, or renderer authority before that validation succeeds.
public enum DoryApplicationLaunchHandoffClient {
    public static let socketArgument = "--doryd-application-launch-handoff"
    public static let tokenArgument = "--doryd-application-launch-token"

    /// Consumes a daemon-appended launch suffix, installs the received descriptors at their
    /// envelope-defined slots, acknowledges completion, and returns only the runtime arguments.
    /// Ordinary direct invocations contain neither marker and remain byte-for-byte unchanged.
    public static func receiveIfRequested(arguments: [String]) throws -> [String] {
        try receiveIfRequested(arguments: arguments) { daemonPID in
            try DorySecurityDynamicCodeValidator.validate(
                pid: daemonPID,
                requirementText: DorydXPCSecurity.productionDaemonRequirement
            )
        }
    }

    /// Internal authentication seam for transport tests. Production always uses the complete
    /// Developer-ID team plus `doryd` signing requirement above.
    static func receiveIfRequested(
        arguments: [String],
        authenticateDaemon: (pid_t) throws -> Void
    ) throws -> [String] {
        let hasSocketMarker = arguments.contains(socketArgument)
        let hasTokenMarker = arguments.contains(tokenArgument)
        guard hasSocketMarker || hasTokenMarker else { return arguments }
        guard arguments.count >= 4,
              arguments[arguments.count - 4] == socketArgument,
              arguments[arguments.count - 2] == tokenArgument else {
            throw DoryApplicationLaunchHandoffError.invalidInvocation
        }
        let path = arguments[arguments.count - 3]
        let token = arguments[arguments.count - 1]
        guard path.hasPrefix("/"),
              !path.utf8.contains(0),
              token.utf8.count == DoryApplicationLaunchHandoffProtocol.tokenByteCount * 2,
              token.utf8.allSatisfy(DoryApplicationLaunchHandoffProtocol.isLowercaseHex) else {
            throw DoryApplicationLaunchHandoffError.invalidInvocation
        }

        let deadline = DoryApplicationLaunchHandoffProtocol.TransportDeadline(
            timeout: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        let connection = try DoryApplicationLaunchHandoffProtocol.connect(
            path: path,
            deadline: deadline
        )
        var connectionOpen = true
        defer {
            if connectionOpen { Darwin.close(connection) }
        }
        DoryApplicationLaunchHandoffProtocol.setTimeouts(
            descriptor: connection,
            seconds: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        let daemonPeer = try DoryApplicationLaunchHandoffProtocol.peerIdentity(
            descriptor: connection
        )
        guard daemonPeer.uid == geteuid() else {
            throw DoryApplicationLaunchHandoffError.peerUserMismatch(
                expectedUID: geteuid(),
                actualUID: daemonPeer.uid
            )
        }
        try authenticateDaemon(daemonPeer.pid)
        try DoryApplicationLaunchHandoffProtocol.writeFrame(
            Data(token.utf8),
            to: connection,
            deadline: deadline
        )
        let manifestData = try DoryApplicationLaunchHandoffProtocol.readFrame(
            from: connection,
            maximumBytes: 4_096,
            deadline: deadline
        )
        let manifest: DoryApplicationLaunchDescriptorManifest
        do {
            manifest = try JSONDecoder().decode(
                DoryApplicationLaunchDescriptorManifest.self,
                from: manifestData
            )
        } catch {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        try manifest.validate()
        var received = try DoryApplicationLaunchHandoffProtocol.receiveDescriptors(
            from: connection,
            expectedCount: manifest.targetDescriptors.count,
            deadline: deadline
        )
        defer {
            for descriptor in received { Darwin.close(descriptor) }
        }

        // A fresh GUI process commonly allocates its handoff socket at descriptor 3, which is
        // also the system-disk slot. Preserve the channel above every target before installing
        // any resource so the final acknowledgement cannot be redirected into a disk image.
        let safeConnection = fcntl(
            connection,
            F_DUPFD_CLOEXEC,
            max(3, (manifest.targetDescriptors.max() ?? 2) + 1)
        )
        guard safeConnection >= 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("fcntl(F_DUPFD_CLOEXEC)", errno)
        }
        defer { Darwin.close(safeConnection) }
        Darwin.close(connection)
        connectionOpen = false
        try DoryApplicationLaunchHandoffProtocol.install(
            receivedDescriptors: &received,
            targetDescriptors: manifest.targetDescriptors
        )
        try DoryApplicationLaunchHandoffProtocol.writeAll(
            Data([DoryApplicationLaunchHandoffProtocol.acknowledgement]),
            to: safeConnection,
            deadline: deadline
        )
        return Array(arguments.dropLast(4))
    }
}

enum DoryApplicationLaunchHandoffError: Error, CustomStringConvertible, Equatable {
    case invalidInvocation
    case invalidManifest
    case invalidDescriptorTarget(Int32)
    case duplicateDescriptorTarget(Int32)
    case descriptorCountMismatch(expected: Int, actual: Int)
    case peerIdentityMismatch(expectedPID: pid_t, actualPID: pid_t)
    case peerUserMismatch(expectedUID: uid_t, actualUID: uid_t)
    case tokenMismatch
    case timeout(String)
    case closed(String)
    case security(String, OSStatus)
    case syscall(String, Int32)

    var description: String {
        switch self {
        case .invalidInvocation:
            return "invalid Dory application launch handoff invocation"
        case .invalidManifest:
            return "invalid Dory application launch descriptor manifest"
        case .invalidDescriptorTarget(let descriptor):
            return "invalid Dory application launch descriptor target \(descriptor)"
        case .duplicateDescriptorTarget(let descriptor):
            return "duplicate Dory application launch descriptor target \(descriptor)"
        case .descriptorCountMismatch(let expected, let actual):
            return "Dory application launch descriptor count mismatch (expected \(expected), received \(actual))"
        case .peerIdentityMismatch(let expectedPID, let actualPID):
            return "Dory application launch peer PID mismatch (expected \(expectedPID), received \(actualPID))"
        case .peerUserMismatch(let expectedUID, let actualUID):
            return "Dory application launch peer user mismatch (expected \(expectedUID), received \(actualUID))"
        case .tokenMismatch:
            return "Dory application launch token mismatch"
        case .timeout(let operation):
            return "Dory application launch \(operation) timed out"
        case .closed(let operation):
            return "Dory application launch channel closed during \(operation)"
        case .security(let operation, let status):
            return "Dory application launch \(operation) failed with Security status \(status)"
        case .syscall(let operation, let code):
            return "Dory application launch \(operation): \(String(cString: strerror(code)))"
        }
    }
}

/// Daemon-side, single-use descriptor gate. Its directory is created atomically with mode 0700;
/// the socket is 0600, a cryptographic token prevents stale-channel confusion, and LOCAL_PEERPID
/// plus getpeereid bind the accepted stream to the exact LaunchServices result before authority is
/// transferred.
final class DoryApplicationLaunchHandoffServer: @unchecked Sendable {
    let path: String
    let token: String

    private let directory: String
    private let listener: Int32
    private let cleanupLock = NSLock()
    private var cleaned = false

    init() throws {
        var template = Array("/tmp/dory-runner-launch.XXXXXX".utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress!)
        }) else {
            throw DoryApplicationLaunchHandoffError.syscall("mkdtemp", errno)
        }
        directory = String(cString: created)
        path = directory + "/h.sock"
        do {
            token = try Self.makeToken()
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else {
                throw DoryApplicationLaunchHandoffError.syscall("socket", errno)
            }
            do {
                try DoryApplicationLaunchHandoffProtocol.configureTransportDescriptor(listener)
                var address = try DoryApplicationLaunchHandoffProtocol.unixAddress(path: path)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(
                            listener,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
                guard result == 0 else {
                    throw DoryApplicationLaunchHandoffError.syscall("bind", errno)
                }
                guard chmod(path, 0o600) == 0 else {
                    throw DoryApplicationLaunchHandoffError.syscall("chmod", errno)
                }
                guard listen(listener, 1) == 0 else {
                    throw DoryApplicationLaunchHandoffError.syscall("listen", errno)
                }
            } catch {
                Darwin.close(listener)
                throw error
            }
        } catch {
            _ = unlink(path)
            _ = rmdir(directory)
            throw error
        }
    }

    /// Returns the kernel-issued audit token for the authenticated peer. Unlike a bare PID, the
    /// token includes the process incarnation and can therefore be used with
    /// `proc_signal_with_audittoken` without ever signaling a later process that reused the PID.
    @discardableResult
    func transfer(
        toExpectedPID expectedPID: pid_t,
        mappings: [InheritedDescriptorMapping],
        authenticateLiveProcess: () throws -> Void
    ) throws -> audit_token_t {
        try transfer(
            expectedPID: expectedPID,
            mappings: mappings,
            authenticateLiveProcess: { _ in try authenticateLiveProcess() }
        ).auditToken
    }

    /// LaunchServices is allowed to report an application object with no PID. In that case the
    /// authenticated Unix-domain peer is the authoritative live process: LOCAL_PEERPID identifies
    /// the exact socket endpoint, the invitation token binds it to this launch, and the dynamic
    /// code check runs before any descriptor authority is released.
    func transfer(
        mappings: [InheritedDescriptorMapping],
        authenticateLiveProcess: (pid_t) throws -> Void
    ) throws -> DoryApplicationLaunchPeerIdentity {
        try transfer(
            expectedPID: nil,
            mappings: mappings,
            authenticateLiveProcess: authenticateLiveProcess
        )
    }

    private func transfer(
        expectedPID: pid_t?,
        mappings: [InheritedDescriptorMapping],
        authenticateLiveProcess: (pid_t) throws -> Void
    ) throws -> DoryApplicationLaunchPeerIdentity {
        try DoryApplicationLaunchHandoffProtocol.validateTargets(
            mappings.map(\.childDescriptor)
        )
        let deadline = DoryApplicationLaunchHandoffProtocol.TransportDeadline(
            timeout: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        let connection = try DoryApplicationLaunchHandoffProtocol.acceptConnection(
            listener: listener,
            deadline: deadline
        )
        defer { Darwin.close(connection) }
        DoryApplicationLaunchHandoffProtocol.setTimeouts(
            descriptor: connection,
            seconds: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )

        let peer = try DoryApplicationLaunchHandoffProtocol.peerIdentity(
            descriptor: connection
        )
        if let expectedPID, peer.pid != expectedPID {
            throw DoryApplicationLaunchHandoffError.peerIdentityMismatch(
                expectedPID: expectedPID,
                actualPID: peer.pid
            )
        }
        let expectedUID = geteuid()
        guard peer.uid == expectedUID else {
            throw DoryApplicationLaunchHandoffError.peerUserMismatch(
                expectedUID: expectedUID,
                actualUID: peer.uid
            )
        }
        let receivedToken = try DoryApplicationLaunchHandoffProtocol.readFrame(
            from: connection,
            maximumBytes: DoryApplicationLaunchHandoffProtocol.tokenByteCount * 2,
            deadline: deadline
        )
        guard DoryApplicationLaunchHandoffProtocol.constantTimeEqual(
            receivedToken,
            Data(token.utf8)
        ) else {
            throw DoryApplicationLaunchHandoffError.tokenMismatch
        }

        // This callback performs the dynamic Security.framework check for this exact PID. The
        // client is blocked waiting for the manifest and owns no admitted descriptors yet.
        try authenticateLiveProcess(peer.pid)
        let manifest = DoryApplicationLaunchDescriptorManifest(
            targetDescriptors: mappings.map(\.childDescriptor)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DoryApplicationLaunchHandoffProtocol.writeFrame(
            try encoder.encode(manifest),
            to: connection,
            deadline: deadline
        )
        try DoryApplicationLaunchHandoffProtocol.sendDescriptors(
            mappings.map(\.parentDescriptor),
            to: connection,
            deadline: deadline
        )
        let acknowledgement = try DoryApplicationLaunchHandoffProtocol.readExact(
            count: 1,
            from: connection,
            operation: "acknowledgement",
            deadline: deadline
        )
        guard acknowledgement.first == DoryApplicationLaunchHandoffProtocol.acknowledgement else {
            throw DoryApplicationLaunchHandoffError.closed("acknowledgement")
        }
        return DoryApplicationLaunchPeerIdentity(
            processIdentifier: peer.pid,
            auditToken: peer.auditToken
        )
    }

    func cleanup() {
        cleanupLock.lock()
        guard !cleaned else {
            cleanupLock.unlock()
            return
        }
        cleaned = true
        cleanupLock.unlock()
        Darwin.close(listener)
        _ = unlink(path)
        _ = rmdir(directory)
    }

    deinit { cleanup() }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: DoryApplicationLaunchHandoffProtocol.tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DoryApplicationLaunchHandoffError.security("random-token generation", status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct DoryApplicationLaunchPeerIdentity {
    let processIdentifier: pid_t
    let auditToken: audit_token_t
}

public enum DoryRendererGenerationHandoffError: Error, Sendable, CustomStringConvertible, Equatable {
    case invalidRequest
    case invalidResponse
    case descriptorCountMismatch(expected: Int, actual: Int)
    case peerUserMismatch(expectedUID: uid_t, actualUID: uid_t)
    case rejected(String)
    case closed(String)
    case security(String, OSStatus)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case .invalidRequest:
            return "invalid renderer generation handoff request"
        case .invalidResponse:
            return "invalid renderer generation handoff response"
        case let .descriptorCountMismatch(expected, actual):
            return "renderer generation descriptor count mismatch (expected \(expected), received \(actual))"
        case let .peerUserMismatch(expectedUID, actualUID):
            return "renderer generation peer user mismatch (expected \(expectedUID), received \(actualUID))"
        case let .rejected(message):
            return message.isEmpty ? "renderer generation handoff rejected" : message
        case let .closed(operation):
            return "renderer generation handoff channel closed during \(operation)"
        case let .security(operation, status):
            return "renderer generation handoff \(operation) failed with Security status \(status)"
        case let .syscall(operation, code):
            return "renderer generation handoff \(operation): \(String(cString: strerror(code)))"
        }
    }
}

public struct DoryRendererGenerationHandoffRequest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let tokenByteCount = 64

    public var schemaVersion: UInt16
    public var token: String
    public var machineID: String
    public var operationID: String
    public var resolvedPlanSHA256: String
    public var planRevision: UInt64
    public var previousRendererGeneration: UInt64
    public var requestedRendererGeneration: UInt64

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        token: String,
        machineID: String,
        operationID: String,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        previousRendererGeneration: UInt64,
        requestedRendererGeneration: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256.lowercased()
        self.planRevision = planRevision
        self.previousRendererGeneration = previousRendererGeneration
        self.requestedRendererGeneration = requestedRendererGeneration
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && token.utf8.count == Self.tokenByteCount
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && !machineID.isEmpty
            && DoryOperationIdentity.parseCanonical(operationID) != nil
            && isLowercaseSHA256(resolvedPlanSHA256)
            && planRevision > 0
            && previousRendererGeneration > 0
            && requestedRendererGeneration == previousRendererGeneration &+ 1
            && requestedRendererGeneration > previousRendererGeneration
    }
}

public struct DoryRendererGenerationHandoffResponse: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var ok: Bool
    public var message: String
    public var rendererGeneration: UInt64?
    public var bootstrapByteCount: UInt64?
    public var bootstrapSHA256: String?
    public var descriptorCount: Int

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        ok: Bool,
        message: String = "",
        rendererGeneration: UInt64? = nil,
        bootstrapByteCount: UInt64? = nil,
        bootstrapSHA256: String? = nil,
        descriptorCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.ok = ok
        self.message = message
        self.rendererGeneration = rendererGeneration
        self.bootstrapByteCount = bootstrapByteCount
        self.bootstrapSHA256 = bootstrapSHA256?.lowercased()
        self.descriptorCount = descriptorCount
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              descriptorCount == 0 || descriptorCount == 1 else { return false }
        if ok {
            return descriptorCount == 1
                && rendererGeneration.map { $0 > 1 } == true
                && bootstrapByteCount == UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount)
                && bootstrapSHA256.map(isLowercaseSHA256) == true
                && message.isEmpty
        }
        return descriptorCount == 0
            && rendererGeneration == nil
            && bootstrapByteCount == nil
            && bootstrapSHA256 == nil
    }
}

public final class DoryRendererGenerationHandoff: @unchecked Sendable {
    public let response: DoryRendererGenerationHandoffResponse

    private let lock = NSLock()
    private var ownedBootstrapDescriptor: Int32?

    public init(response: DoryRendererGenerationHandoffResponse, bootstrapDescriptor: Int32?) {
        self.response = response
        ownedBootstrapDescriptor = bootstrapDescriptor
    }

    public func takeBootstrapDescriptor() -> Int32? {
        lock.withLock {
            let descriptor = ownedBootstrapDescriptor
            ownedBootstrapDescriptor = nil
            return descriptor
        }
    }

    public func close() {
        if let descriptor = takeBootstrapDescriptor(), descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    deinit { close() }
}

struct DoryRendererGenerationHandoffPeerIdentity {
    let processIdentifier: pid_t
    let auditToken: audit_token_t
}

final class DoryRendererGenerationHandoffServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        DoryRendererGenerationHandoffRequest,
        DoryRendererGenerationHandoffPeerIdentity
    ) throws -> DoryRendererGenerationHandoff

    let path: String
    let token: String

    private let handler: Handler
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var queue: DispatchQueue?
    private var boundIdentity: (device: dev_t, inode: ino_t)?
    private var listenerGeneration: UInt64 = 0

    init(path: String, token: String, handler: @escaping Handler) {
        self.path = path
        self.token = token
        self.handler = handler
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: DoryApplicationLaunchHandoffProtocol.tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DoryRendererGenerationHandoffError.security("random-token generation", status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var isRunning: Bool { lock.withLock { listener >= 0 } }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let shouldStart = lock.withLock { listener < 0 }
        guard shouldStart else { return }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DoryRendererGenerationHandoffError.syscall("socket", errno) }
        do {
            try DoryApplicationLaunchHandoffProtocol.configureTransportDescriptor(fd)
            var address = try DoryApplicationLaunchHandoffProtocol.unixAddress(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw DoryRendererGenerationHandoffError.syscall("bind", errno)
            }
            guard chmod(path, 0o600) == 0 else {
                throw DoryRendererGenerationHandoffError.syscall("chmod", errno)
            }
            guard listen(fd, 8) == 0 else {
                throw DoryRendererGenerationHandoffError.syscall("listen", errno)
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw DoryRendererGenerationHandoffError.syscall("lstat", errno)
            }
            let queue = DispatchQueue(label: "dev.dory.doryd.renderer-generation.\(fd)")
            let generation = lock.withLock { () -> UInt64 in
                listenerGeneration &+= 1
                listener = fd
                self.queue = queue
                boundIdentity = (info.st_dev, info.st_ino)
                return listenerGeneration
            }
            queue.async { [weak self] in self?.acceptLoop(listener: fd, generation: generation) }
        } catch {
            Darwin.close(fd)
            unlink(path)
            throw error
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let state = lock.withLock { () -> (Int32, (device: dev_t, inode: ino_t)?) in
            let state = (listener, boundIdentity)
            listener = -1
            queue = nil
            boundIdentity = nil
            listenerGeneration &+= 1
            return state
        }
        if state.0 >= 0 { Darwin.close(state.0) }
        if let identity = state.1 {
            var info = stat()
            if lstat(path, &info) == 0,
               info.st_dev == identity.device,
               info.st_ino == identity.inode
            {
                unlink(path)
            }
        }
    }

    private func acceptLoop(listener expectedListener: Int32, generation expectedGeneration: UInt64) {
        while isCurrentListener(expectedListener, generation: expectedGeneration) {
            let accepted = accept(expectedListener, nil, nil)
            if accepted < 0 {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            guard isCurrentListener(expectedListener, generation: expectedGeneration) else {
                Darwin.close(accepted)
                return
            }
            handle(accepted)
            Darwin.close(accepted)
        }
    }

    private func isCurrentListener(_ expectedListener: Int32, generation expectedGeneration: UInt64) -> Bool {
        lock.withLock {
            listener == expectedListener && listenerGeneration == expectedGeneration
        }
    }

    private func handle(_ connection: Int32) {
        let deadline = DoryApplicationLaunchHandoffProtocol.TransportDeadline(
            timeout: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        DoryApplicationLaunchHandoffProtocol.setTimeouts(
            descriptor: connection,
            seconds: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        var descriptors: [Int32] = []
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { Darwin.close($0) } }
        var response: DoryRendererGenerationHandoffResponse
        do {
            let peer = try DoryApplicationLaunchHandoffProtocol.peerIdentity(
                descriptor: connection
            )
            let expectedUID = geteuid()
            guard peer.uid == expectedUID else {
                throw DoryRendererGenerationHandoffError.peerUserMismatch(
                    expectedUID: expectedUID,
                    actualUID: peer.uid
                )
            }
            let requestData = try DoryApplicationLaunchHandoffProtocol.readFrame(
                from: connection,
                maximumBytes: 4096,
                deadline: deadline
            )
            let request = try JSONDecoder().decode(
                DoryRendererGenerationHandoffRequest.self,
                from: requestData
            )
            guard request.isValid,
                  DoryApplicationLaunchHandoffProtocol.constantTimeEqual(
                    Data(request.token.utf8),
                    Data(token.utf8)
                  ) else {
                throw DoryRendererGenerationHandoffError.invalidRequest
            }
            let handoff = try handler(
                request,
                DoryRendererGenerationHandoffPeerIdentity(
                    processIdentifier: peer.pid,
                    auditToken: peer.auditToken
                )
            )
            response = handoff.response
            guard response.isValid else { throw DoryRendererGenerationHandoffError.invalidResponse }
            if response.ok, response.rendererGeneration != request.requestedRendererGeneration {
                throw DoryRendererGenerationHandoffError.invalidResponse
            }
            ownedDescriptors = handoff.takeBootstrapDescriptor().map { [$0] } ?? []
            descriptors = ownedDescriptors
            guard descriptors.count == response.descriptorCount else {
                throw DoryRendererGenerationHandoffError.descriptorCountMismatch(
                    expected: response.descriptorCount,
                    actual: descriptors.count
                )
            }
        } catch let error as DoryRendererGenerationHandoffError {
            response = DoryRendererGenerationHandoffResponse(ok: false, message: error.description)
            descriptors = []
        } catch {
            response = DoryRendererGenerationHandoffResponse(ok: false, message: "renderer generation handoff failed")
            descriptors = []
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try DoryApplicationLaunchHandoffProtocol.writeFrame(
                try encoder.encode(response),
                to: connection,
                deadline: deadline
            )
            try DoryApplicationLaunchHandoffProtocol.sendDescriptors(
                descriptors,
                to: connection,
                deadline: deadline
            )
        } catch {
            return
        }
    }

    deinit { stop() }
}

public enum DoryRendererGenerationHandoffClient {
    public static func request(
        path: String,
        request: DoryRendererGenerationHandoffRequest
    ) throws -> DoryRendererGenerationHandoff {
        try Self.request(path: path, request: request) { daemonPID, _ in
            try DorySecurityDynamicCodeValidator.validate(
                pid: daemonPID,
                requirementText: DorydXPCSecurity.productionDaemonRequirement
            )
        }
    }

    static func request(
        path: String,
        request: DoryRendererGenerationHandoffRequest,
        authenticateDaemon: (pid_t, audit_token_t) throws -> Void
    ) throws -> DoryRendererGenerationHandoff {
        guard request.isValid else { throw DoryRendererGenerationHandoffError.invalidRequest }
        let deadline = DoryApplicationLaunchHandoffProtocol.TransportDeadline(
            timeout: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        let fd = try DoryApplicationLaunchHandoffProtocol.connect(path: path, deadline: deadline)
        defer { Darwin.close(fd) }
        DoryApplicationLaunchHandoffProtocol.setTimeouts(
            descriptor: fd,
            seconds: DoryApplicationLaunchHandoffProtocol.transferTimeoutSeconds
        )
        let daemonPeer = try DoryApplicationLaunchHandoffProtocol.peerIdentity(descriptor: fd)
        guard daemonPeer.uid == geteuid() else {
            throw DoryRendererGenerationHandoffError.peerUserMismatch(
                expectedUID: geteuid(),
                actualUID: daemonPeer.uid
            )
        }
        try authenticateDaemon(daemonPeer.pid, daemonPeer.auditToken)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DoryApplicationLaunchHandoffProtocol.writeFrame(
            try encoder.encode(request),
            to: fd,
            deadline: deadline
        )
        let responseData = try DoryApplicationLaunchHandoffProtocol.readFrame(
            from: fd,
            maximumBytes: 4096,
            deadline: deadline
        )
        let response = try JSONDecoder().decode(
            DoryRendererGenerationHandoffResponse.self,
            from: responseData
        )
        guard response.isValid else { throw DoryRendererGenerationHandoffError.invalidResponse }
        let descriptors = try DoryApplicationLaunchHandoffProtocol.receiveDescriptors(
            from: fd,
            expectedCount: response.descriptorCount,
            deadline: deadline
        )
        guard descriptors.count == response.descriptorCount else {
            for descriptor in descriptors { Darwin.close(descriptor) }
            throw DoryRendererGenerationHandoffError.descriptorCountMismatch(
                expected: response.descriptorCount,
                actual: descriptors.count
            )
        }
        if response.ok {
            guard descriptors.count == 1,
                  response.rendererGeneration == request.requestedRendererGeneration else {
                for descriptor in descriptors { Darwin.close(descriptor) }
                throw DoryRendererGenerationHandoffError.invalidResponse
            }
            return DoryRendererGenerationHandoff(
                response: response,
                bootstrapDescriptor: descriptors[0]
            )
        }
        for descriptor in descriptors { Darwin.close(descriptor) }
        throw DoryRendererGenerationHandoffError.rejected(response.message)
    }
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}


private struct DoryApplicationLaunchDescriptorManifest: Codable, Equatable {
    static let currentSchemaVersion: UInt16 = 1
    var schemaVersion: UInt16 = currentSchemaVersion
    var targetDescriptors: [Int32]

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        try DoryApplicationLaunchHandoffProtocol.validateTargets(targetDescriptors)
    }
}

enum DoryApplicationLaunchHandoffProtocol {
    enum AuditTokenSignalResult: Equatable {
        case delivered
        case unavailable
        case failed(Int32)
    }

    enum InterruptedSyscallOutcome: Equatable {
        case value(Int64)
        case failure(Int32)
    }

    struct TransportDeadline: Sendable, Equatable {
        let uptimeNanoseconds: UInt64

        init(
            timeout: TimeInterval,
            monotonicNow: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) {
            let interval = UInt64(max(0, timeout) * 1_000_000_000)
            let sum = monotonicNow.addingReportingOverflow(interval)
            uptimeNanoseconds = sum.overflow ? UInt64.max : sum.partialValue
        }

        func remainingMilliseconds(
            monotonicNow: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) -> Int32? {
            guard monotonicNow < uptimeNanoseconds else { return nil }
            let remaining = uptimeNanoseconds - monotonicNow
            let roundedMilliseconds = (remaining + 999_999) / 1_000_000
            return Int32(min(UInt64(Int32.max), max(1, roundedMilliseconds)))
        }
    }

    private typealias AuditTokenSignalFunction = @convention(c) (
        UnsafeMutablePointer<audit_token_t>?,
        Int32
    ) -> Int32

    /// `proc_signal_with_audittoken` was added during the macOS 14 lifecycle, after Dory's 14.0
    /// deployment target. Resolve it lazily so early Sonoma can still load doryd. Those hosts use
    /// the exact NSRunningApplication fallback for termination; VZ pause/resume already travels
    /// over the helper's lifecycle control socket rather than a process signal.
    private static let auditTokenSignalFunction: AuditTokenSignalFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let symbol = dlsym(handle, "proc_signal_with_audittoken") else {
            dlclose(handle)
            return nil
        }
        // Keep the main-program handle open for the lifetime of the cached function pointer.
        return unsafeBitCast(symbol, to: AuditTokenSignalFunction.self)
    }()

    static let tokenByteCount = 32
    static let maximumDescriptorCount = 16
    static let maximumTargetDescriptor: Int32 = 1_023
    static let transferTimeoutSeconds: TimeInterval = 15
    static let maximumInterruptedSignalAttempts = 8
    static let maximumInterruptedTransportAttempts = 8
    static let descriptorMarker: UInt8 = 0xd4
    static let acknowledgement: UInt8 = 0xa7

    static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    static func connect(
        path: String,
        deadline: TransportDeadline? = nil
    ) throws -> Int32 {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("socket", errno)
        }
        do {
            try configureTransportDescriptor(descriptor)
            var address = try unixAddress(path: path)
            let outcome = boundedInterruptedSyscall {
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
                return (Int64(result), result < 0 ? errno : 0)
            }
            switch outcome {
            case .value:
                return descriptor
            case let .failure(code)
                where code == EINPROGRESS || code == EALREADY || code == EAGAIN:
                try waitUntilReady(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    operation: "connect"
                )
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                ) == 0 else {
                    throw DoryApplicationLaunchHandoffError.syscall(
                        "getsockopt(SO_ERROR)",
                        errno
                    )
                }
                guard socketError == 0 || socketError == EISCONN else {
                    throw DoryApplicationLaunchHandoffError.syscall(
                        "connect",
                        socketError
                    )
                }
                return descriptor
            case let .failure(code) where code == EISCONN:
                return descriptor
            case let .failure(code):
                throw DoryApplicationLaunchHandoffError.syscall("connect", code)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func configureTransportDescriptor(_ descriptor: Int32) throws {
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("fcntl(F_GETFL)", errno)
        }
        guard fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("fcntl(F_SETFL)", errno)
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("fcntl(F_GETFD)", errno)
        }
        guard fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("fcntl(F_SETFD)", errno)
        }
    }

    static func boundedInterruptedSyscall(
        invoke: () -> (result: Int64, error: Int32)
    ) -> InterruptedSyscallOutcome {
        for attempt in 1...maximumInterruptedTransportAttempts {
            let outcome = invoke()
            if outcome.result >= 0 { return .value(outcome.result) }
            let code = outcome.error == 0 ? EIO : outcome.error
            if code == EINTR, attempt < maximumInterruptedTransportAttempts {
                continue
            }
            return .failure(code)
        }
        return .failure(EINTR)
    }

    static func waitUntilReady(
        descriptor: Int32,
        events: Int16,
        deadline: TransportDeadline,
        operation: String,
        monotonicNow: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        pollOperation: ((Int32) -> (result: Int32, error: Int32))? = nil
    ) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let outcome = boundedInterruptedSyscall {
            guard let timeoutMilliseconds = deadline.remainingMilliseconds(
                monotonicNow: monotonicNow()
            ) else {
                return (-1, ETIMEDOUT)
            }
            let result: Int32
            let code: Int32
            if let pollOperation {
                let injected = pollOperation(timeoutMilliseconds)
                result = injected.result
                code = injected.error
            } else {
                result = poll(&pollDescriptor, 1, timeoutMilliseconds)
                code = result < 0 ? errno : 0
            }
            return (Int64(result), code)
        }
        switch outcome {
        case let .value(result) where result > 0:
            return
        case .value:
            throw DoryApplicationLaunchHandoffError.timeout(operation)
        case .failure(ETIMEDOUT):
            throw DoryApplicationLaunchHandoffError.timeout(operation)
        case let .failure(code):
            throw DoryApplicationLaunchHandoffError.syscall("poll(\(operation))", code)
        }
    }

    static func acceptConnection(
        listener: Int32,
        deadline: TransportDeadline
    ) throws -> Int32 {
        while true {
            try waitUntilReady(
                descriptor: listener,
                events: Int16(POLLIN),
                deadline: deadline,
                operation: "accept"
            )
            let outcome = boundedInterruptedSyscall {
                let connection = accept(listener, nil, nil)
                return (Int64(connection), connection < 0 ? errno : 0)
            }
            switch outcome {
            case let .value(connection):
                let descriptor = Int32(connection)
                do {
                    try configureTransportDescriptor(descriptor)
                    return descriptor
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            case let .failure(code) where code == EAGAIN || code == EWOULDBLOCK:
                continue
            case let .failure(code):
                throw DoryApplicationLaunchHandoffError.syscall("accept", code)
            }
        }
    }

    static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty,
              bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DoryApplicationLaunchHandoffError.invalidInvocation
        }
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

    static func setTimeouts(descriptor: Int32, seconds: TimeInterval) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    static func peerIdentity(
        descriptor: Int32
    ) throws -> (pid: pid_t, uid: uid_t, auditToken: audit_token_t) {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &peerPIDLength
        ) == 0 else {
            throw DoryApplicationLaunchHandoffError.syscall(
                "getsockopt(LOCAL_PEERPID)",
                errno
            )
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
            throw DoryApplicationLaunchHandoffError.syscall("getpeereid", errno)
        }
        var auditToken = audit_token_t()
        var auditTokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERTOKEN,
            &auditToken,
            &auditTokenLength
        ) == 0 else {
            throw DoryApplicationLaunchHandoffError.syscall(
                "getsockopt(LOCAL_PEERTOKEN)",
                errno
            )
        }
        guard auditTokenLength == MemoryLayout<audit_token_t>.size else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        return (peerPID, peerUID, auditToken)
    }

    /// Darwin's audit-token signal operation atomically targets the exact process incarnation;
    /// it fails once that process exits even if its numeric PID has already been recycled.
    static func signal(
        _ signal: Int32,
        auditToken: audit_token_t
    ) -> AuditTokenSignalResult {
        guard let auditTokenSignalFunction else { return .unavailable }
        return self.signal(
            signal,
            auditToken: auditToken,
            invoke: { token, signal in
                auditTokenSignalFunction(&token, signal)
            },
            currentErrno: { errno }
        )
    }

    /// Testable core for the weak-linked audit-token syscall. Darwin syscall wrappers may report
    /// either `-1` plus `errno` or a positive errno value; normalize both forms so callers receive
    /// an actionable failure code. Repeated EINTR is bounded because this runs while the exact
    /// process lifecycle lock is held.
    static func signal(
        _ signal: Int32,
        auditToken: audit_token_t,
        invoke: (inout audit_token_t, Int32) -> Int32,
        currentErrno: () -> Int32
    ) -> AuditTokenSignalResult {
        var token = auditToken
        for attempt in 1...maximumInterruptedSignalAttempts {
            let result = invoke(&token, signal)
            if result == 0 { return .delivered }
            let code: Int32
            if result == -1 {
                let capturedErrno = currentErrno()
                code = capturedErrno == 0 ? EIO : capturedErrno
            } else if result > 0 {
                code = result
            } else {
                code = EIO
            }
            if code == EINTR, attempt < maximumInterruptedSignalAttempts {
                continue
            }
            return .failed(code)
        }
        return .failed(EINTR)
    }

    static func validateTargets(_ targets: [Int32]) throws {
        guard targets.count <= maximumDescriptorCount else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        var unique: Set<Int32> = []
        for target in targets {
            guard (0...maximumTargetDescriptor).contains(target) else {
                throw DoryApplicationLaunchHandoffError.invalidDescriptorTarget(target)
            }
            guard unique.insert(target).inserted else {
                throw DoryApplicationLaunchHandoffError.duplicateDescriptorTarget(target)
            }
        }
    }

    static func writeFrame(
        _ payload: Data,
        to descriptor: Int32,
        deadline: TransportDeadline? = nil
    ) throws {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        guard payload.count <= Int(UInt32.max) else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) {
            try writeAll(Data($0), to: descriptor, deadline: deadline)
        }
        try writeAll(payload, to: descriptor, deadline: deadline)
    }

    static func readFrame(
        from descriptor: Int32,
        maximumBytes: Int,
        deadline: TransportDeadline? = nil
    ) throws -> Data {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        let header = try readExact(
            count: 4,
            from: descriptor,
            operation: "frame header",
            deadline: deadline
        )
        let length = header.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard length <= UInt32(maximumBytes) else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        return try readExact(
            count: Int(length),
            from: descriptor,
            operation: "frame payload",
            deadline: deadline
        )
    }

    static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: TransportDeadline? = nil
    ) throws {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try waitUntilReady(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    operation: "write"
                )
                let outcome = boundedInterruptedSyscall {
                    let count = Darwin.write(
                        descriptor,
                        raw.baseAddress!.advanced(by: offset),
                        raw.count - offset
                    )
                    return (Int64(count), count < 0 ? errno : 0)
                }
                switch outcome {
                case let .value(count) where count > 0:
                    offset += Int(count)
                case .value:
                    throw DoryApplicationLaunchHandoffError.closed("write")
                case let .failure(code) where code == EAGAIN || code == EWOULDBLOCK:
                    continue
                case let .failure(code):
                    throw DoryApplicationLaunchHandoffError.syscall("write", code)
                }
            }
        }
    }

    static func readExact(
        count: Int,
        from descriptor: Int32,
        operation: String,
        deadline: TransportDeadline? = nil
    ) throws -> Data {
        guard count > 0 else { return Data() }
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try waitUntilReady(
                descriptor: descriptor,
                events: Int16(POLLIN),
                deadline: deadline,
                operation: operation
            )
            let outcome = bytes.withUnsafeMutableBytes { raw in
                boundedInterruptedSyscall {
                    let received = Darwin.read(
                        descriptor,
                        raw.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                    return (Int64(received), received < 0 ? errno : 0)
                }
            }
            switch outcome {
            case let .value(received) where received > 0:
                offset += Int(received)
            case .value:
                throw DoryApplicationLaunchHandoffError.closed(operation)
            case let .failure(code) where code == EAGAIN || code == EWOULDBLOCK:
                continue
            case let .failure(code):
                throw DoryApplicationLaunchHandoffError.syscall("read", code)
            }
        }
        return Data(bytes)
    }

    static func sendDescriptors(
        _ descriptors: [Int32],
        to socket: Int32,
        deadline: TransportDeadline? = nil
    ) throws {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        guard !descriptors.isEmpty else {
            try writeAll(Data([descriptorMarker]), to: socket, deadline: deadline)
            return
        }
        let descriptorBytes = descriptors.count * MemoryLayout<Int32>.size
        while true {
            try waitUntilReady(
                descriptor: socket,
                events: Int16(POLLOUT),
                deadline: deadline,
                operation: "descriptor transfer"
            )
            let outcome = boundedInterruptedSyscall {
                var control = [UInt8](repeating: 0, count: cmsgSpace(descriptorBytes))
                var marker = descriptorMarker
                let sent = control.withUnsafeMutableBytes { controlRaw -> ssize_t in
                    descriptors.withUnsafeBytes { descriptorRaw -> ssize_t in
                        withUnsafeMutablePointer(to: &marker) { markerPointer in
                            var vector = iovec(iov_base: markerPointer, iov_len: 1)
                            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                                var message = msghdr(
                                    msg_name: nil,
                                    msg_namelen: 0,
                                    msg_iov: vectorPointer,
                                    msg_iovlen: 1,
                                    msg_control: controlRaw.baseAddress,
                                    msg_controllen: socklen_t(controlRaw.count),
                                    msg_flags: 0
                                )
                                let header = cmsghdr(
                                    cmsg_len: socklen_t(cmsgLen(descriptorBytes)),
                                    cmsg_level: SOL_SOCKET,
                                    cmsg_type: SCM_RIGHTS
                                )
                                controlRaw.storeBytes(of: header, as: cmsghdr.self)
                                controlRaw.baseAddress!
                                    .advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
                                    .copyMemory(
                                        from: descriptorRaw.baseAddress!,
                                        byteCount: descriptorBytes
                                    )
                                return sendmsg(socket, &message, MSG_NOSIGNAL)
                            }
                        }
                    }
                }
                return (Int64(sent), sent < 0 ? errno : 0)
            }
            switch outcome {
            case .value(1):
                return
            case .value:
                throw DoryApplicationLaunchHandoffError.closed("descriptor transfer")
            case let .failure(code) where code == EAGAIN || code == EWOULDBLOCK:
                continue
            case let .failure(code):
                throw DoryApplicationLaunchHandoffError.syscall("sendmsg", code)
            }
        }
    }

    static func receiveDescriptors(
        from socket: Int32,
        expectedCount: Int,
        deadline: TransportDeadline? = nil
    ) throws -> [Int32] {
        let deadline = deadline ?? TransportDeadline(timeout: transferTimeoutSeconds)
        guard (0...maximumDescriptorCount).contains(expectedCount) else {
            throw DoryApplicationLaunchHandoffError.invalidManifest
        }
        while true {
            try waitUntilReady(
                descriptor: socket,
                events: Int16(POLLIN),
                deadline: deadline,
                operation: "descriptor transfer"
            )
            var marker: UInt8 = 0
            var control = [UInt8](
                repeating: 0,
                count: 2048  // Full XNU control bound; avoid losing installed rights to truncation.
            )
            var controlLength = 0
            var messageFlags: Int32 = 0
            let outcome = boundedInterruptedSyscall {
                let received = control.withUnsafeMutableBytes { controlRaw -> ssize_t in
                    withUnsafeMutablePointer(to: &marker) { markerPointer in
                        var vector = iovec(iov_base: markerPointer, iov_len: 1)
                        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                            var message = msghdr(
                                msg_name: nil,
                                msg_namelen: 0,
                                msg_iov: vectorPointer,
                                msg_iovlen: 1,
                                msg_control: controlRaw.baseAddress,
                                msg_controllen: socklen_t(controlRaw.count),
                                msg_flags: 0
                            )
                            let count = recvmsg(socket, &message, 0)
                            controlLength = Int(message.msg_controllen)
                            messageFlags = message.msg_flags
                            return count
                        }
                    }
                }
                return (Int64(received), received < 0 ? errno : 0)
            }
            var descriptors = fileDescriptors(from: Array(control.prefix(controlLength)))
            defer { for descriptor in descriptors { Darwin.close(descriptor) } }
            switch outcome {
            case .value(1):
                guard marker == descriptorMarker,
                      messageFlags & MSG_CTRUNC == 0 else {
                    throw DoryApplicationLaunchHandoffError.invalidManifest
                }
                guard descriptors.count == expectedCount else {
                    throw DoryApplicationLaunchHandoffError.descriptorCountMismatch(
                        expected: expectedCount,
                        actual: descriptors.count
                    )
                }
                let receivedDescriptors = descriptors
                descriptors = []
                return receivedDescriptors
            case .value(0):
                throw DoryApplicationLaunchHandoffError.closed("descriptor transfer")
            case .value:
                throw DoryApplicationLaunchHandoffError.invalidManifest
            case let .failure(code) where code == EAGAIN || code == EWOULDBLOCK:
                continue
            case let .failure(code):
                throw DoryApplicationLaunchHandoffError.syscall("recvmsg", code)
            }
        }
    }

    static func install(
        receivedDescriptors: inout [Int32],
        targetDescriptors: [Int32]
    ) throws {
        // This function consumes the received SCM_RIGHTS descriptors on every path. Stage each
        // source above the complete target range, close the originals, and only then install the
        // targets. Closing originals after `dup2` is incorrect when a fresh process received a
        // source at fd 4 and the manifest also targets fd 4: that close would destroy the newly
        // installed VM resource while still allowing the launch acknowledgement to succeed.
        var ownedReceivedDescriptors = receivedDescriptors
        receivedDescriptors.removeAll(keepingCapacity: false)
        defer {
            for descriptor in ownedReceivedDescriptors { Darwin.close(descriptor) }
        }
        guard ownedReceivedDescriptors.count == targetDescriptors.count else {
            throw DoryApplicationLaunchHandoffError.descriptorCountMismatch(
                expected: targetDescriptors.count,
                actual: ownedReceivedDescriptors.count
            )
        }
        try validateTargets(targetDescriptors)
        var staged: [(source: Int32, target: Int32)] = []
        defer { for item in staged { Darwin.close(item.source) } }
        var next = max(3, (targetDescriptors.max() ?? 2) + 1)
        for (source, target) in zip(ownedReceivedDescriptors, targetDescriptors) {
            let duplicate = fcntl(source, F_DUPFD_CLOEXEC, next)
            guard duplicate >= 0 else {
                throw DoryApplicationLaunchHandoffError.syscall(
                    "fcntl(F_DUPFD_CLOEXEC)",
                    errno
                )
            }
            staged.append((duplicate, target))
            next = duplicate + 1
        }
        for descriptor in ownedReceivedDescriptors { Darwin.close(descriptor) }
        ownedReceivedDescriptors.removeAll(keepingCapacity: false)
        for item in staged {
            guard dup2(item.source, item.target) == item.target else {
                throw DoryApplicationLaunchHandoffError.syscall("dup2", errno)
            }
        }
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func fileDescriptors(from control: [UInt8]) -> [Int32] {
        var descriptors: [Int32] = []
        control.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<cmsghdr>.size <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                let headerLength = Int(header.cmsg_len)
                guard headerLength >= MemoryLayout<cmsghdr>.size,
                      offset + headerLength <= raw.count else { break }
                if header.cmsg_level == SOL_SOCKET,
                   header.cmsg_type == SCM_RIGHTS {
                    let dataOffset = offset + cmsgAlign(MemoryLayout<cmsghdr>.size)
                    let dataLength = headerLength - cmsgAlign(MemoryLayout<cmsghdr>.size)
                    let count = max(0, dataLength / MemoryLayout<Int32>.size)
                    for index in 0..<count {
                        descriptors.append(raw.loadUnaligned(
                            fromByteOffset: dataOffset + index * MemoryLayout<Int32>.size,
                            as: Int32.self
                        ))
                    }
                }
                offset += cmsgAlign(headerLength)
            }
        }
        return descriptors
    }

    private static func cmsgAlign(_ length: Int) -> Int {
        let alignment = MemoryLayout<cmsghdr>.alignment
        return (length + alignment - 1) & ~(alignment - 1)
    }

    private static func cmsgSpace(_ length: Int) -> Int {
        cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(length)
    }

    private static func cmsgLen(_ length: Int) -> Int {
        cmsgAlign(MemoryLayout<cmsghdr>.size) + length
    }
}
