import Darwin
import Foundation

/// Bidirectional, private serial console for EFI installers and recovery boots.
///
/// Virtualization.framework receives one end of a socket pair. The host end is multiplexed to the
/// durable serial log and one local Unix-socket client, so diagnostics remain available even when
/// no terminal is attached. The socket is user-only and lives inside Dory's short runtime directory
/// because Darwin Unix-domain socket paths have a small fixed limit.
final class DoryVMMSerialConsole: @unchecked Sendable {
    let guestInput: FileHandle
    let guestOutput: FileHandle

    private let hostInputDescriptor: Int32
    private let hostOutputDescriptor: Int32
    private let listenerDescriptor: Int32
    private let log: FileHandle
    private let socketPath: String
    private let queue = DispatchQueue(label: "dev.dory.dory-vmm.serial-console")
    private let lock = NSLock()
    private var running = true
    private var clientDescriptor: Int32 = -1

    init(socketPath: String, log: FileHandle) throws {
        self.socketPath = socketPath
        self.log = log

        var inputPair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0 else {
            throw DoryVZMachineError.syscall("socketpair serial console input", errno)
        }
        var outputPair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &outputPair) == 0 else {
            close(inputPair[0])
            close(inputPair[1])
            throw DoryVZMachineError.syscall("socketpair serial console output", errno)
        }
        let hostInput = inputPair[0]
        let input = inputPair[1]
        let hostOutput = outputPair[0]
        let output = outputPair[1]

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            close(input)
            close(output)
            close(hostInput)
            close(hostOutput)
            throw DoryVZMachineError.syscall("socket serial console", errno)
        }

        do {
            try Self.configureDescriptor(hostInput, nonblocking: true)
            try Self.configureDescriptor(hostOutput, nonblocking: true)
            try Self.configureDescriptor(input, nonblocking: false)
            try Self.configureDescriptor(output, nonblocking: false)
            try Self.configureDescriptor(listener, nonblocking: true)
            try Self.bind(listener: listener, path: socketPath)
        } catch {
            close(listener)
            close(input)
            close(output)
            close(hostInput)
            close(hostOutput)
            throw error
        }

        hostInputDescriptor = hostInput
        hostOutputDescriptor = hostOutput
        listenerDescriptor = listener
        guestInput = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        guestOutput = FileHandle(fileDescriptor: output, closeOnDealloc: true)

        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let client = clientDescriptor
        clientDescriptor = -1
        lock.unlock()

        if client >= 0 {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        shutdown(listenerDescriptor, SHUT_RDWR)
        close(listenerDescriptor)
        shutdown(hostInputDescriptor, SHUT_RDWR)
        close(hostInputDescriptor)
        shutdown(hostOutputDescriptor, SHUT_RDWR)
        close(hostOutputDescriptor)
        try? guestInput.close()
        try? guestOutput.close()
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while isRunning {
            let client = currentClient
            var descriptors = [
                pollfd(fd: hostOutputDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            if client >= 0 {
                descriptors.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0))
            }

            let result = poll(&descriptors, nfds_t(descriptors.count), 250)
            if result < 0 {
                if errno == EINTR { continue }
                break
            }
            if result == 0 { continue }

            if descriptors[1].revents & Int16(POLLIN) != 0 {
                acceptClient()
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let count = Darwin.read(hostOutputDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    try? log.write(contentsOf: data)
                    forwardToClient(buffer: &buffer, count: count)
                } else if count == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    break
                }
            }
            if descriptors.count == 3, descriptors[2].revents & Int16(POLLIN) != 0 {
                let count = Darwin.read(client, &buffer, buffer.count)
                if count > 0 {
                    sendAll(descriptor: hostInputDescriptor, buffer: &buffer, count: count)
                } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    disconnectClient(client)
                }
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private var currentClient: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return clientDescriptor
    }

    private func acceptClient() {
        let accepted = accept(listenerDescriptor, nil, nil)
        guard accepted >= 0 else { return }
        do {
            try Self.configureDescriptor(accepted, nonblocking: true)
        } catch {
            close(accepted)
            return
        }

        lock.lock()
        let previous = clientDescriptor
        clientDescriptor = accepted
        lock.unlock()
        if previous >= 0 {
            shutdown(previous, SHUT_RDWR)
            close(previous)
        }
    }

    private func disconnectClient(_ descriptor: Int32) {
        lock.lock()
        if clientDescriptor == descriptor { clientDescriptor = -1 }
        lock.unlock()
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    private func forwardToClient(buffer: inout [UInt8], count: Int) {
        let client = currentClient
        guard client >= 0 else { return }
        if !sendAll(descriptor: client, buffer: &buffer, count: count) {
            disconnectClient(client)
        }
    }

    @discardableResult
    private func sendAll(descriptor: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let sent = buffer.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset,
                    MSG_NOSIGNAL
                )
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent < 0, errno == EINTR { continue }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            }
            return false
        }
        return true
    }

    private static func configureDescriptor(_ descriptor: Int32, nonblocking: Bool) throws {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw DoryVZMachineError.syscall("fcntl serial console cloexec", errno)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(
                descriptor,
                F_SETFL,
                nonblocking ? flags | O_NONBLOCK : flags & ~O_NONBLOCK
              ) == 0 else {
            throw DoryVZMachineError.syscall("fcntl serial console flags", errno)
        }
    }

    private static func bind(listener: Int32, path: String) throws {
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw DoryVZMachineError.validation("serial console socket path is too long")
        }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(listener, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw DoryVZMachineError.syscall("bind serial console", errno)
        }
        guard chmod(path, mode_t(0o600)) == 0 else {
            throw DoryVZMachineError.syscall("chmod serial console", errno)
        }
        guard listen(listener, 1) == 0 else {
            throw DoryVZMachineError.syscall("listen serial console", errno)
        }
    }
}
