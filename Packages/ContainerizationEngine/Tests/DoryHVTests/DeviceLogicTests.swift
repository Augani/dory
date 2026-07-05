import Foundation
import Testing
@testable import DoryHV

@Suite struct FDTBuilderTests {
    @Test func emitsValidFlattenedDeviceTreeHeader() {
        let fdt = FDTBuilder()
        fdt.beginNode("")
        fdt.property("compatible", string: "linux,dummy-virt")
        fdt.property("#address-cells", cells: [2])
        fdt.beginNode("memory@40000000")
        fdt.property("device_type", string: "memory")
        fdt.property("reg", cells64: [0x4000_0000, 0x8000_0000])
        fdt.endNode()
        fdt.endNode()
        let blob = fdt.finish(bootCPU: 0)

        func beU32(_ offset: Int) -> UInt32 {
            (UInt32(blob[offset]) << 24) | (UInt32(blob[offset + 1]) << 16)
                | (UInt32(blob[offset + 2]) << 8) | UInt32(blob[offset + 3])
        }
        #expect(beU32(0) == 0xD00D_FEED)            // magic
        #expect(beU32(4) == UInt32(blob.count))     // totalsize matches actual length
        #expect(beU32(20) == 17)                    // version
        #expect(beU32(24) == 16)                    // last_comp_version
        // off_dt_struct + size_dt_struct stay within the blob.
        let structOffset = Int(beU32(8))
        let structSize = Int(beU32(36))
        #expect(structOffset + structSize <= blob.count)
    }

    @Test func stringsAreDeduplicatedInTheStringsBlock() {
        let a = FDTBuilder()
        a.beginNode("")
        a.property("reg", cells: [1])
        a.property("reg", cells: [2])  // same property name twice
        a.endNode()
        let one = a.finish()

        let b = FDTBuilder()
        b.beginNode("")
        b.property("reg", cells: [1])
        b.property("other", cells: [2])
        b.endNode()
        let two = b.finish()
        // Reusing "reg" must not grow the strings block the way two distinct names do.
        #expect(one.count < two.count)
    }
}

