import Darwin
import DoryCore
import Foundation

public enum SourcePreservingLANPrivilegedError: Error, Sendable, Equatable, CustomStringConvertible {
    case rootRequired
    case unsupportedVersion(Int)
    case invalidSessionID
    case invalidSocketPath
    case socketUnavailable(String)
    case socketOwnerMismatch(expected: uid_t, actual: uid_t)
    case sessionConflict
    case noActiveSession
    case interfaceUnavailable
    case commandFailed(String)

    public var description: String {
        switch self {
        case .rootRequired: "source-preserving LAN helper must run as root"
        case .unsupportedVersion(let value): "unsupported source-preserving LAN request version: \(value)"
        case .invalidSessionID: "invalid source-preserving LAN session identifier"
        case .invalidSocketPath: "invalid gvproxy socket path"
        case .socketUnavailable(let path): "gvproxy socket is unavailable: \(path)"
        case .socketOwnerMismatch(let expected, let actual):
            "gvproxy socket owner mismatch (expected uid \(expected), found \(actual))"
        case .sessionConflict: "another source-preserving LAN session is already active"
        case .noActiveSession: "source-preserving LAN session is not active"
        case .interfaceUnavailable: "privileged UTUN did not report an interface name"
        case .commandFailed(let message): "source-preserving LAN privileged command failed: \(message)"
        }
    }
}

public protocol SourcePreservingLANBridgeSession: AnyObject, Sendable {
    var activeInterfaceName: String? { get }
    var isHealthy: Bool { get }
    func start() throws
    func stop()
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void)
}

extension DirectIPBridge: SourcePreservingLANBridgeSession {}

/// Root-side owner for the UTUN, gvproxy packet bridge, host route, and a dedicated PF anchor.
/// The controller accepts only a signed-XPC caller's own gvproxy socket and re-derives every rule
/// from closed scalar inputs; callers never submit a command or PF fragment.
public final class SourcePreservingLANPrivilegedController: @unchecked Sendable {
    public typealias BridgeFactory = @Sendable (DirectIPBridgeConfiguration) throws -> any SourcePreservingLANBridgeSession
    public typealias CommandRunner = @Sendable ([String]) throws -> String
    public typealias AnchorWriter = @Sendable (String) throws -> Void

    public static let anchorName = "com.apple/dev.dory.lan"
    public static let anchorPath = "/etc/pf.anchors/dev.dory.lan"
    public static let runtimeDirectory = "/var/run/dev.dory"

    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private let bridgeFactory: BridgeFactory
    private let runCommand: CommandRunner
    private let writeAnchor: AnchorWriter
    private let enforceRoot: Bool
    private let runtimeDirectory: String
    private var activeSessionID: String?
    private var activeBridge: (any SourcePreservingLANBridgeSession)?
    private var activeInterfaceName: String?
    private var activePFToken: String?

    public init(
        enforceRoot: Bool = true,
        runtimeDirectory: String = SourcePreservingLANPrivilegedController.runtimeDirectory,
        bridgeFactory: BridgeFactory? = nil,
        runCommand: CommandRunner? = nil,
        writeAnchor: AnchorWriter? = nil
    ) {
        self.enforceRoot = enforceRoot
        self.runtimeDirectory = runtimeDirectory
        self.bridgeFactory = bridgeFactory ?? { configuration in
            try DirectIPBridge(configuration: configuration)
        }
        self.runCommand = runCommand ?? Self.runCommand
        self.writeAnchor = writeAnchor ?? Self.writeAnchor
    }

    deinit {
        activeBridge?.stop()
    }

    public func apply(
        _ request: SourcePreservingLANRequest,
        clientUID: uid_t
    ) throws -> SourcePreservingLANResponse {
        operationLock.lock()
        defer { operationLock.unlock() }
        if enforceRoot, geteuid() != 0 { throw SourcePreservingLANPrivilegedError.rootRequired }
        try Self.validateCommon(request)
        switch request.operation {
        case .activate:
            return try activate(request, clientUID: clientUID)
        case .refresh:
            return try refresh(request)
        case .deactivate:
            return try deactivate(request)
        }
    }

