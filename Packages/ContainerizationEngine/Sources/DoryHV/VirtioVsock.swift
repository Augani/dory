import Foundation

public struct VirtioVsockHeader: Equatable {
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

    public enum Operation: UInt16 {
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
        let data = Array(bytes)
        guard data.count >= Self.byteCount else {
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

    public func reply(operation: Operation, length: UInt32 = 0, forwardCount: UInt32? = nil) -> VirtioVsockHeader {
        VirtioVsockHeader(
            sourceCID: destinationCID,
            destinationCID: sourceCID,
            sourcePort: destinationPort,
            destinationPort: sourcePort,
            length: length,
            type: type,
            operation: operation,
            flags: flags,
            bufferAllocation: bufferAllocation,
            forwardCount: forwardCount ?? self.forwardCount
        )
    }
}

public protocol VsockConnection: AnyObject {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func write(_ bytes: [UInt8]) throws
    func close()
}

public enum VsockPorts {
    public static let agent: UInt32 = 1024
}

public final class VirtioVsock: VirtioDeviceBackend {
    public let deviceID: UInt32 = 19
    public let queueCount = 3
    public let deviceFeatures: UInt64 = 0
    public var configSpace: [UInt8] {
        var bytes = [UInt8]()
        var cid = UInt64(guestCID).littleEndian
        withUnsafeBytes(of: &cid) { bytes.append(contentsOf: $0) }
        return bytes
    }

    private let guestCID: UInt32
    private let stateLock = NSLock()
    private var listeners: [UInt32: (VsockConnection) -> Void] = [:]
    private var connections: [ConnectionKey: InProcessConnection] = [:]
    private var pendingGuestPackets: [[UInt8]] = []
    private var nextHostPort: UInt32 = 49_152
    private weak var lastTransport: VirtioMMIOTransport?

    private struct ConnectionKey: Hashable {
        var guestPort: UInt32
        var hostPort: UInt32
    }

