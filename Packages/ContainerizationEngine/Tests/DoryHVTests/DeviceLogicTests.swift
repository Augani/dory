import Foundation
import Darwin
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

@Suite struct VirtioBlkTests {
    private func makeDisk(byteCount: Int = 4096) throws -> String {
        let path = NSTemporaryDirectory() + "/dory-virtioblk-test-\(UUID().uuidString).img"
        try Data(repeating: 0, count: byteCount).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func defaultsToSingleQueueWithoutMQFeature() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        #expect(block.queueCount == 1)
        #expect(block.deviceFeatures & (1 << 9) != 0)
        #expect(block.deviceFeatures & (1 << 12) == 0)
        #expect(block.configSpace.leUInt16(at: 34) == 1)
    }

    @Test func multiqueueAdvertisesQueueCountInConfigSpace() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let block = try VirtioBlk(path: path, identity: "test", queueCount: 4)

        #expect(block.queueCount == 4)
        #expect(block.deviceFeatures & (1 << 12) != 0)
        #expect(block.configSpace.leUInt16(at: 34) == 4)
    }

    @Test func queueCountIsClampedToVirtioMMIOLimits() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let tooLow = try VirtioBlk(path: path, identity: "test", queueCount: 0)
        let tooHigh = try VirtioBlk(path: path, identity: "test", queueCount: 99)

        #expect(tooLow.queueCount == 1)
        #expect(tooHigh.queueCount == 16)
    }

    @Test func advertisesDiscardAndWriteZeroesByDefault() throws {
        let path = try makeDisk(byteCount: 1 << 20)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        #expect(block.deviceFeatures & (1 << 13) != 0)  // VIRTIO_BLK_F_DISCARD
        #expect(block.deviceFeatures & (1 << 14) != 0)  // VIRTIO_BLK_F_WRITE_ZEROES
        #expect(block.configSpace.count >= 60)
        #expect(block.configSpace.leUInt32(at: 36) > 0)  // max_discard_sectors
        #expect(block.configSpace.leUInt32(at: 48) > 0)  // max_write_zeroes_sectors
        #expect(block.configSpace[56] == 1)              // write_zeroes_may_unmap
    }

    @Test func readOnlyImageAdvertisesReadOnlyFeatureAndNoDiscard() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ro = try VirtioBlk(path: path, identity: "test", readOnly: true, queueCount: 1)
        let rw = try VirtioBlk(path: path, identity: "test", readOnly: false, queueCount: 1)

        #expect(ro.deviceFeatures & (1 << 5) != 0)   // VIRTIO_BLK_F_RO advertised
        #expect(ro.deviceFeatures & (1 << 13) == 0)  // discard off for read-only
        #expect(rw.deviceFeatures & (1 << 5) == 0)   // writable image: no RO bit
    }

    @Test func recordsFlushCountMaximumLatencyAndSlowThreshold() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [UInt64] = [10, 310]

            func next() -> UInt64 {
                lock.withLock { values.removeFirst() }
            }
        }
        let clock = Clock()
        let block = try VirtioBlk(
            path: path,
            identity: "test",
            queueCount: 1,
            flushTelemetry: VirtioBlkFlushTelemetryConfiguration(
                slowThresholdNanoseconds: 300,
                synchronize: { _ in 0 },
                monotonicNanoseconds: { clock.next() }
            )
        )

        #expect(block.flush() == .ok)
        #expect(block.statistics == VirtioBlkStatistics(
            flushes: 1,
            maximumFlushLatencyNanoseconds: 300,
            slowFlushes: 1
        ))
    }

    @Test func discardCanBeDisabled() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1, discard: false)

        #expect(block.deviceFeatures & (1 << 13) == 0)
        #expect(block.deviceFeatures & (1 << 14) == 0)
        #expect(block.configSpace.count == 36)
    }

    @Test func disabledDiscardRejectsRequestsWithoutChangingData() throws {
        let path = try makeDisk(byteCount: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xA5, count: 4096).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1, discard: false)
        var range = [UInt8]()
        range.appendLE(UInt64(0))
        range.appendLE(UInt32(8))
        range.appendLE(UInt32(0))

        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        #expect(status == .unsupported)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0xA5 })
    }

    @Test func discardRejectsMoreThanAdvertisedSegmentsBeforeMutation() throws {
        let path = try makeDisk(byteCount: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)
        var ranges = [UInt8]()
        for _ in 0...256 {
            ranges.appendLE(UInt64(0))
            ranges.appendLE(UInt32(1))
            ranges.appendLE(UInt32(0))
        }

        let status = ranges.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        #expect(status == .ioError)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x5A })
    }

    @Test func writeZeroesRejectsUnknownFlagsWithoutChangingData() throws {
        let path = try makeDisk(byteCount: 8192)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0x3C, count: 8192).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)
        var range = [UInt8]()
        range.appendLE(UInt64(0))
        range.appendLE(UInt32(8))
        range.appendLE(UInt32(0))
        // A later malformed range must be rejected before the first valid range is zeroed.
        range.appendLE(UInt64(8))
        range.appendLE(UInt32(8))
        range.appendLE(UInt32(2))

        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true)
        }

        #expect(status == .unsupported)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x3C })
    }

    @Test func writeZeroesRejectsRangeLargerThanAdvertisedLimit() throws {
        let path = try makeDisk()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(truncate(path, off_t(3) * 1024 * 1024 * 1024) == 0)
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)
        var range = [UInt8]()
        range.appendLE(UInt64(0))
        range.appendLE(UInt32((1 << 22) + 1))
        range.appendLE(UInt32(0))

        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true)
        }

        #expect(status == .ioError)
    }

    @Test func discardPunchesHoleReadingBackZeros() throws {
        let path = try makeDisk(byteCount: 12288)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xFF, count: 12288).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(8))   // start sector 8 -> byte 4096
        range.appendLE(UInt32(8))   // 8 sectors -> 4096 bytes
        range.appendLE(UInt32(0))   // flags
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        #expect(status == .ok)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data[4095] == 0xFF)
        #expect(Array(data[4096..<8192]).allSatisfy { $0 == 0 })
        #expect(data[8192] == 0xFF)
    }

    @Test func alignedDiscardReturnsAllocatedBlocksToHost() throws {
        let byteCount = 1 << 20
        let path = try makeDisk(byteCount: byteCount)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xA5, count: byteCount).write(to: URL(fileURLWithPath: path))
        var beforeInfo = stat()
        let beforeStatus = path.withCString { Darwin.lstat($0, &beforeInfo) }
        try #require(beforeStatus == 0)
        let before = Int64(beforeInfo.st_blocks) * 512
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(0))
        range.appendLE(UInt32(byteCount / 512))
        range.appendLE(UInt32(0))
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        var afterInfo = stat()
        let afterStatus = path.withCString { Darwin.lstat($0, &afterInfo) }
        try #require(afterStatus == 0)
        let after = Int64(afterInfo.st_blocks) * 512
        #expect(status == .ok)
        #expect(after < before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0 })
    }

    @Test func subBlockDiscardMayNoOpInsteadOfAllocatingAZeroFallback() throws {
        let path = try makeDisk(byteCount: 8192)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xCC, count: 8192).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(2))
        range.appendLE(UInt32(4))
        range.appendLE(UInt32(0))
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        #expect(status == .ok)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0xCC })
    }

    @Test func writeZeroesWithoutUnmapZerosRange() throws {
        let path = try makeDisk(byteCount: 8192)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xAB, count: 8192).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(0))
        range.appendLE(UInt32(2))   // 1024 bytes
        range.appendLE(UInt32(0))   // no unmap flag
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true)
        }

        #expect(status == .ok)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(Array(data[0..<1024]).allSatisfy { $0 == 0 })
        #expect(data[1024] == 0xAB)
    }

    @Test func unalignedWriteZeroesWithUnmapStillUsesZeroFallback() throws {
        let path = try makeDisk(byteCount: 8192)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xAB, count: 8192).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(2))
        range.appendLE(UInt32(4))
        range.appendLE(UInt32(1)) // VIRTIO_BLK_WRITE_ZEROES_FLAG_UNMAP
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true)
        }

        #expect(status == .ok)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data[1023] == 0xAB)
        #expect(Array(data[1024..<3072]).allSatisfy { $0 == 0 })
        #expect(data[3072] == 0xAB)
    }

    @Test func discardBeyondCapacityIsRejected() throws {
        let path = try makeDisk(byteCount: 4096)  // 8 sectors
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0xFF, count: 4096).write(to: URL(fileURLWithPath: path))
        let block = try VirtioBlk(path: path, identity: "test", queueCount: 1)

        var range = [UInt8]()
        range.appendLE(UInt64(6))    // sector 6
        range.appendLE(UInt32(10))   // 10 sectors overruns the 8-sector disk
        range.appendLE(UInt32(0))
        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: false)
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false)
        }

        #expect(status == .ioError)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.allSatisfy { $0 == 0xFF })
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

    #if arch(arm64)
    @Test func exceptionClassFromSyndrome() {
        #expect(ExceptionClass(syndrome: UInt64(0x24) << 26) == .dataAbortLowerEL)
        #expect(ExceptionClass(syndrome: UInt64(0x20) << 26) == .instructionAbortLowerEL)
        #expect(ExceptionClass(syndrome: UInt64(0x16) << 26) == .hvc64)
        #expect(ExceptionClass(syndrome: UInt64(0x17) << 26) == .smc64)
    }
    #endif
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

    @Test func publishesMonotonicTransportTelemetryCounters() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let backend = Backend(sharedMemoryRegions: [])
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        transport.write(offset: 0x030, value: 0, width: 4)
        transport.write(offset: 0x044, value: 1, width: 4)
        transport.write(offset: 0x050, value: 0, width: 4)
        transport.notifyUsed()
        transport.notifyConfigChange()
        transport.write(offset: 0x070, value: 0, width: 4)

        #expect(transport.statistics == VirtioMMIOTransportStatistics(
            queueNotifications: 1,
            queueStateChanges: 1,
            usedInterrupts: 1,
            configurationInterrupts: 1,
            deviceResets: 1
        ))
    }

    private final class KickOverlapProbe: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var active = 0
        private(set) var maximumActive = 0

        func handleKick() {
            lock.lock()
            active += 1
            maximumActive = max(maximumActive, active)
            lock.unlock()
            entered.signal()
            release.wait()
            lock.lock()
            active -= 1
            lock.unlock()
        }
    }

    /// Deliberately relies on the protocol default: kicks must remain transport-serialized.
    private final class DefaultKickBackend: VirtioDeviceBackend {
        let deviceID: UInt32 = 1
        let deviceFeatures: UInt64 = 0
        let queueCount = 2
        let configSpace: [UInt8] = []
        let probe: KickOverlapProbe

        init(probe: KickOverlapProbe) {
            self.probe = probe
        }

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {
            probe.handleKick()
        }
    }

    private final class ManagedKickBackend: VirtioDeviceBackend {
        let deviceID: UInt32 = 2
        let deviceFeatures: UInt64 = 0
        let queueCount = 2
        let configSpace: [UInt8] = []
        let kickSynchronization: VirtioKickSynchronization = .backendManaged
        let probe: KickOverlapProbe

        init(probe: KickOverlapProbe) {
            self.probe = probe
        }

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {
            probe.handleKick()
        }
    }

    /// Models virtio-fs's lifecycle rule: a kick may perform host work without the register lock,
    /// but its eventual ring access is admitted only if QueueReady/reset did not change its epoch.
    private final class LifecycleManagedKickBackend: VirtioDeviceBackend, @unchecked Sendable {
        let deviceID: UInt32 = 3
        let deviceFeatures: UInt64 = 0
        let queueCount = 2
        let configSpace: [UInt8] = []
        let kickSynchronization: VirtioKickSynchronization = .backendManaged
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var generations = [UInt64](repeating: 0, count: 2)
        private var events: [String] = []
        private var acceptedQueues: [Int] = []

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {
            lock.lock()
            let generation = generations[queue]
            events.append("enter-\(queue)-\(generation)")
            lock.unlock()
            entered.signal()
            release.wait()

            let accepted = transport.withQueueLock { () -> Bool in
                lock.lock()
                let current = generations[queue] == generation
                lock.unlock()
                return current && transport.queues[queue].ready
            }
            lock.lock()
            if accepted {
                acceptedQueues.append(queue)
            }
            events.append("finish-\(queue)-\(accepted ? "accepted" : "discarded")")
            lock.unlock()
        }

        func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
            lock.lock()
            generations[queue] &+= 1
            events.append("ready-\(queue)-\(generations[queue])")
            lock.unlock()
        }

        func deviceReset(transport: VirtioMMIOTransport) {
            lock.lock()
            for queue in generations.indices {
                generations[queue] &+= 1
            }
            events.append("reset")
            lock.unlock()
        }

        var snapshot: (events: [String], acceptedQueues: [Int]) {
            lock.lock()
            defer { lock.unlock() }
            return (events, acceptedQueues)
        }
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

    @Test func defaultBackendKicksRemainSerializedByTransport() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let probe = KickOverlapProbe()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: DefaultKickBackend(probe: probe),
            memory: memory
        ) {}
        let group = DispatchGroup()
        let secondStarted = DispatchSemaphore(value: 0)

        group.enter()
        DispatchQueue.global().async {
            transport.write(offset: 0x050, value: 0, width: 4)
            group.leave()
        }
        #expect(probe.entered.wait(timeout: .now() + 2) == .success)

        group.enter()
        DispatchQueue.global().async {
            secondStarted.signal()
            transport.write(offset: 0x050, value: 1, width: 4)
            group.leave()
        }
        #expect(secondStarted.wait(timeout: .now() + 2) == .success)
        #expect(probe.entered.wait(timeout: .now() + 0.1) == .timedOut)

        probe.release.signal()
        #expect(probe.entered.wait(timeout: .now() + 2) == .success)
        probe.release.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(probe.maximumActive == 1)
    }

    @Test func backendManagedKicksCanOverlapAcrossQueues() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let probe = KickOverlapProbe()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: ManagedKickBackend(probe: probe),
            memory: memory
        ) {}
        let group = DispatchGroup()

        for queue in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                transport.write(offset: 0x050, value: UInt64(queue), width: 4)
                group.leave()
            }
        }
        #expect(probe.entered.wait(timeout: .now() + 2) == .success)
        #expect(probe.entered.wait(timeout: .now() + 2) == .success)
        #expect(probe.maximumActive == 2)

        probe.release.signal()
        probe.release.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)
    }

    @Test func backendManagedKickLifecycleGatesOrderResetAndQueueReconfigure() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        let backend = LifecycleManagedKickBackend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        for queue in 0..<2 {
            transport.write(offset: 0x030, value: UInt64(queue), width: 4)
            transport.write(offset: 0x044, value: 1, width: 4)
        }

        let group = DispatchGroup()
        for queue in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                transport.write(offset: 0x050, value: UInt64(queue), width: 4)
                group.leave()
            }
        }
        #expect(backend.entered.wait(timeout: .now() + 2) == .success)
        #expect(backend.entered.wait(timeout: .now() + 2) == .success)

        // Both writes must complete while the kick handlers are paused outside registerLock.
        transport.write(offset: 0x030, value: 0, width: 4)
        transport.write(offset: 0x044, value: 1, width: 4)
        transport.write(offset: 0x070, value: 0, width: 4)

        backend.release.signal()
        backend.release.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)

        let snapshot = backend.snapshot
        let reconfigured = snapshot.events.firstIndex(of: "ready-0-2")
        let reset = snapshot.events.firstIndex(of: "reset")
        let finishedZero = snapshot.events.firstIndex(of: "finish-0-discarded")
        let finishedOne = snapshot.events.firstIndex(of: "finish-1-discarded")
        #expect(reconfigured != nil && finishedZero != nil && reconfigured! < finishedZero!)
        #expect(reset != nil && finishedOne != nil && reset! < finishedOne!)
        #expect(snapshot.acceptedQueues.isEmpty)
    }
}

