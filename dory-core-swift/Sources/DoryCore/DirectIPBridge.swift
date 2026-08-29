import Darwin
import Foundation

public struct DirectIPBridgeConfiguration: Sendable, Equatable {
    public var tunnelEnabled: Bool
    public var subnetCIDR: String
    public var gateway: String
    public var ipv6SubnetCIDR: String?
    public var ipv6Gateway: String?
    public var ipv6VirtualNetworkCIDR: String?
    public var ipv6HostGateway: String?
    public var gvproxySocketPath: String
    public var localSocketPath: String
    public var interfaceNamePath: String?
    public var guestMACAddress: [UInt8]

    public init(
        subnetCIDR: String,
        gateway: String,
        tunnelEnabled: Bool = true,
        ipv6SubnetCIDR: String? = nil,
        ipv6Gateway: String? = nil,
        ipv6VirtualNetworkCIDR: String? = nil,
        ipv6HostGateway: String? = nil,
        gvproxySocketPath: String,
        localSocketPath: String,
        interfaceNamePath: String? = nil,
        guestMACAddress: [UInt8] = DirectIPPacketBridge.defaultGuestMAC
    ) {
        self.tunnelEnabled = tunnelEnabled
        self.subnetCIDR = subnetCIDR
        self.gateway = gateway
        self.ipv6SubnetCIDR = ipv6SubnetCIDR
        self.ipv6Gateway = ipv6Gateway
        self.ipv6VirtualNetworkCIDR = ipv6VirtualNetworkCIDR
        self.ipv6HostGateway = ipv6HostGateway
        self.gvproxySocketPath = gvproxySocketPath
        self.localSocketPath = localSocketPath
        self.interfaceNamePath = interfaceNamePath
        self.guestMACAddress = guestMACAddress
    }
}

public enum DirectIPBridgeError: Error, Equatable, CustomStringConvertible {
    case invalidCIDR(String)
    case invalidIPv4(String)
    case invalidIPv6(String)
    case unsupportedFrame
    case socket(String)

    public var description: String {
        switch self {
        case .invalidCIDR(let value): "invalid IPv4 CIDR: \(value)"
        case .invalidIPv4(let value): "invalid IPv4 address: \(value)"
        case .invalidIPv6(let value): "invalid IPv6 address or CIDR: \(value)"
        case .unsupportedFrame: "unsupported network frame"
        case .socket(let message): message
        }
    }
}

public struct DirectIPv6Address: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ value: String) {
        guard !value.isEmpty, !value.contains("%") else { return nil }
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        self.bytes = withUnsafeBytes(of: address) { Array($0) }
    }

    public init?(bytes: some Collection<UInt8>) {
        let materialized = Array(bytes)
        guard materialized.count == 16 else { return nil }
        self.bytes = materialized
    }

    public var description: String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return "<invalid-ipv6>"
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

public struct DirectIPv6Route: Sendable, Equatable {
    public let network: DirectIPv6Address
    public let prefixLength: Int

    public init(cidr: String) throws {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...128).contains(prefix),
              let address = DirectIPv6Address(String(parts[0])) else {
            throw DirectIPBridgeError.invalidIPv6(cidr)
        }
        self.network = address
        self.prefixLength = prefix
    }

    public func contains(_ address: DirectIPv6Address) -> Bool {
        let wholeBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        guard network.bytes.prefix(wholeBytes) == address.bytes.prefix(wholeBytes) else { return false }
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return network.bytes[wholeBytes] & mask == address.bytes[wholeBytes] & mask
    }
}

public struct DirectIPv4Address: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  let octet = UInt8(part),
                  String(octet) == part || part == "0" else {
                return nil
            }
            octets.append(octet)
        }
        rawValue = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String {
        [
            UInt8((rawValue >> 24) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8(rawValue & 0xff),
        ].map(String.init).joined(separator: ".")
    }
}

public struct DirectIPv4Route: Sendable, Equatable {
    public let network: UInt32
    public let prefixLength: Int

