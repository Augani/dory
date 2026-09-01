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
    private let descriptor: Int32
    private let localSocketPath: String
    private let datapathSocketPath: String
    private let apiSocketPath: String
    private let configurationPath: String
    private let process: Process
    private let receiveSource: any DispatchSourceRead
    private let portForwardReconciler: ResolvedPortForwardReconciler?
    private let receiveCompletion = DispatchSemaphore(value: 0)
    private let stopCompletion: DispatchGroup = {
        let completion = DispatchGroup()
        completion.enter()
        return completion
    }()
    private let maximumFrameBytes: Int
    private var receiveSink: (@Sendable ([UInt8]) -> Void)?
    private var stopped = false

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
            localSocketPath = local
            datapathSocketPath = datapath
            apiSocketPath = api
            configurationPath = yaml
            process = child
            portForwardReconciler = reconciler
            maximumFrameBytes = Int(interface.maximumTransmissionUnit) + 18
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(
                    label: "dev.dory.dory-hv.dorypc.network.receive",
                    qos: .userInitiated
                )
            )
            receiveSource = source
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

    func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
        lock.withLock { receiveSink = sink }
        drainReceive()
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

    func stop() {
        let ownsStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            receiveSink = nil
            return true
        }
        guard ownsStop else {
            // A receive failure, host signal, and the AppKit cleanup path may converge here. The
            // first caller owns teardown; every other caller must wait for it rather than letting
            // the runner exit while that queue still holds an unreaped gvproxy child.
            _ = stopCompletion.wait(timeout: .now() + 5)
            return
        }
        defer { stopCompletion.leave() }
        receiveSource.cancel()
        _ = receiveCompletion.wait(timeout: .now() + 2)
        portForwardReconciler?.stop()
        ChildProcessTerminator.terminateAndReap(process)
        for path in [localSocketPath, datapathSocketPath, apiSocketPath, configurationPath] {
            unlink(path)
        }
    }

    deinit { stop() }

    private func drainReceive() {
        while true {
            let result: (frame: [UInt8]?, code: Int32) = lock.withLock {
                guard !stopped else { return (nil, ECANCELED) }
                var bytes = [UInt8](repeating: 0, count: maximumFrameBytes + 1)
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                }
                guard count >= 0 else { return (nil, errno) }
                bytes.removeSubrange(Int(count)..<bytes.count)
                return (bytes, 0)
            }
            if let frame = result.frame {
                guard (14...maximumFrameBytes).contains(frame.count) else { continue }
                let sink = lock.withLock { receiveSink }
                sink?(frame)
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