@Suite struct VirtioGPUTests {
    private let base: UInt64 = 0x8000_0000
    private let descTable: UInt64 = 0x8000_1000
    private let availRing: UInt64 = 0x8000_2000
    private let usedRing: UInt64 = 0x8000_3000
    private let requestBuffer: UInt64 = 0x8000_4000
    private let responseBuffer: UInt64 = 0x8000_5000

    @Test func virglLogClassifiesOnlyExplicitVulkanDeviceLoss() {
        #expect(VirglRenderer.runtimeFailure(
            logMessage: "queue submit failed: VK_ERROR_DEVICE_LOST"
        ) == .deviceLost("renderer reported VK_ERROR_DEVICE_LOST"))
        #expect(VirglRenderer.runtimeFailure(
            logMessage: "guest command rejected with invalid resource"
        ) == nil)
        #expect(VirglRenderer.runtimeFailure(
            logMessage: "generic renderer device lost text"
        ) == nil)
    }

    @Test func singleCapsetBecomesImplicitRendererDefault() {
        let venus = VirtioGPUCapset(id: 4, maxVersion: 0, data: [1])
        #expect(VirtioGPU.rendererContextFlags(requested: 0, capsets: [venus]) == 4)
        #expect(VirtioGPU.rendererContextFlags(requested: 4, capsets: [venus]) == 4)
        #expect(VirtioGPU.rendererContextFlags(requested: 2, capsets: [venus]) == 2)
        #expect(VirtioGPU.rendererContextFlags(requested: 0, capsets: []) == 0)
    }

    @Test func virgl2IsTheImplicitDefaultWhenDesktopAndVulkanCapsetsCoexist() {
        let virgl = VirtioGPUCapset(id: 1, maxVersion: 1, data: [1])
        let virgl2 = VirtioGPUCapset(id: 2, maxVersion: 2, data: [2])
        let venus = VirtioGPUCapset(id: 4, maxVersion: 0, data: [4])

        #expect(VirtioGPU.rendererContextFlags(requested: 0, capsets: [virgl, virgl2, venus]) == 2)
        #expect(VirtioGPU.rendererContextFlags(requested: 4, capsets: [virgl, virgl2, venus]) == 4)
    }

    @Test func exposesBootstrapIdentityConfigAndHostMemoryWindow() {
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, hostMemorySize: 0x2000_0000)

        #expect(gpu.deviceID == 16)
        #expect(gpu.queueCount == 2)
        #expect(gpu.deviceFeatures == 0)
        #expect(gpu.configSpace.count == 16)
        #expect(gpu.sharedMemoryRegions == [
            VirtioSharedMemoryRegion(id: 1, guestBase: 0x1_0000_0000, length: 0x2000_0000)
        ])
    }

    @Test func venusModeAdvertisesRendererFeaturesAndCapsets() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [
            VirtioGPUCapset(id: 4, maxVersion: 2, data: [0x56, 0x45, 0x4e, 0x55, 0x53])
        ])
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)

        #expect(gpu.deviceFeatures & (1 << 0) != 0)  // VIRGL command family
        #expect(gpu.deviceFeatures & (1 << 2) != 0)  // resource UUID / cross-device DRM
        #expect(gpu.deviceFeatures & (1 << 3) != 0)  // resource blobs
        #expect(gpu.deviceFeatures & (1 << 4) != 0)  // context init
        #expect(leUInt32(gpu.configSpace, at: 12) == 1)

        var infoRequest = gpuRequest(type: 0x0108, fenceID: 42, contextID: 0, ringIndex: 0)
        infoRequest.appendLE(UInt32(0))  // capset_index
        infoRequest.appendLE(UInt32(0))
        let info = try gpuResponse(gpu: gpu, request: infoRequest)
        #expect(leUInt32(info, at: 0) == 0x1102)
        #expect(leUInt32(info, at: 24) == 4)
        #expect(leUInt32(info, at: 28) == 2)
        #expect(leUInt32(info, at: 32) == 5)

        var dataRequest = gpuRequest(type: 0x0109, fenceID: 43, contextID: 0, ringIndex: 0)
        dataRequest.appendLE(UInt32(4))  // Venus capset
        dataRequest.appendLE(UInt32(2))
        let data = try gpuResponse(gpu: gpu, request: dataRequest)
        #expect(leUInt32(data, at: 0) == 0x1103)
        #expect(Array(data[24..<29]) == [0x56, 0x45, 0x4e, 0x55, 0x53])
    }

    @Test func assignsStableUUIDToRendererResource() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [
            VirtioGPUCapset(id: 4, maxVersion: 2, data: [0x56, 0x45, 0x4e, 0x55, 0x53])
        ])
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)

        var create = gpuRequest(type: 0x0204, fenceID: 0, contextID: 0, ringIndex: 0)
        create.appendLE(UInt32(7))       // resource_id
        create.appendLE(UInt32(2))       // PIPE_TEXTURE_2D
        create.appendLE(UInt32(1))       // B8G8R8A8_UNORM
        create.appendLE(UInt32(1 << 1))  // PIPE_BIND_RENDER_TARGET
        create.appendLE(UInt32(4))
        create.appendLE(UInt32(3))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(0))
        create.appendLE(UInt32(0))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(0))
        #expect(leUInt32(try gpuResponse(gpu: gpu, request: create), at: 0) == 0x1100)

        var assign = gpuRequest(type: 0x010B, fenceID: 41, contextID: 0, ringIndex: 0)
        assign.appendLE(UInt32(7))
        assign.appendLE(UInt32(0))
        let first = try gpuResponse(gpu: gpu, request: assign)
        #expect(first.count == 40)
        #expect(leUInt32(first, at: 0) == 0x1105)
        #expect(Array(first[24..<40]) != Array(repeating: UInt8(0), count: 16))

        let second = try gpuResponse(gpu: gpu, request: assign)
        #expect(leUInt32(second, at: 0) == 0x1105)
        #expect(Array(second[24..<40]) == Array(first[24..<40]))

        var unknown = gpuRequest(type: 0x010B, fenceID: 42, contextID: 0, ringIndex: 0)
        unknown.appendLE(UInt32(99))
        unknown.appendLE(UInt32(0))
        #expect(leUInt32(try gpuResponse(gpu: gpu, request: unknown), at: 0) == 0x1202)
    }

    @Test func respondsToDisplayInfoOnControlQueue() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2_560,
            scanoutHeight: 1_600
        )
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: gpu, memory: memory) {}
        transport.queues[0].configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        transport.queues[0].setReady(true)

        try writeDescriptor(memory, index: 0, addr: requestBuffer, len: 24, flags: 0x1, next: 1)
        try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
        try memory.write(gpuRequest(type: 0x0100, fenceID: 42, contextID: 7, ringIndex: 3), at: requestBuffer)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)

        gpu.handleKick(queue: 0, transport: transport)

        #expect(try memory.read(UInt32.self, at: responseBuffer) == 0x1101)
        #expect(try memory.read(UInt64.self, at: responseBuffer + 8) == 42)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 16) == 7)
        #expect(try memory.readBytes(at: responseBuffer + 20, count: 1) == [3])
        #expect(try memory.read(UInt32.self, at: responseBuffer + 32) == 2_560)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 36) == 1_600)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 40) == 1)
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 408)
        #expect(leUInt32(gpu.configSpace, at: 8) == 1)
    }

    @Test func publishesAndResizesEachScanoutIndependently() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutSizes: [
                VirtioGPUScanoutSize(width: 1_920, height: 1_080),
                VirtioGPUScanoutSize(width: 1_280, height: 1_024),
            ]
        )
        var interruptCount = 0
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) { interruptCount += 1 }

        var display = try gpuResponse(gpu: gpu, request: gpuRequest(
            type: 0x0100,
            fenceID: 0,
            contextID: 0,
            ringIndex: 0
        ))
        #expect(leUInt32(gpu.configSpace, at: 8) == 2)
        #expect(leUInt32(display, at: 32) == 1_920)
        #expect(leUInt32(display, at: 36) == 1_080)
        #expect(leUInt32(display, at: 40) == 1)
        #expect(leUInt32(display, at: 56) == 1_280)
        #expect(leUInt32(display, at: 60) == 1_024)
        #expect(leUInt32(display, at: 64) == 1)

        gpu.updateScanoutSize(
            scanoutID: 1,
            width: 2_560,
            height: 1_440,
            transport: transport
        )
        #expect(interruptCount == 1)

        display = try gpuResponse(gpu: gpu, request: gpuRequest(
            type: 0x0100,
            fenceID: 0,
            contextID: 0,
            ringIndex: 0
        ))
        #expect(leUInt32(display, at: 32) == 1_920)
        #expect(leUInt32(display, at: 36) == 1_080)
        #expect(leUInt32(display, at: 56) == 2_560)
        #expect(leUInt32(display, at: 60) == 1_440)

        gpu.updateScanoutSize(
            scanoutID: 7,
            width: 800,
            height: 600,
            transport: transport
        )
        #expect(interruptCount == 1)
    }

    @Test func hostResizeRaisesConfigInterruptAndUpdatesPreferredMode() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2_560,
            scanoutHeight: 1_600
        )
        var interruptCount = 0
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) { interruptCount += 1 }

        gpu.updateScanoutSize(width: 3_024, height: 1_964, transport: transport)

        #expect(interruptCount == 1)
        #expect(transport.read(offset: 0x060, width: 4) == 2)
        #expect(transport.read(offset: 0x0FC, width: 4) == 1)
        #expect(leUInt32(gpu.configSpace, at: 0) == 1)

        let display = try gpuResponse(gpu: gpu, request: gpuRequest(
            type: 0x0100,
            fenceID: 0,
            contextID: 0,
            ringIndex: 0
        ))
        #expect(leUInt32(display, at: 32) == 3_024)
        #expect(leUInt32(display, at: 36) == 1_964)

        gpu.writeConfig(offset: 4, value: 1, width: 4)
        #expect(leUInt32(gpu.configSpace, at: 0) == 0)

        // Re-publishing the same size must not create an interrupt storm.
        gpu.updateScanoutSize(width: 3_024, height: 1_964, transport: transport)
        #expect(interruptCount == 1)
    }

    @Test func cursorQueuePublishesCopiedShapeAndHotspotAndRejectsInvalidUpdates() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let cursorBox = CursorUpdateBox()
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2_560,
            scanoutHeight: 1_600,
            onCursorUpdate: { cursorBox.store($0) }
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descTable,
            availRing: availRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)

        var controlAvailableIndex = UInt16(0)
        func submitControl(_ request: [UInt8]) throws -> [UInt8] {
            try writeDescriptor(
                memory,
                index: 0,
                addr: requestBuffer,
                len: UInt32(request.count),
                flags: 0x1,
                next: 1
            )
            try writeDescriptor(
                memory,
                index: 1,
                addr: responseBuffer,
                len: 512,
                flags: 0x2,
                next: 0
            )
            try memory.write(request, at: requestBuffer)
            let slot = UInt64(controlAvailableIndex % 8)
            try memory.write(UInt16(0), at: availRing + 4 + slot * 2)
            controlAvailableIndex &+= 1
            try memory.write(controlAvailableIndex, at: availRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
            let usedSlot = UInt64((controlAvailableIndex - 1) % 8)
            let responseLength = try memory.read(UInt32.self, at: usedRing + 8 + usedSlot * 8)
            return try memory.readBytes(at: responseBuffer, count: Int(responseLength))
        }

        var create = gpuRequest(type: 0x0101, fenceID: 0, contextID: 0, ringIndex: 0)
        create.appendLE(UInt32(7))
        create.appendLE(UInt32(1))  // B8G8R8A8_UNORM
        create.appendLE(UInt32(2))
        create.appendLE(UInt32(2))
        #expect(leUInt32(try submitControl(create), at: 0) == 0x1100)

        let pixelBuffer = base + 0x6000
        let pixels: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16,
        ]
        try memory.write(pixels, at: pixelBuffer)
        var attach = gpuRequest(type: 0x0106, fenceID: 0, contextID: 0, ringIndex: 0)
        attach.appendLE(UInt32(7))
        attach.appendLE(UInt32(1))
        attach.appendLE(pixelBuffer)
        attach.appendLE(UInt32(pixels.count))
        attach.appendLE(UInt32(0))
        #expect(leUInt32(try submitControl(attach), at: 0) == 0x1100)

        let cursorDescriptorTable = base + 0x7000
        let cursorAvailableRing = base + 0x8000
        let cursorUsedRing = base + 0x9000
        let cursorRequestBuffer = base + 0xA000
        let cursorResponseBuffer = base + 0xB000
        transport.queues[1].configure(
            size: 8,
            descriptorTable: cursorDescriptorTable,
            availRing: cursorAvailableRing,
            usedRing: cursorUsedRing
        )
        transport.queues[1].setReady(true)

        var cursorAvailableIndex = UInt16(0)
        func writeCursorDescriptor(
            index: UInt64,
            address: UInt64,
            length: UInt32,
            flags: UInt16,
            next: UInt16
        ) throws {
            let descriptor = cursorDescriptorTable + index * 16
            try memory.write(address, at: descriptor)
            try memory.write(length, at: descriptor + 8)
            try memory.write(flags, at: descriptor + 12)
            try memory.write(next, at: descriptor + 14)
        }
        func submitCursor(_ request: [UInt8]) throws -> [UInt8] {
            try writeCursorDescriptor(
                index: 0,
                address: cursorRequestBuffer,
                length: UInt32(request.count),
                flags: 0x1,
                next: 1
            )
            try writeCursorDescriptor(
                index: 1,
                address: cursorResponseBuffer,
                length: 512,
                flags: 0x2,
                next: 0
            )
            try memory.write(request, at: cursorRequestBuffer)
            let slot = UInt64(cursorAvailableIndex % 8)
            try memory.write(UInt16(0), at: cursorAvailableRing + 4 + slot * 2)
            cursorAvailableIndex &+= 1
            try memory.write(cursorAvailableIndex, at: cursorAvailableRing + 2)
            gpu.handleKick(queue: 1, transport: transport)
            let usedSlot = UInt64((cursorAvailableIndex - 1) % 8)
            let responseLength = try memory.read(
                UInt32.self,
                at: cursorUsedRing + 8 + usedSlot * 8
            )
            return try memory.readBytes(at: cursorResponseBuffer, count: Int(responseLength))
        }

        func cursorRequest(resourceID: UInt32, hotX: UInt32, hotY: UInt32) -> [UInt8] {
            var request = gpuRequest(type: 0x0300, fenceID: 0, contextID: 0, ringIndex: 0)
            request.appendLE(UInt32(0))  // scanout_id
            request.appendLE(UInt32(111))
            request.appendLE(UInt32(222))
            request.appendLE(UInt32(0))
            request.appendLE(resourceID)
            request.appendLE(hotX)
            request.appendLE(hotY)
            request.appendLE(UInt32(0))
            return request
        }

        #expect(leUInt32(try submitCursor(cursorRequest(resourceID: 7, hotX: 1, hotY: 0)), at: 0) == 0x1100)
        let update = try #require(cursorBox.values.last ?? nil)
        #expect(update.scanoutID == 0)
        #expect(update.resourceID == 7)
        #expect(update.x == 111)
        #expect(update.y == 222)
        #expect(update.width == 2)
        #expect(update.height == 2)
        #expect(update.hotX == 1)
        #expect(update.hotY == 0)
        #expect(Array(update.bytes) == pixels)

        try memory.write([UInt8](repeating: 0xFF, count: pixels.count), at: pixelBuffer)
        #expect(Array(update.bytes) == pixels)  // callback owns a stable copy, never guest memory

        let countBeforeInvalid = cursorBox.values.count
        #expect(leUInt32(try submitCursor(cursorRequest(resourceID: 7, hotX: 2, hotY: 0)), at: 0) == 0x1202)
        #expect(cursorBox.values.count == countBeforeInvalid)

        #expect(leUInt32(try submitCursor(cursorRequest(resourceID: 0, hotX: 0, hotY: 0)), at: 0) == 0x1100)
        #expect(cursorBox.values.count == countBeforeInvalid + 1)
        #expect(cursorBox.values.last! == nil)
    }

    @Test func scanoutDisableAcceptsTheEmptyRectangleUsedDuringModesets() throws {
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2_560,
            scanoutHeight: 1_600
        )
        var disable2D = gpuRequest(type: 0x0103, fenceID: 0, contextID: 0, ringIndex: 0)
        disable2D.append(contentsOf: [UInt8](repeating: 0, count: 16))  // ignored empty rect
        disable2D.appendLE(UInt32(0))  // scanout_id
        disable2D.appendLE(UInt32(0))  // resource_id disables the scanout
        #expect(leUInt32(try gpuResponse(gpu: gpu, request: disable2D), at: 0) == 0x1100)

        var disableBlob = gpuRequest(type: 0x010D, fenceID: 0, contextID: 0, ringIndex: 0)
        disableBlob.append(contentsOf: [UInt8](repeating: 0, count: 72))
        #expect(disableBlob.count == 96)
        #expect(leUInt32(try gpuResponse(gpu: gpu, request: disableBlob), at: 0) == 0x1100)
    }

    @Test func twoDimensionalBindingFlushAndReleaseFollowScanoutLifetime() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let frameBox = ScanoutFrameBox()
        let releasedResources = ScanoutResourceBox()
        let renderer = FakeVirtioGPURenderer(capsets: [])
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2,
            scanoutHeight: 2,
            renderer: renderer,
            onScanoutFrame: { frameBox.store($0) },
            onScanoutResourceReleased: { releasedResources.store($0) }
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descTable,
            availRing: availRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)

        var availableIndex = UInt16(0)
        func submit(_ request: [UInt8]) throws -> [UInt8] {
            try writeDescriptor(
                memory,
                index: 0,
                addr: requestBuffer,
                len: UInt32(request.count),
                flags: 0x1,
                next: 1
            )
            try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
            try memory.write(request, at: requestBuffer)
            let slot = UInt64(availableIndex % 8)
            try memory.write(UInt16(0), at: availRing + 4 + slot * 2)
            availableIndex &+= 1
            try memory.write(availableIndex, at: availRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
            let usedSlot = UInt64((availableIndex - 1) % 8)
            let responseLength = try memory.read(UInt32.self, at: usedRing + 8 + usedSlot * 8)
            return try memory.readBytes(at: responseBuffer, count: Int(responseLength))
        }

        var create = gpuRequest(type: 0x0101, fenceID: 0, contextID: 0, ringIndex: 0)
        create.appendLE(UInt32(7))  // resource_id
        create.appendLE(UInt32(1))  // B8G8R8A8_UNORM
        create.appendLE(UInt32(2))
        create.appendLE(UInt32(2))
        #expect(leUInt32(try submit(create), at: 0) == 0x1100)
        #expect(renderer.createdResources.count == 1)
        let rendererResource = try #require(renderer.createdResources.first)
        #expect(rendererResource.resourceID == 7)
        #expect(rendererResource.target == 2)
        #expect(rendererResource.bind == 1 << 1)
        #expect(rendererResource.width == 2)
        #expect(rendererResource.height == 2)
        #expect(rendererResource.depth == 1)
        #expect(rendererResource.arraySize == 1)
        #expect(rendererResource.flags == 1)

        let pixelBuffer = base + 0x6000
        let pixels: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16,
        ]
        try memory.write(pixels, at: pixelBuffer)
        var attach = gpuRequest(type: 0x0106, fenceID: 0, contextID: 0, ringIndex: 0)
        attach.appendLE(UInt32(7))
        attach.appendLE(UInt32(1))
        attach.appendLE(pixelBuffer)
        attach.appendLE(UInt32(pixels.count))
        attach.appendLE(UInt32(0))
        #expect(leUInt32(try submit(attach), at: 0) == 0x1100)
        #expect(renderer.attachedBackingResourceIDs == [7])

        var setScanout = gpuRequest(type: 0x0103, fenceID: 0, contextID: 0, ringIndex: 0)
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(7))
        #expect(leUInt32(try submit(setScanout), at: 0) == 0x1100)
        let boundFrame = try #require(frameBox.value)
        #expect(boundFrame.dirtyRect == VirtioGPURect(x: 0, y: 0, width: 2, height: 2))
        #expect(Array(boundFrame.bytes) == pixels)

        var flush = gpuRequest(type: 0x0104, fenceID: 0, contextID: 0, ringIndex: 0)
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(0))
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(2))
        flush.appendLE(UInt32(7))
        flush.appendLE(UInt32(0))
        #expect(leUInt32(try submit(flush), at: 0) == 0x1100)

        let frame = try #require(frameBox.value)
        #expect(frame.scanoutID == 0)
        #expect(frame.resourceID == 7)
        #expect(frame.format == 1)
        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.stride == 4)
        #expect(frame.dirtyRect == VirtioGPURect(x: 1, y: 0, width: 1, height: 2))
        #expect(Array(frame.bytes) == [5, 6, 7, 8, 13, 14, 15, 16])

        var detach = gpuRequest(type: 0x0107, fenceID: 0, contextID: 0, ringIndex: 0)
        detach.appendLE(UInt32(7))
        detach.appendLE(UInt32(0))
        #expect(leUInt32(try submit(detach), at: 0) == 0x1100)
        #expect(renderer.detachedBackingResourceIDs == [7])

        var unref = gpuRequest(type: 0x0102, fenceID: 0, contextID: 0, ringIndex: 0)
        unref.appendLE(UInt32(7))
        unref.appendLE(UInt32(0))
        #expect(leUInt32(try submit(unref), at: 0) == 0x1100)
        #expect(releasedResources.value == 7)
        #expect(renderer.unreferencedResourceIDs == [7])
    }

    @Test func threeDimensionalPartialFlushUsesFullResourceReadbackStride() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let frameBox = ScanoutFrameBox()
        let renderer = FakeVirtioGPURenderer(capsets: [])
        renderer.setTransferReadback(
            width: 4,
            height: 3,
            pixels: Array(0..<48).map(UInt8.init)
        )
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 4,
            scanoutHeight: 3,
            renderer: renderer,
            onScanoutFrame: { frameBox.store($0) }
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descTable,
            availRing: availRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)

        var availableIndex = UInt16(0)
        func submit(_ request: [UInt8]) throws -> [UInt8] {
            try writeDescriptor(
                memory,
                index: 0,
                addr: requestBuffer,
                len: UInt32(request.count),
                flags: 0x1,
                next: 1
            )
            try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
            try memory.write(request, at: requestBuffer)
            let slot = UInt64(availableIndex % 8)
            try memory.write(UInt16(0), at: availRing + 4 + slot * 2)
            availableIndex &+= 1
            try memory.write(availableIndex, at: availRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
            let usedSlot = UInt64((availableIndex - 1) % 8)
            let responseLength = try memory.read(UInt32.self, at: usedRing + 8 + usedSlot * 8)
            return try memory.readBytes(at: responseBuffer, count: Int(responseLength))
        }

        var create = gpuRequest(type: 0x0204, fenceID: 0, contextID: 0, ringIndex: 0)
        create.appendLE(UInt32(7))  // resource_id
        create.appendLE(UInt32(2))  // PIPE_TEXTURE_2D
        create.appendLE(UInt32(1))  // B8G8R8A8_UNORM
        create.appendLE(UInt32(1 << 1))  // PIPE_BIND_RENDER_TARGET
        create.appendLE(UInt32(4))
        create.appendLE(UInt32(3))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(0))
        create.appendLE(UInt32(0))
        create.appendLE(UInt32(1))
        create.appendLE(UInt32(0))
        #expect(leUInt32(try submit(create), at: 0) == 0x1100)

        var setScanout = gpuRequest(type: 0x0103, fenceID: 0, contextID: 0, ringIndex: 0)
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(4))
        setScanout.appendLE(UInt32(3))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(7))
        #expect(leUInt32(try submit(setScanout), at: 0) == 0x1100)
        #expect(Array(try #require(frameBox.value).bytes) == Array(0..<48).map(UInt8.init))

        renderer.setTransferReadback(
            width: 4,
            height: 3,
            pixels: Array(100..<148).map(UInt8.init)
        )
        renderer.transferFromHostCalls.removeAll()
        var flush = gpuRequest(type: 0x0104, fenceID: 0, contextID: 0, ringIndex: 0)
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(2))
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(7))
        flush.appendLE(UInt32(0))
        #expect(leUInt32(try submit(flush), at: 0) == 0x1100)

        let transfer = try #require(renderer.transferFromHostCalls.last)
        #expect(transfer.stride == 16)
        #expect(transfer.entryLengths == [48])
        #expect(transfer.offset == 20)
        #expect(transfer.box == [1, 1, 0, 2, 1, 1])
        let frame = try #require(frameBox.value)
        #expect(frame.stride == 8)
        #expect(frame.dirtyRect == VirtioGPURect(x: 1, y: 1, width: 2, height: 1))
        #expect(Array(frame.bytes) == Array(120..<128).map(UInt8.init))
    }

    @Test func guestBlobFlushPublishesStrideAwareScanoutFrame() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let frameBox = ScanoutFrameBox()
        let renderer = FakeVirtioGPURenderer(capsets: [])
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            scanoutWidth: 2,
            scanoutHeight: 2,
            renderer: renderer,
            onScanoutFrame: { frameBox.store($0) }
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descTable,
            availRing: availRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)

        var availableIndex = UInt16(0)
        func submit(_ request: [UInt8]) throws -> [UInt8] {
            try writeDescriptor(
                memory,
                index: 0,
                addr: requestBuffer,
                len: UInt32(request.count),
                flags: 0x1,
                next: 1
            )
            try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
            try memory.write(request, at: requestBuffer)
            let slot = UInt64(availableIndex % 8)
            try memory.write(UInt16(0), at: availRing + 4 + slot * 2)
            availableIndex &+= 1
            try memory.write(availableIndex, at: availRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
            let usedSlot = UInt64((availableIndex - 1) % 8)
            let responseLength = try memory.read(UInt32.self, at: usedRing + 8 + usedSlot * 8)
            return try memory.readBytes(at: responseBuffer, count: Int(responseLength))
        }

        let pixelBuffer = base + 0x6000
        let pixels: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
            9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
        ]
        try memory.write(pixels, at: pixelBuffer)
        var createBlob = gpuRequest(type: 0x010C, fenceID: 0, contextID: 0, ringIndex: 0)
        createBlob.appendLE(UInt32(7))
        createBlob.appendLE(UInt32(1))  // VIRTIO_GPU_BLOB_MEM_GUEST
        createBlob.appendLE(UInt32(0))
        createBlob.appendLE(UInt32(1))
        createBlob.appendLE(UInt64(0))
        createBlob.appendLE(UInt64(pixels.count))
        createBlob.appendLE(pixelBuffer)
        createBlob.appendLE(UInt32(pixels.count))
        createBlob.appendLE(UInt32(0))
        #expect(leUInt32(try submit(createBlob), at: 0) == 0x1100)

        var setScanout = gpuRequest(type: 0x010D, fenceID: 0, contextID: 0, ringIndex: 0)
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(7))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(1))  // B8G8R8A8_UNORM
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(12))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        #expect(leUInt32(try submit(setScanout), at: 0) == 0x1100)

        var flush = gpuRequest(type: 0x0104, fenceID: 0, contextID: 0, ringIndex: 0)
        flush.appendLE(UInt32(0))
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(2))
        flush.appendLE(UInt32(1))
        flush.appendLE(UInt32(7))
        flush.appendLE(UInt32(0))
        #expect(leUInt32(try submit(flush), at: 0) == 0x1100)

        let frame = try #require(frameBox.value)
        #expect(frame.scanoutID == 0)
        #expect(frame.resourceID == 7)
        #expect(frame.format == 1)
        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.stride == 8)
        #expect(frame.dirtyRect == VirtioGPURect(x: 0, y: 1, width: 2, height: 1))
        #expect(Array(frame.bytes) == [9, 10, 11, 12, 13, 14, 15, 16])
    }

    @Test func host3DBlobScanoutMapsRendererMemoryUntilDisplayIsReleased() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let frameBox = ScanoutFrameBox()
        let rendererPixels: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 80, 81, 82, 83,
            9, 10, 11, 12, 13, 14, 15, 16, 84, 85, 86, 87,
        ]
        let renderer = FakeVirtioGPURenderer(capsets: [], blobBytes: rendererPixels)
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            scanoutCount: 1,
            renderer: renderer,
            onScanoutFrame: { frameBox.store($0) }
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descTable,
            availRing: availRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)

        var availableIndex = UInt16(0)
        func submit(_ request: [UInt8]) throws -> [UInt8] {
            try writeDescriptor(memory, index: 0, addr: requestBuffer, len: UInt32(request.count), flags: 0x1, next: 1)
            try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
            try memory.write(request, at: requestBuffer)
            try memory.write(UInt16(0), at: availRing + 4 + UInt64(availableIndex % 8) * 2)
            availableIndex &+= 1
            try memory.write(availableIndex, at: availRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
            let usedSlot = UInt64((availableIndex - 1) % 8)
            let responseLength = try memory.read(UInt32.self, at: usedRing + 8 + usedSlot * 8)
            return try memory.readBytes(at: responseBuffer, count: Int(responseLength))
        }

        var createBlob = gpuRequest(type: 0x010C, fenceID: 0, contextID: 3, ringIndex: 0)
        createBlob.appendLE(UInt32(9))
        createBlob.appendLE(UInt32(2))  // VIRTIO_GPU_BLOB_MEM_HOST3D
        createBlob.appendLE(UInt32(1))  // mappable
        createBlob.appendLE(UInt32(0))
        createBlob.appendLE(UInt64(44))
        createBlob.appendLE(UInt64(rendererPixels.count))
        #expect(leUInt32(try submit(createBlob), at: 0) == 0x1100)

        var setScanout = gpuRequest(type: 0x010D, fenceID: 0, contextID: 0, ringIndex: 0)
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(9))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(2))
        setScanout.appendLE(UInt32(1))
        setScanout.appendLE(UInt32(0))
        setScanout.appendLE(UInt32(12))
        for _ in 0..<7 { setScanout.appendLE(UInt32(0)) }
        #expect(leUInt32(try submit(setScanout), at: 0) == 0x1100)
        let boundFrame = try #require(frameBox.value)
        #expect(boundFrame.dirtyRect == VirtioGPURect(x: 0, y: 0, width: 2, height: 2))
        #expect(Array(boundFrame.bytes) == [
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16,
        ])

        var flush = gpuRequest(type: 0x0104, fenceID: 0, contextID: 0, ringIndex: 0)
        flush.appendLE(UInt32(0))
        flush.appendLE(UInt32(0))
        flush.appendLE(UInt32(2))
        flush.appendLE(UInt32(2))
        flush.appendLE(UInt32(9))
        flush.appendLE(UInt32(0))
        #expect(leUInt32(try submit(flush), at: 0) == 0x1100)
        #expect(renderer.mapBlobCount == 1)
        #expect(Array(try #require(frameBox.value).bytes) == [
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16,
        ])

        var disable = gpuRequest(type: 0x0103, fenceID: 0, contextID: 0, ringIndex: 0)
        disable.appendLE(UInt32(0))
        disable.appendLE(UInt32(0))
        disable.appendLE(UInt32(2))
        disable.appendLE(UInt32(2))
        disable.appendLE(UInt32(0))
        disable.appendLE(UInt32(0))
        #expect(leUInt32(try submit(disable), at: 0) == 0x1100)
        #expect(renderer.unmapBlobCount == 1)
    }

    @Test func explicitHostRendererLossIsLatchedWithoutCountingGuestCommandErrors() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [
            VirtioGPUCapset(id: 4, maxVersion: 0, data: [1]),
        ])
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)
        var request = gpuRequest(type: 0x0207, fenceID: 0, contextID: 7, ringIndex: 0)
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(0))

        renderer.failSubmit = true
        #expect(leUInt32(try gpuResponse(gpu: gpu, request: request), at: 0) == 0x1202)
        #expect(gpu.statistics.rendererDeviceLosses == 0)
        #expect(!gpu.statistics.hasLostRendererDevice)

        renderer.signalRuntimeFailure(.deviceLost("VK_ERROR_DEVICE_LOST"))
        #expect(gpu.statistics.rendererDeviceLosses == 1)
        #expect(gpu.statistics.hasLostRendererDevice)

        // A lost renderer can reject many subsequent guest commands or repeat its diagnostic.
        // The metric records the single loss transition rather than fabricating extra devices.
        renderer.signalRuntimeFailure(.deviceLost("VK_ERROR_DEVICE_LOST"))
        #expect(gpu.statistics.rendererDeviceLosses == 1)
        #expect(gpu.statistics.hasLostRendererDevice)
    }

    @Test func fencedCommandDefersCompletionUntilRendererSignals() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [VirtioGPUCapset(id: 4, maxVersion: 0, data: [1])])
        let gpu = VirtioGPU(
            hostMemoryBase: 0x1_0000_0000,
            renderer: renderer,
            fenceTimeoutNanoseconds: 0
        )
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: gpu, memory: memory) {}
        transport.queues[0].configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        transport.queues[0].setReady(true)

        // SUBMIT_3D with VIRTIO_GPU_FLAG_FENCE on the global (ctx0) timeline: no INFO_RING_IDX.
        var request = [UInt8]()
        request.appendLE(UInt32(0x0207))
        request.appendLE(UInt32(1))       // FLAG_FENCE
        request.appendLE(UInt64(7))       // fence_id
        request.appendLE(UInt32(5))       // ctx_id
        request.append(contentsOf: [0, 0, 0, 0])
        request.appendLE(UInt32(0))       // size
        request.appendLE(UInt32(0))       // padding
        try writeDescriptor(memory, index: 0, addr: requestBuffer, len: UInt32(request.count), flags: 0x1, next: 1)
        try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
        try memory.write(request, at: requestBuffer)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)

        gpu.handleKick(queue: 0, transport: transport)

        // The command executed and registered a fence, but the descriptor must stay unused.
        #expect(renderer.createdFences.count == 1)
        #expect(renderer.createdFences.first?.fenceID == 7)
        #expect(renderer.createdFences.first?.contextFence == false)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        #expect(gpu.statistics == VirtioGPUStatistics(
            fences: 1,
            fenceRegistrationFailures: 0,
            fenceTimeouts: 1,
            hasTimedOutPendingFence: true
        ))

        // A ctx0 signal completes it: response carries OK + FLAG_FENCE + the fence id.
        renderer.signalFence(contextID: 0, ringIndex: 0, fenceID: 7)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: responseBuffer) == 0x1100)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 4) == 1)
        #expect(try memory.read(UInt64.self, at: responseBuffer + 8) == 7)
        #expect(gpu.statistics == VirtioGPUStatistics(
            fences: 1,
            fenceRegistrationFailures: 0,
            fenceTimeouts: 1,
            hasTimedOutPendingFence: false
        ))
    }

    @Test func contextFenceCompletesOnlyItsRing() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [VirtioGPUCapset(id: 4, maxVersion: 0, data: [1])])
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: gpu, memory: memory) {}
        transport.queues[0].configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        transport.queues[0].setReady(true)

        var request = [UInt8]()
        request.appendLE(UInt32(0x0207))
        request.appendLE(UInt32(3))       // FLAG_FENCE | FLAG_INFO_RING_IDX
        request.appendLE(UInt64(11))      // fence_id
        request.appendLE(UInt32(9))       // ctx_id
        request.append(contentsOf: [2, 0, 0, 0])  // ring_idx 2
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(0))
        try writeDescriptor(memory, index: 0, addr: requestBuffer, len: UInt32(request.count), flags: 0x1, next: 1)
        try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
        try memory.write(request, at: requestBuffer)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)

        gpu.handleKick(queue: 0, transport: transport)
        #expect(renderer.createdFences.first?.contextFence == true)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)

        // Signals for another ring or context leave it pending; its own ring completes it.
        renderer.signalFence(contextID: 9, ringIndex: 1, fenceID: 11)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        renderer.signalFence(contextID: 8, ringIndex: 2, fenceID: 11)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        renderer.signalFence(contextID: 9, ringIndex: 2, fenceID: 11)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 4) == 3)
        #expect(try memory.read(UInt64.self, at: responseBuffer + 8) == 11)
    }

    @Test func fenceRegistrationFailureRespondsImmediately() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [VirtioGPUCapset(id: 4, maxVersion: 0, data: [1])])
        renderer.failFenceCreation = true
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: gpu, memory: memory) {}
        transport.queues[0].configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        transport.queues[0].setReady(true)

        var request = [UInt8]()
        request.appendLE(UInt32(0x0207))
        request.appendLE(UInt32(1))
        request.appendLE(UInt64(13))
        request.appendLE(UInt32(5))
        request.append(contentsOf: [0, 0, 0, 0])
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(0))
        try writeDescriptor(memory, index: 0, addr: requestBuffer, len: UInt32(request.count), flags: 0x1, next: 1)
        try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
        try memory.write(request, at: requestBuffer)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)

        gpu.handleKick(queue: 0, transport: transport)

        // Degraded but never hung: the eager response still carries the fence id as the signal.
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: responseBuffer) == 0x1100)
        #expect(try memory.read(UInt64.self, at: responseBuffer + 8) == 13)
        #expect(gpu.statistics == VirtioGPUStatistics(
            fences: 0,
            fenceRegistrationFailures: 1,
            fenceTimeouts: 0,
            hasTimedOutPendingFence: false
        ))
    }

    private func writeDescriptor(_ memory: GuestMemory, index: UInt64, addr: UInt64, len: UInt32, flags: UInt16, next: UInt16) throws {
        let descriptor = descTable + index * 16
        try memory.write(addr, at: descriptor)
        try memory.write(len, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private func gpuRequest(type: UInt32, fenceID: UInt64, contextID: UInt32, ringIndex: UInt8) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(type)
        data.appendLE(UInt32(0))
        data.appendLE(fenceID)
        data.appendLE(contextID)
        data.append(ringIndex)
        data.append(contentsOf: [0, 0, 0])
        return data
    }

    private func gpuResponse(gpu: VirtioGPU, request: [UInt8]) throws -> [UInt8] {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let transport = VirtioMMIOTransport(baseAddress: GuestLayout.virtioBase, backend: gpu, memory: memory) {}
        transport.queues[0].configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        transport.queues[0].setReady(true)
        try writeDescriptor(memory, index: 0, addr: requestBuffer, len: UInt32(request.count), flags: 0x1, next: 1)
        try writeDescriptor(memory, index: 1, addr: responseBuffer, len: 512, flags: 0x2, next: 0)
        try memory.write(request, at: requestBuffer)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)
        gpu.handleKick(queue: 0, transport: transport)
        return try memory.readBytes(at: responseBuffer, count: Int(try memory.read(UInt32.self, at: usedRing + 8)))
    }

    private func leUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private final class ScanoutFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VirtioGPUScanoutFrame?

    func store(_ frame: VirtioGPUScanoutFrame) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    var value: VirtioGPUScanoutFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

