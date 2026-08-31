import DoryMachinePC
import DoryVirtio
import Foundation

/// VirtIO-vsock over the DoryPC PCI transport. Connection semantics remain owned by the hardened
/// transport-neutral edges on `VirtioVsock`; this type only validates and copies split-ring chains.
public final class DoryPCVirtioVsockPCIDevice: DoryPCPCIFunction,
    DoryPCPCIMSIControllable, DoryPCPCIINTxControllable,
    DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer, @unchecked Sendable
{
    public let pciFunction: DoryPCVirtioPCIFunction
    public let vsock: VirtioVsock

    public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
    public var configurationFunction: DoryPCPCIConfigurationFunction {
        pciFunction.configurationFunction
    }
    public var barIndex: Int { pciFunction.barIndex }
    public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

    public convenience init(
        address: DoryPCPCIAddress,
        initialBARAddress: UInt64,
        guestCID: UInt32 = 3,
        maximumQueueSize: UInt16 = 256
    ) throws {
        try self.init(
            address: address,
            initialBARAddress: initialBARAddress,
            vsock: VirtioVsock(guestCID: guestCID),
            maximumQueueSize: maximumQueueSize
        )
    }

    /// Rebinds an existing service authority to a replacement PCI function during a full machine
    /// reset. Callers reset the vsock before rebinding so listeners survive but guest connections do
    /// not cross machine generations.
    public init(
        address: DoryPCPCIAddress,
        initialBARAddress: UInt64,
        vsock: VirtioVsock,
        maximumQueueSize: UInt16 = 256
    ) throws {
        self.vsock = vsock
        pciFunction = try .init(
            address: address,
            virtioDeviceID: 19,
            classCode: 0x078000,
            initialBARAddress: initialBARAddress,
            queueCount: 3,
            maximumQueueSize: maximumQueueSize,
            offeredFeatures: [.indirectDescriptors, .eventIndex],
            deviceConfiguration: vsock.configSpace,
            onReset: { [vsock] in vsock.resetTransportNeutralDevice() }
        )
        vsock.setTransportNeutralReceiveReadySink {
            [weak transport = pciFunction.transport] in
            transport?.processQueue(0)
        }
    }

    public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
        transport.connectQueueProcessor(
            memory: memory,
            canProcess: { [vsock] queue in
                switch queue {
                case 0: vsock.hasPendingTransportNeutralPacket
                case 1: vsock.hasTransportNeutralControlResponseCapacity
                default: true
                }
            },
            processor: { [vsock] queue, chain, memory in
                switch queue {
                case 0:
                    guard !chain.descriptors.isEmpty,
                          chain.descriptors.allSatisfy({ $0.deviceWillWrite && $0.length > 0 }),
                          chain.writableByteCount >= UInt64(VirtioVsockHeader.byteCount) else {
                        return 0
                    }
                    return try Self.publishReceive(
                        vsock: vsock,
                        chain: chain,
                        memory: memory
                    )
                case 1:
                    let packet: [UInt8]
                    do {
                        packet = try Self.readTransmit(chain: chain, memory: memory)
                    } catch VirtioVsockTransportNeutralError.malformedTransmitPacket {
                        return 0
                    }
                    try vsock.consumeTransportNeutralGuestPacket(
                        packet
                    )
                    return 0
                case 2:
                    return 0
                default:
                    throw DoryPCVirtioPCIError.invalidQueue(queue)
                }
            }
        )
    }

    public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
        try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
    }

    public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
        try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
    }

    public func connectMSISink(
        _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
    ) {
        pciFunction.connectMSISink(sink)
    }

    public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
        try pciFunction.readBAR(offset: offset, byteCount: byteCount)
    }

    public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
        try pciFunction.writeBAR(offset: offset, bytes: bytes)
    }

    private static func readTransmit(
        chain: DoryVirtioDescriptorChain,
        memory: any DoryVirtioGuestMemory
    ) throws -> [UInt8] {
        guard !chain.descriptors.isEmpty,
              chain.descriptors.allSatisfy({ !$0.deviceWillWrite && $0.length > 0 }),
              chain.readableByteCount >= UInt64(VirtioVsockHeader.byteCount) else {
            throw VirtioVsockTransportNeutralError.malformedTransmitPacket
        }
        let headerBytes = try readPrefix(
            descriptors: chain.descriptors,
            byteCount: VirtioVsockHeader.byteCount,
            memory: memory
        )
        let header = try VirtioVsockHeader(decoding: headerBytes)
        let maximumPayload = VirtioVsockLimits.linuxMaximumPacketPayloadBytes
        let requestedPayload = Int(exactly: header.length)
        let packetBytes: Int
        if let requestedPayload, requestedPayload <= maximumPayload,
           UInt64(VirtioVsockHeader.byteCount + requestedPayload) <= chain.readableByteCount {
            packetBytes = VirtioVsockHeader.byteCount + requestedPayload
        } else {
            packetBytes = VirtioVsockHeader.byteCount
        }
        return try readPrefix(
            descriptors: chain.descriptors,
            byteCount: packetBytes,
            memory: memory
        )
    }

    private static func publishReceive(
        vsock: VirtioVsock,
        chain: DoryVirtioDescriptorChain,
        memory: any DoryVirtioGuestMemory
    ) throws -> UInt32 {
        let maximum = Int(min(
            chain.writableByteCount,
            UInt64(VirtioVsockHeader.byteCount + VirtioVsockLimits.linuxMaximumPacketPayloadBytes)
        ))
        let written = try vsock.publishTransportNeutralGuestPacket(
            maximumBytes: maximum
        ) { bytes in
            try write(bytes, descriptors: chain.descriptors, memory: memory)
        } ?? 0
        return UInt32(written)
    }

    private static func readPrefix(
        descriptors: [DoryVirtioDescriptor],
        byteCount: Int,
        memory: any DoryVirtioGuestMemory
    ) throws -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(byteCount)
        for descriptor in descriptors where result.count < byteCount {
            let count = min(Int(descriptor.length), byteCount - result.count)
            result += try memory.read(at: descriptor.address, byteCount: count)
        }
        guard result.count == byteCount else {
            throw VirtioVsockTransportNeutralError.malformedTransmitPacket
        }
        return result
    }

    private static func write(
        _ bytes: [UInt8],
        descriptors: [DoryVirtioDescriptor],
        memory: any DoryVirtioGuestMemory
    ) throws {
        var offset = 0
        for descriptor in descriptors where offset < bytes.count {
            let count = min(Int(descriptor.length), bytes.count - offset)
            try memory.write(
                at: descriptor.address,
                bytes: Array(bytes[offset..<(offset + count)])
            )
            offset += count
        }
        guard offset == bytes.count else {
            throw VirtioVsockTransportNeutralError.receivePublicationRevoked
        }
    }
}
