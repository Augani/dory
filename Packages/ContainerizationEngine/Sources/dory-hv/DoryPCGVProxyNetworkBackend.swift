import Darwin
import DoryCore
import DoryHV
import DoryOperations
import DoryVirtio
import Foundation

enum DoryPCGVProxyNetworkError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            "invalid DoryPC gvproxy configuration: \(detail)"
        case .systemCall(let operation, let code):
            "DoryPC gvproxy \(operation) failed: errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// Connected vfkit Ethernet endpoint shared by DoryPC's transport-neutral VirtIO-net device and
/// the existing gvproxy process. One Unix datagram is exactly one Ethernet frame.
final class DoryPCGVProxyNetworkBackend: DoryVirtioNetworkBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let descriptor: Int32
    private let ownedPaths: [String]
    private let process: Process?
    private let receiveSource: any DispatchSourceRead
    private let receiveQueue: DispatchQueue
    private let receiveQueueKey = DispatchSpecificKey<Bool>()
    private let portForwardReconciler: ResolvedPortForwardReconciler?
    private let receiveCompletion = DispatchSemaphore(value: 0)
    private let stopCompletion: DispatchGroup = {
        let completion = DispatchGroup()
        completion.enter()
        return completion
    }()
    private let maximumFrameBytes: Int
    private var receiveSink: (@Sendable ([UInt8]) -> Void)?
    private var stopSink: (@Sendable () -> Void)?
    private var receiveEpoch = UUID()
    private var stopped = false
    static let maximumReceiveDatagramsPerTurn = 64
    var isStopped: Bool { lock.withLock { stopped } }
    var receiveGeneration: UUID { lock.withLock { receiveEpoch } }

    init(
        gvproxyPath: String,
        stateDirectory: String,
        attachment: DoryVirtualMachineNetworkAttachmentMode,
        interface: DoryVirtualMachineNetworkInterfaceCapabilityRequest,
        portForwards: [DoryVMPortForward]
    ) throws {
        guard attachment == .sharedNAT || attachment == .isolated else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration(
                "attachment must be shared-nat or isolated"
            )
        }
        guard interface.isValid else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration("network identity is invalid")
        }
        guard let resolvedPortForwards = PublishedPortForwardPlan.resolvedForwards(
            portForwards,
            guestIP: "192.168.127.2"
        ), attachment == .sharedNAT
            || !portForwards.contains(where: { $0.exposure == .lan }) else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration(
                "resolved port-forward contract is invalid for the network attachment"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: gvproxyPath) else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration("gvproxy is not executable")
        }
        let local = stateDirectory + "/dorypc-vm.sock"
        let datapath = stateDirectory + "/dorypc-gv.sock"
        let api = stateDirectory + "/dorypc-api.sock"
        let yaml = stateDirectory + "/dorypc-network.yaml"
        for path in [local, datapath, api] {
            try Self.validateSocketPath(path)
            unlink(path)
        }
        let configuration = GVProxyDesktopLaunchPlan.configurationYAML(
            hostOnly: attachment == .isolated,
            guestMAC: interface.macAddress
        )
        try configuration.write(toFile: yaml, atomically: true, encoding: .utf8)
        chmod(yaml, 0o600)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: gvproxyPath)
        child.arguments = GVProxyDesktopLaunchPlan.arguments(
            mtu: Int(interface.maximumTransmissionUnit),
            datapathSocket: datapath,
            apiSocket: api,
            configurationPath: yaml
        )
        child.standardOutput = FileHandle.standardError
        child.standardError = FileHandle.standardError
        try child.run()
        var pendingDescriptor: Int32 = -1
        var pendingReconciler: ResolvedPortForwardReconciler?
        do {
            try Self.waitForSocket(datapath, child: child)
            pendingDescriptor = try Self.connect(localPath: local, remotePath: datapath)
            try Self.publishResolvedPortForwards(
                resolvedPortForwards,
                apiSocketPath: api
            )
            let reconciler = resolvedPortForwards.isEmpty ? nil
                : ResolvedPortForwardReconciler(
                    desired: resolvedPortForwards,
                    apiSocketPath: api,
                    log: { message in
                        FileHandle.standardError.write(
                            Data("dory-hv DoryPC network: \(message)\n".utf8)
                        )
                    }
                )
            pendingReconciler = reconciler
            guard reconciler?.reconcileNow() != false else {
                throw DoryPCGVProxyNetworkError.invalidConfiguration(
                    "gvproxy did not retain the resolved port-forward registry"
                )
            }
            reconciler?.start()
            let descriptor = pendingDescriptor
            self.descriptor = descriptor
            ownedPaths = [local, datapath, api, yaml]
            process = child
            portForwardReconciler = reconciler
            maximumFrameBytes = Int(interface.maximumTransmissionUnit) + 18
            let queue = DispatchQueue(
                label: "dev.dory.dory-hv.dorypc.network.receive", qos: .userInitiated
            )
            receiveQueue = queue
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            receiveSource = source
            queue.setSpecific(key: receiveQueueKey, value: true)
            source.setEventHandler { [weak self] in self?.drainReceive() }
            source.setCancelHandler { [descriptor, receiveCompletion] in
                Darwin.close(descriptor)
                receiveCompletion.signal()
            }
            source.resume()
            pendingDescriptor = -1
            pendingReconciler = nil
        } catch {
            pendingReconciler?.stop()
            if pendingDescriptor >= 0 { Darwin.close(pendingDescriptor) }
            ChildProcessTerminator.terminateAndReap(child)
            for path in [local, datapath, api, yaml] { unlink(path) }
            throw error
        }
    }

    /// Takes ownership of an already-connected Unix datagram endpoint without spawning gvproxy.
    /// Kept internal for isolated lifetime tests and alternative local datapath provisioning.
    init(connectedDescriptor: Int32, maximumFrameBytes: Int) throws {
        guard connectedDescriptor >= 0, (14...65_553).contains(maximumFrameBytes) else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration("invalid connected endpoint")
        }
        guard fcntl(connectedDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(connectedDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw DoryPCGVProxyNetworkError.systemCall("configure connected endpoint", errno)
        }
        descriptor = connectedDescriptor
        ownedPaths = []
        process = nil
        portForwardReconciler = nil
        self.maximumFrameBytes = maximumFrameBytes
        let queue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.network.receive", qos: .userInitiated
        )
        receiveQueue = queue
        let source = DispatchSource.makeReadSource(fileDescriptor: connectedDescriptor, queue: queue)
        receiveSource = source
        queue.setSpecific(key: receiveQueueKey, value: true)
        source.setEventHandler { [weak self] in self?.drainReceive() }
        source.setCancelHandler { [connectedDescriptor, receiveCompletion] in
            Darwin.close(connectedDescriptor)
            receiveCompletion.signal()
        }
        source.resume()
    }

    func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
        let replacement = UUID()
        let admitted = lock.withLock {
            guard !stopped else { return false }
            // Revoke before joining. Otherwise the old reader could repeatedly reacquire the
            // delivery gate and continue delivering queued packets while replacement waits.
            receiveEpoch = replacement
            receiveSink = nil
            return true
        }
        guard admitted else { return }
        let published = deliveryLock.withLock {
            lock.withLock {
                guard !stopped, receiveEpoch == replacement else { return false }
                receiveSink = sink
                return true
            }
        }
        if published { receiveQueue.async { [weak self] in self?.drainReceive() } }
    }

    func connectStopSink(_ sink: @escaping @Sendable () -> Void) {
        let registration = lock.withLock {
            guard !stopped else { return (true, Optional<@Sendable () -> Void>.none) }
            let previous = stopSink
            stopSink = sink
            return (false, previous)
        }
        // A new semantic device may replace a connection, but the previous one cannot retain
        // transmit authority or DMA after the replacement registration returns.
        registration.1?()
        if registration.0 { sink() }
    }

    func transmit(frame: [UInt8]) throws {
        guard (14...maximumFrameBytes).contains(frame.count) else {
            throw DoryVirtioNetworkError.invalidFrameLength(frame.count)
        }
        let result: (Int, Int32) = lock.withLock {
            guard !stopped else { return (-1, ENOTCONN) }
            return frame.withUnsafeBytes {
                let count = Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                return (count, count < 0 ? errno : 0)
            }
        }
        guard result.0 == frame.count else {
            throw DoryPCGVProxyNetworkError.systemCall(
                "transmit",
                result.0 < 0 ? result.1 : EIO
            )
        }
    }

    /// True means the receive source, guest delivery, and child have all been joined. Reentrant
    /// calls from a receive callback revoke immediately, but finish off-queue and return false.
    @discardableResult
    func stop() -> Bool {
        let ownsStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            receiveEpoch = UUID()
            receiveSink = nil
            return true
        }
        let onReceiveQueue = DispatchQueue.getSpecific(key: receiveQueueKey) == true
        guard ownsStop else {
            // A receive failure, host signal, and the AppKit cleanup path may converge here. The
            // first caller owns teardown; every other caller must wait for it rather than letting
            // the runner exit while that queue still holds an unreaped gvproxy child.
            guard !onReceiveQueue else { return false }
            stopCompletion.wait()
            return true
        }
        guard !onReceiveQueue else {
            DispatchQueue.global(qos: .utility).async { self.finishStop() }
            return false
        }
        finishStop()
        return true
    }

    private func finishStop() {
        defer { stopCompletion.leave() }
        // The socket state is revoked first. Join any sink that already passed admission before
        // retiring its semantic device, then wait for cancellation to close the exact descriptor.
        deliveryLock.withLock {}
        let retiringSink = lock.withLock {
            let sink = stopSink
            stopSink = nil
            return sink
        }
        retiringSink?()
        receiveSource.cancel()
        receiveCompletion.wait()
        retireResources()
    }

    private func retireResources() {
        portForwardReconciler?.stop()
        if let process { ChildProcessTerminator.terminateAndReap(process) }
        for path in ownedPaths { unlink(path) }
    }

    deinit {
        if DispatchQueue.getSpecific(key: receiveQueueKey) == true {
            // The event handler's temporary strong reference can be the last owner. Never
            // resurrect self from deinit or wait for cancellation on the cancellation queue.
            // That handler has returned before deinit runs; cancellation owns the descriptor.
            let retirement = lock.withLock {
                guard !stopped else { return (false, Optional<@Sendable () -> Void>.none) }
                stopped = true
                receiveEpoch = UUID()
                receiveSink = nil
                let sink = stopSink
                stopSink = nil
                return (true, sink)
            }
            if retirement.0 {
                retirement.1?()
                receiveSource.cancel()
                retireResources()
                stopCompletion.leave()
            }
        } else {
            stop()
        }
    }

    private func drainReceive() {
        // Invalid/oversized datagrams and EINTR consume the same bounded turn quota as valid
        // traffic. A hostile sender cannot monopolize the serial cancellation queue.
        for _ in 0..<Self.maximumReceiveDatagramsPerTurn {
            let result: (frame: [UInt8]?, code: Int32, epoch: UUID) = lock.withLock {
                guard !stopped else { return (nil, ECANCELED, receiveEpoch) }
                var bytes = [UInt8](repeating: 0, count: maximumFrameBytes + 1)
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                }
                guard count >= 0 else { return (nil, errno, receiveEpoch) }
                bytes.removeSubrange(Int(count)..<bytes.count)
                return (bytes, 0, receiveEpoch)
            }
            if let frame = result.frame {
                guard (14...maximumFrameBytes).contains(frame.count) else { continue }
                deliveryLock.withLock {
                    let sink = lock.withLock {
                        !stopped && receiveEpoch == result.epoch ? receiveSink : nil
                    }
                    sink?(frame)
                }
                continue
            }
            if result.code == EINTR { continue }
            if result.code == EAGAIN || result.code == EWOULDBLOCK || result.code == ECANCELED {
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.stop() }
            return
        }
    }

    private static func connect(localPath: String, remotePath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw DoryPCGVProxyNetworkError.systemCall("socket", errno)
        }
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw DoryPCGVProxyNetworkError.systemCall("configure socket", errno)
            }
            var local = try unixAddress(localPath)
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(localPath, 0o600) == 0 else {
                throw DoryPCGVProxyNetworkError.systemCall("bind socket", errno)
            }
            var remote = try unixAddress(remotePath)
            let connected = withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw DoryPCGVProxyNetworkError.systemCall("connect socket", errno)
            }
            let handshake = Array("VFKT".utf8)
            let sent = handshake.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard sent == handshake.count else {
                throw DoryPCGVProxyNetworkError.systemCall(
                    "vfkit handshake",
                    sent < 0 ? errno : EIO
                )
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            unlink(localPath)
            throw error
        }
    }

    private static func waitForSocket(_ path: String, child: Process) throws {
        for _ in 0..<200 {
            guard child.isRunning else {
                throw DoryPCGVProxyNetworkError.invalidConfiguration(
                    "gvproxy exited before publishing its datapath"
                )
            }
            var status = stat()
            if lstat(path, &status) == 0,
               status.st_mode & S_IFMT == S_IFSOCK,
               status.st_uid == geteuid() { return }
            usleep(25_000)
        }
        throw DoryPCGVProxyNetworkError.invalidConfiguration(
            "gvproxy did not publish its datapath before the deadline"
        )
    }

    private static func publishResolvedPortForwards(
        _ forwards: Set<PublishedPortForward>,
        apiSocketPath: String
    ) throws {
        for forward in forwards.sorted(by: portForwardOrder) {
            let bodyData = try JSONSerialization.data(withJSONObject: [
                "local": forward.localEndpoint,
                "remote": forward.remoteEndpoint,
                "protocol": forward.protocol.rawValue,
            ])
            guard let body = String(data: bodyData, encoding: .utf8) else {
                throw DoryPCGVProxyNetworkError.invalidConfiguration(
                    "could not encode a resolved gvproxy forward"
                )
            }
            var published = false
            for _ in 0..<100 {
                let curl = Process()
                curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curl.arguments = [
                    "--fail", "--silent", "--show-error",
                    "--connect-timeout", "1", "--max-time", "1",
                    "--unix-socket", apiSocketPath,
                    "--request", "POST",
                    "--data-binary", body,
                    "http://gvproxy/services/forwarder/expose",
                ]
                curl.standardOutput = FileHandle.nullDevice
                curl.standardError = FileHandle.nullDevice
                if (try? curl.run()) != nil {
                    curl.waitUntilExit()
                    if curl.terminationStatus == 0 {
                        published = true
                        break
                    }
                }
                usleep(20_000)
            }
            guard published else {
                throw DoryPCGVProxyNetworkError.invalidConfiguration(
                    "gvproxy could not publish \(forward.localEndpoint)/\(forward.protocol.rawValue)"
                )
            }
        }
    }

    private static func portForwardOrder(
        _ lhs: PublishedPortForward,
        _ rhs: PublishedPortForward
    ) -> Bool {
        if lhs.protocol != rhs.protocol {
            return lhs.protocol.rawValue < rhs.protocol.rawValue
        }
        if lhs.localHost != rhs.localHost { return lhs.localHost < rhs.localHost }
        return lhs.localPort < rhs.localPort
    }

    private static func validateSocketPath(_ path: String) throws {
        guard path.hasPrefix("/"),
              !path.utf8.contains(0),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw DoryPCGVProxyNetworkError.invalidConfiguration("Unix socket path is invalid")
        }
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        try validateSocketPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: path.utf8)
        }
        return address
    }
}