private final class CursorUpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var updates = [VirtioGPUCursorUpdate?]()

    func store(_ update: VirtioGPUCursorUpdate?) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var values: [VirtioGPUCursorUpdate?] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

private final class ScanoutResourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resourceID: UInt32?

    func store(_ resourceID: UInt32) {
        lock.lock()
        self.resourceID = resourceID
        lock.unlock()
    }

    var value: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return resourceID
    }
}

private final class FakeVirtioGPURenderer: VirtioGPURenderer {
    struct TransferFromHostCall {
        var stride: UInt32
        var offset: UInt64
        var entryLengths: [Int]
        var box: [UInt32]
    }

    let capsets: [VirtioGPUCapset]
    private let blobStorage: UnsafeMutableRawPointer?
    private let blobStorageSize: UInt64
    private(set) var mapBlobCount = 0
    private(set) var unmapBlobCount = 0
    private(set) var createdResources: [VirtioGPUResourceCreate3D] = []
    private(set) var attachedBackingResourceIDs: [UInt32] = []
    private(set) var detachedBackingResourceIDs: [UInt32] = []
    private(set) var unreferencedResourceIDs: [UInt32] = []
    private var transferReadbackWidth: UInt32 = 0
    private var transferReadbackHeight: UInt32 = 0
    private var transferReadbackPixels = [UInt8]()
    var transferFromHostCalls = [TransferFromHostCall]()
    var failSubmit = false
    var onRuntimeFailure: ((VirtioGPURendererRuntimeFailure) -> Void)?

