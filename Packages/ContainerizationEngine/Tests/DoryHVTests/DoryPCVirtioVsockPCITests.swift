import DoryMachinePC
import Foundation
import Testing
@testable import DoryHV

@Suite struct DoryPCVirtioVsockPCITests {
    @Test func guestRequestCrossesPCIQueuesAndPublishesResponse() throws {
        let device = try DoryPCVirtioVsockPCIDevice(
            address: .init(bus: 0, device: 10, function: 0),
            initialBARAddress: 0xD000_E000
        )
        let machine = try DoryPCDirectKernelMachine(
            memoryBytes: 2 * 1024 * 1024,
            pciFunctions: [device]
        )
        let accepted = PCVsockLockedValue<VsockConnection?>(nil)
        let listener = try device.vsock.registerListener(port: 1_024) { connection in
            accepted.withValue { $0 = connection }
        }
        defer { listener.close() }

        try device.writeConfiguration(offset: 4, bytes: [2, 0])
        try write32(machine, 0xD000_E008, 1)
        try write32(machine, 0xD000_E00C, 1)
        try write8(machine, 0xD000_E014, 0x0F)
        try configureQueue(
            0,
            descriptor: 0x1000,
            available: 0x2000,
            used: 0x3000,
            machine: machine
        )
        try configureQueue(
            1,
            descriptor: 0x5000,
            available: 0x6000,
            used: 0x7000,
            machine: machine
        )

        try writeDescriptor(
            machine,
            at: 0x1000,
            address: 0x4000,
            length: 256,
            flags: 2,
            next: 0
        )
        try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

        let request = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 1_024,
            length: 0,
            operation: .request
        ).encoded()
        try writeDescriptor(
            machine,
            at: 0x5000,
            address: 0x8000,
            length: UInt32(request.count),
            flags: 0,
            next: 0
        )
        try machine.physicalMemory.write(at: 0x8000, bytes: request)
        try machine.physicalMemory.write(at: 0x6000, bytes: [0, 0, 1, 0, 0, 0])

        try write16(machine, 0xD000_E104, 1)

        #expect(accepted.value != nil)
        #expect(read16(try machine.physicalMemory.read(at: 0x7002, byteCount: 2)) == 1)
        #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
        #expect(read32(try machine.physicalMemory.read(at: 0x3004, byteCount: 4)) == 0)
        #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 44)
        let response = try VirtioVsockHeader(decoding: machine.physicalMemory.read(
            at: 0x4000,
            byteCount: VirtioVsockHeader.byteCount
        ))
        #expect(response.operation == .response)
        #expect(response.sourceCID == 2)
        #expect(response.destinationCID == 3)
    }

    @Test func replacementTransportPreservesListenersButRevokesConnections() throws {
        let vsock = VirtioVsock(guestCID: 3)
        let listener = try vsock.registerListener(port: 1_024) { _ in }
        defer { listener.close() }
        _ = try DoryPCVirtioVsockPCIDevice(
            address: .init(bus: 0, device: 10, function: 0),
            initialBARAddress: 0xD000_E000,
            vsock: vsock
        )

        try vsock.consumeTransportNeutralGuestPacket(VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: 40_000,
            destinationPort: 1_024,
            length: 0,
            operation: .request
        ).encoded())
        #expect(vsock.resourceSnapshot.connections == 1)

        vsock.resetTransportNeutralDevice()
        _ = try DoryPCVirtioVsockPCIDevice(
            address: .init(bus: 0, device: 10, function: 0),
            initialBARAddress: 0xD000_E000,
            vsock: vsock
        )
        #expect(vsock.resourceSnapshot.connections == 0)
        #expect(vsock.resourceSnapshot.listeners == 1)
    }

    private func configureQueue(
        _ queue: UInt16,
        descriptor: UInt64,
        available: UInt64,
        used: UInt64,
        machine: DoryPCDirectKernelMachine
    ) throws {
        try write16(machine, 0xD000_E016, queue)
        try write16(machine, 0xD000_E018, 8)
        try write64(machine, 0xD000_E020, descriptor)
        try write64(machine, 0xD000_E028, available)
        try write64(machine, 0xD000_E030, used)
        try write16(machine, 0xD000_E01C, 1)
    }

    private func writeDescriptor(
        _ machine: DoryPCDirectKernelMachine,
        at tableAddress: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        try machine.physicalMemory.write(
            at: tableAddress,
            bytes: littleEndian(address) + littleEndian(length)
                + littleEndian(flags) + littleEndian(next)
        )
    }

    private func write8(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt8)
        throws
    {
        try machine.physicalMemory.write(at: address, bytes: [value])
    }

    private func write16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt16)
        throws
    {
        try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
    }

    private func write32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt32)
        throws
    {
        try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
    }

    private func write64(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt64)
        throws
    {
        try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
    }
}

private func read16(_ bytes: [UInt8]) -> UInt16 {
    UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func read32(_ bytes: [UInt8]) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[$1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private final class PCVsockLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
