import Darwin
import Foundation

public struct VmmReadyMessage: Sendable, Equatable, Codable {
    public var machineID: String
    public var agentBuild: String?
    public var agentSocketPath: String?
    public var dockerdSocketPath: String?
    public var shellSocketPath: String?
    public var controlSocketPath: String?
    public var detail: String?

    public init(
        machineID: String,
        agentBuild: String? = nil,
        agentSocketPath: String? = nil,
        dockerdSocketPath: String? = nil,
        shellSocketPath: String? = nil,
        controlSocketPath: String? = nil,
        detail: String? = nil
    ) {
        self.machineID = machineID
        self.agentBuild = agentBuild
        self.agentSocketPath = agentSocketPath
        self.dockerdSocketPath = dockerdSocketPath
        self.shellSocketPath = shellSocketPath
        self.controlSocketPath = controlSocketPath
        self.detail = detail
    }
}

public final class VmmHandoff: @unchecked Sendable {
    public let ready: VmmReadyMessage
    public let fileDescriptors: [Int32]

    public init(ready: VmmReadyMessage, fileDescriptors: [Int32]) {
        self.ready = ready
        self.fileDescriptors = fileDescriptors
    }

    deinit {
        for fd in fileDescriptors {
            close(fd)
        }
    }
}

public enum VmmHandoffError: Error, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)
    case emptyMessage
    case invalidJSON(String)

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            return "handoff socket path is too long: \(path)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        case .emptyMessage:
            return "empty VMM handoff message"
        case let .invalidJSON(message):
            return "invalid VMM handoff JSON: \(message)"
        }
    }
}

public final class VmmHandoffServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Result<VmmHandoff, Error>) -> Void

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var queue: DispatchQueue?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenerFD >= 0
    }

    public func start() throws {
        lock.lock()
        guard listenerFD < 0 else {
            lock.unlock()
            return
        }
        lock.unlock()

        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmHandoffError.syscall("socket", errno) }

        do {
            var address = try Self.unixAddress(path: path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw VmmHandoffError.syscall("bind", errno) }
            chmod(path, 0o600)
            guard listen(fd, 1) == 0 else { throw VmmHandoffError.syscall("listen", errno) }

            let queue = DispatchQueue(label: "dev.dory.doryd.vmm-handoff.\(fd)")
            lock.lock()
            listenerFD = fd
            self.queue = queue
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptOne(listenerFD: fd)
            }
        } catch {
            close(fd)
            unlink(path)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        queue = nil
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    private func acceptOne(listenerFD: Int32) {
        let accepted = accept(listenerFD, nil, nil)
        if accepted < 0 {
            lock.lock()
            let wasRunning = self.listenerFD == listenerFD
            lock.unlock()
            if wasRunning {
                handler(.failure(VmmHandoffError.syscall("accept", errno)))
            }
            return
        }
        defer { close(accepted) }

        do {
            let handoff = try Self.receive(from: accepted)
            handler(.success(handoff))
        } catch {
            handler(.failure(error))
        }
    }

    private static func receive(from fd: Int32) throws -> VmmHandoff {
        var data = [UInt8](repeating: 0, count: 16 * 1024)
        var control = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size * 8))
        let dataCapacity = data.count
        let controlCapacity = control.count
        var controlLength = 0
        let received: ssize_t = try data.withUnsafeMutableBytes { dataBuffer in
            try control.withUnsafeMutableBytes { controlBuffer in
                var iov = iovec(iov_base: dataBuffer.baseAddress, iov_len: dataCapacity)
                return try withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: iovPointer,
                        msg_iovlen: 1,
                        msg_control: controlBuffer.baseAddress,
                        msg_controllen: socklen_t(controlCapacity),
                        msg_flags: 0
                    )
                    let count = recvmsg(fd, &message, 0)
                    guard count >= 0 else { throw VmmHandoffError.syscall("recvmsg", errno) }
                    controlLength = Int(message.msg_controllen)
                    return count
                }
            }
        }
        guard received > 0 else { throw VmmHandoffError.emptyMessage }

        let payload = Data(data.prefix(Int(received)))
        let ready: VmmReadyMessage
        do {
            ready = try JSONDecoder().decode(VmmReadyMessage.self, from: payload)
        } catch {
            throw VmmHandoffError.invalidJSON("\(error)")
        }
        return VmmHandoff(ready: ready, fileDescriptors: fileDescriptors(from: Array(control.prefix(controlLength))))
    }

    fileprivate static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw VmmHandoffError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        return address
    }

    deinit {
        stop()
    }
}

