import Darwin
import Foundation

/// Bridges the guest's well-known SSH-agent vsock port to the current user's macOS SSH agent.
///
/// Host Unix sockets are deliberately not exposed as ordinary virtio-fs inodes: Linux can apply
/// special-file semantics before FUSE receives an OPEN, and cross-kernel AF_UNIX connections cannot
/// be represented safely by a filesystem lookup. The guest agent instead owns a normal Linux Unix
/// socket at `/run/host-services/ssh-auth.sock` and opens one vsock stream here per client.
public final class HostSSHAgentBridge: @unchecked Sendable {
    public enum ConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
        case relativePath(String)
        case embeddedNull(String)
        case pathTooLong(path: String, utf8ByteCount: Int, maximumUTF8ByteCount: Int)

        public var description: String {
            switch self {
            case .relativePath(let path): "SSH agent socket path must be absolute: \(path)"
            case .embeddedNull(let path): "SSH agent socket path contains a NUL byte: \(path)"
            case let .pathTooLong(path, count, maximum):
                "SSH agent socket path is \(count) UTF-8 bytes (maximum \(maximum)): \(path)"
            }
        }
    }

    private let socketPath: String
    private let expectedUID: uid_t
    private let log: @Sendable (String) -> Void
    private let lifecycle: BoundedGuestVsockServiceLifecycle

    public init(
        socketPath: String,
        expectedUID: uid_t = geteuid(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try Self.validate(socketPath: socketPath)
        self.socketPath = socketPath
        self.expectedUID = expectedUID
        self.log = log
        self.lifecycle = BoundedGuestVsockServiceLifecycle(
            endpointLabel: "SSH agent bridge",
            log: log
        )
    }

    public static func validate(socketPath: String) throws {
        guard socketPath.hasPrefix("/") else {
            throw ConfigurationError.relativePath(socketPath)
        }
        let bytes = Array(socketPath.utf8)
        guard !bytes.contains(0) else {
            throw ConfigurationError.embeddedNull(socketPath)
        }
        guard bytes.count <= VsockUnixRelay.maximumSocketPathByteCount else {
            throw ConfigurationError.pathTooLong(
                path: socketPath,
                utf8ByteCount: bytes.count,
                maximumUTF8ByteCount: VsockUnixRelay.maximumSocketPathByteCount
            )
        }
    }

    public func attach(to vsock: VirtioVsock) throws {
        try lifecycle.beginAttachment(to: vsock)
        var unregister = [@Sendable () -> Void]()
        do {
            let socketPath = self.socketPath
            let expectedUID = self.expectedUID
            let log = self.log
            let registration = try vsock.registerServiceListener(
                port: VsockPorts.sshAgent,
                service: .sshAgent
            ) { [weak lifecycle] connection in
                guard let lifecycle else {
                    connection.close()
                    return
                }
                lifecycle.admit(connection) { connection, completion in
                    GuestVsockHostSocketRelaySession(
                        connection: connection,
                        connector: { session in
                            let descriptor = Self.connectSameUserSocket(
                                path: socketPath,
                                expectedUID: expectedUID,
                                context: session
                            )
                            if descriptor == nil {
                                log(
                                    "SSH agent bridge rejected an unavailable or "
                                        + "non-owned host socket"
                                )
                            }
                            return descriptor
                        },
                        completion: completion
                    )
                }
            }
            unregister.append { registration.close() }
            guard lifecycle.commitAttachment(unregister: unregister) else {
                throw VMError.invalidConfiguration(
                    "SSH agent bridge stopped while attaching"
                )
            }
        } catch {
            lifecycle.cancelAttachment(unregister: unregister)
            throw error
        }
        log("SSH agent bridge ready on guest vsock:\(VsockPorts.sshAgent)")
    }

    public func stop(timeout: TimeInterval = 1) {
        lifecycle.stop(timeout: timeout)
    }

    public var activeSessionCount: Int {
        lifecycle.activeSessionCount
    }

    public var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot? {
        lifecycle.serviceAdmissionSnapshot
    }

    deinit {
        lifecycle.stop()
    }

    static func connectSameUserSocket(
        path: String,
        expectedUID: uid_t,
        timeoutMilliseconds: Int32 = 2_000
    ) -> Int32? {
        connectSameUserSocket(
            path: path,
            expectedUID: expectedUID,
            timeoutMilliseconds: timeoutMilliseconds,
            context: UncancelledHostSocketConnectContext()
        )
    }

    private static func connectSameUserSocket(
        path: String,
        expectedUID: uid_t,
        timeoutMilliseconds: Int32 = 2_000,
        context: any BoundedHostSocketConnectContext
    ) -> Int32? {
        let pathBytes = Array(path.utf8)
        guard path.hasPrefix("/"),
              !pathBytes.contains(0),
              pathBytes.count <= VsockUnixRelay.maximumSocketPathByteCount else {
            return nil
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_uid == expectedUID else {
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: pathBytes.count
                )
            }
        }
        return BoundedHostSocketConnector.connect(
            domain: AF_UNIX,
            timeout: TimeInterval(max(0, timeoutMilliseconds)) / 1_000,
            context: context,
            initiate: { descriptor in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
            },
            verify: { descriptor in
                peerUIDMatches(descriptor: descriptor, expectedUID: expectedUID)
            }
        )
    }

    static func peerUIDMatches(descriptor: Int32, expectedUID: uid_t) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return getpeereid(descriptor, &peerUID, &peerGID) == 0
            && peerUID == expectedUID
    }
}
