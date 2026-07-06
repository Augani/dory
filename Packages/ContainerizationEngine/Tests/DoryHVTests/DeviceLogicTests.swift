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

@Suite struct VirtioGPUTests {
    private let base: UInt64 = 0x8000_0000
    private let descTable: UInt64 = 0x8000_1000
    private let availRing: UInt64 = 0x8000_2000
    private let usedRing: UInt64 = 0x8000_3000
    private let requestBuffer: UInt64 = 0x8000_4000
    private let responseBuffer: UInt64 = 0x8000_5000

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

    @Test func respondsToDisplayInfoOnControlQueue() throws {
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000)
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
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 408)
    }

    @Test func fencedCommandDefersCompletionUntilRendererSignals() throws {
        let renderer = FakeVirtioGPURenderer(capsets: [VirtioGPUCapset(id: 4, maxVersion: 0, data: [1])])
        let gpu = VirtioGPU(hostMemoryBase: 0x1_0000_0000, renderer: renderer)
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

        // A ctx0 signal completes it: response carries OK + FLAG_FENCE + the fence id.
        renderer.signalFence(contextID: 0, ringIndex: 0, fenceID: 7)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)
        #expect(try memory.read(UInt32.self, at: responseBuffer) == 0x1100)
        #expect(try memory.read(UInt32.self, at: responseBuffer + 4) == 1)
        #expect(try memory.read(UInt64.self, at: responseBuffer + 8) == 7)
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

private final class FakeVirtioGPURenderer: VirtioGPURenderer {
    let capsets: [VirtioGPUCapset]

    init(capsets: [VirtioGPUCapset]) {
        self.capsets = capsets
    }

    func createContext(id: UInt32, flags: UInt32, name: String) throws {}
    func destroyContext(id: UInt32) throws {}
    func attachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func detachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func submit3D(contextID: UInt32, command: [UInt8]) throws {}
    func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64,
        entries: [VirtioGPUMemoryEntry]
    ) throws {}
    func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws {}
    func detachBacking(resourceID: UInt32) throws {}
    func unrefResource(resourceID: UInt32) throws {}
    func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping {
        VirtioGPUBlobMapping(hostPointer: UnsafeMutableRawPointer(bitPattern: 0x1000)!, size: 4096, mapInfo: 2)
    }
    func unmapBlob(resourceID: UInt32) throws {}
    func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {}

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
