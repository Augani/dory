import Darwin
import Foundation

/// virtio-net wired to a userspace network stack (gvproxy) over a unix datagram socket, one
/// ethernet frame per datagram (the vfkit protocol). No offloads: VERSION_1 + MAC only, so the
/// 12-byte header is constant and the stack stays trivially small. No host entitlement needed.
public final class VirtioNet: VirtioDeviceBackend {
    public let deviceID: UInt32 = 1
    public let queueCount = 2  // 0 = receive, 1 = transmit
    public var deviceFeatures: UInt64 { 1 << 5 }  // VIRTIO_NET_F_MAC

    /// gvproxy's canonical vfkit guest MAC; its DHCP hands this MAC 192.168.127.2.
    public static let guestMAC: [UInt8] = [0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xEE]

    private static let headerLength = 12
    private let socketFD: Int32
    private var receiveSource: (any DispatchSourceRead)?
    private weak var transport: VirtioMMIOTransport?
    private let receiveQueue = DispatchQueue(label: "dory-hv.net.rx")

    public init(socketPath: String, remotePath: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot create datagram socket: errno \(errno)")
        }
        unlink(socketPath)
        var local = sockaddr_un()
        local.sun_family = sa_family_t(AF_UNIX)
        Self.copyPath(socketPath, into: &local)
        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("cannot bind \(socketPath): errno \(errno)")
        }
        var remote = sockaddr_un()
        remote.sun_family = sa_family_t(AF_UNIX)
        Self.copyPath(remotePath, into: &remote)
        let connectResult = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                connect(descriptor, address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("cannot connect \(remotePath): errno \(errno)")
        }
        var bufferSize = 1 << 20
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
        self.socketFD = descriptor
    }

    deinit {
        receiveSource?.cancel()
        close(socketFD)
    }

    public var configSpace: [UInt8] { Self.guestMAC }

    public func deviceReady(transport: VirtioMMIOTransport) {
        self.transport = transport
        guard receiveSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: receiveQueue)
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        source.resume()
        receiveSource = source
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 1 else { return }
        let virtqueue = transport.queues[1]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let frame = chain.readBytes()
            if frame.count > Self.headerLength {
                frame[Self.headerLength...].withUnsafeBytes { buffer in
                    _ = send(socketFD, buffer.baseAddress, buffer.count, 0)
                }
            }
            let wants = (try? virtqueue.push(chain, written: 0)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    private func drainSocket() {
        guard let transport else { return }
        let virtqueue = transport.queues[0]
        var frame = [UInt8](repeating: 0, count: 65536)
        var interrupt = false
        while true {
            let received = recv(socketFD, &frame, frame.count, MSG_DONTWAIT)
            guard received > 0 else { break }
            // Serialize the pop/copy/push against any vCPU thread reconfiguring or resetting this
            // queue via MMIO; without this, a concurrent reset (size -> 0) traps the VMM.
            let wants = transport.withQueueLock { () -> Bool in
                guard let chain = (try? virtqueue.pop()) ?? nil else { return false }  // no buffer: drop
                var packet = [UInt8](repeating: 0, count: Self.headerLength)
                packet[10] = 1  // num_buffers = 1
                packet.append(contentsOf: frame[0..<received])
                let written = chain.writeBytes(packet)
                return (try? virtqueue.push(chain, written: written)) ?? false
            }
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    private static func copyPath(_ path: String, into address: inout sockaddr_un) {
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
    }
}