    init(capsets: [VirtioGPUCapset], blobBytes: [UInt8]? = nil) {
        self.capsets = capsets
        if let blobBytes {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: blobBytes.count, alignment: 16)
            blobBytes.withUnsafeBytes { bytes in
                storage.copyMemory(from: bytes.baseAddress!, byteCount: blobBytes.count)
            }
            self.blobStorage = storage
            self.blobStorageSize = UInt64(blobBytes.count)
        } else {
            self.blobStorage = nil
            self.blobStorageSize = 0
        }
    }

    deinit {
        blobStorage?.deallocate()
    }

    func createContext(id: UInt32, flags: UInt32, name: String) throws {}
    func destroyContext(id: UInt32) throws {}
    func attachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func detachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func submit3D(contextID: UInt32, command: [UInt8]) throws {
        if failSubmit {
            throw VMError.invalidConfiguration("guest command rejected")
        }
    }

    func signalRuntimeFailure(_ failure: VirtioGPURendererRuntimeFailure) {
        onRuntimeFailure?(failure)
    }
    func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws {
        createdResources.append(resource)
    }
    func createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64,
        entries: [VirtioGPUMemoryEntry]
    ) throws {}
    func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws {
        attachedBackingResourceIDs.append(resourceID)
    }
    func detachBacking(resourceID: UInt32) throws {
        detachedBackingResourceIDs.append(resourceID)
    }
    func unrefResource(resourceID: UInt32) throws {
        unreferencedResourceIDs.append(resourceID)
    }
    func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping {
        mapBlobCount += 1
        return VirtioGPUBlobMapping(
            hostPointer: blobStorage ?? UnsafeMutableRawPointer(bitPattern: 0x1000)!,
            size: blobStorage == nil ? 4096 : blobStorageSize,
            mapInfo: 2
        )
    }
    func unmapBlob(resourceID: UInt32) throws { unmapBlobCount += 1 }
    func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func setTransferReadback(width: UInt32, height: UInt32, pixels: [UInt8]) {
        transferReadbackWidth = width
        transferReadbackHeight = height
        transferReadbackPixels = pixels
    }

    func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {
        transferFromHostCalls.append(TransferFromHostCall(
            stride: transfer.stride,
            offset: transfer.offset,
            entryLengths: entries.map(\.length),
            box: transfer.box
        ))
        guard transferReadbackWidth > 0, transferReadbackHeight > 0 else { return }
        guard transfer.box.count == 6,
              transfer.box[2] == 0, transfer.box[5] == 1,
              transfer.box[0] <= transferReadbackWidth,
              transfer.box[3] <= transferReadbackWidth - transfer.box[0],
              transfer.box[1] <= transferReadbackHeight,
              transfer.box[4] <= transferReadbackHeight - transfer.box[1],
              transferReadbackPixels.count == Int(transferReadbackWidth * transferReadbackHeight * 4),
              let destination = entries.first else {
            throw VMError.invalidConfiguration("invalid fake renderer readback")
        }
        let rowBytes = Int(transfer.box[3] * 4)
        for row in 0..<Int(transfer.box[4]) {
            let y = Int(transfer.box[1]) + row
            let x = Int(transfer.box[0])
            let sourceOffset = (y * Int(transferReadbackWidth) + x) * 4
            let destinationOffset = Int(transfer.offset) + row * Int(transfer.stride)
            guard destinationOffset <= destination.length,
                  rowBytes <= destination.length - destinationOffset else {
                throw VMError.invalidConfiguration("fake renderer readback destination is too small")
            }
            transferReadbackPixels.withUnsafeBytes { source in
                destination.pointer.advanced(by: destinationOffset).copyMemory(
                    from: source.baseAddress!.advanced(by: sourceOffset),
                    byteCount: rowBytes
                )
            }
        }
    }

    var onFenceSignaled: ((UInt32, UInt32, UInt64) -> Void)?
    /// Registered fences accumulate; tests fire them via `signalFence` to model asynchronous
    /// completion, or set `autoSignalFences` for the old eager behavior.
    private(set) var createdFences: [(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool)] = []
    var autoSignalFences = false
    var failFenceCreation = false

    func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws {
        if failFenceCreation {
            throw VMError.invalidConfiguration("fence creation disabled")
        }
        createdFences.append((contextID, ringIndex, fenceID, contextFence))
        if autoSignalFences {
            signalFence(contextID: contextFence ? contextID : 0, ringIndex: contextFence ? ringIndex : 0, fenceID: fenceID)
        }
    }

    func signalFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64) {
        onFenceSignaled?(contextID, ringIndex, fenceID)
    }
}