    public init(cidr: String) throws {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...32).contains(prefix),
              let address = DirectIPv4Address(String(parts[0])) else {
            throw DirectIPBridgeError.invalidCIDR(cidr)
        }
        self.prefixLength = prefix
        self.network = address.rawValue & Self.mask(for: prefix)
    }

    public func contains(_ address: DirectIPv4Address) -> Bool {
        (address.rawValue & Self.mask(for: prefixLength)) == network
    }

    private static func mask(for prefix: Int) -> UInt32 {
        UInt32.max << UInt32(32 - prefix)
    }
}

public struct DirectIPv4Packet: Sendable, Equatable {
    public let source: DirectIPv4Address
    public let destination: DirectIPv4Address
    public let protocolNumber: UInt8
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count >= 20 else { return nil }
        let versionAndIHL = bytes[bytes.startIndex]
        guard versionAndIHL >> 4 == 4 else { return nil }
        let headerLength = Int(versionAndIHL & 0x0f) * 4
        guard headerLength >= 20, bytes.count >= headerLength else { return nil }
        let totalLength = Int(UInt16(bytes[bytes.startIndex + 2]) << 8 | UInt16(bytes[bytes.startIndex + 3]))
        guard totalLength >= headerLength, bytes.count >= totalLength else { return nil }
        self.protocolNumber = bytes[bytes.startIndex + 9]
        self.source = DirectIPv4Address(rawValue: Self.readUInt32(bytes, offset: 12))
        self.destination = DirectIPv4Address(rawValue: Self.readUInt32(bytes, offset: 16))
        self.bytes = bytes.prefix(totalLength)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24
            | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8
            | UInt32(data[start + 3])
    }
}

public struct DirectIPv6Packet: Sendable, Equatable {
    public let source: DirectIPv6Address
    public let destination: DirectIPv6Address
    public let nextHeader: UInt8
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count >= 40, bytes[bytes.startIndex] >> 4 == 6 else { return nil }
        let payloadLength = Int(UInt16(bytes[bytes.startIndex + 4]) << 8 | UInt16(bytes[bytes.startIndex + 5]))
        let totalLength = 40 + payloadLength
        guard bytes.count >= totalLength,
              let source = DirectIPv6Address(bytes: bytes[(bytes.startIndex + 8)..<(bytes.startIndex + 24)]),
              let destination = DirectIPv6Address(bytes: bytes[(bytes.startIndex + 24)..<(bytes.startIndex + 40)]) else {
            return nil
        }
        self.source = source
        self.destination = destination
        self.nextHeader = bytes[bytes.startIndex + 6]
        self.bytes = bytes.prefix(totalLength)
    }
}

public enum DirectIPPacketDecision: Sendable, Equatable {
    case injectToGvproxy(packet: Data, destination: DirectIPv4Address)
    case injectIPv6ToGvproxy(packet: Data, destination: DirectIPv6Address)
    case ignore(reason: String)
}

public enum GVProxyQEMUFrameError: Error, Sendable, Equatable {
    case invalidFrameLength(Int)
}

/// gvproxy's QEMU switch port carries one Ethernet frame behind a four-byte big-endian length.
/// It is a separate macOS-supported Unix stream connection, unlike vfkit's single-peer datagram
/// listener, so source-preserving LAN replies return to the tunnel instead of looping to the VM.
public struct GVProxyQEMUFrameDecoder: Sendable {
    public static let maximumFrameLength = 128 * 1024
    private var buffered = Data()

    public init() {}

