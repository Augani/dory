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

    @Test func discontiguousBackingPinsOnlyEntryGranulesUntilLastRegionSetCopyRetires() throws {
        let guestBase: UInt64 = 0x8200_0000
        let (memory, unmaps) = try makeMockReclaimMemory(guestBase: guestBase)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: VirtioRng(),
            memory: memory,
            interrupt: {}
        )
        let first = guestBase + HostPage.size + 13
        let second = guestBase + 6 * HostPage.size - 8
        var regions: DoryRendererWorkerSharedRegionSet? = try DoryRendererWorkerSharedRegionSet.guestBacking(
            entries: [
                VirtioGPUMemoryEntry(
                    pointer: try memory.hostPointer(at: first, count: 33),
                    length: 33, guestAddress: first
                ),
                VirtioGPUMemoryEntry(
                    pointer: try memory.hostPointer(at: second, count: 16),
                    length: 16, guestAddress: second
                ),
            ],
            transport: transport
        )
        #expect(regions?.references.count == 2)
        #expect(regions?.descriptors.count == 1)
        withExtendedLifetime(regions) {
            // Neither offset entry covers a whole page, but all overlapping granules are pinned.
            for page in [UInt64(1), 5, 6] {
                #expect(memory.releaseRange(
                    guestAddress: guestBase + page * HostPage.size, length: HostPage.size
                ) == .rejected)
            }
            #expect(unmaps.load() == 0)
            // Sharing one descriptor must not pin the untouched gap between its entry ranges.
            #expect(memory.releaseRange(
                guestAddress: guestBase + 3 * HostPage.size, length: HostPage.size
            ) == .reclaimed)
        }
        #expect(unmaps.load() == 1)

        var retainedCopy = regions
        regions = nil
        withExtendedLifetime(retainedCopy) {
            #expect(retainedCopy?.references.count == 2)
            #expect(memory.releaseRange(
                guestAddress: guestBase + HostPage.size, length: HostPage.size
            ) == .rejected)
        }
        retainedCopy = nil
        for page in [UInt64(1), 5, 6] {
            #expect(memory.releaseRange(
                guestAddress: guestBase + page * HostPage.size, length: HostPage.size
            ) == .reclaimed)
        }
        #expect(unmaps.load() == 4)
    }

    @Test func rejectedBackingSetReleasesPinsAdmittedBeforeTheInvalidEntry() throws {
        let guestBase: UInt64 = 0x8300_0000
        let (memory, unmaps) = try makeMockReclaimMemory(guestBase: guestBase)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: VirtioRng(),
            memory: memory,
            interrupt: {}
        )
        let address = guestBase + 2 * HostPage.size + 32
        let pointer = try memory.hostPointer(at: address, count: 64)
        #expect(throws: VMError.self) {
            _ = try DoryRendererWorkerSharedRegionSet.guestBacking(
                entries: [
                    VirtioGPUMemoryEntry(pointer: pointer, length: 64, guestAddress: address),
                    VirtioGPUMemoryEntry(pointer: pointer, length: 0, guestAddress: address),
                ],
                transport: transport
            )
        }
        #expect(memory.releaseRange(
            guestAddress: guestBase + 2 * HostPage.size, length: HostPage.size
        ) == .reclaimed)
        #expect(unmaps.load() == 1)
    }

    private func makeMockReclaimMemory(guestBase: UInt64) throws -> (GuestMemory, ByteCounter) {
        let unmaps = ByteCounter()
        let memory = try GuestMemory(
            guestBase: guestBase,
            size: 8 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in
                    unmaps.add(1)
                    return true
                },
                map: { _, _, _ in true },
                markReusable: { _, _ in true },
                markInUse: { _, _ in true }
            )
        )
        return (memory, unmaps)
    }
}
