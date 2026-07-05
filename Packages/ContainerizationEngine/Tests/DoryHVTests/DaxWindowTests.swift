import Testing
@testable import DoryHV

struct DaxWindowTests {
    @Test func setupMappingTracksPageAlignedWindowEntries() throws {
        let window = try DaxWindow(guestBase: 0x1_0000_0000, length: 0x20_0000)

        let mapping = try window.setup(FuseSetupMappingIn(
            fileHandle: 7,
            fileOffset: 0x4000,
            length: 0x8000,
            flags: 0,
            memoryOffset: 0x10_0000
        ))

        #expect(mapping.fileHandle == 7)
        #expect(try window.guestAddress(forMemoryOffset: 0x10_0000) == 0x1_0010_0000)
        #expect(window.activeMappings == [mapping])
    }

    @Test func setupMappingRejectsUnalignedOutOfBoundsAndOverlaps() throws {
        let window = try DaxWindow(guestBase: 0x8000_0000, length: 0x20_000)
        _ = try window.setup(FuseSetupMappingIn(fileHandle: 1, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0x4000))

        #expect(throws: DaxWindowError.unaligned) {
            try window.setup(FuseSetupMappingIn(fileHandle: 2, fileOffset: 1, length: 0x4000, flags: 0, memoryOffset: 0x8000))
        }
        #expect(throws: DaxWindowError.outOfBounds) {
            try window.setup(FuseSetupMappingIn(fileHandle: 2, fileOffset: 0, length: 0x40_000, flags: 0, memoryOffset: 0))
        }
        #expect(throws: DaxWindowError.overlap) {
            try window.setup(FuseSetupMappingIn(fileHandle: 2, fileOffset: 0, length: 0x8000, flags: 0, memoryOffset: 0))
        }
    }

    @Test func removeMappingDropsOverlappingEntriesAndNoOpsOnUnmapped() throws {
        let window = try DaxWindow(guestBase: 0x8000_0000, length: 0x20_000)
        _ = try window.setup(FuseSetupMappingIn(fileHandle: 1, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0))
        _ = try window.setup(FuseSetupMappingIn(fileHandle: 2, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0x8000))

        try window.remove(FuseRemoveMappingIn(mappings: [FuseRemoveMappingOne(memoryOffset: 0, length: 0x4000)]))

        #expect(window.activeMappings.map(\.fileHandle) == [2])

        try window.remove(FuseRemoveMappingIn(mappings: [FuseRemoveMappingOne(memoryOffset: 0, length: 0x4000)]))
        #expect(window.activeMappings.map(\.fileHandle) == [2])
    }

    @Test func backendMapsAndUnmapsWithOpenFileDescriptorAndGuestAddress() throws {
        let backend = RecordingDaxBackend()
        let window = try DaxWindow(guestBase: 0x1_0000_0000, length: 0x20_000, backend: backend)
        let request = FuseSetupMappingIn(
            fileHandle: 7,
            fileOffset: 0x4000,
            length: 0x4000,
            flags: FuseSetupMappingFlag.read.union(.write).rawValue,
            memoryOffset: 0x8000
        )

        _ = try window.setup(request, fileDescriptor: 42)

        #expect(backend.mapped.count == 1)
        #expect(backend.mapped[0].fd == 42)
        #expect(backend.mapped[0].guestAddress == 0x1_0000_0000 + 0x8000)
        #expect(backend.mapped[0].mapping.fileOffset == 0x4000)

        try window.remove(FuseRemoveMappingIn(mappings: [
            FuseRemoveMappingOne(memoryOffset: 0x8000, length: 0x4000),
        ]))

        #expect(backend.unmapped.count == 1)
        #expect(backend.unmapped[0].guestAddress == 0x1_0000_0000 + 0x8000)
    }

    @Test func backendWindowRejectsSetupWithoutFileDescriptor() throws {
        let backend = RecordingDaxBackend()
        let window = try DaxWindow(guestBase: 0x1_0000_0000, length: 0x20_000, backend: backend)

        #expect(throws: DaxWindowError.mappingFailed("missing file descriptor")) {
            try window.setup(FuseSetupMappingIn(fileHandle: 7, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0))
        }
        #expect(backend.mapped.isEmpty)
    }
}

private final class RecordingDaxBackend: DaxMappingBackend, @unchecked Sendable {
    var mapped: [(mapping: DaxMapping, fd: Int32, guestAddress: UInt64)] = []
    var unmapped: [(mapping: DaxMapping, guestAddress: UInt64)] = []

    func map(_ mapping: DaxMapping, fileDescriptor: Int32, guestAddress: UInt64) throws {
        mapped.append((mapping, fileDescriptor, guestAddress))
    }

    func unmap(_ mapping: DaxMapping, guestAddress: UInt64) throws {
        unmapped.append((mapping, guestAddress))
    }
}