    public static func encode(_ frame: Data) throws -> Data {
        guard (14...maximumFrameLength).contains(frame.count) else {
            throw GVProxyQEMUFrameError.invalidFrameLength(frame.count)
        }
        let count = UInt32(frame.count)
        return Data([
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff),
        ]) + frame
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffered.append(data)
        var frames = [Data]()
        while buffered.count >= 4 {
            let start = buffered.startIndex
            let length = Int(UInt32(buffered[start]) << 24
                | UInt32(buffered[start + 1]) << 16
                | UInt32(buffered[start + 2]) << 8
                | UInt32(buffered[start + 3]))
            guard (14...Self.maximumFrameLength).contains(length) else {
                throw GVProxyQEMUFrameError.invalidFrameLength(length)
            }
            guard buffered.count >= 4 + length else { break }
            frames.append(buffered.subdata(in: (start + 4)..<(start + 4 + length)))
            buffered.removeFirst(4 + length)
        }
        return frames
    }
}

public struct DirectIPPacketBridge: Sendable {
    public static let utunIPv4Header = Data([0, 0, 0, 2])
    public static let utunIPv6Header = Data([0, 0, 0, 30])
    public static let bridgeMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xd0, 0x12, 0x01]
    /// gvproxy's canonical vfkit guest MAC, shared by raw-HV and VZ network devices.
    public static let defaultGuestMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee]

    public let route: DirectIPv4Route
    public let gateway: DirectIPv4Address
    public let ipv6Route: DirectIPv6Route?
    public let ipv6Gateway: DirectIPv6Address?
    public let guestMAC: [UInt8]

    public init(
        subnetCIDR: String,
        gateway: String,
        ipv6SubnetCIDR: String? = nil,
        ipv6Gateway: String? = nil,
        guestMAC: [UInt8] = Self.defaultGuestMAC
    ) throws {
        guard guestMAC.count == 6,
              guestMAC[0] & 0x01 == 0,
              guestMAC[0] & 0x02 == 0x02 else {
            throw DirectIPBridgeError.socket("invalid guest MAC address")
        }
        self.guestMAC = guestMAC
        self.route = try DirectIPv4Route(cidr: subnetCIDR)
        guard let gatewayAddress = DirectIPv4Address(gateway) else {
            throw DirectIPBridgeError.invalidIPv4(gateway)
        }
        self.gateway = gatewayAddress
        switch (ipv6SubnetCIDR, ipv6Gateway) {
        case (nil, nil):
            self.ipv6Route = nil
            self.ipv6Gateway = nil
        case let (cidr?, gateway?):
            self.ipv6Route = try DirectIPv6Route(cidr: cidr)
            guard let parsedGateway = DirectIPv6Address(gateway) else {
                throw DirectIPBridgeError.invalidIPv6(gateway)
            }
            self.ipv6Gateway = parsedGateway
        default:
            throw DirectIPBridgeError.invalidIPv6(ipv6SubnetCIDR ?? ipv6Gateway ?? "")
        }
    }

    public func classifyOutboundUtunFrame(_ frame: Data) -> DirectIPPacketDecision {
        if let ipv6Route, let ipv6Gateway,
           let packet = ipv6Packet(fromUtunFrame: frame) {
            guard ipv6Route.contains(packet.destination) else {
                return .ignore(reason: "destination outside routed IPv6 subnet")
            }
            guard packet.destination != ipv6Gateway else {
                return .ignore(reason: "destination is direct-IP IPv6 gateway")
            }
            return .injectIPv6ToGvproxy(packet: packet.bytes, destination: packet.destination)
        }
        guard let packet = ipv4Packet(fromUtunFrame: frame) else {
            return .ignore(reason: ipv6Route == nil ? "not an IPv4 utun frame" : "not a routed IPv4 or IPv6 utun frame")
        }
        guard route.contains(packet.destination) else {
            return .ignore(reason: "destination outside routed subnet")
        }
        guard packet.destination != gateway else {
            return .ignore(reason: "destination is direct-IP gateway")
        }
        return .injectToGvproxy(packet: packet.bytes, destination: packet.destination)
    }

    public func ethernetFrameForGvproxy(_ packet: Data) -> Data? {
        guard DirectIPv4Packet(bytes: packet) != nil else { return nil }
        var frame = Data()
        frame.append(contentsOf: guestMAC)
        frame.append(contentsOf: Self.bridgeMAC)
        frame.append(contentsOf: [0x08, 0x00])
        frame.append(packet)
        return frame
    }

    public func ethernetFrameForGvproxyIPv6(_ packet: Data) -> Data? {
        guard DirectIPv6Packet(bytes: packet) != nil else { return nil }
        var frame = Data()
        frame.append(contentsOf: guestMAC)
        frame.append(contentsOf: Self.bridgeMAC)
        frame.append(contentsOf: [0x86, 0xdd])
        frame.append(packet)
        return frame
    }

    public func ipv4PacketFromGvproxyFrame(_ frame: Data) -> Data? {
        guard frame.count >= 34 else { return nil }
        let etherTypeOffset = frame.startIndex + 12
        guard frame[etherTypeOffset] == 0x08, frame[etherTypeOffset + 1] == 0x00 else { return nil }
        let packet = frame.dropFirst(14)
        guard let parsed = DirectIPv4Packet(bytes: packet) else { return nil }
        return parsed.bytes
    }

    public func ipv6PacketFromGvproxyFrame(_ frame: Data) -> Data? {
        guard frame.count >= 54 else { return nil }
        let etherTypeOffset = frame.startIndex + 12
        guard frame[etherTypeOffset] == 0x86, frame[etherTypeOffset + 1] == 0xdd else { return nil }
        let packet = frame.dropFirst(14)
        guard let parsed = DirectIPv6Packet(bytes: packet) else { return nil }
        return parsed.bytes
    }

    public func wrapInboundPacketForUtun(_ packet: Data) -> Data? {
        guard DirectIPv4Packet(bytes: packet) != nil else { return nil }
        return Self.utunIPv4Header + packet
    }

    public func wrapInboundIPv6PacketForUtun(_ packet: Data) -> Data? {
        guard DirectIPv6Packet(bytes: packet) != nil else { return nil }
        return Self.utunIPv6Header + packet
    }

    private func ipv4Packet(fromUtunFrame frame: Data) -> DirectIPv4Packet? {
        guard frame.count >= Self.utunIPv4Header.count + 20,
              frame.prefix(Self.utunIPv4Header.count) == Self.utunIPv4Header else {
            return nil
        }
        return DirectIPv4Packet(bytes: frame.dropFirst(Self.utunIPv4Header.count))
    }

    private func ipv6Packet(fromUtunFrame frame: Data) -> DirectIPv6Packet? {
        guard frame.count >= Self.utunIPv6Header.count + 40,
              frame.prefix(Self.utunIPv6Header.count) == Self.utunIPv6Header else {
            return nil
        }
        return DirectIPv6Packet(bytes: frame.dropFirst(Self.utunIPv6Header.count))
    }
}