@Suite struct VirtioSoundTests {
    @Test func advertisesStandardPlaybackAndCaptureStreams() {
        let host = TestSoundHost()
        let sound = VirtioSound(host: host)

        #expect(sound.deviceID == 25)
        #expect(sound.queueCount == 4)
        #expect(sound.configSpace.leUInt32(at: 0) == 0)
        #expect(sound.configSpace.leUInt32(at: 4) == 2)
        #expect(sound.configSpace.leUInt32(at: 8) == 0)

        var request = [UInt8]()
        request.appendLE(UInt32(0x0100))
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(2))
        request.appendLE(UInt32(32))
        let response = sound.controlResponseForTesting(request, responseCapacity: 68)

        #expect(response.count == 68)
        #expect(response.leUInt32(at: 0) == 0x8000)
        #expect(response[28] == VirtioSoundDirection.output.rawValue)
        #expect(response[60] == VirtioSoundDirection.input.rawValue)
        #expect(response[29] == 1 && response[30] == 2)
        #expect(response[61] == 1 && response[62] == 2)
        #expect(response.leUInt64(at: 12) & (1 << 5) != 0)  // S16_LE
        #expect(response.leUInt64(at: 20) & (1 << 6) != 0)  // 44.1 kHz
        #expect(response.leUInt64(at: 20) & (1 << 7) != 0)  // 48 kHz
    }

    @Test func enforcesTheVirtioPCMStreamLifecycle() {
        let host = TestSoundHost()
        let sound = VirtioSound(host: host)

        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0104, streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0105, streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0103, streamID: 0)) == 0x8000)
        #expect(host.events == [
            "configure-0-output-48000-2",
            "prepare-0-output",
            "start-0-output",
            "stop-0-output",
            "release-0-output",
        ])
    }

    @Test func rejectsFormatsThatLinuxWasNotToldAreAvailable() {
        let host = TestSoundHost()
        let sound = VirtioSound(host: host)

        #expect(status(sound, setParameters(streamID: 0, format: 1)) == 0x8002)
        #expect(host.events.isEmpty)
    }

    @Test func playbackDescriptorCompletesOnlyAfterHostPlaybackCallback() throws {
        let base = GuestLayout.ramBase
        let descriptorTable = base + 0x1000
        let availableRing = base + 0x2000
        let usedRing = base + 0x3000
        let requestBuffer = base + 0x4000
        let responseBuffer = base + 0x5000
        let host = TestSoundHost()
        host.acceptPlayback = true
        let sound = VirtioSound(host: host)

        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0104, streamID: 0)) == 0x8000)

        let memory = try GuestMemory(guestBase: base, size: 8 * HostPage.size)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: sound,
            memory: memory
        ) {}
        transport.queues[2].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[2].setReady(true)

        let audio = [UInt8](repeating: 0x40, count: 16)
        var request = [UInt8]()
        request.appendLE(UInt32(0))
        request.append(contentsOf: audio)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: requestBuffer,
            length: UInt32(request.count),
            flags: 0x1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 1,
            address: responseBuffer,
            length: 8,
            flags: 0x2,
            next: 0
        )
        try memory.write(request, at: requestBuffer)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 4)
        try memory.write(UInt16(1), at: availableRing + 2)

        sound.handleKick(queue: 2, transport: transport)

        #expect(host.playbackData == Data(audio))
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        let completion = try #require(host.playbackCompletion)
        completion(true, 256)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 8)
        #expect(try memory.read(UInt32.self, at: responseBuffer) == 0x8000)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 4) == 256)
    }

    @Test func captureDescriptorCanPrimeBeforeStartAndReturnsPayloadThenStatus() throws {
        let base = GuestLayout.ramBase
        let descriptorTable = base + 0x1000
        let availableRing = base + 0x2000
        let usedRing = base + 0x3000
        let requestBuffer = base + 0x4000
        let audioBuffer = base + 0x5000
        let statusBuffer = base + 0x6000
        let host = TestSoundHost()
        host.acceptCapture = true
        let sound = VirtioSound(host: host)

        #expect(status(sound, setParameters(streamID: 1)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 1)) == 0x8000)

        let memory = try GuestMemory(guestBase: base, size: 8 * HostPage.size)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: sound,
            memory: memory
        ) {}
        transport.queues[3].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[3].setReady(true)

        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: requestBuffer,
            length: 4,
            flags: 0x1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 1,
            address: audioBuffer,
            length: 16,
            flags: 0x3,
            next: 2
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 2,
            address: statusBuffer,
            length: 8,
            flags: 0x2,
            next: 0
        )
        try memory.write([UInt8](repeating: 0, count: 4), at: requestBuffer)
        try memory.write(UInt32(1), at: requestBuffer)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 4)
        try memory.write(UInt16(1), at: availableRing + 2)

        sound.handleKick(queue: 3, transport: transport)

        #expect(host.captureByteCount == 16)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        let completion = try #require(host.captureCompletion)
        let audio = Data((0..<16).map(UInt8.init))
        completion(audio, 512)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 24)
        #expect(try memory.readBytes(at: audioBuffer, count: 16) == [UInt8](audio))
        #expect(try memory.read(UInt32.self, at: statusBuffer) == 0x8000)
        #expect(try memory.read(UInt32.self, at: statusBuffer + 4) == 512)
    }

    private func status(_ sound: VirtioSound, _ request: [UInt8]) -> UInt32 {
        sound.controlResponseForTesting(request).leUInt32(at: 0)
    }

    private func lifecycle(_ code: UInt32, streamID: UInt32) -> [UInt8] {
        var request = [UInt8]()
        request.appendLE(code)
        request.appendLE(streamID)
        return request
    }

    private func setParameters(
        streamID: UInt32,
        channels: UInt8 = 2,
        format: UInt8 = 5,
        rate: UInt8 = 7
    ) -> [UInt8] {
        var request = [UInt8]()
        request.appendLE(UInt32(0x0101))
        request.appendLE(streamID)
        request.appendLE(UInt32(32_768))
        request.appendLE(UInt32(4_096))
        request.appendLE(UInt32(0))
        request.append(channels)
        request.append(format)
        request.append(rate)
        request.append(0)
        return request
    }

    private func writeDescriptor(
        _ memory: GuestMemory,
        table: UInt64,
        index: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        let descriptor = table + index * 16
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private final class TestSoundHost: VirtioSoundHost, @unchecked Sendable {
        var events = [String]()
        var acceptPlayback = false
        var acceptCapture = false
        var playbackData: Data?
        var playbackCompletion: (@Sendable (Bool, UInt32) -> Void)?
        var captureByteCount: Int?
        var captureCompletion: (@Sendable (Data?, UInt32) -> Void)?

        func configure(
            streamID: Int,
            direction: VirtioSoundDirection,
            parameters: VirtioSoundPCMParameters
        ) -> Bool {
            events.append("configure-\(streamID)-\(direction)-\(Int(parameters.sampleRate))-\(parameters.channels)")
            return true
        }

        func prepare(streamID: Int, direction: VirtioSoundDirection) -> Bool {
            events.append("prepare-\(streamID)-\(direction)")
            return true
        }

        func start(streamID: Int, direction: VirtioSoundDirection) -> Bool {
            events.append("start-\(streamID)-\(direction)")
            return true
        }

        func stop(streamID: Int, direction: VirtioSoundDirection) -> Bool {
            events.append("stop-\(streamID)-\(direction)")
            return true
        }

        func release(streamID: Int, direction: VirtioSoundDirection) {
            events.append("release-\(streamID)-\(direction)")
        }

        func enqueuePlayback(
            _ data: Data,
            parameters: VirtioSoundPCMParameters,
            completion: @escaping @Sendable (Bool, UInt32) -> Void
        ) -> Bool {
            guard acceptPlayback else { return false }
            playbackData = data
            playbackCompletion = completion
            return true
        }

        func requestCapture(
            byteCount: Int,
            parameters: VirtioSoundPCMParameters,
            completion: @escaping @Sendable (Data?, UInt32) -> Void
        ) -> Bool {
            guard acceptCapture else { return false }
            captureByteCount = byteCount
            captureCompletion = completion
            return true
        }

        func reset() { events.append("reset") }
    }
}

