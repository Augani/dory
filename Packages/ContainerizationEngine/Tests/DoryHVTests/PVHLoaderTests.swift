import Foundation
import Testing
@testable import DoryHV

@Suite struct PVHLoaderTests {
    @Test func parsesPVHEntryAndLoadSegmentsFromELFNotes() throws {
        let image = try PVHKernelImage(data: makeELF(pvhEntry: 0x0010_0020))

        #expect(image.entryPoint == 0x0010_0020)
        #expect(image.segments == [
            PVHKernelSegment(physicalAddress: 0x0010_0000, fileOffset: 0x200, fileSize: 4, memorySize: 8)
        ])
    }

    @Test func loadCopiesSegmentsAndZerosBSS() throws {
        let image = try PVHKernelImage(data: makeELF(pvhEntry: 0x0010_0020))
        let memory = try GuestMemory(guestBase: 0, size: 2 * 1024 * 1024)

        let entry = try image.load(into: memory)

        #expect(entry == 0x0010_0020)
        #expect(try memory.readBytes(at: 0x0010_0000, count: 8) == [1, 2, 3, 4, 0, 0, 0, 0])
    }

    @Test func rejectsELFWithoutPVHEntryNote() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: nil))
        }
    }

    @Test func rejectsLoadSegmentWhoseFileSizeExceedsMemorySize() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: 0x0010_0020, fileSize: 9, memorySize: 8))
        }
    }

    @Test func rejectsNonX8664ELF() {
        #expect(throws: VMError.self) {
            _ = try PVHKernelImage(data: makeELF(pvhEntry: 0x0010_0020, machine: 0xB7))
        }
    }

    private func makeELF(
        pvhEntry: UInt32?,
        machine: UInt16 = 0x3E,
        fileSize: UInt64 = 4,
        memorySize: UInt64 = 8
    ) -> Data {
        let programHeaderOffset = 0x40
        let noteOffset = 0x180
        let segmentOffset = 0x200
        var data = Data(repeating: 0, count: 0x240)

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
        data.writeLE16(2, at: 56)

        writeProgramHeader(
            data: &data,
            at: programHeaderOffset,
            type: 1,
            fileOffset: UInt64(segmentOffset),
            physicalAddress: 0x0010_0000,
            fileSize: fileSize,
            memorySize: memorySize
        )
        let noteSize = UInt64(writePVHNote(&data, at: noteOffset, entry: pvhEntry))
        writeProgramHeader(
            data: &data,
            at: programHeaderOffset + 56,
            type: 4,
            fileOffset: UInt64(noteOffset),
            physicalAddress: 0,
            fileSize: noteSize,
            memorySize: noteSize
        )

        data[segmentOffset] = 1
        data[segmentOffset + 1] = 2
        data[segmentOffset + 2] = 3
        data[segmentOffset + 3] = 4
        return data
    }

    private func writeProgramHeader(
        data: inout Data,
        at offset: Int,
        type: UInt32,
        fileOffset: UInt64,
        physicalAddress: UInt64,
        fileSize: UInt64,
        memorySize: UInt64
    ) {
        data.writeLE32(type, at: offset)
        data.writeLE32(0, at: offset + 4)
        data.writeLE64(fileOffset, at: offset + 8)
        data.writeLE64(0, at: offset + 16)
        data.writeLE64(physicalAddress, at: offset + 24)
        data.writeLE64(fileSize, at: offset + 32)
        data.writeLE64(memorySize, at: offset + 40)
        data.writeLE64(0x1000, at: offset + 48)
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