    /// Called once when launchd starts or restarts the daemon. A previous crash must leave closed
    /// ports, never a stale redirect to a dead tunnel.
    public func clearStaleAnchor() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureRuntimeDirectory()
        try cleanPersistentNetworkState()
    }

    private func activate(
        _ request: SourcePreservingLANRequest,
        clientUID: uid_t
    ) throws -> SourcePreservingLANResponse {
        guard let gvproxySocketPath = request.gvproxySocketPath else {
            throw SourcePreservingLANPrivilegedError.invalidSocketPath
        }
        try Self.validateGVProxySocket(gvproxySocketPath, clientUID: clientUID)

        lock.lock()
        let existingSessionID = activeSessionID
        let existingBridge = activeBridge
        let existingInterfaceName = activeInterfaceName
        lock.unlock()
        if let existingSessionID, let existingBridge {
            if existingBridge.isHealthy {
                guard existingSessionID == request.sessionID else {
                    throw SourcePreservingLANPrivilegedError.sessionConflict
                }
                _ = try applyPF(bindings: request.bindings, enable: false)
                return response(request, interfaceName: existingInterfaceName)
            }
            _ = try cleanupActiveSession(expectedSessionID: existingSessionID)
        } else if existingSessionID != nil || existingBridge != nil {
            throw SourcePreservingLANPrivilegedError.sessionConflict
        }

        try ensureRuntimeDirectory()
        let localSocket = "\(runtimeDirectory)/\(request.sessionID).sock"
        let interfaceFile = "\(runtimeDirectory)/\(request.sessionID).interface"
        let configuration = DirectIPBridgeConfiguration(
            subnetCIDR: SourcePreservingLANPlan.guestIngressCIDR,
            gateway: "192.168.215.253",
            gvproxySocketPath: gvproxySocketPath,
            localSocketPath: localSocket,
            interfaceNamePath: interfaceFile
        )
        let bridge = try bridgeFactory(configuration)
        let bridgeID = ObjectIdentifier(bridge)
        bridge.setFailureHandler { [weak self] detail in
            self?.bridgeFailed(
                sessionID: request.sessionID,
                bridgeID: bridgeID,
                detail: detail
            )
        }
        lock.lock()
        guard activeSessionID == nil, activeBridge == nil else {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.sessionConflict
        }
        activeSessionID = request.sessionID
        activeBridge = bridge
        activeInterfaceName = nil
        activePFToken = nil
        lock.unlock()

        do {
            try bridge.start()
            guard let interfaceName = bridge.activeInterfaceName,
                  interfaceName.wholeMatch(of: /utun[0-9]+/) != nil else {
                throw SourcePreservingLANPrivilegedError.interfaceUnavailable
            }
            _ = try runCommand([
                "/sbin/ifconfig", interfaceName, "inet",
                "192.168.215.253", SourcePreservingLANPlan.guestIngressIPv4,
                "netmask", "255.255.255.255", "mtu", "1500", "up",
            ])
            _ = try? runCommand([
                "/sbin/route", "-n", "delete", "-host", SourcePreservingLANPlan.guestIngressIPv4,
            ])
            _ = try runCommand([
                "/sbin/route", "-n", "add", "-host", SourcePreservingLANPlan.guestIngressIPv4,
                "-interface", interfaceName,
            ])
            lock.lock()
            activeInterfaceName = interfaceName
            lock.unlock()
            _ = try enableIPv4ForwardingIfNeeded()
            let acquiredPFToken = try applyPF(bindings: request.bindings, enable: true)
            lock.lock()
            activePFToken = acquiredPFToken
            lock.unlock()
            guard bridge.isHealthy else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "gvproxy LAN switch disconnected during activation"
                )
            }
            return response(request, interfaceName: interfaceName)
        } catch {
            do {
                _ = try cleanupActiveSession(
                    expectedSessionID: request.sessionID,
                    expectedBridgeID: bridgeID
                )
            } catch let cleanupError {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "activation failed (\(error)); cleanup remains retryable (\(cleanupError))"
                )
            }
            throw error
        }
    }

    private func bridgeFailed(
        sessionID: String,
        bridgeID: ObjectIdentifier,
        detail: String
    ) {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            _ = try cleanupActiveSession(
                expectedSessionID: sessionID,
                expectedBridgeID: bridgeID
            )
            FileHandle.standardError.write(
                Data("dory-network-helper: LAN bridge failed and was cleaned up: \(detail)\n".utf8)
            )
        } catch SourcePreservingLANPrivilegedError.noActiveSession {
            // A delayed callback from an already replaced bridge owns no current host state.
        } catch {
            FileHandle.standardError.write(
                Data("dory-network-helper: LAN bridge failed; cleanup remains retryable: \(detail); \(error)\n".utf8)
            )
        }
    }

    private func refresh(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse {
        lock.lock()
        let matches = activeSessionID == request.sessionID && activeBridge != nil
        let interfaceName = activeInterfaceName
        lock.unlock()
        guard matches else { throw SourcePreservingLANPrivilegedError.noActiveSession }
        _ = try applyPF(bindings: request.bindings, enable: false)
        return response(request, interfaceName: interfaceName)
    }

    private func deactivate(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse {
        let interfaceName = try cleanupActiveSession(expectedSessionID: request.sessionID)
        return SourcePreservingLANResponse(
            status: "stopped",
            sessionID: request.sessionID,
            interfaceName: interfaceName,
            lanBindingCount: 0
        )
    }

    /// Cleanup retains the session until every owned host mutation has been reversed. A caller can
    /// therefore retry deactivation after a transient pfctl or sysctl failure without leaking the
    /// PF reference or losing the knowledge required to restore host forwarding.
    private func cleanupActiveSession(
        expectedSessionID: String,
        expectedBridgeID: ObjectIdentifier? = nil
    ) throws -> String? {
        lock.lock()
        guard activeSessionID == expectedSessionID, let bridge = activeBridge else {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.noActiveSession
        }
        if let expectedBridgeID, ObjectIdentifier(bridge) != expectedBridgeID {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.noActiveSession
        }
        let interfaceName = activeInterfaceName
        let pfToken = activePFToken
        lock.unlock()

        bridge.stop()
        var firstError: Error?
        func retainFirst(_ error: Error) {
            if firstError == nil { firstError = error }
        }
        var runtimeSafe = true
        do { try ensureRuntimeDirectory() } catch {
            runtimeSafe = false
            retainFirst(error)
        }
        do { try writeAnchor("# Managed by Dory. Do not edit.\n") } catch {
            retainFirst(error)
        }
        do {
            _ = try runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
        } catch {
            retainFirst(error)
        }
        if runtimeSafe {
            var tokenToRelease = pfToken
            if tokenToRelease == nil {
                do { tokenToRelease = try readPersistedPFToken() } catch {
                    retainFirst(error)
                }
            }
            if let tokenToRelease {
                do {
                    try releasePFToken(tokenToRelease)
                    lock.lock()
                    if activeSessionID == expectedSessionID { activePFToken = nil }
                    lock.unlock()
                } catch {
                    retainFirst(error)
                }
            }
        }
        if runtimeSafe {
            do {
                try restoreIPv4ForwardingIfOwned()
            } catch {
                retainFirst(error)
            }
        }
        if let firstError { throw firstError }

        lock.lock()
        guard activeSessionID == expectedSessionID,
              let currentBridge = activeBridge,
              ObjectIdentifier(currentBridge) == ObjectIdentifier(bridge) else {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.noActiveSession
        }
        activeSessionID = nil
        activeBridge = nil
        activeInterfaceName = nil
        activePFToken = nil
        lock.unlock()
        return interfaceName
    }

    private func cleanPersistentNetworkState() throws {
        var firstError: Error?
        func retainFirst(_ error: Error) {
            if firstError == nil { firstError = error }
        }
        do { try writeAnchor("# Managed by Dory. Do not edit.\n") } catch {
            retainFirst(error)
        }
        do {
            _ = try runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
        } catch {
            retainFirst(error)
        }
        do {
            if let token = try readPersistedPFToken() { try releasePFToken(token) }
        } catch {
            retainFirst(error)
        }
        do { try restoreIPv4ForwardingIfOwned() } catch {
            retainFirst(error)
        }
        if let firstError { throw firstError }
    }

    private func applyPF(bindings: Set<PublishedPortBinding>, enable: Bool) throws -> String? {
        let contents = SourcePreservingLANPlan.pfAnchorContents(bindings: bindings)
        try writeAnchor(contents)
        _ = try runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-f", Self.anchorPath])
        guard enable else { return nil }
        let output = try runCommand(["/sbin/pfctl", "-E"])
        guard let token = Self.pfEnableToken(from: output) else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "pfctl -E did not return a releasable enable token"
            )
        }
        do {
            try persistPFToken(token)
        } catch {
            _ = try? runCommand(["/sbin/pfctl", "-X", token])
            throw error
        }
        return token
    }

    /// `/sbin/pfctl -E` writes `Token : %llu` (possibly alongside status text and on either
    /// output stream). DoryShell deliberately merges stdout/stderr so the root daemon can retain
    /// and later release the exact PF enable reference it acquired.
    static func pfEnableToken(from output: String) -> String? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("Token :") else { continue }
            let token = value.dropFirst("Token :".count).trimmingCharacters(in: .whitespaces)
            if token.wholeMatch(of: /[0-9]+/) != nil { return token }
        }
        return nil
    }

    private var pfTokenPath: String { runtimeDirectory + "/pf-enable-token" }
    private var forwardingMarkerPath: String { runtimeDirectory + "/ipv4-forwarding-owner" }

    private func ensureRuntimeDirectory() throws {
        if mkdir(runtimeDirectory, 0o755) != 0, errno != EEXIST {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "mkdir \(runtimeDirectory): \(String(cString: strerror(errno)))"
            )
        }
        var info = stat()
        let expectedOwner: uid_t = enforceRoot ? 0 : geteuid()
        guard lstat(runtimeDirectory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == expectedOwner,
              info.st_mode & 0o022 == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unsafe source-preserving LAN runtime directory: \(runtimeDirectory)"
            )
        }
    }

    /// UTUN packets written by the bridge enter macOS as received packets. IPv4 forwarding must be
    /// enabled while PF-rdr replies travel from that UTUN back to the physical/VPN interface. Dory
    /// records ownership only when it changed the host from 0 to 1, and restores that exact prior
    /// state on normal shutdown, bridge failure, or daemon crash recovery.
    private func enableIPv4ForwardingIfNeeded() throws -> Bool {
        let current = try runCommand(["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == "0" || current == "1" else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unexpected net.inet.ip.forwarding value: \(current)"
            )
        }
        guard current == "0" else { return false }
        // Persist the prior state before changing the host. If the process exits between these
        // steps, launchd cleanup can safely restore forwarding instead of losing ownership.
        try writeNewOwnedFile(path: forwardingMarkerPath, contents: "restore=0\n")
        _ = try runCommand(["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"])
        return true
    }

    private func restoreIPv4ForwardingIfOwned() throws {
        guard let data = try readOwnedFile(path: forwardingMarkerPath, maximumBytes: 64) else {
            return
        }
        guard data == Data("restore=0\n".utf8) else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid IPv4 forwarding ownership marker")
        }
        _ = try runCommand(["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"])
        try removeOwnedFile(path: forwardingMarkerPath)
    }

    private func writeNewOwnedFile(path: String, contents: String) throws {
        var existing = stat()
        if lstat(path, &existing) == 0 || errno != ENOENT {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "owned state already exists or is inaccessible: \(path)"
            )
        }
        let temporary = "\(path).tmp.\(UUID().uuidString)"
        let bytes = Array(contents.utf8)
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            _ = unlink(temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "chmod \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                while true {
                    let result = Darwin.write(
                        descriptor,
                        raw.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard written > 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "write \(temporary): \(String(cString: strerror(errno)))"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(path): \(String(cString: strerror(errno)))"
            )
        }
        close(descriptor)
        descriptorOpen = false
        guard rename(temporary, path) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "rename \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        try syncParentDirectory(of: path)
    }

    private func persistPFToken(_ token: String) throws {
        try writeNewOwnedFile(path: pfTokenPath, contents: token + "\n")
    }

    private func readPersistedPFToken() throws -> String? {
        guard let data = try readOwnedFile(path: pfTokenPath, maximumBytes: 64) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              value.wholeMatch(of: /[0-9]+/) != nil else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid persisted PF enable token")
        }
        return value
    }

    private func releasePFToken(_ token: String) throws {
        guard try readPersistedPFToken() == token else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "persisted PF enable token does not match the active session"
            )
        }
        _ = try runCommand(["/sbin/pfctl", "-X", token])
        try removeOwnedFile(path: pfTokenPath)
    }

    private func readOwnedFile(path: String, maximumBytes: Int) throws -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var info = stat()
        let expectedOwner: uid_t = enforceRoot ? 0 : geteuid()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == expectedOwner,
              info.st_mode & 0o077 == 0,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "invalid owned state file: \(path)"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                while true {
                    let result = Darwin.read(descriptor, raw.baseAddress, raw.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "read \(path): \(String(cString: strerror(errno)))"
                )
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "owned state file is too large: \(path)"
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == Int(info.st_size) else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "owned state file changed while reading: \(path)"
            )
        }
        return data
    }

    private func removeOwnedFile(path: String) throws {
        if unlink(path) != 0, errno != ENOENT {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unlink \(path): \(String(cString: strerror(errno)))"
            )
        }
        try syncParentDirectory(of: path)
    }

    private func syncParentDirectory(of path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(directory): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(directory): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func response(
        _ request: SourcePreservingLANRequest,
        interfaceName: String?
    ) -> SourcePreservingLANResponse {
        SourcePreservingLANResponse(
            status: "active",
            sessionID: request.sessionID,
            interfaceName: interfaceName,
            lanBindingCount: SourcePreservingLANPlan.lanBindings(from: request.bindings).count
        )
    }

    private static func validateCommon(_ request: SourcePreservingLANRequest) throws {
        guard request.version == SourcePreservingLANRequest.schemaVersion else {
            throw SourcePreservingLANPrivilegedError.unsupportedVersion(request.version)
        }
        guard request.sessionID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]{0,63}/) != nil,
              !request.sessionID.contains(".."),
              request.bindings.count <= 4_096 else {
            throw SourcePreservingLANPrivilegedError.invalidSessionID
        }
    }

    private static func validateGVProxySocket(_ path: String, clientUID: uid_t) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SourcePreservingLANPrivilegedError.invalidSocketPath
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            throw SourcePreservingLANPrivilegedError.socketUnavailable(path)
        }
        guard info.st_uid == clientUID else {
            throw SourcePreservingLANPrivilegedError.socketOwnerMismatch(
                expected: clientUID,
                actual: info.st_uid
            )
        }
    }

    private static func writeAnchor(_ contents: String) throws {
        let marker = Data("# Managed by Dory. Do not edit.\n".utf8)
        let directory = (anchorPath as NSString).deletingLastPathComponent
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == 0,
              directoryInfo.st_mode & 0o022 == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unsafe PF anchor directory: \(directory)"
            )
        }
        let existing = open(anchorPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            defer { close(existing) }
            var info = stat()
            guard fstat(existing, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1,
                  info.st_uid == 0,
                  info.st_size >= marker.count,
                  info.st_size <= 1 << 20 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "unsafe existing PF anchor: \(anchorPath)"
                )
            }
            var prefix = [UInt8](repeating: 0, count: marker.count)
            var offset = 0
            while offset < prefix.count {
                let remaining = prefix.count - offset
                let count = prefix.withUnsafeMutableBytes { raw in
                    while true {
                        let result = Darwin.read(
                            existing,
                            raw.baseAddress?.advanced(by: offset),
                            remaining
                        )
                        if result < 0, errno == EINTR { continue }
                        return result
                    }
                }
                guard count > 0 else {
                    throw SourcePreservingLANPrivilegedError.commandFailed(
                        "read \(anchorPath): \(String(cString: strerror(errno)))"
                    )
                }
                offset += count
            }
            guard Data(prefix) == marker else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "refusing to replace a PF anchor not owned by Dory"
                )
            }
        } else if errno != ENOENT {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(anchorPath): \(String(cString: strerror(errno)))"
            )
        }

        let temporary = "\(anchorPath).tmp.\(UUID().uuidString)"
        let bytes = Array(contents.utf8)
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            _ = unlink(temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "chmod \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                while true {
                    let result = Darwin.write(
                        descriptor,
                        raw.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard written > 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "write \(temporary): \(String(cString: strerror(errno)))"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(Self.anchorPath): \(String(cString: strerror(errno)))"
            )
        }
        close(descriptor)
        descriptorOpen = false
        guard rename(temporary, anchorPath) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "rename \(temporary): \(String(cString: strerror(errno)))"
            )
        }
        let directoryDescriptor = open(directory, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(directory): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(directory): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func runCommand(_ command: [String]) throws -> String {
        do {
            return try DoryShell.run(command[0], Array(command.dropFirst()))
        } catch {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "\(command.joined(separator: " ")): \(error)"
            )
        }
    }
}
