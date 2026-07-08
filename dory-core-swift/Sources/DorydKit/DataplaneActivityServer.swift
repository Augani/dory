import Darwin
import Foundation

public final class DataplaneActivityServer: @unchecked Sendable {
    public enum ServerError: Error {
        case tooLong
        case syscall(String, Int32)
    }

    private let path: String
    private let idle: IdleController
    private let onWake: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "dev.dory.doryd.activity")
    private var source: DispatchSourceRead?

    public init(
        path: String,
        idle: IdleController,
        onWake: @escaping @Sendable () async -> Void
    ) {
        self.path = path
        self.idle = idle
        self.onWake = onWake
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.syscall("socket", errno) }
        do {
            try bind(fd: fd, path: path)
        } catch {
            close(fd)
            throw error
        }
        guard listen(fd, 32) == 0 else {
            let error = errno
            close(fd)
            throw ServerError.syscall("listen", error)
        }
        guard chmod(path, 0o600) == 0 else {
            let error = errno
            close(fd)
            throw ServerError.syscall("chmod", error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptAvailable(listener: fd)
        }
        readSource.setCancelHandler { [path] in
            close(fd)
            unlink(path)
        }
        source = readSource
        readSource.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func bind(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerError.tooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ServerError.syscall("bind", errno) }
    }

    private func acceptAvailable(listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            let flags = fcntl(client, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
            }
            handle(client: client)
        }
    }

    private func handle(client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.count < 4096 {
            let capacity = buffer.count
            let got = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress!, capacity)
            }
            if got > 0 {
                data.append(contentsOf: buffer.prefix(got))
                continue
            }
            if got < 0 && errno == EINTR { continue }
            break
        }
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !line.isEmpty else {
            close(client)
            return
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "begin":
            let path = parts.count >= 3 ? parts[2] : ""
            if idle.beginRequest(path: path) {
                Task {
                    await onWake()
                    Self.ackAndClose(client)
                }
            } else {
                Self.ackAndClose(client)
            }
        case "end":
            idle.endRequest()
            Self.ackAndClose(client)
        default:
            close(client)
            break
        }
    }

    private static func ackAndClose(_ client: Int32) {
        var noSigpipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout.size(ofValue: noSigpipe)))
        let bytes = Array("ok\n".utf8)
        _ = bytes.withUnsafeBytes { raw in
            Darwin.write(client, raw.baseAddress!, raw.count)
        }
        close(client)
    }

    deinit {
        stop()
    }
}
