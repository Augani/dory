import Foundation
import Testing
@testable import DoryHV

struct KernelImageSafetyTests {
    @Test func craftedTextOffsetOverflowThrowsInsteadOfTrapping() throws {
        let image = try KernelImage(data: arm64Image(textOffset: UInt64.max))
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 1 << 20)

        do {
            _ = try image.load(into: memory)
            Issue.record("overflowing kernel load unexpectedly succeeded")
        } catch {
            #expect(
                String(describing: error) == "boot failure: kernel load address overflows"
            )
        }
    }

    @Test func legacySizeUsesProtocolOffsetRegardlessOfHeaderEndianness() throws {
        var bytes = [UInt8](arm64Image(textOffset: 0x0000_0800_0000_0000))
        putLittleEndian(UInt64(0), into: &bytes, at: 16)
        let image = try KernelImage(data: Data(bytes))
        #expect(image.textOffset == 0x80000)
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 1 << 20)
        #expect(try image.load(into: memory) == 0x8008_0000)
    }

    @Test func reservedOverlapRejectsBeforeCopyingAnyBytes() throws {
        let image = try KernelImage(data: arm64Image(textOffset: 0))
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 1 << 20)
        let pointer = try memory.hostPointer(at: memory.guestBase, count: 4096)
        pointer.initializeMemory(as: UInt8.self, repeating: 0xA5, count: 4096)
        #expect(throws: (any Error).self) {
            try image.load(into: memory, reservedRanges: [0x8000_0800..<0x8000_1000])
        }
        #expect(UnsafeRawBufferPointer(start: pointer, count: 4096).allSatisfy { $0 == 0xA5 })
    }

    @Test func reservationIncludesDeclaredRuntimeExtentAndAllowsAdjacency() throws {
        var bytes = [UInt8](arm64Image(textOffset: 0))
        putLittleEndian(UInt64(8192), into: &bytes, at: 16)
        let image = try KernelImage(data: Data(bytes))
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 1 << 20)
        #expect(throws: (any Error).self) {
            try image.load(into: memory, reservedRanges: [0x8000_1000..<0x8000_2000])
        }
        #expect(try image.load(into: memory, reservedRanges: [0x8000_2000..<0x8000_3000])
            == 0x8000_0000)
    }

    @Test func unalignedRAMBaseIsRejected() throws {
        let image = try KernelImage(data: arm64Image(textOffset: 0))
        let memory = try GuestMemory(guestBase: 0x8000_4000, size: 1 << 20)
        #expect(throws: (any Error).self) { try image.load(into: memory) }
    }

    @Test func loadedExtentOverflowThrowsInsteadOfWrappingReservation() throws {
        let image = try KernelImage(data: arm64Image(textOffset: 0x1F_F000))
        let memory = try GuestMemory(guestBase: 0xFFFF_FFFF_FFE0_0000, size: 2 << 20)
        #expect(throws: (any Error).self) { try image.load(into: memory) }
    }

    private func arm64Image(textOffset: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        putLittleEndian(textOffset, into: &bytes, at: 8)
        putLittleEndian(UInt64(bytes.count), into: &bytes, at: 16)
        putLittleEndian(UInt32(0x644D_5241), into: &bytes, at: 56)
        return Data(bytes)
    }

    private func putLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        for index in 0..<MemoryLayout<T>.size {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> T(index * 8)
            )
        }
    }
}
