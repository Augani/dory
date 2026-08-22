import Darwin
import DoryCore
import DoryOperations
import Foundation
@preconcurrency import Virtualization

/// The macOS 14 VZ fallback uses the same audited dual-stack userspace network as dory-hv. Keeping
/// the addresses and daemon flags explicit here prevents Sonoma from becoming a hidden IPv4-only
/// product tier.
struct DoryVMMNativeIPv6Plan: Sendable, Equatable {
    static let containerSubnet = "fd7d:6f72:7901::/64"
    static let virtualNetwork = "fd7d:6f72:7900::/64"
    static let guestAddress = "fd7d:6f72:7900::2"
    static let hostGateway = "fd7d:6f72:7900::1"
    static let guestMAC = "5a:94:ef:e4:0c:ee"

    var hostOnly = false
    var guestMAC = Self.guestMAC

    var gvproxyYAML: String {
        let connectivity = hostOnly ? "  connectivity: host-only\n" : ""
        return """
        stack:
        \(connectivity)  ipv6Subnet: \(Self.virtualNetwork)
          ipv6GatewayIP: \(Self.hostGateway)
          dhcpStaticLeases:
            192.168.127.2: \(guestMAC)
          nat:
            "192.168.127.254": "127.0.0.1"
            "\(Self.hostGateway)": "::1"

        """
    }

    var guestSetupCommands: [String] {
        [
            "ip -6 addr replace \(Self.guestAddress)/64 dev eth0",
            "ip -6 route replace default via \(Self.hostGateway) dev eth0",
            "sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null",
        ]
    }

    var dockerDaemonArguments: String {
        "--ipv6=true --fixed-cidr-v6=\(Self.containerSubnet) --ip6tables=true"
    }
}

/// Owns the gvproxy child and a connected Unix datagram file descriptor suitable for
/// VZFileHandleNetworkDeviceAttachment. One Ethernet frame is carried per datagram using gvproxy's
/// vfkit protocol, including its compatibility handshake.
final class DoryVMMGVProxyNetwork: @unchecked Sendable {
    let attachment: VZFileHandleNetworkDeviceAttachment
    let apiSocketPath: String
    let shutdownSocketPath: String
    let lanDatapathSocketPath: String?

    private let process: Process
    private let fileHandle: FileHandle
    private let localSocketPath: String
    let datapathSocketPath: String
    private let configurationPath: String
    private let lock = NSLock()
    private var stopped = false
    private var resolvedPortForwardReconciler: ResolvedPortForwardReconciler?

