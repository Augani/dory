import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite struct GuestMemoryTests {
    @Test func boundsCheckedReadWrite() throws {
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 32 * HostPage.size)
        try memory.write(UInt64(0xDEAD_BEEF_CAFE_F00D), at: 0x8000_0100)
        #expect(try memory.read(UInt64.self, at: 0x8000_0100) == 0xDEAD_BEEF_CAFE_F00D)
        #expect(memory.contains(0x8000_0000, count: 32 * HostPage.size))
        #expect(!memory.contains(0x8000_0000, count: 32 * HostPage.size + 1))
        #expect(!memory.contains(0x7FFF_FFFF, count: 1))
        #expect(throws: VMError.self) {
            _ = try memory.read(UInt32.self, at: 0x8000_0000 + 32 * HostPage.size - 2)
        }
    }

    @Test func rejectsUnalignedSize() {
        #expect(throws: VMError.self) {
            _ = try GuestMemory(guestBase: 0x8000_0000, size: 12345)
        }
    }

    @Test func rendererRegionIsPathFreeBoundedAndCoherent() throws {
        let base: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: base, size: 4 * HostPage.size)
        let valueAddress = base + HostPage.size + 128
        try memory.write(UInt32(0x1122_3344), at: valueAddress)

        let region = try memory.duplicateSharedRegion(at: valueAddress, count: 4)
        #expect(region.offset == 2 * HostPage.size + 128)
        #expect(region.length == 4)
        #expect(region.declaredFileSize == 5 * HostPage.size)

        var status = stat()
        #expect(fstat(region.descriptor.fileDescriptor, &status) == 0)
        #expect((status.st_mode & S_IFMT) == 0)
        #expect(status.st_nlink == 0)
        #expect(status.st_size == off_t(region.declaredFileSize))
        #expect(fcntl(region.descriptor.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(region.descriptor.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDWR)
        #expect(memory.sharedBackingDescriptorMatches(region.descriptor.fileDescriptor))

        let mapped = mmap(
            nil,
            Int(region.declaredFileSize),
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            region.descriptor.fileDescriptor,
            0
        )
        #expect(mapped != MAP_FAILED)
        guard mapped != MAP_FAILED, let mapped else { return }
        defer { munmap(mapped, Int(region.declaredFileSize)) }
        let word = mapped.advanced(by: Int(region.offset)).assumingMemoryBound(to: UInt32.self)
        #expect(UInt32(littleEndian: word.pointee) == 0x1122_3344)
        word.pointee = UInt32(0xaabb_ccdd).littleEndian
        #expect(try memory.read(UInt32.self, at: valueAddress) == 0xaabb_ccdd)

        #expect(throws: VMError.self) {
            _ = try memory.duplicateSharedRegion(
                at: base + 4 * HostPage.size - 2,
                count: 4
            )
        }
    }

    @Test func backingIdentityRejectsRegularStaleAndDifferentPOSIXDescriptors() throws {
        let base: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: base, size: 2 * HostPage.size)
        let region = try memory.duplicateSharedRegion(at: base, count: HostPage.size)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-guest-memory-test.XXXXXX")
        var template = temporaryURL.path.utf8CString
        let regularDescriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        #expect(regularDescriptor >= 0)
        guard regularDescriptor >= 0 else { return }
        defer { close(regularDescriptor) }
        #expect(template.withUnsafeBufferPointer { unlink($0.baseAddress!) } == 0)
        #expect(ftruncate(regularDescriptor, off_t(region.declaredFileSize)) == 0)
        let regularFlags = fcntl(regularDescriptor, F_GETFD)
        #expect(regularFlags >= 0)
        #expect(fcntl(regularDescriptor, F_SETFD, regularFlags | FD_CLOEXEC) == 0)
        var regularStatus = stat()
        #expect(fstat(regularDescriptor, &regularStatus) == 0)
        #expect((regularStatus.st_mode & S_IFMT) == S_IFREG)
        #expect(regularStatus.st_nlink == 0)
        #expect(!memory.sharedBackingDescriptorMatches(regularDescriptor))

        let staleDescriptor = fcntl(
            region.descriptor.fileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        #expect(staleDescriptor >= 0)
        guard staleDescriptor >= 0 else { return }
        #expect(close(staleDescriptor) == 0)
        #expect(!memory.sharedBackingDescriptorMatches(staleDescriptor))

        let otherMemory = try GuestMemory(guestBase: base, size: 2 * HostPage.size)
        let otherRegion = try otherMemory.duplicateSharedRegion(at: base, count: HostPage.size)
        #expect(otherRegion.declaredFileSize == region.declaredFileSize)
        #expect(otherMemory.sharedBackingDescriptorMatches(otherRegion.descriptor.fileDescriptor))
        #expect(!memory.sharedBackingDescriptorMatches(otherRegion.descriptor.fileDescriptor))

        let differentlySizedMemory = try GuestMemory(
            guestBase: base,
            size: 3 * HostPage.size
        )
        let differentlySizedRegion = try differentlySizedMemory.duplicateSharedRegion(
            at: base,
            count: HostPage.size
        )
        #expect(differentlySizedRegion.declaredFileSize != region.declaredFileSize)
        #expect(!memory.sharedBackingDescriptorMatches(
            differentlySizedRegion.descriptor.fileDescriptor
        ))
    }

    @Test func sharedRegionRetainsEveryOverlappingHostGranuleUntilItsLastCopyRetires() throws {
        let base: UInt64 = 0x8400_0000
        let (memory, unmaps) = try makeMockReclaimMemory(guestBase: base)
        var region: GuestMemorySharedRegion? = try memory.duplicateSharedRegion(
            at: base + HostPage.size - 8,
            count: 16
        )
        #expect(region?.length == 16)
        for page in [UInt64(0), 1] {
            #expect(memory.releaseRange(
                guestAddress: base + page * HostPage.size, length: HostPage.size
            ) == .rejected)
        }
        #expect(unmaps.load() == 0)
        #expect(memory.releaseRange(
            guestAddress: base + 2 * HostPage.size, length: HostPage.size
        ) == .reclaimed)

        var retainedCopy = region
        region = nil
        try withExtendedLifetime(retainedCopy) {
            #expect(retainedCopy?.offset == 2 * HostPage.size - 8)
            // Closing transport alone is not proof that every guest-RAM consumer retired.
            try retainedCopy?.descriptor.close()
            for page in [UInt64(0), 1] {
                #expect(memory.releaseRange(
                    guestAddress: base + page * HostPage.size, length: HostPage.size
                ) == .rejected)
            }
        }
        retainedCopy = nil
        for page in [UInt64(0), 1] {
            #expect(memory.releaseRange(
                guestAddress: base + page * HostPage.size, length: HostPage.size
            ) == .reclaimed)
        }
        #expect(unmaps.load() == 3)
    }

    @Test func retiringOneSharedRegionCannotUnpinAnotherExportOfTheSameHostGranule() throws {
        let base: UInt64 = 0x8500_0000
        let (memory, unmaps) = try makeMockReclaimMemory(guestBase: base)
        var first: GuestMemorySharedRegion? = try memory.duplicateSharedRegion(
            at: base + HostPage.size + 16,
            count: 32
        )
        var second: GuestMemorySharedRegion? = try memory.duplicateSharedRegion(
            at: base + HostPage.size + 128,
            count: 64
        )
        #expect(first?.length == 32)
        #expect(second?.length == 64)
        first = nil
        withExtendedLifetime(second) {
            #expect(memory.releaseRange(
                guestAddress: base + HostPage.size, length: HostPage.size
            ) == .rejected)
        }
        #expect(unmaps.load() == 0)
        second = nil
        #expect(memory.releaseRange(
            guestAddress: base + HostPage.size, length: HostPage.size
        ) == .reclaimed)
        #expect(unmaps.load() == 1)
    }

    private func makeMockReclaimMemory(guestBase: UInt64) throws -> (GuestMemory, ByteCounter) {
        let unmaps = ByteCounter()
        let memory = try GuestMemory(
            guestBase: guestBase,
            size: 4 * HostPage.size,
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
