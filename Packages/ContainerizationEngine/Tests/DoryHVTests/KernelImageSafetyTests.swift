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
