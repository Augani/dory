import Foundation

public struct VirtioVsockHeader: Equatable, Sendable {
    public static let byteCount = 44

    public var sourceCID: UInt64
    public var destinationCID: UInt64
    public var sourcePort: UInt32
    public var destinationPort: UInt32
    public var length: UInt32
    public var type: UInt16
    public var operation: Operation
    public var flags: UInt32
    public var bufferAllocation: UInt32
    public var forwardCount: UInt32

    public enum Operation: UInt16, Sendable {
        case invalid = 0
        case request = 1
        case response = 2
        case reset = 3
        case shutdown = 4
        case readWrite = 5
        case creditUpdate = 6
        case creditRequest = 7
    }

    public init(
        sourceCID: UInt64,
        destinationCID: UInt64,
        sourcePort: UInt32,
        destinationPort: UInt32,
        length: UInt32,
        type: UInt16 = 1,
        operation: Operation,
        flags: UInt32 = 0,
        bufferAllocation: UInt32 = 256 * 1024,
        forwardCount: UInt32 = 0
    ) {
        self.sourceCID = sourceCID
        self.destinationCID = destinationCID
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.length = length
        self.type = type
        self.operation = operation
        self.flags = flags
        self.bufferAllocation = bufferAllocation
        self.forwardCount = forwardCount
    }

    public init(decoding bytes: some Collection<UInt8>) throws {
        // Never materialize an untrusted packet just to decode its fixed-size header. Queue
        // admission separately bounds and copies the declared payload after this prefix parses.
        let data = Array(bytes.prefix(Self.byteCount))
        guard data.count == Self.byteCount else {
            throw VMError.invalidConfiguration("short virtio-vsock header")
        }
        func le16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func le32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        func le64(_ offset: Int) -> UInt64 {
            UInt64(le32(offset)) | (UInt64(le32(offset + 4)) << 32)
        }
        let rawOperation = le16(30)
        self.init(
            sourceCID: le64(0),
            destinationCID: le64(8),
            sourcePort: le32(16),
            destinationPort: le32(20),
            length: le32(24),
            type: le16(28),
            operation: Operation(rawValue: rawOperation) ?? .invalid,
            flags: le32(32),
            bufferAllocation: le32(36),
            forwardCount: le32(40)
        )
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        appendLE(sourceCID)
        appendLE(destinationCID)
        appendLE(sourcePort)
        appendLE(destinationPort)
        appendLE(length)
        appendLE(type)
        appendLE(operation.rawValue)
        appendLE(flags)
        appendLE(bufferAllocation)
        appendLE(forwardCount)
        return bytes
    }

}

public enum VsockConnectionWriteError: Error, Equatable, Sendable {
    case timedOut
    case connectionClosed
    case outboundQueueFull
}

public protocol VsockConnection: AnyObject, Sendable {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func write(_ bytes: [UInt8]) throws
    func write(_ bytes: [UInt8], timeoutNanoseconds: UInt64?) throws
    func close()
    func waitForReadable(timeoutNanoseconds: UInt64?) -> Bool
    func shutdownSend()
    var isPeerClosed: Bool { get }
}

public extension VsockConnection {
    func write(_ bytes: [UInt8], timeoutNanoseconds: UInt64?) throws {
        try write(bytes)
    }

    func waitForReadable(timeoutNanoseconds: UInt64?) -> Bool {
        if isPeerClosed { return true }
        if let timeoutNanoseconds {
            usleep(useconds_t(min(timeoutNanoseconds / 1_000, UInt64(useconds_t.max))))
        } else {
            usleep(1_000)
        }
        return !isPeerClosed
    }
}

public enum VsockPorts {
    public static let agent: UInt32 = 1024
    public static let usbip: UInt32 = 1025
    public static let docker: UInt32 = 1026
    public static let fsevents: UInt32 = 1028
    public static let sshAgent: UInt32 = 1029
}

public enum VirtioVsockConfigurationError: Error, Equatable, Sendable {
    case invalidGuestCID(UInt32)
    case invalidLimit(String)
}

/// Immutable per-device resource ceilings used by every admission and accounting path.
public struct VirtioVsockLimits: Equatable, Sendable {
    /// Linux's virtio transport splits socket writes into at most 64 KiB packet payloads
    /// (`VIRTIO_VSOCK_MAX_PKT_BUF_SIZE`). Keeping the same frontend ceiling bounds copies while
    /// preserving interoperability with the in-tree guest driver.
    public static let linuxMaximumPacketPayloadBytes = 64 * 1024

    public static let hardenedDefault = VirtioVsockLimits(
        maximumConnections: 256,
        maximumListeners: 64,
        maximumInboundBytesPerConnection: 256 * 1024,
        maximumInboundBytesTotal: 16 * 1024 * 1024,
        maximumPendingGuestPackets: 1024,
        maximumPendingGuestBytes: 8 * 1024 * 1024,
        maximumPacketPayloadBytes: linuxMaximumPacketPayloadBytes,
        maximumChainsPerKick: Int(Virtqueue.maximumSize),
        maximumBytesPerKick: (linuxMaximumPacketPayloadBytes + VirtioVsockHeader.byteCount)
            * Int(Virtqueue.maximumSize),
        hostPortRange: 49_152...65_535,
        shutdownTimeoutNanoseconds: 5_000_000_000,
        validated: ()
    )

    public let maximumConnections: Int
    public let maximumListeners: Int
    public let maximumInboundBytesPerConnection: Int
    public let maximumInboundBytesTotal: Int
    public let maximumPendingGuestPackets: Int
    public let maximumPendingGuestBytes: Int
    public let maximumPacketPayloadBytes: Int
    public let maximumChainsPerKick: Int
    public let maximumBytesPerKick: Int
    public let hostPortRange: ClosedRange<UInt32>
    public let shutdownTimeoutNanoseconds: UInt64

    public init(
        maximumConnections: Int,
        maximumListeners: Int,
        maximumInboundBytesPerConnection: Int,
        maximumInboundBytesTotal: Int,
        maximumPendingGuestPackets: Int,
        maximumPendingGuestBytes: Int,
        maximumPacketPayloadBytes: Int = Self.linuxMaximumPacketPayloadBytes,
        maximumChainsPerKick: Int = Int(Virtqueue.maximumSize),
        maximumBytesPerKick: Int = (Self.linuxMaximumPacketPayloadBytes
            + VirtioVsockHeader.byteCount) * Int(Virtqueue.maximumSize),
        hostPortRange: ClosedRange<UInt32>,
        shutdownTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws {
        guard maximumConnections > 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumConnections")
        }
        guard maximumListeners >= 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumListeners")
        }
        guard maximumInboundBytesPerConnection > 0,
              maximumInboundBytesPerConnection <= Int(UInt32.max) else {
            throw VirtioVsockConfigurationError.invalidLimit(
                "maximumInboundBytesPerConnection"
            )
        }
        guard maximumInboundBytesTotal > 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumInboundBytesTotal")
        }
        guard maximumPendingGuestPackets > 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumPendingGuestPackets")
        }
        guard maximumPendingGuestBytes > 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumPendingGuestBytes")
        }
        guard maximumPacketPayloadBytes > 0,
              maximumPacketPayloadBytes <= Int(UInt32.max) else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumPacketPayloadBytes")
        }
        guard maximumChainsPerKick > 0,
              maximumChainsPerKick <= Int(Virtqueue.maximumSize) else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumChainsPerKick")
        }
        let (maximumPacketBytes, packetOverflow) = maximumPacketPayloadBytes
            .addingReportingOverflow(VirtioVsockHeader.byteCount)
        guard !packetOverflow, maximumBytesPerKick >= maximumPacketBytes else {
            throw VirtioVsockConfigurationError.invalidLimit("maximumBytesPerKick")
        }
        guard shutdownTimeoutNanoseconds > 0 else {
            throw VirtioVsockConfigurationError.invalidLimit("shutdownTimeoutNanoseconds")
        }
        self.init(
            maximumConnections: maximumConnections,
            maximumListeners: maximumListeners,
            maximumInboundBytesPerConnection: maximumInboundBytesPerConnection,
            maximumInboundBytesTotal: maximumInboundBytesTotal,
            maximumPendingGuestPackets: maximumPendingGuestPackets,
            maximumPendingGuestBytes: maximumPendingGuestBytes,
            maximumPacketPayloadBytes: maximumPacketPayloadBytes,
            maximumChainsPerKick: maximumChainsPerKick,
            maximumBytesPerKick: maximumBytesPerKick,
            hostPortRange: hostPortRange,
            shutdownTimeoutNanoseconds: shutdownTimeoutNanoseconds,
            validated: ()
        )
    }

    private init(
        maximumConnections: Int,
        maximumListeners: Int,
        maximumInboundBytesPerConnection: Int,
        maximumInboundBytesTotal: Int,
        maximumPendingGuestPackets: Int,
        maximumPendingGuestBytes: Int,
        maximumPacketPayloadBytes: Int,
        maximumChainsPerKick: Int,
        maximumBytesPerKick: Int,
        hostPortRange: ClosedRange<UInt32>,
        shutdownTimeoutNanoseconds: UInt64,
        validated: Void
    ) {
        self.maximumConnections = maximumConnections
        self.maximumListeners = maximumListeners
        self.maximumInboundBytesPerConnection = maximumInboundBytesPerConnection
        self.maximumInboundBytesTotal = maximumInboundBytesTotal
        self.maximumPendingGuestPackets = maximumPendingGuestPackets
        self.maximumPendingGuestBytes = maximumPendingGuestBytes
        self.maximumPacketPayloadBytes = maximumPacketPayloadBytes
        self.maximumChainsPerKick = maximumChainsPerKick
        self.maximumBytesPerKick = maximumBytesPerKick
        self.hostPortRange = hostPortRange
        self.shutdownTimeoutNanoseconds = shutdownTimeoutNanoseconds
    }
}

