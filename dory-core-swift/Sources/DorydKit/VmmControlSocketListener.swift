import Darwin
import Foundation

/// Owns one native control listener and removes only the socket inode it bound.
public final class VmmControlSocketListener: @unchecked Sendable {
    public enum AcceptResult {
        case client(Int32)
        case retry
        case stopped
    }
    public let descriptor: Int32
    private let path: String
    private let device: dev_t
    private let inode: ino_t
    private let lock = NSLock()
    private var active = true

    public init(path: String) throws {
        var address = try Self.address(path)
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(parent, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(), directory.st_mode & 0o022 == 0 else {
            throw VmmControlError.rejected("control socket parent must be an directory owned by this user and not writable by other users")
        }
        try Self.removeStaleSocket(path, address: &address)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
        var bound: stat?
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw VmmControlError.syscall("fcntl(FD_CLOEXEC)", errno)
            }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw VmmControlError.syscall("fcntl(O_NONBLOCK)", errno)
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw VmmControlError.syscall("bind", errno) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw VmmControlError.syscall("lstat", errno) }
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
                throw VmmControlError.rejected("control socket changed during bind")
            }
            bound = info
            guard chmod(path, 0o600) == 0 else { throw VmmControlError.syscall("chmod", errno) }
            guard listen(fd, 16) == 0 else { throw VmmControlError.syscall("listen", errno) }
            descriptor = fd
            self.path = path
            device = info.st_dev
            inode = info.st_ino
        } catch {
            close(fd)
            if let bound { Self.removeIfMatching(path, device: bound.st_dev, inode: bound.st_ino) }
            throw error
        }
    }

    /// Serialize poll/accept with close so descriptor reuse cannot cross listener lifetimes.
    /// The short poll bounds how long stop must wait; accept itself is nonblocking.
    public func acceptClient() throws -> AcceptResult {
        try lock.withLock {
            guard active else { return .stopped }
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { return .retry }
            guard ready > 0 else { throw VmmControlError.syscall("poll", errno) }
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .retry }
                throw VmmControlError.syscall("accept", errno)
            }
            return .client(client)
        }
    }

    public func stop() {
        lock.withLock {
            guard active else { return }
            active = false
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            Self.removeIfMatching(path, device: device, inode: inode)
        }
    }

    private static func removeStaleSocket(_ path: String, address: inout sockaddr_un) throws {
        var existing = stat()
        if lstat(path, &existing) != 0 {
            guard errno == ENOENT else { throw VmmControlError.syscall("lstat", errno) }
            return
        }
        guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
            throw VmmControlError.rejected("control path is not an owned socket")
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw VmmControlError.syscall("socket", errno) }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
            throw VmmControlError.syscall("fcntl(O_NONBLOCK)", errno)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result < 0, errno == ECONNREFUSED else {
            throw VmmControlError.rejected("control socket is already active or cannot be proven stale")
        }
        removeIfMatching(path, device: existing.st_dev, inode: existing.st_ino)
    }

    private static func removeIfMatching(_ path: String, device: dev_t, inode: ino_t) {
        var current = stat()
        guard lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
              current.st_uid == geteuid(), current.st_dev == device, current.st_ino == inode else { return }
        unlink(path)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        // Validate lexical components without Foundation's filesystem-dependent /private
        // rewriting: an abandoned socket must retain the exact pathname whose inode we own.
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw VmmControlError.rejected("invalid control socket path")
        }
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw VmmControlError.pathTooLong(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    deinit { stop() }
}
