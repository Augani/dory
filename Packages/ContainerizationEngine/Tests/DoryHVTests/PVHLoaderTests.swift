import Foundation
import Testing
@testable import DoryHV

@Suite struct PVHLoaderTests {
    private static let validEntry: UInt32 = 0x0010_0000
    private static let validPaddr: UInt64 = 0x0010_0000

    @Test func parsesPVHEntryAndLoadSegmentsFromELFNotes() throws {
        let image = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry))

        #expect(image.entryPoint == UInt64(Self.validEntry))
        #expect(image.segments == [
            PVHKernelSegment(physicalAddress: 0x0010_0000, fileOffset: 0x200, fileSize: 4, memorySize: 8)
        ])
    }

    @Test func loadCopiesSegmentsAndZerosBSS() throws {
        let image = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry))
        let memory = try GuestMemory(guestBase: 0, size: 2 * 1024 * 1024)

        let entry = try image.load(into: memory)

        #expect(entry == UInt64(Self.validEntry))
        #expect(try memory.readBytes(at: 0x0010_0000, count: 8) == [1, 2, 3, 4, 0, 0, 0, 0])
    }

    @Test func rejectsELFWithoutPVHEntryNote() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: nil))
        }
    }

    @Test func rejectsLoadSegmentWhoseFileSizeExceedsMemorySize() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry, fileSize: 9, memorySize: 8))
        }
    }

    @Test func rejectsFileExtentOutsideImage() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry, fileOffset: 0x1000, fileSize: 4))
        }
    }

    @Test func rejectsOverflowingFileExtent() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(
                data: makeELF(pvhEntry: Self.validEntry, fileOffset: UInt64.max - 2, fileSize: 4)
            )
        }
    }

    @Test func rejectsFileExtentEndingBeyondIntMax() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(
                data: makeELF(pvhEntry: Self.validEntry, fileOffset: UInt64(Int.max), fileSize: 1)
            )
        }
    }

    @Test func rejectsOverflowingPhysicalExtent() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(
                data: makeELF(
                    pvhEntry: Self.validEntry,
                    physicalAddress: UInt64.max - 4,
                    virtualAddress: UInt64.max - 4,
                    fileSize: 4,
                    memorySize: 8
                )
            )
        }
    }

    @Test func rejectsOverlappingPhysicalExtents() {
        let loads = [
            LoadSpec(physicalAddress: 0x0010_0000, virtualAddress: 0x0010_0000, fileOffset: 0x200),
            LoadSpec(physicalAddress: 0x0010_0004, virtualAddress: 0x0010_0004, fileOffset: 0x210),
        ]
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeMultiSegmentELF(pvhEntry: Self.validEntry, loads: loads))
        }
    }

    @Test func allowsEmptySegmentAtSameAddress() throws {
        let loads = [
            LoadSpec(physicalAddress: 0x0010_0000, virtualAddress: 0x0010_0000, fileOffset: 0x200),
            LoadSpec(
                physicalAddress: 0x0010_0000,
                virtualAddress: 0x0010_0000,
                fileOffset: 0x220,
                fileSize: 0,
                memorySize: 0
            ),
        ]
        let image = try PVHKernelImage(data: makeMultiSegmentELF(pvhEntry: Self.validEntry, loads: loads))
        #expect(image.segments.count == 2)
    }

    @Test func rejectsNonPowerOfTwoAlign() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry, align: 3))
        }
    }

    @Test func rejectsMisalignedVaddrOffsetCongruence() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(
                data: makeELF(
                    pvhEntry: Self.validEntry,
                    virtualAddress: 0,
                    fileOffset: 0x200,
                    align: 0x1000
                )
            )
        }
    }

    @Test func acceptsPowerOfTwoAlignedVaddrOffsetCongruence() throws {
        let image = try PVHKernelImage(
            data: makeELF(
                pvhEntry: Self.validEntry,
                virtualAddress: 0x0010_0200,
                fileOffset: 0x200,
                align: 0x1000
            )
        )
        #expect(image.entryPoint == UInt64(Self.validEntry))
    }

    @Test func acceptsZeroAlignWithoutCongruence() throws {
        let image = try PVHKernelImage(
            data: makeELF(pvhEntry: Self.validEntry, virtualAddress: 0, fileOffset: 0x200, align: 0)
        )
        #expect(image.entryPoint == UInt64(Self.validEntry))
    }

    @Test func rejectsEntryOutsideSegments() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: 0x0020_0000))
        }
    }

    @Test func rejectsNonExecutableEntry() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry, flags: 4))
        }
    }

    @Test func rejectsBSSOnlyEntry() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: 0x0010_0004))
        }
    }

    @Test func rejectsNonX8664ELF() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: Self.validEntry, machine: 0xB7))
        }
    }

    @Test func lateOutOfRAMSegmentLeavesEarlierGuestBytesUntouched() throws {
        let loads = [
            LoadSpec(physicalAddress: 0x0010_0000, virtualAddress: 0x0010_0000, fileOffset: 0x200),
            LoadSpec(physicalAddress: 0x0030_0000, virtualAddress: 0x0030_0000, fileOffset: 0x210),
        ]
        let image = try PVHKernelImage(data: makeMultiSegmentELF(pvhEntry: Self.validEntry, loads: loads))
        let memory = try GuestMemory(guestBase: 0, size: 2 * 1024 * 1024)
        let sentinel = [UInt8](repeating: 0xAA, count: 8)
        try memory.write(sentinel, at: 0x0010_0000)

        #expect(throws: VMError.self) {
            _ = try image.load(into: memory)
        }
        #expect(try memory.readBytes(at: 0x0010_0000, count: 8) == sentinel)
    }

    private struct LoadSpec {
        var physicalAddress: UInt64 = 0x0010_0000
        var virtualAddress: UInt64 = 0x0010_0000
        var fileOffset: UInt64 = 0x200
        var fileSize: UInt64 = 4
        var memorySize: UInt64 = 8
        var flags: UInt32 = 5
        var align: UInt64 = 1
    }

    private func makeELF(
        pvhEntry: UInt32?,
        machine: UInt16 = 0x3E,
        fileSize: UInt64 = 4,
        memorySize: UInt64 = 8,
        flags: UInt32 = 5,
        align: UInt64 = 1,
        virtualAddress: UInt64 = 0x0010_0000,
        physicalAddress: UInt64 = 0x0010_0000,
        fileOffset: UInt64 = 0x200
    ) -> Data {
        makeMultiSegmentELF(
            pvhEntry: pvhEntry,
            machine: machine,
            loads: [LoadSpec(
                physicalAddress: physicalAddress,
                virtualAddress: virtualAddress,
                fileOffset: fileOffset,
                fileSize: fileSize,
                memorySize: memorySize,
                flags: flags,
                align: align
            )]
        )
    }

    private func makeMultiSegmentELF(
        pvhEntry: UInt32?,
        machine: UInt16 = 0x3E,
        loads: [LoadSpec]
    ) -> Data {
        let programHeaderOffset = 0x40
        let noteOffset = 0x180
        var data = Data(repeating: 0, count: 0x400)

        data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
        data[4] = 2  // ELFCLASS64
        data[5] = 1  // little endian
        data[6] = 1  // current ELF version
        data.writeLE16(2, at: 16)
        data.writeLE16(machine, at: 18)
        data.writeLE32(1, at: 20)
        data.writeLE64(0, at: 24)
        data.writeLE64(UInt64(programHeaderOffset), at: 32)
        data.writeLE16(64, at: 52)
        data.writeLE16(56, at: 54)
        data.writeLE16(UInt16(loads.count + 1), at: 56)

        for (index, load) in loads.enumerated() {
            writeProgramHeader(
                data: &data,
                at: programHeaderOffset + index * 56,
                type: 1,
                flags: load.flags,
                fileOffset: load.fileOffset,
                virtualAddress: load.virtualAddress,
                physicalAddress: load.physicalAddress,
                fileSize: load.fileSize,
                memorySize: load.memorySize,
                align: load.align
            )
        }
        let noteSize = UInt64(writePVHNote(&data, at: noteOffset, entry: pvhEntry))
        writeProgramHeader(
            data: &data,
            at: programHeaderOffset + loads.count * 56,
            type: 4,
            flags: 0,
            fileOffset: UInt64(noteOffset),
            virtualAddress: 0,
            physicalAddress: 0,
            fileSize: noteSize,
            memorySize: noteSize,
            align: 1
        )

        for (index, load) in loads.enumerated() {
            guard load.fileSize > 0,
                  load.fileOffset <= UInt64(data.count),
                  load.fileSize <= UInt64(data.count)
            else {
                continue
            }
            let end = load.fileOffset.addingReportingOverflow(load.fileSize)
            guard !end.overflow, end.partialValue <= UInt64(data.count) else {
                continue
            }
            let start = Int(load.fileOffset)
            for byteIndex in 0..<Int(load.fileSize) {
                data[start + byteIndex] = UInt8((index * 16 + byteIndex + 1) & 0xFF)
            }
        }
        return data
    }

    private func writeProgramHeader(
        data: inout Data,
        at offset: Int,
        type: UInt32,
        flags: UInt32 = 0,
        fileOffset: UInt64,
        virtualAddress: UInt64 = 0,
        physicalAddress: UInt64,
        fileSize: UInt64,
        memorySize: UInt64,
        align: UInt64 = 1
    ) {
        data.writeLE32(type, at: offset)
        data.writeLE32(flags, at: offset + 4)
        data.writeLE64(fileOffset, at: offset + 8)
        data.writeLE64(virtualAddress, at: offset + 16)
        data.writeLE64(physicalAddress, at: offset + 24)
        data.writeLE64(fileSize, at: offset + 32)
        data.writeLE64(memorySize, at: offset + 40)
        data.writeLE64(align, at: offset + 48)
    }

    @discardableResult
    private func writePVHNote(_ data: inout Data, at offset: Int, entry: UInt32?) -> Int {
        guard let entry else { return 0 }
        data.writeLE32(4, at: offset)       // "Xen\0"
        data.writeLE32(4, at: offset + 4)
        data.writeLE32(0x12, at: offset + 8)
        data.replaceSubrange(offset + 12..<offset + 16, with: Array("Xen".utf8) + [0])
        data.writeLE32(entry, at: offset + 16)
        return 20
    }
}

private extension Data {
    mutating func writeLE16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeLE32(_ value: UInt32, at offset: Int) {
        for byteIndex in 0..<4 {
            self[offset + byteIndex] = UInt8((value >> UInt32(8 * byteIndex)) & 0xFF)
        }
    }

    mutating func writeLE64(_ value: UInt64, at offset: Int) {
        for byteIndex in 0..<8 {
            self[offset + byteIndex] = UInt8((value >> UInt64(8 * byteIndex)) & 0xFF)
        }
    }
}