public enum VirtioVsockConnectionAdmissionError: Error, Equatable, Sendable {
    case deviceQuiesced
    case connectionCapacityReached(limit: Int)
    case hostPortRangeExhausted
    case outboundQueueCapacityReached
}

public enum VirtioVsockListenerRegistrationError: Error, Equatable, Sendable {
    case deviceQuiesced
    case duplicatePort(UInt32)
    case listenerCapacityReached(limit: Int)
}

public struct VirtioVsockResourceSnapshot: Equatable, Sendable {
    public let connections: Int
    public let listeners: Int
    public let inboundBufferedBytes: Int
    public let pendingGuestPackets: Int
    public let pendingGuestBytes: Int
    public let isQuiesced: Bool
}

/// Cumulative frontend telemetry. Queue faults are terminal for that queue generation and become
/// admissible again only after QueueReady is rewritten or the device is reset.
public struct VirtioVsockStatistics: Equatable, Sendable {
    public var receivedGuestPackets: UInt64 = 0
    public var publishedGuestPackets: UInt64 = 0
    public var invalidTXChains: UInt64 = 0
    public var invalidRXChains: UInt64 = 0
    public var invalidEventChains: UInt64 = 0
    public var malformedGuestPackets: UInt64 = 0
    public var oversizedGuestPackets: UInt64 = 0
    public var rxStarvationEvents: UInt64 = 0
    public var responseBackpressureStops: UInt64 = 0
    public var boundedDrainStops: UInt64 = 0
    public var peerCreditClamps: UInt64 = 0
    public var staleHostOperations: UInt64 = 0
    public var queueFaults: UInt64 = 0
    public var publicationFaults: UInt64 = 0
    public var revokedCompletions: UInt64 = 0

    public init() {}
}

/// Closing or releasing the token unregisters only its exact listener generation.
public final class VirtioVsockListenerRegistration: @unchecked Sendable {
    public let port: UInt32

    private let lock = NSLock()
    private var closeAction: (@Sendable () -> Void)?

    fileprivate init(port: UInt32, closeAction: @escaping @Sendable () -> Void) {
        self.port = port
        self.closeAction = closeAction
    }

    public func close() {
        lock.lock()
        let action = closeAction
        closeAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        close()
    }
}

enum VirtioVsockCreditArithmetic {
    /// VirtIO 1.3 section 5.10.6.3 defines free-running u32 counters. Counter subtraction wraps,
    /// while an in-flight value larger than the peer's allocation must fail closed.
    static func available(
        bufferAllocation: UInt32,
        transmittedCount: UInt32,
        peerForwardCount: UInt32
    ) -> UInt32 {
        let inFlight = transmittedCount &- peerForwardCount
        guard inFlight <= bufferAllocation else { return 0 }
        return bufferAllocation - inFlight
    }
}

public final class VirtioVsock: VirtioDeviceBackend {
    public let deviceID: UInt32 = 19
    public let queueCount = 3
    /// VirtIO 1.3 section 5.10.3: stream support is implied with no negotiated feature bits.
    public let deviceFeatures: UInt64 = 0
    public var configSpace: [UInt8] {
        var bytes = [UInt8]()
        var cid = UInt64(guestCID).littleEndian
        withUnsafeBytes(of: &cid) { bytes.append(contentsOf: $0) }
        return bytes
    }

    private static let hostCID: UInt64 = 2
    private static let streamType: UInt16 = 1

    private let guestCID: UInt32
    private let limits: VirtioVsockLimits
    private let serviceAdmissionAuthority: VirtioVsockServiceAdmissionAuthority
    private let lifecycleResetLock = NSLock()
    private let stateLock = NSLock()
    private var listeners: [UInt32: Listener] = [:]
    private var connections: [ConnectionKey: InProcessConnection] = [:]
    private var pendingGuestPackets: [PendingGuestPacket?] = []
    private var pendingGuestPacketHead = 0
    private var pendingGuestBytes = 0
    private var controlResponseReservations: Set<UUID> = []
    private var reservedControlResponseBytes = 0
    private var uncommittedTerminalResetKeys: Set<ConnectionKey> = []
    private var inboundBufferedBytes = 0
    private var nextHostPort: UInt32
    private var lifecycleEpoch: UInt64 = 1
    private var isQuiesced = false
    private var isResetting = false
    private var terminalQueues = Set<Int>()
    private var statisticsState = VirtioVsockStatistics()
    private var closingConnections: [ConnectionKey: ClosingConnection] = [:]
    private let shutdownReaperQueue = DispatchQueue(label: "com.dory.vsock.shutdown-reaper")
    private var shutdownReaper: DispatchSourceTimer?
    private weak var lastTransport: VirtioMMIOTransport?

    private struct ConnectionKey: Hashable, Sendable {
        var guestPort: UInt32
        var hostPort: UInt32
    }

    private struct Listener {
        var registrationID: UUID
        var handler: @Sendable (VsockConnection) -> Void
    }

    private struct PendingGuestPacket {
        var id: UUID
        var key: ConnectionKey?
        var bytes: [UInt8]
    }

    private struct PendingGuestDelivery {
        var packetID: UUID
        var bytes: [UInt8]
        /// Nil means the head packet was delivered completely. A value replaces the exact head
        /// after used-ring publication, allowing a large RW packet to be fragmented transactionally.
        var replacement: [UInt8]?
    }

    private struct ControlResponseReservation {
        var id: UUID
        var epoch: UInt64
    }

    private struct ClosingConnection {
        var id: UUID
        var deadlineNanoseconds: UInt64
    }

    private struct GuestPacketResult {
        var responses: [[UInt8]] = []
        var invokeListener: (() -> Void)?
        var terminalResetKey: ConnectionKey?
    }

    private enum TXChainInspection {
        case invalid
        case packet(
            bytes: [UInt8],
            header: VirtioVsockHeader,
            copiedByteCount: Int
        )
    }

    private enum RXPublicationResult {
        case published(wantsInterrupt: Bool)
        case revoked
        case stalePacket
    }

    private enum ConnectionOrigin: Equatable {
        case guest
        case host
    }

    private enum HostPacketEnqueueResult: Equatable {
        case enqueued
        case connectionClosed
        case capacityExceeded
    }

    private enum InboundReservationResult {
        case reserved
        case connectionClosed
        case globalCapacityExceeded
    }

    private enum InboundReceiveResult {
        case accepted
        case connectionClosed
        case perConnectionCapacityExceeded
        case globalCapacityExceeded
    }

    public init(guestCID: UInt32) {
        precondition(Self.isValidGuestCID(guestCID), "virtio-vsock guest CID is reserved")
        self.guestCID = guestCID
        limits = .hardenedDefault
        serviceAdmissionAuthority = VirtioVsockServiceAdmissionAuthority(
            limits: .hardenedDefault
        )
        nextHostPort = limits.hostPortRange.lowerBound
    }

    public init(
        guestCID: UInt32,
        serviceAdmissionLimits: VirtioVsockServiceAdmissionLimits
    ) {
        precondition(Self.isValidGuestCID(guestCID), "virtio-vsock guest CID is reserved")
        self.guestCID = guestCID
        limits = .hardenedDefault
        serviceAdmissionAuthority = VirtioVsockServiceAdmissionAuthority(
            limits: serviceAdmissionLimits
        )
        nextHostPort = limits.hostPortRange.lowerBound
    }

    public init(
        guestCID: UInt32,
        limits: VirtioVsockLimits,
        serviceAdmissionLimits: VirtioVsockServiceAdmissionLimits = .hardenedDefault
    ) throws {
        guard Self.isValidGuestCID(guestCID) else {
            throw VirtioVsockConfigurationError.invalidGuestCID(guestCID)
        }
        self.guestCID = guestCID
        self.limits = limits
        serviceAdmissionAuthority = VirtioVsockServiceAdmissionAuthority(
            limits: serviceAdmissionLimits
        )
        nextHostPort = limits.hostPortRange.lowerBound
    }

    public var resourceSnapshot: VirtioVsockResourceSnapshot {
        withLock {
            VirtioVsockResourceSnapshot(
                connections: connections.count,
                listeners: listeners.count,
                inboundBufferedBytes: inboundBufferedBytes,
                pendingGuestPackets: pendingGuestPacketCountLocked
                    + controlResponseReservations.count,
                pendingGuestBytes: pendingGuestBytes + reservedControlResponseBytes,
                isQuiesced: isQuiesced
            )
        }
    }

    public var statistics: VirtioVsockStatistics {
        withLock { statisticsState }
    }

    public var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot {
        serviceAdmissionAuthority.snapshot
    }