@Suite struct VirtioInputTests {
    private let base = GuestLayout.ramBase
    private var descriptorTable: UInt64 { base + 0x1000 }
    private var availableRing: UInt64 { base + 0x2000 }
    private var usedRing: UInt64 { base + 0x3000 }
    private var eventBuffers: UInt64 { base + 0x4000 }

    @Test func advertisesKeyboardPointerWheelAndAbsoluteAxes() {
        let input = VirtioInput()

        input.writeConfig(offset: 0, value: 0x11, width: 1)
        input.writeConfig(offset: 1, value: 1, width: 1)  // EV_KEY
        var config = input.configSpace
        #expect(config[2] >= 35)
        #expect(config[8 + 30] & (1 << 7) != 0)  // KEY 247
        #expect(config[8 + 34] & 1 != 0)         // BTN_LEFT 272

        input.writeConfig(offset: 1, value: 2, width: 1)  // EV_REL
        config = input.configSpace
        #expect(config[8 + 1] & (1 << 3) != 0)   // REL_WHEEL_HI_RES 11

        input.writeConfig(offset: 0, value: 0x12, width: 1)
        input.writeConfig(offset: 1, value: 0, width: 1)  // ABS_X
        config = input.configSpace
        #expect(config[2] == 20)
        #expect(config.leUInt32(at: 12) == 32_767)
    }