@Suite struct KernelImageTests {
    private func writeImage(magic: UInt32, textOffset: UInt64, imageSize: UInt64, bytes: Int) throws -> String {
        var data = [UInt8](repeating: 0, count: max(bytes, 64))
        func putLE64(_ value: UInt64, at offset: Int) {
            for i in 0..<8 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        func putLE32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        putLE64(textOffset, at: 8)
        putLE64(imageSize, at: 16)
        putLE32(magic, at: 56)
        let path = NSTemporaryDirectory() + "/dory-kernel-test-\(textOffset)-\(bytes).img"
        try Data(data).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func parsesArm64ImageHeader() throws {
        let path = try writeImage(magic: 0x644D_5241, textOffset: 0x8_0000, imageSize: 0x20_0000, bytes: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let image = try KernelImage(contentsOf: path)
        #expect(image.textOffset == 0x8_0000)
        #expect(image.imageSize == 0x20_0000)  // declared size wins when larger than the file
    }

    @Test func rejectsBadMagic() throws {
        let path = try writeImage(magic: 0xDEAD_BEEF, textOffset: 0, imageSize: 0, bytes: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: VMError.self) { _ = try KernelImage(contentsOf: path) }
    }
}

@Suite struct DataAbortInfoTests {
    @Test func decodesWriteOfA4ByteRegister() {
        // ISV=1, SAS=0b10 (4 bytes), SSE=0, SRT=5, SF=1, WnR=1
        var syndrome: UInt64 = 0
        syndrome |= 1 << 24            // ISV
        syndrome |= 0b10 << 22         // SAS -> width 4
        syndrome |= 5 << 16            // SRT
        syndrome |= 1 << 15            // SF (64-bit reg)
        syndrome |= 1 << 6             // WnR (write)
        let info = DataAbortInfo(syndrome: syndrome)
        #expect(info.isValid)
        #expect(info.width == 4)
        #expect(info.registerIndex == 5)
        #expect(info.sixtyFourBit)
        #expect(info.isWrite)
        #expect(!info.signExtend)
    }

    @Test func decodesSignExtendedByteRead() {
        var syndrome: UInt64 = 0
        syndrome |= 1 << 24            // ISV
        syndrome |= 0b00 << 22         // SAS -> width 1
        syndrome |= 1 << 21            // SSE
        syndrome |= 31 << 16           // SRT = 31 (xzr)
        let info = DataAbortInfo(syndrome: syndrome)
        #expect(info.width == 1)
        #expect(info.registerIndex == 31)
        #expect(info.signExtend)
        #expect(!info.isWrite)
    }

    @Test func exceptionClassFromSyndrome() {
        #expect(ExceptionClass(syndrome: UInt64(0x24) << 26) == .dataAbortLowerEL)
        #expect(ExceptionClass(syndrome: UInt64(0x20) << 26) == .instructionAbortLowerEL)
        #expect(ExceptionClass(syndrome: UInt64(0x16) << 26) == .hvc64)
        #expect(ExceptionClass(syndrome: UInt64(0x17) << 26) == .smc64)
    }
}

@Suite struct MMIOBusTests {
    private final class StubDevice: MMIODevice {
        let baseAddress: UInt64
        let size: UInt64
        init(base: UInt64, size: UInt64) { self.baseAddress = base; self.size = size }
        func read(offset: UInt64, width: Int) -> UInt64 { offset }
        func write(offset: UInt64, value: UInt64, width: Int) {}
    }

    @Test func routesByAddressAndComputesOffset() {
        let bus = MMIOBus()
        let uart = StubDevice(base: 0x0C00_0000, size: 0x1000)
        let virtio = StubDevice(base: 0x0C10_0000, size: 0x200)
        bus.attach(uart)
        bus.attach(virtio)

        let hit = bus.device(for: 0x0C00_0018)
        #expect(hit?.0 === uart)
        #expect(hit?.1 == 0x18)
        #expect(bus.device(for: 0x0C10_0004)?.0 === virtio)
        #expect(bus.device(for: 0x0C10_0004)?.1 == 4)
        #expect(bus.device(for: 0x0900_0000) == nil)     // below any device
        #expect(bus.device(for: 0x0C00_1000) == nil)     // exactly past the UART window
    }
}

@Suite struct PIOBusTests {
    private final class StubDevice: PIODevice {
        let basePort: UInt16
        let portCount: UInt16
        var writes: [(offset: UInt16, value: UInt32, width: Int)] = []

        init(basePort: UInt16, portCount: UInt16) {
            self.basePort = basePort
            self.portCount = portCount
        }

        func read(portOffset: UInt16, width: Int) -> UInt32 {
            UInt32(portOffset) | (UInt32(width) << 16)
        }

        func write(portOffset: UInt16, value: UInt32, width: Int) {
            writes.append((portOffset, value, width))
        }
    }

    @Test func routesByPortAndComputesOffset() {
        let bus = PIOBus()
        let uart = StubDevice(basePort: 0x3F8, portCount: 8)
        let cmos = StubDevice(basePort: 0x70, portCount: 2)
        bus.attach(uart)
        bus.attach(cmos)

        let hit = bus.device(for: 0x3FD)
        #expect(hit?.0 === uart)
        #expect(hit?.1 == 5)
        #expect(bus.device(for: 0x71)?.0 === cmos)
        #expect(bus.device(for: 0x71)?.1 == 1)
        #expect(bus.device(for: 0x3F7) == nil)
        #expect(bus.device(for: 0x400) == nil)
    }

    @Test func readAndWriteDispatchToMappedDevice() {
        let bus = PIOBus()
        let uart = StubDevice(basePort: 0x3F8, portCount: 8)
        bus.attach(uart)

        #expect(bus.read(port: 0x3FA, width: 1) == 0x1_0002)
        bus.write(port: 0x3F8, value: 0x41, width: 1)

        #expect(uart.writes.count == 1)
        #expect(uart.writes.first?.offset == 0)
        #expect(uart.writes.first?.value == 0x41)
        #expect(uart.writes.first?.width == 1)
    }

    @Test func unmappedPortsReadAsAllOnesAndIgnoreWrites() {
        let bus = PIOBus()

        #expect(bus.read(port: 0x80, width: 1) == 0xFF)
        #expect(bus.read(port: 0x80, width: 2) == 0xFFFF)
        #expect(bus.read(port: 0x80, width: 4) == 0xFFFF_FFFF)
        #expect(bus.read(port: 0x80, width: 8) == 0)
        bus.write(port: 0x80, value: 0xDEAD_BEEF, width: 4)
    }
}

@Suite struct VirtioMMIOTransportTests {
    private final class Backend: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider {
        let deviceID: UInt32 = 26
        let deviceFeatures: UInt64 = 0
        let queueCount = 1
        let configSpace: [UInt8] = []
        let sharedMemoryRegions: [VirtioSharedMemoryRegion]

        init(sharedMemoryRegions: [VirtioSharedMemoryRegion]) {
            self.sharedMemoryRegions = sharedMemoryRegions
        }

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {}
    }

    @Test func sharedMemoryRegistersExposeSelectedRegionAndMissingSentinel() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let backend = Backend(sharedMemoryRegions: [
            VirtioSharedMemoryRegion(id: 0, guestBase: 0x1_0000_0000, length: 0x2_0000),
            VirtioSharedMemoryRegion(id: 3, guestBase: 0x2_0010_0000, length: 0x1_0000_0000),
        ])
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: backend, memory: memory) {}

        transport.write(offset: 0x0AC, value: 3, width: 4)

        #expect(transport.read(offset: 0x0B0, width: 4) == 0)
        #expect(transport.read(offset: 0x0B4, width: 4) == 1)
        #expect(transport.read(offset: 0x0B8, width: 4) == 0x0010_0000)
        #expect(transport.read(offset: 0x0BC, width: 4) == 2)

        transport.write(offset: 0x0AC, value: 99, width: 4)

        #expect(transport.read(offset: 0x0B0, width: 4) == UInt64(UInt32.max))
        #expect(transport.read(offset: 0x0B4, width: 4) == UInt64(UInt32.max))
    }
}

@Suite struct PL011Tests {
    @Test func transmitsToSinkAndReportsReadyFlags() {
        var out = [UInt8]()
        let uart = PL011(baseAddress: 0x0C00_0000) { out.append($0) }
        uart.write(offset: 0x00, value: UInt64(UInt8(ascii: "H")), width: 1)
        uart.write(offset: 0x00, value: UInt64(UInt8(ascii: "i")), width: 1)
        #expect(out == [UInt8(ascii: "H"), UInt8(ascii: "i")])
        #expect(uart.read(offset: 0x18, width: 2) == 0x90)   // FR: TX empty | RX empty
        #expect(uart.read(offset: 0xFE0, width: 4) == 0x11)  // PeriphID0
        #expect(uart.read(offset: 0xFF0, width: 4) == 0x0D)  // PCellID0
    }
}