public final class DirectIPBridge: @unchecked Sendable {
    private static let ctlIOCGetInfo = UInt(3_227_799_043)
    private static let fioNonBlocking = UInt(2_147_772_030)
    private static let utunOptInterfaceName: Int32 = 2

    private let configuration: DirectIPBridgeConfiguration
    private let packetBridge: DirectIPPacketBridge
    private let log: @Sendable (String) -> Void
    private var utunFD: Int32 = -1
    private var gvproxyFD: Int32 = -1
    private var interfaceName: String?
    private var utunSource: (any DispatchSourceRead)?
    private var gvproxySource: (any DispatchSourceRead)?
    private var gvproxyFrameDecoder = GVProxyQEMUFrameDecoder()
    private var failureHandler: (@Sendable (String) -> Void)?
    private var failureReported = false
    private let queue = DispatchQueue(label: "dev.dory.direct-ip-bridge")
    private let queueKey = DispatchSpecificKey<UInt8>()

    public init(configuration: DirectIPBridgeConfiguration, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.configuration = configuration
        self.packetBridge = try DirectIPPacketBridge(
            subnetCIDR: configuration.subnetCIDR,
            gateway: configuration.gateway,
            ipv6SubnetCIDR: configuration.ipv6SubnetCIDR,
            ipv6Gateway: configuration.ipv6Gateway,
            guestMAC: configuration.guestMACAddress
        )
        self.log = log
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try onQueue {
            guard utunFD < 0, gvproxyFD < 0 else { return }
            let utun = try Self.openUtun()
            let gvproxy: Int32
            do {
                // Use gvproxy's dedicated QEMU stream switch port. A second vfkit datagram
                // sender shares the first peer's return address, which can inject ingress frames but
                // incorrectly loops guest replies back to the VM. QEMU gives this bridge its own CAM
                // port; GVProxyQEMUFrameDecoder preserves Ethernet packet boundaries.
                gvproxy = try Self.openUnixStream(remotePath: configuration.gvproxySocketPath)
            } catch {
                close(utun.fileDescriptor)
                throw error
            }
            utunFD = utun.fileDescriptor
            gvproxyFD = gvproxy
            interfaceName = utun.interfaceName
            failureReported = false
            gvproxyFrameDecoder = GVProxyQEMUFrameDecoder()
            if let path = configuration.interfaceNamePath {
                do {
                    try "\(utun.interfaceName)\n".write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    log("direct-ip: could not write interface name to \(path): \(error)")
                }
            }
            installSources()
            log("direct-ip bridge active on \(utun.interfaceName) for \(configuration.subnetCIDR) via \(configuration.gvproxySocketPath)")
        }
    }