    public init(guestCID: UInt32) {
        self.guestCID = guestCID
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public func listen(port: UInt32, handler: @escaping (VsockConnection) -> Void) {
        withLock { listeners[port] = handler }
    }

    public func connect(port guestPort: UInt32) -> VsockConnection {
        let (key, connection) = withLock { () -> (ConnectionKey, InProcessConnection) in
            let hostPort = allocateHostPortLocked()
            let key = ConnectionKey(guestPort: guestPort, hostPort: hostPort)
            let connection = InProcessConnection(key: key) { [weak self] operation, payload, forwardCount in
                self?.enqueueHostPacket(key: key, operation: operation, payload: payload, forwardCount: forwardCount)
            } onClose: { [weak self] key in
                self?.removeConnection(key: key)
            }
            connections[key] = connection
            return (key, connection)
        }
        enqueueHostPacket(key: key, operation: .request)
        return connection
    }

    private func removeConnection(key: ConnectionKey) {
        withLock { _ = connections.removeValue(forKey: key) }
    }

    public func drainPendingGuestPackets() -> [[UInt8]] {
        withLock {
            defer { pendingGuestPackets.removeAll() }
            return pendingGuestPackets
        }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        withLock { lastTransport = transport }
        if queue == 0 {
            flushPendingGuestPackets(transport: transport)
            return
        }
        guard queue == 1 else { return }
        let virtqueue = transport.queues[1]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let packet = chain.readBytes()
            let responses = (try? receive(packet: packet)) ?? []
            for response in responses {
                if let rx = (try? transport.queues[0].pop()) ?? nil {
                    let written = rx.writeBytes(response)
                    let wants = (try? transport.queues[0].push(rx, written: written)) ?? false
                    interrupt = interrupt || wants
                }
            }
            let wants = (try? virtqueue.push(chain, written: 0)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        withLock { lastTransport = transport }
    }

    private func flushPendingGuestPackets(transport: VirtioMMIOTransport) {
        var interrupt = false
        while withLock({ !pendingGuestPackets.isEmpty }), let rx = (try? transport.queues[0].pop()) ?? nil {
            let packet = withLock { pendingGuestPackets.removeFirst() }
            let written = rx.writeBytes(packet)
            let wants = (try? transport.queues[0].push(rx, written: written)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    public func receive(packet: [UInt8]) throws -> [[UInt8]] {
        let header = try VirtioVsockHeader(decoding: packet.prefix(VirtioVsockHeader.byteCount))
        let payload = Array(packet.dropFirst(VirtioVsockHeader.byteCount))
        let key = ConnectionKey(guestPort: header.sourcePort, hostPort: header.destinationPort)
        switch header.operation {
        case .request:
            let listener = withLock { listeners[header.destinationPort] }
            guard let listener else {
                return [header.reply(operation: .reset).encoded()]
            }
            let connection = withLock { () -> InProcessConnection in
                let connection = InProcessConnection(key: key) { [weak self] operation, payload, forwardCount in
                    self?.enqueueHostPacket(key: key, operation: operation, payload: payload, forwardCount: forwardCount)
                } onClose: { [weak self] key in
                    self?.removeConnection(key: key)
                }
                connections[key] = connection
                return connection
            }
            listener(connection)
            return [header.reply(operation: .response).encoded()]
        case .readWrite:
            let connection = withLock { connections[key] }
            guard let connection, UInt32(payload.count) <= header.bufferAllocation else {
                return [header.reply(operation: .reset).encoded()]
            }
            connection.receive(payload)
            return [header.reply(operation: .creditUpdate, forwardCount: connection.forwardCount).encoded()]
        case .shutdown, .reset:
            withLock { connections.removeValue(forKey: key) }?.close()
            return [header.reply(operation: .shutdown).encoded()]
        case .creditRequest:
            return [header.reply(operation: .creditUpdate).encoded()]
        case .response:
            return []
        case .creditUpdate:
            return []
        case .invalid:
            return []
        }
    }

    private func allocateHostPortLocked() -> UInt32 {
        defer { nextHostPort &+= 1 }
        return nextHostPort
    }

    private func enqueueHostPacket(
        key: ConnectionKey,
        operation: VirtioVsockHeader.Operation,
        payload: [UInt8] = [],
        forwardCount: UInt32 = 0
    ) {
        let header = VirtioVsockHeader(
            sourceCID: 2,
            destinationCID: UInt64(guestCID),
            sourcePort: key.hostPort,
            destinationPort: key.guestPort,
            length: UInt32(payload.count),
            operation: operation,
            forwardCount: forwardCount
        )
        let transport = withLock { () -> VirtioMMIOTransport? in
            pendingGuestPackets.append(header.encoded() + payload)
            return lastTransport
        }
        if let transport {
            transport.withQueueLock {
                flushPendingGuestPackets(transport: transport)
            }
        }
    }

    private final class InProcessConnection: VsockConnection {
        let key: ConnectionKey
        private let send: (VirtioVsockHeader.Operation, [UInt8], UInt32) -> Void
        private let onClose: (ConnectionKey) -> Void
        private var inbound = [UInt8]()
        private(set) var forwardCount: UInt32 = 0
        private var isClosed = false

        init(
            key: ConnectionKey,
            send: @escaping (VirtioVsockHeader.Operation, [UInt8], UInt32) -> Void,
            onClose: @escaping (ConnectionKey) -> Void
        ) {
            self.key = key
            self.send = send
            self.onClose = onClose
        }

        func receive(_ bytes: [UInt8]) {
            inbound.append(contentsOf: bytes)
            forwardCount &+= UInt32(bytes.count)
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            guard !isClosed else { return 0 }
            let count = min(buffer.count, inbound.count)
            guard count > 0 else { return 0 }
            inbound.prefix(count).withUnsafeBytes { source in
                buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
            }
            inbound.removeFirst(count)
            return count
        }

        func write(_ bytes: [UInt8]) throws {
            guard !isClosed else { return }
            send(.readWrite, bytes, forwardCount)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            send(.shutdown, [], forwardCount)
            inbound.removeAll()
            onClose(key)
        }
    }
}

extension VirtioVsock: @unchecked Sendable {}