    @Test func convertsAppKitScrollDirectionToLinuxWheelDirection() {
        var scroll = VirtioInputScrollAccumulator()
        let events = scroll.events(
            horizontalDelta: -1,
            verticalDelta: 1,
            hasPreciseDeltas: false
        )

        #expect(events == [
            VirtioInputEvent(type: 2, code: 11, value: -120),
            VirtioInputEvent(type: 2, code: 8, value: -1),
            VirtioInputEvent(type: 2, code: 12, value: 120),
            VirtioInputEvent(type: 2, code: 6, value: 1),
        ])
    }

    @Test func accumulatesPreciseScrollIntoDiscreteLinuxTicks() {
        var scroll = VirtioInputScrollAccumulator()
        for _ in 0..<9 {
            let events = scroll.events(
                horizontalDelta: 0,
                verticalDelta: 1,
                hasPreciseDeltas: true
            )
            #expect(events == [VirtioInputEvent(type: 2, code: 11, value: -12)])
        }
        let finalEvents = scroll.events(
            horizontalDelta: 0,
            verticalDelta: 1,
            hasPreciseDeltas: true
        )
        #expect(finalEvents == [
            VirtioInputEvent(type: 2, code: 11, value: -12),
            VirtioInputEvent(type: 2, code: 8, value: -1),
        ])
    }

    @Test func focusLossReleasesEveryPressedKeyAndButtonExactlyOnce() {
        var state = VirtioInputPressedState()
        state.record(VirtioInputEvent(type: 1, code: 42, value: 1))
        state.record(VirtioInputEvent(type: 1, code: 30, value: 1))
        state.record(VirtioInputEvent(type: 1, code: 30, value: 2))
        state.record(VirtioInputEvent(type: 1, code: 272, value: 1))
        state.record(VirtioInputEvent(type: 3, code: 0, value: 16_000))
        state.record(VirtioInputEvent(type: 1, code: 42, value: 0))

        #expect(state.releaseFrame() == [
            VirtioInputEvent(type: 1, code: 30, value: 0),
            VirtioInputEvent(type: 1, code: 272, value: 0),
        ])
        #expect(state.releaseFrame().isEmpty)
    }

    @Test func waitsForEnoughGuestBuffersBeforePublishingWholeInputFrame() throws {
        let memory = try GuestMemory(guestBase: base, size: 8 * HostPage.size)
        let input = VirtioInput()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: input,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)
        input.deviceReady(transport: transport)

        for index in 0..<3 {
            let descriptor = descriptorTable + UInt64(index) * 16
            try memory.write(eventBuffers + UInt64(index) * 8, at: descriptor)
            try memory.write(UInt32(8), at: descriptor + 8)
            try memory.write(UInt16(2), at: descriptor + 12)  // device-writable
            try memory.write(UInt16(0), at: descriptor + 14)
            try memory.write(UInt16(index), at: availableRing + 4 + UInt64(index) * 2)
        }
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(2), at: availableRing + 2)

        input.send(frame: [
            VirtioInputEvent(type: 1, code: 30, value: 1),
            VirtioInputEvent(type: 3, code: 0, value: 16_000),
        ])
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)

        try memory.write(UInt16(3), at: availableRing + 2)
        input.handleKick(queue: 0, transport: transport)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 3)
        #expect(try memory.read(UInt16.self, at: eventBuffers) == 1)
        #expect(try memory.read(UInt16.self, at: eventBuffers + 2) == 30)
        #expect(try memory.read(UInt32.self, at: eventBuffers + 4) == 1)
        #expect(try memory.read(UInt16.self, at: eventBuffers + 8) == 3)
        #expect(try memory.read(UInt32.self, at: eventBuffers + 12) == 16_000)
        #expect(try memory.read(UInt16.self, at: eventBuffers + 16) == 0)
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

private extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