    public var activeInterfaceName: String? {
        queue.sync { interfaceName }
    }

    public var isHealthy: Bool {
        queue.sync { utunFD >= 0 && gvproxyFD >= 0 && !failureReported }
    }

    public func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        let existingFailure = queue.sync { () -> Bool in
            failureHandler = handler
            return failureReported
        }
        if existingFailure { handler("gvproxy LAN switch connection is unavailable") }
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        utunSource?.cancel()
        gvproxySource?.cancel()
        utunSource = nil
        gvproxySource = nil
        utunFD = -1
        gvproxyFD = -1
        failureReported = true
        if let path = configuration.interfaceNamePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }

    private func installSources() {
        let utun = DispatchSource.makeReadSource(fileDescriptor: utunFD, queue: queue)
        utun.setEventHandler { [weak self] in self?.drainUtun() }
        utun.setCancelHandler { [fd = utunFD] in if fd >= 0 { close(fd) } }
        utun.resume()
        utunSource = utun

        let gvproxy = DispatchSource.makeReadSource(fileDescriptor: gvproxyFD, queue: queue)
        gvproxy.setEventHandler { [weak self] in self?.drainGvproxy() }
        gvproxy.setCancelHandler { [fd = gvproxyFD] in if fd >= 0 { close(fd) } }
        gvproxy.resume()
        gvproxySource = gvproxy
    }

    private func drainUtun() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let received = read(utunFD, &buffer, buffer.count)
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                if received == 0 {
                    reportFailure("utun closed while source-preserving LAN was active")
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    reportFailure("utun read failed: errno \(errno)")
                }
                break
            }
            let frame = Data(buffer.prefix(received))
            switch packetBridge.classifyOutboundUtunFrame(frame) {
            case .injectToGvproxy(let packet, _):
                guard let ethernet = packetBridge.ethernetFrameForGvproxy(packet) else { continue }
                writeGvproxyFrame(ethernet)
            case .injectIPv6ToGvproxy(let packet, _):
                guard let ethernet = packetBridge.ethernetFrameForGvproxyIPv6(packet) else { continue }
                writeGvproxyFrame(ethernet)
            case .ignore:
                continue
            }
        }
    }

    private func drainGvproxy() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let received = recv(gvproxyFD, &buffer, buffer.count, MSG_DONTWAIT)
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                if received == 0 {
                    reportFailure("gvproxy closed the LAN switch connection")
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    reportFailure("gvproxy LAN switch read failed: errno \(errno)")
                }
                break
            }
            let frames: [Data]
            do {
                frames = try gvproxyFrameDecoder.append(Data(buffer.prefix(received)))
            } catch {
                reportFailure("invalid gvproxy QEMU frame: \(error)")
                return
            }
            for frame in frames {
                let utunFrame: Data?
                if let packet = packetBridge.ipv4PacketFromGvproxyFrame(frame) {
                    utunFrame = packetBridge.wrapInboundPacketForUtun(packet)
                } else if let packet = packetBridge.ipv6PacketFromGvproxyFrame(frame) {
                    utunFrame = packetBridge.wrapInboundIPv6PacketForUtun(packet)
                } else {
                    utunFrame = nil
                }
                guard let utunFrame else { continue }
                let written = utunFrame.withUnsafeBytes { raw -> Int in
                    while true {
                        let result = write(utunFD, raw.baseAddress, raw.count)
                        if result < 0, errno == EINTR { continue }
                        return result
                    }
                }
                guard written == utunFrame.count else {
                    reportFailure("utun write failed: wrote \(written) of \(utunFrame.count) bytes, errno \(errno)")
                    return
                }
            }
        }
    }

    private func writeGvproxyFrame(_ frame: Data) {
        guard let encoded = try? GVProxyQEMUFrameDecoder.encode(frame) else { return }
        encoded.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = send(gvproxyFD, pointer, remaining, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    reportFailure("gvproxy LAN switch write failed: errno \(errno)")
                    return
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private func reportFailure(_ detail: String) {
        guard !failureReported else { return }
        failureReported = true
        log("direct-ip: \(detail)")
        failureHandler?(detail)
    }

    private static func openUnixStream(remotePath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DirectIPBridgeError.socket("cannot create direct-ip QEMU socket: errno \(errno)")
        }
        do {
            try connectUnixStream(descriptor, path: remotePath)
            var bufferSize = 1 << 20
            setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw DirectIPBridgeError.socket("cannot suppress SIGPIPE on direct-ip QEMU socket: errno \(errno)")
            }
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            guard setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw DirectIPBridgeError.socket("cannot bound direct-ip QEMU send time: errno \(errno)")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func connectUnixStream(_ descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &address)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw DirectIPBridgeError.socket("cannot connect direct-ip QEMU socket \(path): errno \(errno)")
        }
    }

    private static func copyPath(_ path: String, into address: inout sockaddr_un) {
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
    }

    private static func openUtun() throws -> (fileDescriptor: Int32, interfaceName: String) {
        let descriptor = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard descriptor >= 0 else {
            throw DirectIPBridgeError.socket("cannot create utun control socket: errno \(errno)")
        }
        var info = ctl_info()
        UTUN_CONTROL_NAME.withCString { name in
            withUnsafeMutableBytes(of: &info.ctl_name) { destination in
                destination.copyBytes(from: UnsafeRawBufferPointer(start: name, count: min(strlen(name), destination.count - 1)))
            }
        }
        guard ioctl(descriptor, ctlIOCGetInfo, &info) == 0 else {
            close(descriptor)
            throw DirectIPBridgeError.socket("cannot resolve utun control id: errno \(errno)")
        }
        var address = sockaddr_ctl()
        address.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        address.sc_family = sa_family_t(AF_SYSTEM)
        address.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        address.sc_id = info.ctl_id
        address.sc_unit = 0
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw DirectIPBridgeError.socket("cannot connect utun control socket: errno \(errno)")
        }
        var nonblocking: Int32 = 1
        _ = ioctl(descriptor, fioNonBlocking, &nonblocking)
        return (descriptor, try interfaceName(for: descriptor))
    }

    private static func interfaceName(for descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(buffer.count)
        let result = getsockopt(descriptor, SYSPROTO_CONTROL, utunOptInterfaceName, &buffer, &length)
        guard result == 0 else {
            throw DirectIPBridgeError.socket("cannot read utun interface name: errno \(errno)")
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
