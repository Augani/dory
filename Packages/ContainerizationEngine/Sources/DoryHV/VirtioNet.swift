import Darwin
import Foundation
import Synchronization

public struct VirtioNetStatistics: Equatable, Sendable {
    public var transmitPackets: UInt64
    public var transmitBytes: UInt64
    public var transmitDrops: UInt64
    public var receivePackets: UInt64
    public var receiveBytes: UInt64
    public var receiveDeferred: UInt64
    public var receiveDrops: UInt64
    public var receiveTruncations: UInt64
}

/// virtio-net wired to a userspace network stack (gvproxy) over a unix datagram socket, one
/// ethernet frame per datagram (the vfkit protocol). No offloads: VERSION_1 + MAC only, so the
/// 12-byte header is constant and the stack stays trivially small. No host entitlement needed.
public final class VirtioNet: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 1
    public let queueCount = 2  // 0 = receive, 1 = transmit
    public var deviceFeatures: UInt64 { 1 << 5 }  // VIRTIO_NET_F_MAC

    /// gvproxy's canonical vfkit guest MAC; its DHCP hands this MAC 192.168.127.2.
    public static let guestMAC: [UInt8] = [0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xEE]

    private static let headerLength = 12
    private static let vfkitMagic: [UInt8] = Array("VFKT".utf8)
    /// One full virtqueue of frames absorbs the normal refill gap without letting an otherwise
    /// transient RX-buffer shortage turn into TCP loss. Beyond this bound we account and drop,
    /// rather than allowing an unbounded host allocation under a hostile or wedged guest.
    private static let maximumDeferredReceiveFrames = 256
    private let socketFD: Int32
    private let localSocketPath: String
    private var receiveSource: (any DispatchSourceRead)?
    private weak var transport: VirtioMMIOTransport?
    private let receiveQueue = DispatchQueue(label: "dory-hv.net.rx")
    private var deferredReceiveFrames = [[UInt8]]()
    private var deferredReceiveHead = 0

    private let transmitPackets = Atomic<UInt64>(0)
    private let transmitBytes = Atomic<UInt64>(0)
    private let transmitDrops = Atomic<UInt64>(0)
    private let receivePackets = Atomic<UInt64>(0)
    private let receiveBytes = Atomic<UInt64>(0)
    private let receiveDeferred = Atomic<UInt64>(0)
    private let receiveDrops = Atomic<UInt64>(0)
    private let receiveTruncations = Atomic<UInt64>(0)

    public init(socketPath: String, remotePath: String) throws {
        try Self.validateSocketPath(socketPath)
        try Self.validateSocketPath(remotePath)
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot create datagram socket: errno \(errno)")
        }
        var didBind = false
        do {
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
                throw VMError.invalidConfiguration("cannot bind \(socketPath): errno \(errno)")
            }
            didBind = true

            var remote = sockaddr_un()
            remote.sun_family = sa_family_t(AF_UNIX)
            Self.copyPath(remotePath, into: &remote)
            let connectResult = withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    connect(descriptor, address, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                throw VMError.invalidConfiguration("cannot connect \(remotePath): errno \(errno)")
            }

            // Match vfkit's reference socket sizing. The proxy side has a 4 MiB receive buffer;
            // giving Dory 4 MiB on RX keeps short guest scheduling gaps from becoming datagram loss.
            try Self.setSocketBuffer(descriptor, option: SO_SNDBUF, bytes: 1 << 20)
            try Self.setSocketBuffer(descriptor, option: SO_RCVBUF, bytes: 4 << 20)

            // Queue notifications run under VirtioMMIOTransport's register lock. A blocking send
            // here could therefore stop every MMIO access and queue transition for this device if
            // gvproxy stopped draining its datagram socket. Keep the descriptor nonblocking for
            // its entire operational lifetime; individual TX calls also use MSG_DONTWAIT below as
            // defense in depth against an accidental future flags change.
            try Self.setNonBlocking(descriptor)

            // gvproxy <= 0.8.6 requires this handshake; newer releases deliberately retain support
            // for it while also accepting the first Ethernet frame directly.
            let magicBytes = Self.vfkitMagic.withUnsafeBytes {
                send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
            }
            guard magicBytes == Self.vfkitMagic.count else {
                throw VMError.invalidConfiguration("cannot register vfkit peer: errno \(errno)")
            }
        } catch {
            close(descriptor)
            if didBind { unlink(socketPath) }
            throw error
        }
        self.socketFD = descriptor
        self.localSocketPath = socketPath
    }

    deinit {
        if let receiveSource {
            receiveSource.cancel()
        } else {
            close(socketFD)
            unlink(localSocketPath)
        }
    }

    public var configSpace: [UInt8] { Self.guestMAC }

    public func deviceReady(transport: VirtioMMIOTransport) {
        self.transport = transport
        guard receiveSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: receiveQueue)
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        source.setCancelHandler { [socketFD, localSocketPath] in
            close(socketFD)
            unlink(localSocketPath)
        }
        source.resume()
        receiveSource = source
        receiveQueue.async { [weak self] in self?.drainSocket() }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        if queue == 0 {
            // Linux notifies the receive queue when it replenishes buffers. Drain on the same serial
            // queue as the socket source so the saved frame order and socket reads cannot race.
            receiveQueue.async { [weak self] in self?.drainSocket() }
            return
        }
        guard queue == 1 else { return }
        let virtqueue = transport.queues[1]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let frame = chain.readBytes()
            if frame.count > Self.headerLength {
                let payloadCount = frame.count - Self.headerLength
                let sent = frame[Self.headerLength...].withUnsafeBytes { buffer in
                    send(socketFD, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
                }
                if sent == payloadCount {
                    transmitPackets.wrappingAdd(1, ordering: .relaxed)
                    transmitBytes.wrappingAdd(UInt64(payloadCount), ordering: .relaxed)
                } else {
                    // Datagram writes are atomic. EAGAIN/EWOULDBLOCK means gvproxy is applying
                    // backpressure, while every other short/error result is equally undelivered;
                    // consume the guest descriptor and account one deterministic packet drop.
                    transmitDrops.wrappingAdd(1, ordering: .relaxed)
                }
            } else {
                transmitDrops.wrappingAdd(1, ordering: .relaxed)
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

        var interrupt = false
        while deferredReceiveHead < deferredReceiveFrames.count {
            let frame = deferredReceiveFrames[deferredReceiveHead]
            guard let wantsInterrupt = deliver(frame, transport: transport) else { break }
            deferredReceiveHead += 1
            interrupt = interrupt || wantsInterrupt
        }
        compactDeferredFramesIfNeeded()

        var frame = [UInt8](repeating: 0, count: 65536)
        while true {
            let received = recv(socketFD, &frame, frame.count, MSG_DONTWAIT)
            guard received > 0 else { break }
            receivePackets.wrappingAdd(1, ordering: .relaxed)
            receiveBytes.wrappingAdd(UInt64(received), ordering: .relaxed)
            let receivedFrame = Array(frame[0..<received])

            // Preserve ordering: once a frame is waiting for a guest buffer, later frames join the
            // bounded backlog instead of overtaking it. A receive-queue kick drains this backlog.
            if deferredReceiveHead < deferredReceiveFrames.count {
                deferOrDrop(receivedFrame)
                continue
            }
            if let wantsInterrupt = deliver(receivedFrame, transport: transport) {
                interrupt = interrupt || wantsInterrupt
            } else {
                deferOrDrop(receivedFrame)
            }
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    /// Returns nil when the guest has not supplied an RX descriptor yet.
    private func deliver(_ frame: [UInt8], transport: VirtioMMIOTransport) -> Bool? {
        let virtqueue = transport.queues[0]
        return transport.withQueueLock { () -> Bool? in
            guard let chain = (try? virtqueue.pop()) ?? nil else { return nil }
            var header = [UInt8](repeating: 0, count: Self.headerLength)
            header[10] = 1  // num_buffers = 1
            header.append(contentsOf: frame)
            let written = chain.writeBytes(header)
            if written != Self.headerLength + frame.count {
                receiveTruncations.wrappingAdd(1, ordering: .relaxed)
            }
            return (try? virtqueue.push(chain, written: written)) ?? false
        }
    }

    private func deferOrDrop(_ frame: [UInt8]) {
        let pendingCount = deferredReceiveFrames.count - deferredReceiveHead
        guard pendingCount < Self.maximumDeferredReceiveFrames else {
            receiveDrops.wrappingAdd(1, ordering: .relaxed)
            return
        }
        deferredReceiveFrames.append(frame)
        receiveDeferred.wrappingAdd(1, ordering: .relaxed)
    }

    private func compactDeferredFramesIfNeeded() {
        guard deferredReceiveHead > 0 else { return }
        if deferredReceiveHead == deferredReceiveFrames.count {
            deferredReceiveFrames.removeAll(keepingCapacity: true)
            deferredReceiveHead = 0
        } else if deferredReceiveHead >= 64 {
            deferredReceiveFrames.removeFirst(deferredReceiveHead)
            deferredReceiveHead = 0
        }
    }

    public var statistics: VirtioNetStatistics {
        VirtioNetStatistics(
            transmitPackets: transmitPackets.load(ordering: .relaxed),
            transmitBytes: transmitBytes.load(ordering: .relaxed),
            transmitDrops: transmitDrops.load(ordering: .relaxed),
            receivePackets: receivePackets.load(ordering: .relaxed),
            receiveBytes: receiveBytes.load(ordering: .relaxed),
            receiveDeferred: receiveDeferred.load(ordering: .relaxed),
            receiveDrops: receiveDrops.load(ordering: .relaxed),
            receiveTruncations: receiveTruncations.load(ordering: .relaxed)
        )
    }

    private static func setSocketBuffer(_ descriptor: Int32, option: Int32, bytes: Int32) throws {
        var value = bytes
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw VMError.invalidConfiguration("cannot set network socket buffer option \(option): errno \(errno)")
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else {
            throw VMError.invalidConfiguration("cannot read network socket flags: errno \(errno)")
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw VMError.invalidConfiguration("cannot make network socket nonblocking: errno \(errno)")
        }
    }

    /// Test-only observability for the descriptor-level half of the nonblocking TX invariant.
    /// Production sends additionally pass MSG_DONTWAIT, so either defense prevents lock pinning.
    var isSocketNonblockingForTesting: Bool {
        let flags = fcntl(socketFD, F_GETFL, 0)
        return flags >= 0 && flags & O_NONBLOCK != 0
    }

    private static func validateSocketPath(_ path: String) throws {
        var address = sockaddr_un()
        let capacity = withUnsafeBytes(of: &address.sun_path) { $0.count }
        guard path.utf8.count < capacity else {
            throw VMError.invalidConfiguration(
                "unix datagram socket path is too long (\(path.utf8.count) bytes, maximum \(capacity - 1)): \(path)"
            )
        }
    }

    private static func copyPath(_ path: String, into address: inout sockaddr_un) {
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
    }
}
