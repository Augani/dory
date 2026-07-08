import Darwin
import Foundation

/// Binds `~/.dory/dory.sock` as an AF_UNIX listener at mode 0600. In this
/// slice doryd only binds it; serving through it is the docker slice.
public struct DorySocket {
    public let path: String
    private let directory: String

    public init(home: String = NSHomeDirectory()) {
        self.directory = home + "/.dory"
        self.path = self.directory + "/dory.sock"
    }

    public enum SocketError: Error {
        case tooLong
        case syscall(String, Int32)
        case alreadyInUse(String)
    }

    /// Create `~/.dory` (0700), remove any stale socket, bind + listen, then chmod 0600.
    public func bind() throws -> Int32 {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory, 0o700) == 0 else { throw SocketError.syscall("chmod", errno) }
        try removeStaleSocketIfNeeded()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= capacity else {
            close(fd)
            throw SocketError.tooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw SocketError.syscall("bind", error)
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let error = errno
            close(fd)
            throw SocketError.syscall("listen", error)
        }
        guard chmod(path, 0o600) == 0 else {
            let error = errno
            close(fd)
            throw SocketError.syscall("chmod", error)
        }
        return fd
    }

    private func removeStaleSocketIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if Self.canConnect(to: path) {
            throw SocketError.alreadyInUse(path)
        }
        unlink(path)
    }

    private static func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}
