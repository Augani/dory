import Darwin
import Testing
@testable import DoryHV

@Suite struct DoryRendererWorkerSharedMemoryTests {
    @Test func submitStreamIsOneImmutableReadOnlyDescriptorWithoutArrayMaterialization() throws {
        let first = UnsafeMutableRawPointer.allocate(byteCount: 36, alignment: 8)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            first.deallocate()
            second.deallocate()
        }
        first.initializeMemory(as: UInt8.self, repeating: 0xaa, count: 32)
        [UInt8(1), 2, 3, 4].withUnsafeBytes {
            first.advanced(by: 32).copyMemory(from: $0.baseAddress!, byteCount: 4)
        }
        [UInt8(5), 6, 7, 8, 9, 10, 11, 12].withUnsafeBytes {
            second.copyMemory(from: $0.baseAddress!, byteCount: 8)
        }
        let regions = try DoryRendererWorkerSharedRegionSet.immutableSubmit3D(
            from: [
                VirtqueueSegment(pointer: first, length: 36, isDeviceWritable: false),
                VirtqueueSegment(pointer: second, length: 8, isDeviceWritable: false),
            ],
            readableByteCount: 44,
            readableOffset: 32,
            byteCount: 12,
            maximumByteCount: 4_096
        )
        #expect(regions.references.count == 1)
        #expect(regions.descriptors.count == 1)
        #expect(regions.references[0].length == 12)

        let descriptor = regions.descriptors[0].fileDescriptor
        var status = stat()
        #expect(fstat(descriptor, &status) == 0)
        #expect(status.st_nlink == 0)
        #expect(status.st_size == 12)
        #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        let mapped = mmap(nil, 12, PROT_READ, MAP_SHARED, descriptor, 0)
        #expect(mapped != MAP_FAILED)
        guard mapped != MAP_FAILED, let mapped else { return }
        defer { munmap(mapped, 12) }
        let expected = (1...12).map(UInt8.init)
        #expect(Array(UnsafeRawBufferPointer(start: mapped, count: 12)) == expected)

        first.advanced(by: 32).storeBytes(of: UInt32.zero, as: UInt32.self)
        #expect(Array(UnsafeRawBufferPointer(start: mapped, count: 12)) == expected)
    }

    @Test func discontiguousGuestBackingUsesOneCoherentDescriptor() throws {
        let guestBase: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 8 * HostPage.size)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: VirtioRng(),
            memory: memory,
            interrupt: {}
        )
        let firstAddress = guestBase + HostPage.size
        let secondAddress = guestBase + 5 * HostPage.size
        let firstPointer = try memory.hostPointer(at: firstAddress, count: 64)
        let secondPointer = try memory.hostPointer(at: secondAddress, count: 32)
        let regions = try DoryRendererWorkerSharedRegionSet.guestBacking(
            entries: [
                VirtioGPUMemoryEntry(
                    pointer: firstPointer,
                    length: 64,
                    guestAddress: firstAddress
                ),
                VirtioGPUMemoryEntry(
                    pointer: secondPointer,
                    length: 32,
                    guestAddress: secondAddress
                ),
            ],
            transport: transport
        )
        #expect(regions.references.count == 2)
        #expect(regions.descriptors.count == 1)
        #expect(regions.references.map(\.descriptorIndex) == [0, 0])
        #expect(regions.references.map(\.offset) == [2 * HostPage.size, 6 * HostPage.size])
        #expect(regions.references.allSatisfy {
            $0.declaredFileSize == 9 * HostPage.size
        })
        #expect(fcntl(regions.descriptors[0].fileDescriptor, F_GETFL) & O_ACCMODE == O_RDWR)
    }
}