    init(
        gvproxyPath: String,
        stateDirectory: String,
        networkAttachment: DoryVirtualMachineNetworkAttachmentMode = .sharedNAT,
        networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest? = nil,
        sourcePreservingLAN: Bool = false,
        resolvedPortForwards: Set<PublishedPortForward> = []
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: gvproxyPath) else {
            throw DoryVZMachineError.missingFile(gvproxyPath)
        }
        guard networkAttachment == .sharedNAT || networkAttachment == .isolated else {
            throw DoryVZMachineError.validation(
                "gvproxy implements only shared-NAT and host-only network attachments"
            )
        }
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)

        localSocketPath = stateDirectory + "/vmm-net.sock"
        datapathSocketPath = stateDirectory + "/gvproxy-vz.sock"
        lanDatapathSocketPath = sourcePreservingLAN ? stateDirectory + "/gvproxy-lan.sock" : nil
        apiSocketPath = stateDirectory + "/gvproxy-api.sock"
        shutdownSocketPath = stateDirectory + "/shutdown.sock"
        configurationPath = stateDirectory + "/gvproxy-dual-stack.yaml"
        for path in [localSocketPath, datapathSocketPath, apiSocketPath, shutdownSocketPath] + [lanDatapathSocketPath].compactMap({ $0 }) {
            try Self.validateUnixPath(path)
            unlink(path)
        }
        if let networkInterface, !networkInterface.isValid {
            throw DoryVZMachineError.validation("resolved network interface identity is invalid")
        }
        let guestMAC = networkInterface?.macAddress ?? DoryVMMNativeIPv6Plan.guestMAC
        let mtu = networkInterface.map { Int($0.maximumTransmissionUnit) }
            ?? DoryNetworkMTU.resolved()
        try DoryVMMNativeIPv6Plan(
            hostOnly: networkAttachment == .isolated,
            guestMAC: guestMAC
        ).gvproxyYAML.write(
            toFile: configurationPath,
            atomically: true,
            encoding: .utf8
        )

        let child = Process()
        child.executableURL = URL(fileURLWithPath: gvproxyPath)
        child.arguments = [
            "-mtu", String(mtu),
            "-listen-vfkit", "unixgram://\(datapathSocketPath)",
            "-listen", "unix://\(apiSocketPath)",
            "-config", configurationPath,
        ]
        if let lanDatapathSocketPath {
            child.arguments?.append(contentsOf: [
                "-listen-qemu", "unix://\(lanDatapathSocketPath)",
            ])
        }
        child.standardOutput = FileHandle.standardError
        child.standardError = FileHandle.standardError
        do {
            try child.run()
        } catch {
            throw DoryVZMachineError.validation("could not launch gvproxy: \(error)")
        }
        process = child

        do {
            var ready = false
            for _ in 0..<200 {
                guard child.isRunning else {
                    throw DoryVZMachineError.validation(
                        "gvproxy exited before creating its VZ datapath (status \(child.terminationStatus))"
                    )
                }
                let lanReady = lanDatapathSocketPath == nil
                    || FileManager.default.fileExists(atPath: lanDatapathSocketPath!)
                if FileManager.default.fileExists(atPath: datapathSocketPath), lanReady {
                    ready = true
                    break
                }
                usleep(25_000)
            }
            guard ready else {
                throw DoryVZMachineError.validation("gvproxy did not create its VZ datapath")
            }
            let descriptor = try Self.connectedDatagram(
                localPath: localSocketPath,
                remotePath: datapathSocketPath
            )
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            fileHandle = handle
            let networkAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
            networkAttachment.maximumTransmissionUnit = Int(mtu)
            attachment = networkAttachment
            try Self.publishUnixForward(
                localPath: shutdownSocketPath,
                guestPort: 2377,
                apiSocketPath: apiSocketPath
            )
            for forward in resolvedPortForwards.sorted(by: Self.portForwardOrder) {
                try Self.publishIPForward(forward, apiSocketPath: apiSocketPath)
            }
            if !resolvedPortForwards.isEmpty {
                let reconciler = ResolvedPortForwardReconciler(
                    desired: resolvedPortForwards,
                    apiSocketPath: apiSocketPath,
                    log: { message in
                        FileHandle.standardError.write(Data("dory-vmm: \(message)\n".utf8))
                    }
                )
                resolvedPortForwardReconciler = reconciler
                guard reconciler.reconcileNow() else {
                    throw DoryVZMachineError.validation(
                        "could not verify the resolved gvproxy port-forward registry"
                    )
                }
                reconciler.start()
            }
        } catch {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
            for path in [localSocketPath, datapathSocketPath, apiSocketPath, shutdownSocketPath] + [lanDatapathSocketPath].compactMap({ $0 }) { unlink(path) }
            throw error
        }
    }

    deinit {
        stop()
    }

    var resolvedPortForwardHealth: ResolvedPortForwardHealthSnapshot? {
        resolvedPortForwardReconciler?.healthSnapshot()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        resolvedPortForwardReconciler?.stop()
        try? fileHandle.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        for path in [localSocketPath, datapathSocketPath, apiSocketPath, shutdownSocketPath] + [lanDatapathSocketPath].compactMap({ $0 }) { unlink(path) }
    }

    func requestGuestShutdown() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DoryVZMachineError.syscall("shutdown socket", errno) }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = try Self.unixAddress(shutdownSocketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DoryVZMachineError.syscall("shutdown connect", errno) }
        _ = Darwin.shutdown(descriptor, SHUT_WR)
    }

    private static func connectedDatagram(localPath: String, remotePath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw DoryVZMachineError.syscall("network socket", errno) }
        do {
            var local = try unixAddress(localPath)
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw DoryVZMachineError.syscall("network bind", errno) }

            var remote = try unixAddress(remotePath)
            let connected = withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw DoryVZMachineError.syscall("network connect", errno) }

            var sendBuffer: Int32 = 1 << 20
            var receiveBuffer: Int32 = 4 << 20
            guard setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer))) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer))) == 0 else {
                throw DoryVZMachineError.syscall("network socket buffer", errno)
            }

            let handshake = Array("VFKT".utf8)
            let sent = handshake.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            guard sent == handshake.count else {
                throw DoryVZMachineError.syscall("network handshake", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(localPath)
            throw error
        }
    }

    private static func publishUnixForward(
        localPath: String,
        guestPort: Int,
        apiSocketPath: String
    ) throws {
        let bodyData = try JSONSerialization.data(withJSONObject: [
            "local": localPath,
            "remote": "tcp://192.168.127.2:\(guestPort)",
            "protocol": "unix",
        ])
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw DoryVZMachineError.validation("could not encode gvproxy forward")
        }
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
                if curl.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: localPath) {
                    return
                }
            }
            usleep(20_000)
        }
        throw DoryVZMachineError.validation("gvproxy did not publish the guest shutdown channel")
    }

    private static func publishIPForward(
        _ forward: PublishedPortForward,
        apiSocketPath: String
    ) throws {
        let bodyData = try JSONSerialization.data(withJSONObject: [
            "local": forward.localEndpoint,
            "remote": forward.remoteEndpoint,
            "protocol": forward.protocol.rawValue,
        ])
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw DoryVZMachineError.validation("could not encode resolved gvproxy forward")
        }
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
                if curl.terminationStatus == 0 { return }
            }
            usleep(20_000)
        }
        throw DoryVZMachineError.validation(
            "gvproxy could not publish \(forward.localEndpoint)/\(forward.protocol.rawValue)"
        )
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

    private static func validateUnixPath(_ path: String) throws {
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw DoryVZMachineError.validation("Unix socket path is too long: \(path)")
        }
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        try validateUnixPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}