public enum VmmHandoffClient {
    public static func send(
        path: String,
        ready: VmmReadyMessage,
        fileDescriptors: [Int32] = []
    ) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VmmHandoffError.syscall("socket", errno) }
        defer { close(fd) }

        var address = try VmmHandoffServer.unixAddress(path: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VmmHandoffError.syscall("connect", errno)
        }

        let payload = Array(try JSONEncoder().encode(ready))
        let fdBytes = fileDescriptors.count * MemoryLayout<Int32>.size
        var control = [UInt8](repeating: 0, count: fileDescriptors.isEmpty ? 0 : cmsgSpace(fdBytes))
        let controlCount = control.count
        let sent: ssize_t = payload.withUnsafeBytes { payloadRaw in
            control.withUnsafeMutableBytes { controlRaw in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: payloadRaw.baseAddress),
                    iov_len: payload.count
                )
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: iovPointer,
                        msg_iovlen: 1,
                        msg_control: fileDescriptors.isEmpty ? nil : controlRaw.baseAddress,
                        msg_controllen: fileDescriptors.isEmpty ? 0 : socklen_t(controlCount),
                        msg_flags: 0
                    )
                    if !fileDescriptors.isEmpty {
                        let headerLength = cmsgLen(fdBytes)
                        let header = cmsghdr(
                            cmsg_len: socklen_t(headerLength),
                            cmsg_level: SOL_SOCKET,
                            cmsg_type: SCM_RIGHTS
                        )
                        controlRaw.storeBytes(of: header, as: cmsghdr.self)
                        fileDescriptors.withUnsafeBytes { fdRaw in
                            controlRaw.baseAddress!
                                .advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
                                .copyMemory(from: fdRaw.baseAddress!, byteCount: fdBytes)
                        }
                    }
                    return sendmsg(fd, &message, 0)
                }
            }
        }
        guard sent == payload.count else {
            throw VmmHandoffError.syscall("sendmsg", errno)
        }
    }
}

private func fileDescriptors(from control: [UInt8]) -> [Int32] {
    var descriptors: [Int32] = []
    control.withUnsafeBytes { raw in
        var offset = 0
        while offset + MemoryLayout<cmsghdr>.size <= raw.count {
            let header = raw.load(fromByteOffset: offset, as: cmsghdr.self)
            let headerLength = Int(header.cmsg_len)
            guard headerLength >= MemoryLayout<cmsghdr>.size,
                  offset + headerLength <= raw.count else {
                break
            }
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                let dataOffset = offset + cmsgAlign(MemoryLayout<cmsghdr>.size)
                let dataLength = headerLength - cmsgAlign(MemoryLayout<cmsghdr>.size)
                let count = max(0, dataLength / MemoryLayout<Int32>.size)
                for index in 0..<count {
                    descriptors.append(raw.load(fromByteOffset: dataOffset + index * MemoryLayout<Int32>.size, as: Int32.self))
                }
            }
            offset += cmsgAlign(headerLength)
        }
    }
    return descriptors
}

private func cmsgAlign(_ length: Int) -> Int {
    let alignment = MemoryLayout<cmsghdr>.alignment
    return (length + alignment - 1) & ~(alignment - 1)
}

private func cmsgSpace(_ length: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(length)
}

private func cmsgLen(_ length: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + length
}