    private static func isValidGuestCID(_ cid: UInt32) -> Bool {
        cid > 2 && cid != UInt32.max
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    func registerListener(
        port: UInt32,
        handler: @escaping @Sendable (VsockConnection) -> Void
    ) throws -> VirtioVsockListenerRegistration {
        let registrationID = UUID()
        try withLock {
            guard !isQuiesced, !isResetting else {
                throw VirtioVsockListenerRegistrationError.deviceQuiesced
            }
            guard listeners[port] == nil else {
                throw VirtioVsockListenerRegistrationError.duplicatePort(port)
            }
            guard listeners.count < limits.maximumListeners else {
                throw VirtioVsockListenerRegistrationError.listenerCapacityReached(
                    limit: limits.maximumListeners
                )
            }
            listeners[port] = Listener(registrationID: registrationID, handler: handler)
        }
        return VirtioVsockListenerRegistration(port: port) { [weak self] in
            self?.unregisterListener(port: port, registrationID: registrationID)
        }
    }

    /// Registers a guest-initiated service. Admission is reserved before the untrusted callback is
    /// invoked, and the wrapped connection holds that exact service lease until close/peer reset.
    public func registerServiceListener(
        port: UInt32,
        service: VirtioVsockService,
        handler: @escaping @Sendable (VsockConnection) -> Void
    ) throws -> VirtioVsockListenerRegistration {
        try registerListener(port: port) { [weak self] connection in
            guard let self else {
                connection.close()
                return
            }
            let reservation: VirtioVsockServiceReservation
            do {
                reservation = try serviceAdmissionAuthority.reserve(service)
            } catch {
                connection.close()
                return
            }
            guard let lease = serviceAdmissionAuthority.publish(
                reservation,
                requestStop: { connection.close() }
            ) else {
                connection.close()
                return
            }
            handler(ServiceOwnedVsockConnection(connection: connection, lease: lease))
        }
    }

    private func unregisterListener(port: UInt32, registrationID: UUID) {
        withLock {
            guard listeners[port]?.registrationID == registrationID else { return }
            listeners.removeValue(forKey: port)
        }
    }

    /// Reserves a connection slot, collision-free tuple, and REQUEST queue space atomically.
    func connectIfCapacity(port guestPort: UInt32) throws -> VsockConnection {
        let admitted = try withLock { () throws -> (InProcessConnection, VirtioMMIOTransport?) in
            guard !isQuiesced, !isResetting else {
                throw VirtioVsockConnectionAdmissionError.deviceQuiesced
            }
            guard connections.count < limits.maximumConnections else {
                throw VirtioVsockConnectionAdmissionError.connectionCapacityReached(
                    limit: limits.maximumConnections
                )
            }
            let hostPort = try allocateHostPortLocked(guestPort: guestPort)
            let key = ConnectionKey(guestPort: guestPort, hostPort: hostPort)
            let connection = makeConnectionLocked(key: key, origin: .host)
            let packet = makeHostPacket(
                key: key,
                operation: .request,
                payload: [],
                forwardCount: 0,
                flags: 0
            )
            guard appendPendingGuestPacketLocked(packet, key: key) else {
                throw VirtioVsockConnectionAdmissionError.outboundQueueCapacityReached
            }
            connections[key] = connection
            return (connection, lastTransport)
        }
        flushIfAttached(admitted.1)
        return admitted.0
    }

    /// Admits one host-initiated service session before allocating a transport tuple or REQUEST.
    /// The returned connection owns both resources and releases the service lease exactly once.
    public func connectForServiceIfCapacity(
        port guestPort: UInt32,
        service: VirtioVsockService
    ) throws -> VsockConnection {
        let reservation = try serviceAdmissionAuthority.reserve(service)
        do {
            let connection = try connectIfCapacity(port: guestPort)
            guard let lease = serviceAdmissionAuthority.publish(
                reservation,
                requestStop: { connection.close() }
            ) else {
                connection.close()
                throw VirtioVsockServiceAdmissionError.lifecycleRevoked(service: service)
            }
            return ServiceOwnedVsockConnection(connection: connection, lease: lease)
        } catch {
            serviceAdmissionAuthority.cancel(reservation)
            throw error
        }
    }

    func reserveServiceSession(
        _ service: VirtioVsockService
    ) throws -> VirtioVsockServiceReservation {
        try serviceAdmissionAuthority.reserve(service)
    }

    func publishServiceSession(
        _ reservation: VirtioVsockServiceReservation,
        requestStop: @escaping @Sendable () -> Void
    ) -> VirtioVsockServiceLease? {
        serviceAdmissionAuthority.publish(reservation, requestStop: requestStop)
    }

    func cancelServiceSession(_ reservation: VirtioVsockServiceReservation) {
        serviceAdmissionAuthority.cancel(reservation)
    }

    func drainPendingGuestPackets() -> [[UInt8]] {
        withLock {
            let result = pendingGuestPackets.dropFirst(pendingGuestPacketHead)
                .compactMap { $0?.bytes }
            pendingGuestPackets.removeAll(keepingCapacity: true)
            pendingGuestPacketHead = 0
            pendingGuestBytes = 0
            return result
        }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard transport.queues.indices.contains(queue) else { return }
        let isAdmissible = withLock { () -> Bool in
            lastTransport = transport
            return !terminalQueues.contains(queue)
        }
        guard isAdmissible else { return }

        switch queue {
        case 0:
            flushPendingGuestPackets(transport: transport)
        case 1:
            // Section 5.10.6.1 requires progress on incoming TX packets while bounded resources
            // remain even if the peer neglected RX. Flush first to reclaim response capacity, then
            // drain TX once and make one bounded pass over newly generated replies.
            flushPendingGuestPackets(transport: transport)
            drainGuestTX(transport: transport)
            flushPendingGuestPackets(transport: transport)
        case 2:
            validateEventQueue(transport: transport)
        default:
            break
        }
    }

    private func drainGuestTX(transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[1]
        var interrupt = false
        defer { if interrupt { transport.notifyUsed() } }

        let pending: UInt16
        do {
            pending = try virtqueue.pendingCount()
        } catch {
            recordQueueFault(queue: 1)
            return
        }
        let chainBudget = min(Int(pending), limits.maximumChainsPerKick)
        if Int(pending) > chainBudget { recordBoundedDrainStop() }

        var handled = 0
        var copiedBytes = 0
        while handled < chainBudget {
            let preview: VirtqueueChain
            do {
                guard let next = try virtqueue.peek() else { break }
                preview = next
            } catch {
                recordQueueFault(queue: 1)
                return
            }

            let inspection = inspectTXChain(preview)
            guard case .packet(
                let packet,
                let header,
                let packetCopyBytes
            ) = inspection else {
                let rejected: VirtqueueChain
                do {
                    rejected = try popPreviewed(preview, from: virtqueue)
                } catch {
                    recordQueueFault(queue: 1)
                    return
                }
                handled += 1
                withLock { statisticsState.invalidTXChains &+= 1 }
                guard publish(
                    rejected,
                    written: 0,
                    on: virtqueue,
                    queueIndex: 1,
                    interrupt: &interrupt
                ) else { return }
                continue
            }

            guard copiedBytes <= limits.maximumBytesPerKick - packetCopyBytes else {
                recordBoundedDrainStop()
                break
            }
            let reservation: ControlResponseReservation?
            if requiresControlResponse(header) {
                guard let reserved = reserveControlResponse() else {
                    withLock { statisticsState.responseBackpressureStops &+= 1 }
                    break
                }
                reservation = reserved
            } else {
                reservation = nil
            }

            let chain: VirtqueueChain
            do {
                chain = try popPreviewed(preview, from: virtqueue)
            } catch {
                if let reservation { releaseControlResponse(reservation) }
                recordQueueFault(queue: 1)
                return
            }
            handled += 1
            copiedBytes += packetCopyBytes

            let result: GuestPacketResult
            do {
                result = try processGuestPacket(
                    packet,
                    transactionEpoch: reservation?.epoch ?? currentLifecycleEpoch
                )
            } catch {
                if let reservation { releaseControlResponse(reservation) }
                withLock { statisticsState.malformedGuestPackets &+= 1 }
                guard publish(
                    chain,
                    written: 0,
                    on: virtqueue,
                    queueIndex: 1,
                    interrupt: &interrupt
                ) else { return }
                continue
            }
            withLock { statisticsState.receivedGuestPackets &+= 1 }

            let responseCommitted: Bool
            if let reservation, let response = result.responses.first {
                responseCommitted = commitControlResponse(
                    response,
                    reservation: reservation,
                    terminalResetKey: result.terminalResetKey
                )
            } else if let reservation {
                releaseControlResponse(reservation)
                responseCommitted = result.responses.isEmpty
            } else if result.responses.isEmpty {
                responseCommitted = true
            } else {
                // Admission reserves for every packet that can produce a response. Reaching this
                // branch is an internal fail-closed invariant violation, not guest backpressure.
                responseCommitted = false
                recordQueueFault(queue: 1)
            }
            if responseCommitted { result.invokeListener?() }
            guard publish(
                chain,
                written: 0,
                on: virtqueue,
                queueIndex: 1,
                interrupt: &interrupt
            ) else { return }
        }
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        withLock { lastTransport = transport }
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        guard transport.queues.indices.contains(queue) else { return }
        withLock {
            // QueueReady writes establish a new ring generation. Old faults remain counted, while
            // the replacement queue receives a fresh admission opportunity.
            terminalQueues.remove(queue)
            lastTransport = transport
        }
    }

    /// Clears all transport-owned state. Host listener registrations are configuration authority,
    /// so they survive reset as required for listeners by VirtIO 1.3 section 5.10.6.7.
    public func deviceReset(transport: VirtioMMIOTransport) {
        resetTransportState(preserveListeners: true, remainQuiesced: false)
    }

    /// Permanently stops admission and releases connections, queues, bytes, and listener tokens.
    @discardableResult
    public func quiesce() -> VirtioVsockResourceSnapshot {
        resetTransportState(preserveListeners: false, remainQuiesced: true)
        return resourceSnapshot
    }

    deinit {
        resetTransportState(preserveListeners: false, remainQuiesced: true)
    }

    private var maximumGuestPacketPayloadBytes: Int {
        min(limits.maximumPacketPayloadBytes, limits.maximumInboundBytesPerConnection)
    }

    private var currentLifecycleEpoch: UInt64 {
        withLock { lifecycleEpoch }
    }

    private func inspectTXChain(_ chain: VirtqueueChain) -> TXChainInspection {
        // VirtIO 1.3 section 5.10.6.4: every outgoing packet buffer is device-readable. Zero-byte
        // descriptors do not carry protocol data and are rejected rather than normalized away.
        guard !chain.containsZeroLengthDescriptor,
              chain.readableSegmentCount > 0,
              chain.writableSegmentCount == 0,
              chain.readableByteCount >= VirtioVsockHeader.byteCount else {
            return .invalid
        }

        let headerBytes = chain.readBytes(maximum: VirtioVsockHeader.byteCount)
        guard headerBytes.count == VirtioVsockHeader.byteCount else { return .invalid }
        let header: VirtioVsockHeader
        do {
            header = try VirtioVsockHeader(decoding: headerBytes)
        } catch {
            return .invalid
        }

        guard let payloadByteCount = Int(exactly: header.length) else {
            return .packet(
                bytes: headerBytes,
                header: header,
                copiedByteCount: headerBytes.count
            )
        }
        if payloadByteCount > maximumGuestPacketPayloadBytes {
            // The fixed header is sufficient to produce the protocol RST. Never copy the claimed
            // oversized body merely to reject it.
            return .packet(
                bytes: headerBytes,
                header: header,
                copiedByteCount: headerBytes.count
            )
        }
        let requiredByteCount = VirtioVsockHeader.byteCount + payloadByteCount
        guard requiredByteCount <= chain.readableByteCount else {
            // Preserve the parsed route so processGuestPacket can generate the required RST without
            // copying unavailable or unrelated descriptor memory.
            return .packet(
                bytes: headerBytes,
                header: header,
                copiedByteCount: headerBytes.count
            )
        }
        let packet = chain.readBytes(maximum: requiredByteCount)
        guard packet.count == requiredByteCount else { return .invalid }
        return .packet(
            bytes: packet,
            header: header,
            copiedByteCount: packet.count
        )
    }

    private func popPreviewed(
        _ preview: VirtqueueChain,
        from queue: Virtqueue
    ) throws -> VirtqueueChain {
        guard let chain = try queue.pop(),
              chain.head == preview.head,
              chain.lease == preview.lease else {
            throw VMError.unexpectedExit("virtio-vsock queue changed between admission and pop")
        }
        return chain
    }

    private func requiresControlResponse(_ header: VirtioVsockHeader) -> Bool {
        // A well-formed RST is the only input that can never require an outbound packet. Every
        // other opcode may need RESPONSE, CREDIT_UPDATE, SHUTDOWN, or a fail-closed RST.
        !(header.operation == .reset
            && header.sourceCID == UInt64(guestCID)
            && header.destinationCID == Self.hostCID
            && header.type == Self.streamType
            && header.length == 0
            && header.flags == 0)
    }

    @discardableResult
    private func publish(
        _ chain: VirtqueueChain,
        written: Int,
        on queue: Virtqueue,
        queueIndex: Int,
        interrupt: inout Bool
    ) -> Bool {
        do {
            switch try queue.pushOutcome(chain, written: written) {
            case .published(let wantsInterrupt):
                interrupt = interrupt || wantsInterrupt
                return true
            case .revoked:
                withLock { statisticsState.revokedCompletions &+= 1 }
                return false
            }
        } catch {
            recordPublicationFault(queue: queueIndex)
            return false
        }
    }

    private func validateEventQueue(transport: VirtioMMIOTransport) {
        let queue = transport.queues[2]
        var interrupt = false
        defer { if interrupt { transport.notifyUsed() } }

        let pending: UInt16
        do {
            pending = try queue.pendingCount()
        } catch {
            recordQueueFault(queue: 2)
            return
        }
        let budget = min(Int(pending), limits.maximumChainsPerKick)
        if Int(pending) > budget { recordBoundedDrainStop() }

        for _ in 0..<budget {
            let preview: VirtqueueChain
            do {
                guard let chain = try queue.peek() else { return }
                preview = chain
            } catch {
                recordQueueFault(queue: 2)
                return
            }
            let isValid = !preview.containsZeroLengthDescriptor
                && preview.readableSegmentCount == 0
                && preview.writableSegmentCount > 0
                && preview.writableByteCount >= 4
            if isValid {
                // No transport-reset event is pending. Leave the valid buffer available to the
                // device, exactly as Linux expects, instead of completing/replenishing it in a loop.
                return
            }
            let rejected: VirtqueueChain
            do {
                rejected = try popPreviewed(preview, from: queue)
            } catch {
                recordQueueFault(queue: 2)
                return
            }
            withLock { statisticsState.invalidEventChains &+= 1 }
            guard publish(
                rejected,
                written: 0,
                on: queue,
                queueIndex: 2,
                interrupt: &interrupt
            ) else { return }
        }
    }

    private func recordQueueFault(queue: Int) {
        withLock {
            statisticsState.queueFaults &+= 1
            terminalQueues.insert(queue)
        }
    }

    private func recordPublicationFault(queue: Int) {
        withLock {
            statisticsState.publicationFaults &+= 1
            terminalQueues.insert(queue)
        }
    }

    private func recordBoundedDrainStop() {
        withLock { statisticsState.boundedDrainStops &+= 1 }
    }

    private func flushIfAttached(_ transport: VirtioMMIOTransport?) {
        guard let transport else { return }
        transport.withQueueLock {
            flushPendingGuestPackets(transport: transport)
        }
    }

    private func flushPendingGuestPackets(transport: VirtioMMIOTransport) {
        guard withLock({ !terminalQueues.contains(0) }) else { return }
        guard withLock({ pendingGuestPacketCountLocked > 0 }) else { return }

        let queue = transport.queues[0]
        var interrupt = false
        defer { if interrupt { transport.notifyUsed() } }

        let pending: UInt16
        do {
            pending = try queue.pendingCount()
        } catch {
            recordQueueFault(queue: 0)
            return
        }
        let chainBudget = min(Int(pending), limits.maximumChainsPerKick)
        if Int(pending) > chainBudget { recordBoundedDrainStop() }

        var handled = 0
        var publishedBytes = 0
        while handled < chainBudget,
              withLock({ pendingGuestPacketCountLocked > 0 }) {
            let remainingByteBudget = limits.maximumBytesPerKick - publishedBytes
            let minimumDeliveryBytes = withLock { minimumPendingDeliveryBytesLocked() }
            guard let minimumDeliveryBytes,
                  remainingByteBudget >= minimumDeliveryBytes else {
                recordBoundedDrainStop()
                break
            }

            let rx: VirtqueueChain
            do {
                guard let next = try queue.pop() else { break }
                rx = next
            } catch {
                recordQueueFault(queue: 0)
                return
            }
            handled += 1

            // VirtIO 1.3 section 5.10.6.4: RX packet chains are device-writable only. A mixed or
            // readable chain receives no bytes and cannot consume the pending packet authority.
            guard !rx.containsZeroLengthDescriptor,
                  rx.writableSegmentCount > 0,
                  rx.readableSegmentCount == 0 else {
                withLock { statisticsState.invalidRXChains &+= 1 }
                guard publish(
                    rx,
                    written: 0,
                    on: queue,
                    queueIndex: 0,
                    interrupt: &interrupt
                ) else { return }
                continue
            }

            let capacity = min(rx.writableByteCount, remainingByteBudget)
            let delivery: PendingGuestDelivery?
            do {
                delivery = try withLock {
                    try pendingGuestDeliveryLocked(maximumBytes: capacity)
                }
            } catch {
                recordQueueFault(queue: 0)
                return
            }
            guard let delivery else {
                withLock { statisticsState.rxStarvationEvents &+= 1 }
                guard publish(
                    rx,
                    written: 0,
                    on: queue,
                    queueIndex: 0,
                    interrupt: &interrupt
                ) else { return }
                continue
            }

            let outcome: RXPublicationResult
            do {
                outcome = try withLock {
                    guard peekPendingGuestPacketLocked()?.id == delivery.packetID else {
                        return .stalePacket
                    }
                    guard rx.writeBytes(delivery.bytes) == delivery.bytes.count else {
                        throw VMError.unexpectedExit(
                            "virtio-vsock RX lease revoked during bounded write"
                        )
                    }
                    switch try queue.pushOutcome(rx, written: delivery.bytes.count) {
                    case .published(let wantsInterrupt):
                        commitPendingGuestDeliveryLocked(delivery)
                        statisticsState.publishedGuestPackets &+= 1
                        return .published(wantsInterrupt: wantsInterrupt)
                    case .revoked:
                        statisticsState.revokedCompletions &+= 1
                        return .revoked
                    }
                }
            } catch {
                recordPublicationFault(queue: 0)
                return
            }
            switch outcome {
            case .published(let wantsInterrupt):
                publishedBytes += delivery.bytes.count
                interrupt = interrupt || wantsInterrupt
            case .revoked:
                return
            case .stalePacket:
                // A concurrent direct control path removed the exact pending flow before guest
                // memory was touched. Complete this offered buffer empty and preserve newer FIFO.
                guard publish(
                    rx,
                    written: 0,
                    on: queue,
                    queueIndex: 0,
                    interrupt: &interrupt
                ) else { return }
            }
        }
    }

    private func minimumPendingDeliveryBytesLocked() -> Int? {
        guard let packet = peekPendingGuestPacketLocked() else { return nil }
        guard packet.bytes.count > VirtioVsockHeader.byteCount else {
            return packet.bytes.count
        }
        // Every fragment needs a complete header and at least one stream byte. Control packets are
        // fixed at one header and are returned in full.
        do {
            let header = try VirtioVsockHeader(decoding: packet.bytes)
            if header.operation == .readWrite {
                return VirtioVsockHeader.byteCount + 1
            }
            return packet.bytes.count
        } catch {
            return packet.bytes.count
        }
    }

    private func pendingGuestDeliveryLocked(
        maximumBytes: Int
    ) throws -> PendingGuestDelivery? {
        guard let current = peekPendingGuestPacketLocked() else { return nil }
        guard maximumBytes >= VirtioVsockHeader.byteCount else { return nil }
        if current.bytes.count <= maximumBytes {
            return PendingGuestDelivery(
                packetID: current.id,
                bytes: current.bytes,
                replacement: nil
            )
        }

        // Linux may provide an RX buffer smaller than a queued stream packet. The vhost transport
        // handles this by emitting a shorter RW packet and retaining the rest. Do the same without
        // increasing pending packet/byte accounting and without splitting any control opcode.
        let header = try VirtioVsockHeader(decoding: current.bytes)
        let payload = current.bytes.dropFirst(VirtioVsockHeader.byteCount)
        guard header.operation == .readWrite,
              header.length == UInt32(payload.count),
              maximumBytes > VirtioVsockHeader.byteCount else { return nil }
        let fragmentPayloadCount = min(
            maximumBytes - VirtioVsockHeader.byteCount,
            payload.count
        )
        guard fragmentPayloadCount > 0 else { return nil }

        var fragmentHeader = header
        fragmentHeader.length = UInt32(fragmentPayloadCount)
        let fragmentPayload = payload.prefix(fragmentPayloadCount)
        let emitted = fragmentHeader.encoded() + fragmentPayload

        let remainingPayload = payload.dropFirst(fragmentPayloadCount)
        var remainingHeader = header
        remainingHeader.length = UInt32(remainingPayload.count)
        let replacement = remainingHeader.encoded() + remainingPayload
        return PendingGuestDelivery(
            packetID: current.id,
            bytes: emitted,
            replacement: replacement
        )
    }

    private func commitPendingGuestDeliveryLocked(_ delivery: PendingGuestDelivery) {
        guard pendingGuestPacketHead < pendingGuestPackets.count,
              let current = pendingGuestPackets[pendingGuestPacketHead],
              current.id == delivery.packetID else { return }
        if let replacement = delivery.replacement {
            pendingGuestPackets[pendingGuestPacketHead]?.bytes = replacement
            pendingGuestBytes -= current.bytes.count - replacement.count
        } else {
            _ = dequeuePendingGuestPacketLocked()
        }
    }

    func receive(packet: [UInt8]) throws -> [[UInt8]] {
        let result = try processGuestPacket(packet, transactionEpoch: nil)
        result.invokeListener?()
        return result.responses
    }

    private func processGuestPacket(
        _ packet: [UInt8],
        transactionEpoch: UInt64?
    ) throws -> GuestPacketResult {
        let header = try VirtioVsockHeader(
            decoding: packet.prefix(VirtioVsockHeader.byteCount)
        )
        let key = ConnectionKey(
            guestPort: header.sourcePort,
            hostPort: header.destinationPort
        )
        let addressIsValid = header.sourceCID == UInt64(guestCID)
            && header.destinationCID == Self.hostCID
        let typeIsValid = header.type == Self.streamType
        let availablePayloadBytes = packet.count - VirtioVsockHeader.byteCount

        guard Int(header.length) <= maximumGuestPacketPayloadBytes else {
            withLock {
                statisticsState.oversizedGuestPackets &+= 1
                statisticsState.malformedGuestPackets &+= 1
            }
            if addressIsValid && typeIsValid {
                return terminalResetResult(
                    to: header,
                    key: key,
                    transactionEpoch: transactionEpoch
                )
            }
            return GuestPacketResult(responses: [makeReply(to: header, operation: .reset)])
        }
        // VirtIO 1.3 section 5.10.6 explicitly permits descriptor bytes beyond len. Consume only
        // the first len payload bytes, and RST a header that claims unavailable bytes.
        guard Int(header.length) <= availablePayloadBytes else {
            withLock { statisticsState.malformedGuestPackets &+= 1 }
            if addressIsValid && typeIsValid {
                return terminalResetResult(
                    to: header,
                    key: key,
                    transactionEpoch: transactionEpoch
                )
            }
            return GuestPacketResult(responses: [makeReply(to: header, operation: .reset)])
        }
        guard typeIsValid else {
            withLock { statisticsState.malformedGuestPackets &+= 1 }
            // Section 5.10.6.4.2 requires RST for every unsupported type.
            return GuestPacketResult(responses: [makeReply(to: header, operation: .reset)])
        }
        guard addressIsValid else {
            withLock { statisticsState.malformedGuestPackets &+= 1 }
            return GuestPacketResult(responses: [makeReply(to: header, operation: .reset)])
        }
        guard fieldsAreValid(header) else {
            withLock { statisticsState.malformedGuestPackets &+= 1 }
            return terminalResetResult(
                to: header,
                key: key,
                transactionEpoch: transactionEpoch
            )
        }

        if header.bufferAllocation > UInt32(limits.maximumInboundBytesPerConnection) {
            // Match Linux's fail-safe policy: a peer may advertise a larger receive window, but it
            // cannot make this implementation queue more than its own configured socket buffer.
            withLock { statisticsState.peerCreditClamps &+= 1 }
        }

        let payloadStart = VirtioVsockHeader.byteCount
        let payloadEnd = payloadStart + Int(header.length)
        let payload = Array(packet[payloadStart..<payloadEnd])

        if header.operation == .request {
            return admitGuestRequest(
                header: header,
                key: key,
                transactionEpoch: transactionEpoch
            )
        }
        if header.operation == .reset {
            abortConnection(key: key)
            return GuestPacketResult()
        }

        guard let connection = withLock({ connections[key] }) else {
            return terminalResetResult(
                to: header,
                key: key,
                transactionEpoch: transactionEpoch
            )
        }
        if header.operation != .response, !connection.isEstablished {
            return terminalResetResult(
                to: header,
                key: key,
                transactionEpoch: transactionEpoch
            )
        }

        switch header.operation {
        case .response:
            guard connection.acceptResponse(
                bufferAllocation: header.bufferAllocation,
                forwardCount: header.forwardCount
            ) else {
                return terminalResetResult(
                    to: header,
                    key: key,
                    transactionEpoch: transactionEpoch
                )
            }
            return GuestPacketResult()
        case .readWrite:
            connection.updatePeerCredit(
                bufferAllocation: header.bufferAllocation,
                forwardCount: header.forwardCount
            )
            switch connection.receive(payload) {
            case .accepted:
                return GuestPacketResult(responses: [
                    makeReply(
                        to: header,
                        operation: .creditUpdate,
                        forwardCount: connection.forwardCount
                    ),
                ])
            case .connectionClosed, .perConnectionCapacityExceeded,
                 .globalCapacityExceeded:
                return terminalResetResult(
                    to: header,
                    key: key,
                    transactionEpoch: transactionEpoch
                )
            }
        case .shutdown:
            connection.updatePeerCredit(
                bufferAllocation: header.bufferAllocation,
                forwardCount: header.forwardCount
            )
            if connection.markPeerShutdown(flags: header.flags) {
                return terminalResetResult(
                    to: header,
                    key: key,
                    transactionEpoch: transactionEpoch
                )
            }
            return GuestPacketResult(responses: [
                makeReply(
                    to: header,
                    operation: .shutdown,
                    forwardCount: connection.forwardCount,
                    flags: header.flags
                ),
            ])
        case .creditRequest:
            connection.updatePeerCredit(
                bufferAllocation: header.bufferAllocation,
                forwardCount: header.forwardCount
            )
            return GuestPacketResult(responses: [
                makeReply(
                    to: header,
                    operation: .creditUpdate,
                    forwardCount: connection.forwardCount
                ),
            ])
        case .creditUpdate:
            connection.updatePeerCredit(
                bufferAllocation: header.bufferAllocation,
                forwardCount: header.forwardCount
            )
            return GuestPacketResult()
        case .request, .reset, .invalid:
            return terminalResetResult(
                to: header,
                key: key,
                transactionEpoch: transactionEpoch
            )
        }
    }

    private func fieldsAreValid(_ header: VirtioVsockHeader) -> Bool {
        switch header.operation {
        case .readWrite:
            return header.length > 0 && header.flags == 0
        case .shutdown:
            return header.length == 0
                && header.flags != 0
                && header.flags & ~VsockShutdown.all == 0
        case .request, .response, .reset, .creditUpdate, .creditRequest:
            return header.length == 0 && header.flags == 0
        case .invalid:
            return false
        }
    }

    private func admitGuestRequest(
        header: VirtioVsockHeader,
        key: ConnectionKey,
        transactionEpoch: UInt64?
    ) -> GuestPacketResult {
        var rejected: InProcessConnection?
        var terminalResetKey: ConnectionKey?
        let admission = withLock { () -> (Listener, InProcessConnection)? in
            guard transactionEpoch == nil || transactionEpoch == lifecycleEpoch else {
                return nil
            }
            if connections[key] != nil {
                rejected = prepareTerminalResetLocked(
                    key: key,
                    transactionEpoch: transactionEpoch
                )
                if transactionEpoch != nil { terminalResetKey = key }
                return nil
            }
            guard !isQuiesced, !isResetting,
                  connections.count < limits.maximumConnections,
                  !hasPendingGuestPacketLocked(for: key),
                  !uncommittedTerminalResetKeys.contains(key),
                  let listener = listeners[header.destinationPort] else {
                rejected = prepareTerminalResetLocked(
                    key: key,
                    transactionEpoch: transactionEpoch
                )
                if transactionEpoch != nil { terminalResetKey = key }
                return nil
            }
            let connection = makeConnectionLocked(key: key, origin: .guest)
            connections[key] = connection
            return (listener, connection)
        }
        rejected?.abort()
        guard let (listener, connection) = admission else {
            // Section 5.10.6.5 requires RST for a missing listener or insufficient resources.
            return GuestPacketResult(
                responses: [makeReply(to: header, operation: .reset)],
                terminalResetKey: terminalResetKey
            )
        }
        connection.updatePeerCredit(
            bufferAllocation: header.bufferAllocation,
            forwardCount: header.forwardCount
        )
        return GuestPacketResult(
            responses: [makeReply(to: header, operation: .response)],
            invokeListener: { listener.handler(connection) }
        )
    }

    private func terminalResetResult(
        to header: VirtioVsockHeader,
        key: ConnectionKey,
        transactionEpoch: UInt64?
    ) -> GuestPacketResult {
        var removed: InProcessConnection?
        var terminalResetKey: ConnectionKey?
        withLock {
            guard transactionEpoch == nil || transactionEpoch == lifecycleEpoch else { return }
            removed = prepareTerminalResetLocked(
                key: key,
                transactionEpoch: transactionEpoch
            )
            if transactionEpoch != nil { terminalResetKey = key }
        }
        removed?.abort()
        return GuestPacketResult(
            responses: [makeReply(to: header, operation: .reset)],
            terminalResetKey: terminalResetKey
        )
    }

    private func prepareTerminalResetLocked(
        key: ConnectionKey,
        transactionEpoch: UInt64?
    ) -> InProcessConnection? {
        let removed = connections.removeValue(forKey: key)
        removePendingGuestPacketsLocked(for: key)
        closingConnections.removeValue(forKey: key)
        if transactionEpoch != nil { uncommittedTerminalResetKeys.insert(key) }
        scheduleShutdownReaperLocked()
        return removed
    }

    private func makeReply(
        to header: VirtioVsockHeader,
        operation: VirtioVsockHeader.Operation,
        forwardCount: UInt32 = 0,
        flags: UInt32 = 0
    ) -> [UInt8] {
        VirtioVsockHeader(
            sourceCID: Self.hostCID,
            destinationCID: UInt64(guestCID),
            sourcePort: header.destinationPort,
            destinationPort: header.sourcePort,
            length: 0,
            type: header.type,
            operation: operation,
            flags: flags,
            bufferAllocation: UInt32(limits.maximumInboundBytesPerConnection),
            forwardCount: forwardCount
        ).encoded()
    }

    private func makeHostPacket(
        key: ConnectionKey,
        operation: VirtioVsockHeader.Operation,
        payload: [UInt8],
        forwardCount: UInt32,
        flags: UInt32
    ) -> [UInt8] {
        VirtioVsockHeader(
            sourceCID: Self.hostCID,
            destinationCID: UInt64(guestCID),
            sourcePort: key.hostPort,
            destinationPort: key.guestPort,
            length: UInt32(payload.count),
            operation: operation,
            flags: flags,
            bufferAllocation: UInt32(limits.maximumInboundBytesPerConnection),
            forwardCount: forwardCount
        ).encoded() + payload
    }

    private func makeConnectionLocked(
        key: ConnectionKey,
        origin: ConnectionOrigin
    ) -> InProcessConnection {
        let id = UUID()
        let epoch = lifecycleEpoch
        return InProcessConnection(
            id: id,
            key: key,
            origin: origin,
            maximumInboundBytes: limits.maximumInboundBytesPerConnection,
            send: { [weak self] operation, payload, forwardCount, flags in
                self?.enqueueHostPacket(
                    id: id,
                    key: key,
                    epoch: epoch,
                    operation: operation,
                    payload: payload,
                    forwardCount: forwardCount,
                    flags: flags
                ) ?? .connectionClosed
            },
            reserveInbound: { [weak self] count in
                self?.reserveInboundBytes(
                    count,
                    id: id,
                    key: key,
                    epoch: epoch
                ) ?? .connectionClosed
            },
            releaseInbound: { [weak self] count in
                self?.releaseInboundBytes(count)
            },
            onLocalClose: { [weak self] in
                self?.markConnectionClosing(id: id, key: key, epoch: epoch)
            }
        )
    }

    private func reserveInboundBytes(
        _ count: Int,
        id: UUID,
        key: ConnectionKey,
        epoch: UInt64
    ) -> InboundReservationResult {
        withLock {
            guard !isQuiesced, !isResetting,
                  lifecycleEpoch == epoch,
                  connections[key]?.id == id else { return .connectionClosed }
            let (next, overflow) = inboundBufferedBytes.addingReportingOverflow(count)
            guard !overflow, next <= limits.maximumInboundBytesTotal else {
                return .globalCapacityExceeded
            }
            inboundBufferedBytes = next
            return .reserved
        }
    }

    private func releaseInboundBytes(_ count: Int) {
        withLock {
            inboundBufferedBytes = max(0, inboundBufferedBytes - count)
        }
    }

    private func enqueueHostPacket(
        id: UUID,
        key: ConnectionKey,
        epoch: UInt64,
        operation: VirtioVsockHeader.Operation,
        payload: [UInt8],
        forwardCount: UInt32,
        flags: UInt32
    ) -> HostPacketEnqueueResult {
        let result = withLock { () -> (HostPacketEnqueueResult, VirtioMMIOTransport?) in
            guard !isQuiesced, !isResetting,
                  lifecycleEpoch == epoch,
                  connections[key]?.id == id else {
                statisticsState.staleHostOperations &+= 1
                return (.connectionClosed, nil)
            }
            let packet = makeHostPacket(
                key: key,
                operation: operation,
                payload: payload,
                forwardCount: forwardCount,
                flags: flags
            )
            guard appendPendingGuestPacketLocked(packet, key: key) else {
                return (.capacityExceeded, nil)
            }
            return (.enqueued, lastTransport)
        }
        flushIfAttached(result.1)
        return result.0
    }

    private var pendingGuestPacketCountLocked: Int {
        pendingGuestPackets.count - pendingGuestPacketHead
    }

    private func reserveControlResponse() -> ControlResponseReservation? {
        withLock {
            guard !isQuiesced, !isResetting,
                  pendingGuestPacketCountLocked + controlResponseReservations.count
                    < limits.maximumPendingGuestPackets else {
                return nil
            }
            let (usedBytes, usedOverflow) = pendingGuestBytes.addingReportingOverflow(
                reservedControlResponseBytes
            )
            guard !usedOverflow else { return nil }
            let (next, overflow) = usedBytes.addingReportingOverflow(
                VirtioVsockHeader.byteCount
            )
            guard !overflow, next <= limits.maximumPendingGuestBytes else { return nil }
            let id = UUID()
            controlResponseReservations.insert(id)
            reservedControlResponseBytes += VirtioVsockHeader.byteCount
            return ControlResponseReservation(id: id, epoch: lifecycleEpoch)
        }
    }

    private func commitControlResponse(
        _ packet: [UInt8],
        reservation: ControlResponseReservation,
        terminalResetKey: ConnectionKey?
    ) -> Bool {
        withLock {
            guard reservation.epoch == lifecycleEpoch,
                  controlResponseReservations.remove(reservation.id) != nil else {
                return false
            }
            reservedControlResponseBytes -= VirtioVsockHeader.byteCount
            if let terminalResetKey,
               uncommittedTerminalResetKeys.remove(terminalResetKey) == nil {
                return false
            }
            guard packet.count <= VirtioVsockHeader.byteCount,
                  !isQuiesced, !isResetting else {
                return false
            }
            // The count/bytes were reserved while every ordinary append included reservations in
            // its capacity check, so this commit cannot be displaced by a concurrent host enqueue.
            pendingGuestPackets.append(PendingGuestPacket(
                id: UUID(),
                key: terminalResetKey,
                bytes: packet
            ))
            pendingGuestBytes += packet.count
            return true
        }
    }

    private func releaseControlResponse(_ reservation: ControlResponseReservation) {
        withLock {
            guard reservation.epoch == lifecycleEpoch,
                  controlResponseReservations.remove(reservation.id) != nil else { return }
            reservedControlResponseBytes -= VirtioVsockHeader.byteCount
        }
    }

    private func appendPendingGuestPacketLocked(
        _ packet: [UInt8],
        key: ConnectionKey?
    ) -> Bool {
        guard pendingGuestPacketCountLocked + controlResponseReservations.count
            < limits.maximumPendingGuestPackets else {
            return false
        }
        let (usedBytes, usedOverflow) = pendingGuestBytes.addingReportingOverflow(
            reservedControlResponseBytes
        )
        guard !usedOverflow else { return false }
        let (nextBytes, overflow) = usedBytes.addingReportingOverflow(packet.count)
        guard !overflow, nextBytes <= limits.maximumPendingGuestBytes else { return false }
        let (newPendingBytes, pendingOverflow) = pendingGuestBytes.addingReportingOverflow(
            packet.count
        )
        guard !pendingOverflow else { return false }
        pendingGuestPackets.append(PendingGuestPacket(id: UUID(), key: key, bytes: packet))
        pendingGuestBytes = newPendingBytes
        return true
    }

    private func peekPendingGuestPacketLocked() -> PendingGuestPacket? {
        guard pendingGuestPacketHead < pendingGuestPackets.count else { return nil }
        return pendingGuestPackets[pendingGuestPacketHead]
    }

    @discardableResult
    private func dequeuePendingGuestPacketLocked() -> PendingGuestPacket? {
        guard pendingGuestPacketHead < pendingGuestPackets.count,
              let packet = pendingGuestPackets[pendingGuestPacketHead] else { return nil }
        pendingGuestPackets[pendingGuestPacketHead] = nil
        pendingGuestPacketHead += 1
        pendingGuestBytes -= packet.bytes.count
        compactPendingGuestPacketsLockedIfNeeded()
        return packet
    }

    private func compactPendingGuestPacketsLockedIfNeeded() {
        guard pendingGuestPacketHead > 0 else { return }
        if pendingGuestPacketHead == pendingGuestPackets.count {
            pendingGuestPackets.removeAll(keepingCapacity: true)
            pendingGuestPacketHead = 0
        } else if pendingGuestPacketHead >= 64,
                  pendingGuestPacketHead * 2 >= pendingGuestPackets.count {
            pendingGuestPackets.removeFirst(pendingGuestPacketHead)
            pendingGuestPacketHead = 0
        }
    }

    private func removePendingGuestPacketsLocked(for key: ConnectionKey) {
        let kept = pendingGuestPackets.dropFirst(pendingGuestPacketHead)
            .compactMap { $0 }
            .filter { $0.key != key }
        pendingGuestPackets = kept.map(Optional.some)
        pendingGuestPacketHead = 0
        pendingGuestBytes = kept.reduce(into: 0) { $0 += $1.bytes.count }
    }

    private func hasPendingGuestPacketLocked(for key: ConnectionKey) -> Bool {
        pendingGuestPackets.dropFirst(pendingGuestPacketHead).contains { $0?.key == key }
    }

    private func allocateHostPortLocked(guestPort: UInt32) throws -> UInt32 {
        let lower = limits.hostPortRange.lowerBound
        let upper = limits.hostPortRange.upperBound
        let rangeCount = UInt64(upper) - UInt64(lower) + 1
        var candidate = nextHostPort
        for _ in 0..<rangeCount {
            let key = ConnectionKey(guestPort: guestPort, hostPort: candidate)
            let next = candidate == upper ? lower : candidate &+ 1
            if connections[key] == nil,
               !hasPendingGuestPacketLocked(for: key),
               !uncommittedTerminalResetKeys.contains(key) {
                nextHostPort = next
                return candidate
            }
            candidate = next
        }
        throw VirtioVsockConnectionAdmissionError.hostPortRangeExhausted
    }

    private func abortConnection(key: ConnectionKey) {
        let connection = withLock { () -> InProcessConnection? in
            let removed = connections.removeValue(forKey: key)
            removePendingGuestPacketsLocked(for: key)
            uncommittedTerminalResetKeys.remove(key)
            closingConnections.removeValue(forKey: key)
            scheduleShutdownReaperLocked()
            return removed
        }
        connection?.abort()
    }

    private func markConnectionClosing(id: UUID, key: ConnectionKey, epoch: UInt64) {
        withLock {
            guard !isQuiesced, !isResetting,
                  lifecycleEpoch == epoch,
                  connections[key]?.id == id else { return }
            closingConnections[key] = ClosingConnection(
                id: id,
                deadlineNanoseconds: addingClamped(
                    DispatchTime.now().uptimeNanoseconds,
                    limits.shutdownTimeoutNanoseconds
                )
            )
            scheduleShutdownReaperLocked()
        }
    }

    private func scheduleShutdownReaperLocked() {
        guard let deadline = closingConnections.values
            .map(\.deadlineNanoseconds)
            .min() else {
            shutdownReaper?.cancel()
            shutdownReaper = nil
            return
        }

        let timer: DispatchSourceTimer
        if let shutdownReaper {
            timer = shutdownReaper
        } else {
            let newTimer = DispatchSource.makeTimerSource(queue: shutdownReaperQueue)
            newTimer.setEventHandler { [weak self] in
                self?.reapExpiredConnections()
            }
            newTimer.activate()
            shutdownReaper = newTimer
            timer = newTimer
        }
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: deadline),
            leeway: .milliseconds(1)
        )
    }

    private func reapExpiredConnections() {
        let now = DispatchTime.now().uptimeNanoseconds
        let candidates = withLock { () -> [(ConnectionKey, ClosingConnection, InProcessConnection)] in
            closingConnections.compactMap { key, closing in
                guard closing.deadlineNanoseconds <= now,
                      let connection = connections[key],
                      connection.id == closing.id else { return nil }
                return (key, closing, connection)
            }
        }
        let candidatesWithCredit = candidates.map { candidate in
            (candidate.0, candidate.1, candidate.2, candidate.2.forwardCount)
        }

        let outcome = withLock {
            () -> ([InProcessConnection], VirtioMMIOTransport?) in
            guard !isQuiesced, !isResetting else {
                scheduleShutdownReaperLocked()
                return ([], nil)
            }
            var retired = [InProcessConnection]()
            var enqueuedReset = false
            let retryDelay = max(
                10_000_000,
                min(limits.shutdownTimeoutNanoseconds, 100_000_000)
            )
            for (key, closing, connection, forwardCount) in candidatesWithCredit {
                guard closingConnections[key]?.id == closing.id,
                      closingConnections[key]?.deadlineNanoseconds ?? UInt64.max <= now,
                      connections[key]?.id == closing.id else { continue }
                let reset = makeHostPacket(
                    key: key,
                    operation: .reset,
                    payload: [],
                    forwardCount: forwardCount,
                    flags: 0
                )
                var resetCommitted = appendPendingGuestPacketLocked(reset, key: key)
                if !resetCommitted, hasPendingGuestPacketLocked(for: key) {
                    // At the implementation shutdown deadline this flow is being reset, so its
                    // not-yet-delivered payload/SHUTDOWN packets are stale authority. Replacing
                    // them with the terminal RST makes ordinary close retirement wall-bounded.
                    removePendingGuestPacketsLocked(for: key)
                    resetCommitted = appendPendingGuestPacketLocked(reset, key: key)
                }
                guard resetCommitted else {
                    // Required responses or packets belonging to other flows are never dropped to
                    // make room. Keep this one bounded tombstone and retry on the single reaper.
                    closingConnections[key]?.deadlineNanoseconds = addingClamped(now, retryDelay)
                    continue
                }
                // The RST is committed before the live tuple is retired. Its keyed pending authority
                // prevents either host-port reuse or a guest REQUEST for this tuple until delivery.
                connections.removeValue(forKey: key)
                closingConnections.removeValue(forKey: key)
                retired.append(connection)
                enqueuedReset = true
            }
            scheduleShutdownReaperLocked()
            return (retired, enqueuedReset ? lastTransport : nil)
        }
        for connection in outcome.0 { connection.abort() }
        flushIfAttached(outcome.1)
    }

    private func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func resetTransportState(
        preserveListeners: Bool,
        remainQuiesced: Bool
    ) {
        lifecycleResetLock.lock()
        defer { lifecycleResetLock.unlock() }
        let terminallyQuiesced = withLock { () -> Bool in
            let terminal = remainQuiesced || isQuiesced
            isResetting = true
            lifecycleEpoch &+= 1
            return terminal
        }

        // Revoke service work before aborting the transport objects it may be using. Stop callbacks
        // run outside both authority and device locks; their close paths see isResetting and cannot
        // publish a new shutdown tombstone into the replacement generation.
        if terminallyQuiesced {
            serviceAdmissionAuthority.quiesce()
        } else {
            serviceAdmissionAuthority.beginReset()
        }

        let staleConnections = withLock { () -> [InProcessConnection] in
            let stale = Array(connections.values)
            connections.removeAll(keepingCapacity: true)
            pendingGuestPackets.removeAll(keepingCapacity: true)
            pendingGuestPacketHead = 0
            pendingGuestBytes = 0
            controlResponseReservations.removeAll(keepingCapacity: true)
            reservedControlResponseBytes = 0
            uncommittedTerminalResetKeys.removeAll(keepingCapacity: true)
            terminalQueues.removeAll(keepingCapacity: true)
            nextHostPort = limits.hostPortRange.lowerBound
            lastTransport = nil
            closingConnections.removeAll(keepingCapacity: true)
            shutdownReaper?.cancel()
            shutdownReaper = nil
            if !preserveListeners || terminallyQuiesced {
                listeners.removeAll(keepingCapacity: true)
            }
            return stale
        }
        for connection in staleConnections { connection.abort() }
        withLock {
            inboundBufferedBytes = 0
            // Quiesce is a terminal host lifecycle decision. A late guest MMIO reset must not
            // resurrect admission after teardown has begun.
            isQuiesced = terminallyQuiesced
            isResetting = false
        }
        if !terminallyQuiesced {
            serviceAdmissionAuthority.finishReset()
        }
    }

    private enum VsockShutdown {
        static let receive: UInt32 = 1
        static let send: UInt32 = 2
        static let all = receive | send
    }

    private final class InProcessConnection: VsockConnection, @unchecked Sendable {
        let id: UUID
        let key: ConnectionKey

        private let origin: ConnectionOrigin
        private let maximumInboundBytes: Int
        private let send: (
            VirtioVsockHeader.Operation,
            [UInt8],
            UInt32,
            UInt32
        ) -> HostPacketEnqueueResult
        private let reserveInbound: (Int) -> InboundReservationResult
        private let releaseInbound: (Int) -> Void
        private let onLocalClose: () -> Void
        private let condition = NSCondition()
        private let writeLock = NSLock()
        private var inbound = [UInt8]()
        private var forwardCountValue: UInt32 = 0
        private var isClosed = false
        private var peerSendClosed = false
        private var peerReceiveClosed = false
        private var hostSendClosed = false
        private var established: Bool
        private var peerBufferAllocation: UInt32 = 256 * 1024
        private var peerForwardCount: UInt32 = 0
        private var transmittedCount: UInt32 = 0

        private static let writeChunk = 4 * 1024

        var forwardCount: UInt32 {
            condition.lock()
            defer { condition.unlock() }
            return forwardCountValue
        }

        var isEstablished: Bool {
            condition.lock()
            defer { condition.unlock() }
            return established && !isClosed
        }

        var isPeerClosed: Bool {
            condition.lock()
            defer { condition.unlock() }
            return isClosed || peerSendClosed
        }

        init(
            id: UUID,
            key: ConnectionKey,
            origin: ConnectionOrigin,
            maximumInboundBytes: Int,
            send: @escaping (
                VirtioVsockHeader.Operation,
                [UInt8],
                UInt32,
                UInt32
            ) -> HostPacketEnqueueResult,
            reserveInbound: @escaping (Int) -> InboundReservationResult,
            releaseInbound: @escaping (Int) -> Void,
            onLocalClose: @escaping () -> Void
        ) {
            self.id = id
            self.key = key
            self.origin = origin
            self.maximumInboundBytes = maximumInboundBytes
            self.send = send
            self.reserveInbound = reserveInbound
            self.releaseInbound = releaseInbound
            self.onLocalClose = onLocalClose
            established = origin == .guest
        }

        func acceptResponse(bufferAllocation: UInt32, forwardCount: UInt32) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard origin == .host, !established, !isClosed else { return false }
            established = true
            peerBufferAllocation = min(bufferAllocation, UInt32(maximumInboundBytes))
            peerForwardCount = forwardCount
            condition.broadcast()
            return true
        }

        func receive(_ bytes: [UInt8]) -> InboundReceiveResult {
            condition.lock()
            defer { condition.unlock() }
            guard established, !isClosed, !peerSendClosed else {
                return .connectionClosed
            }
            let (next, overflow) = inbound.count.addingReportingOverflow(bytes.count)
            guard !overflow, next <= maximumInboundBytes else {
                return .perConnectionCapacityExceeded
            }
            switch reserveInbound(bytes.count) {
            case .reserved:
                inbound.append(contentsOf: bytes)
                condition.broadcast()
                return .accepted
            case .connectionClosed:
                return .connectionClosed
            case .globalCapacityExceeded:
                return .globalCapacityExceeded
            }
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            condition.lock()
            let count = min(buffer.count, inbound.count)
            guard count > 0 else {
                condition.unlock()
                return 0
            }
            inbound.prefix(count).withUnsafeBytes { source in
                buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
            }
            inbound.removeFirst(count)
            // fwd_cnt advances only when the host consumer frees receive bytes. Advancing it when
            // data is merely enqueued would falsely grant unlimited credit (VirtIO 1.3 5.10.6.3).
            forwardCountValue &+= UInt32(count)
            let credit = forwardCountValue
            let shouldUpdateCredit = established && !isClosed && !peerSendClosed
            condition.unlock()

            releaseInbound(count)
            if shouldUpdateCredit {
                // If this optional update meets outbound backpressure, CREDIT_REQUEST can recover
                // the same current counter later without dropping any payload or required reply.
                _ = send(.creditUpdate, [], credit, 0)
            }
            return count
        }

        func updatePeerCredit(bufferAllocation: UInt32, forwardCount: UInt32) {
            condition.lock()
            peerBufferAllocation = min(bufferAllocation, UInt32(maximumInboundBytes))
            peerForwardCount = forwardCount
            condition.broadcast()
            condition.unlock()
        }

        func waitForReadable(timeoutNanoseconds: UInt64?) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            if !inbound.isEmpty || isClosed || peerSendClosed { return true }
            if let timeoutNanoseconds {
                let deadline = ProcessInfo.processInfo.systemUptime
                    + Double(timeoutNanoseconds) / 1_000_000_000
                while inbound.isEmpty && !isClosed && !peerSendClosed {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    // NSCondition exposes a wall-clock Date API only. Short waits plus a monotonic
                    // outer deadline prevent clock adjustments from extending the caller's bound.
                    _ = condition.wait(
                        until: Date().addingTimeInterval(min(remaining, 0.05))
                    )
                }
            } else {
                while inbound.isEmpty && !isClosed && !peerSendClosed {
                    condition.wait()
                }
            }
            return !inbound.isEmpty || isClosed || peerSendClosed
        }

        func write(_ bytes: [UInt8]) throws {
            try write(bytes, timeoutNanoseconds: nil)
        }

        func write(_ bytes: [UInt8], timeoutNanoseconds: UInt64?) throws {
            let deadline = timeoutNanoseconds.map {
                ProcessInfo.processInfo.systemUptime + Double($0) / 1_000_000_000
            }
            writeLock.lock()
            defer { writeLock.unlock() }
            var offset = 0
            while offset < bytes.count {
                let maximumChunkCount = min(Self.writeChunk, bytes.count - offset)
                let reservation = try reserveTransmit(
                    maximumCount: UInt32(maximumChunkCount),
                    deadline: deadline
                )
                let chunkCount = Int(reservation.count)
                let result = send(
                    .readWrite,
                    Array(bytes[offset..<(offset + chunkCount)]),
                    reservation.forwardCount,
                    0
                )
                guard result == .enqueued else {
                    condition.lock()
                    transmittedCount &-= reservation.count
                    condition.unlock()
                    if result == .capacityExceeded {
                        throw VsockConnectionWriteError.outboundQueueFull
                    }
                    throw VsockConnectionWriteError.connectionClosed
                }
                offset += chunkCount
            }
        }

        private func reserveTransmit(
            maximumCount: UInt32,
            deadline: TimeInterval?
        ) throws -> (count: UInt32, forwardCount: UInt32) {
            while true {
                condition.lock()
                let writable = !isClosed && !hostSendClosed && !peerReceiveClosed
                let available = VirtioVsockCreditArithmetic.available(
                    bufferAllocation: peerBufferAllocation,
                    transmittedCount: transmittedCount,
                    peerForwardCount: peerForwardCount
                )
                if !writable {
                    condition.unlock()
                    throw VsockConnectionWriteError.connectionClosed
                }
                if established && available > 0 {
                    let count = min(maximumCount, available)
                    transmittedCount &+= count
                    let credit = forwardCountValue
                    condition.unlock()
                    return (count, credit)
                }
                if let deadline {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        condition.unlock()
                        throw VsockConnectionWriteError.timedOut
                    }
                    _ = condition.wait(
                        until: Date().addingTimeInterval(min(remaining, 0.05))
                    )
                    condition.unlock()
                } else {
                    condition.wait()
                    condition.unlock()
                }
            }
        }

        func markPeerShutdown(flags: UInt32) -> Bool {
            condition.lock()
            if flags & VsockShutdown.receive != 0 { peerReceiveClosed = true }
            if flags & VsockShutdown.send != 0 { peerSendClosed = true }
            let complete = peerReceiveClosed && peerSendClosed
            condition.broadcast()
            condition.unlock()
            return complete
        }

        func shutdownSend() {
            writeLock.lock()
            condition.lock()
            if isClosed || hostSendClosed {
                condition.unlock()
                writeLock.unlock()
                return
            }
            hostSendClosed = true
            let credit = forwardCountValue
            condition.broadcast()
            condition.unlock()
            let result = send(.shutdown, [], credit, VsockShutdown.send)
            if result != .enqueued {
                abort()
                onLocalClose()
            }
            writeLock.unlock()
        }

        func close() {
            condition.lock()
            if isClosed {
                condition.unlock()
                return
            }
            // Publish closure before waiting for write serialization. A writer can be asleep in
            // reserveTransmit with no timeout; setting this state and broadcasting is what lets it
            // release writeLock so teardown cannot deadlock behind peer-credit starvation.
            isClosed = true
            let released = inbound.count
            inbound.removeAll(keepingCapacity: false)
            let credit = forwardCountValue &+ UInt32(released)
            forwardCountValue = credit
            condition.broadcast()
            condition.unlock()
            if released > 0 { releaseInbound(released) }

            // Start the bounded retirement deadline before waiting for an in-flight writer to
            // release serialization. The writer was woken above; if it is instead stuck below the
            // connection layer, the tuple still fails closed and retires through the reaper.
            onLocalClose()
            writeLock.lock()
            _ = send(.shutdown, [], credit, VsockShutdown.all)
            // Keep a bounded tombstone until peer RST/reset; section 5.10.6.5 forbids tuple reuse
            // while the peer may still be processing the old connection.
            writeLock.unlock()
        }

        func abort() {
            condition.lock()
            if isClosed && inbound.isEmpty {
                condition.broadcast()
                condition.unlock()
                return
            }
            isClosed = true
            let released = inbound.count
            inbound.removeAll(keepingCapacity: false)
            condition.broadcast()
            condition.unlock()
            if released > 0 { releaseInbound(released) }
        }
    }
}

extension VirtioVsock: @unchecked Sendable {}
