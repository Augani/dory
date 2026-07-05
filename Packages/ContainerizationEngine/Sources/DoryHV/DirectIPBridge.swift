import Darwin
import Foundation

public struct DirectIPBridgeConfiguration: Sendable, Equatable {
    public var subnetCIDR: String
    public var gateway: String
    public var gvproxySocketPath: String
    public var localSocketPath: String
    public var interfaceNamePath: String?

    public init(subnetCIDR: String, gateway: String, gvproxySocketPath: String, localSocketPath: String, interfaceNamePath: String? = nil) {
        self.subnetCIDR = subnetCIDR
        self.gateway = gateway
        self.gvproxySocketPath = gvproxySocketPath
        self.localSocketPath = localSocketPath
        self.interfaceNamePath = interfaceNamePath
    }
}

public enum DirectIPBridgeError: Error, Equatable, CustomStringConvertible {
    case invalidCIDR(String)
    case invalidIPv4(String)
    case unsupportedFrame
    case socket(String)

    public var description: String {
        switch self {
        case .invalidCIDR(let value): "invalid IPv4 CIDR: \(value)"
        case .invalidIPv4(let value): "invalid IPv4 address: \(value)"
        case .unsupportedFrame: "unsupported network frame"
        case .socket(let message): message
        }
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

public enum DirectIPPacketDecision: Sendable, Equatable {
    case injectToGvproxy(packet: Data, destination: DirectIPv4Address)
    case ignore(reason: String)
}

public struct DirectIPPacketBridge: Sendable {
    public static let utunIPv4Header = Data([0, 0, 0, 2])
    public static let bridgeMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xd0, 0x12, 0x01]
    public static let guestMAC: [UInt8] = VirtioNet.guestMAC

    public let route: DirectIPv4Route
    public let gateway: DirectIPv4Address

    public init(subnetCIDR: String, gateway: String) throws {
        self.route = try DirectIPv4Route(cidr: subnetCIDR)
        guard let gatewayAddress = DirectIPv4Address(gateway) else {
            throw DirectIPBridgeError.invalidIPv4(gateway)
        }
        self.gateway = gatewayAddress
    }

    public func classifyOutboundUtunFrame(_ frame: Data) -> DirectIPPacketDecision {
        guard let packet = ipv4Packet(fromUtunFrame: frame) else {
            return .ignore(reason: "not an IPv4 utun frame")
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
        frame.append(contentsOf: Self.guestMAC)
        frame.append(contentsOf: Self.bridgeMAC)
        frame.append(contentsOf: [0x08, 0x00])
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

    public func wrapInboundPacketForUtun(_ packet: Data) -> Data? {
        guard DirectIPv4Packet(bytes: packet) != nil else { return nil }
        return Self.utunIPv4Header + packet
    }

    private func ipv4Packet(fromUtunFrame frame: Data) -> DirectIPv4Packet? {
        guard frame.count >= Self.utunIPv4Header.count + 20,
              frame.prefix(Self.utunIPv4Header.count) == Self.utunIPv4Header else {
            return nil
        }
        return DirectIPv4Packet(bytes: frame.dropFirst(Self.utunIPv4Header.count))
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
    private let queue = DispatchQueue(label: "dev.dory.direct-ip-bridge")

    public init(configuration: DirectIPBridgeConfiguration, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.configuration = configuration
        self.packetBridge = try DirectIPPacketBridge(subnetCIDR: configuration.subnetCIDR, gateway: configuration.gateway)
        self.log = log
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard utunFD < 0, gvproxyFD < 0 else { return }
        let utun = try Self.openUtun()
        do {
            let gvproxy = try Self.openUnixDatagram(localPath: configuration.localSocketPath, remotePath: configuration.gvproxySocketPath)
            utunFD = utun.fileDescriptor
            gvproxyFD = gvproxy
            interfaceName = utun.interfaceName
            if let path = configuration.interfaceNamePath {
                do {
                    try "\(utun.interfaceName)\n".write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    log("direct-ip: could not write interface name to \(path): \(error)")
                }
            }
            installSources()
            log("direct-ip bridge active on \(utun.interfaceName) for \(configuration.subnetCIDR) via \(configuration.gvproxySocketPath)")
        } catch {
            close(utun.fileDescriptor)
            throw error
        }
    }

    public func stop() {
        utunSource?.cancel()
        gvproxySource?.cancel()
        utunSource = nil
        gvproxySource = nil
        utunFD = -1
        gvproxyFD = -1
        try? FileManager.default.removeItem(atPath: configuration.localSocketPath)
        if let path = configuration.interfaceNamePath {
            try? FileManager.default.removeItem(atPath: path)
        }
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
            guard received > 0 else { break }
            let frame = Data(buffer.prefix(received))
            switch packetBridge.classifyOutboundUtunFrame(frame) {
            case .injectToGvproxy(let packet, _):
                guard let ethernet = packetBridge.ethernetFrameForGvproxy(packet) else { continue }
                ethernet.withUnsafeBytes { raw in
                    _ = send(gvproxyFD, raw.baseAddress, raw.count, 0)
                }
            case .ignore:
                continue
            }
        }
    }

    private func drainGvproxy() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let received = recv(gvproxyFD, &buffer, buffer.count, MSG_DONTWAIT)
            guard received > 0 else { break }
            let frame = Data(buffer.prefix(received))
            guard let packet = packetBridge.ipv4PacketFromGvproxyFrame(frame),
                  let utunFrame = packetBridge.wrapInboundPacketForUtun(packet) else {
                continue
            }
            utunFrame.withUnsafeBytes { raw in
                _ = write(utunFD, raw.baseAddress, raw.count)
            }
        }
    }

    private static func openUnixDatagram(localPath: String, remotePath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw DirectIPBridgeError.socket("cannot create direct-ip datagram socket: errno \(errno)")
        }
        do {
            try bindUnixDatagram(descriptor, path: localPath)
            try connectUnixDatagram(descriptor, path: remotePath)
            var bufferSize = 1 << 20
            setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int>.size))
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func bindUnixDatagram(_ descriptor: Int32, path: String) throws {
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &address)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw DirectIPBridgeError.socket("cannot bind direct-ip socket \(path): errno \(errno)")
        }
    }

    private static func connectUnixDatagram(_ descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &address)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw DirectIPBridgeError.socket("cannot connect direct-ip socket \(path): errno \(errno)")
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
