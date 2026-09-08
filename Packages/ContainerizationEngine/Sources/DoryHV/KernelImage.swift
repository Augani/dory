import Foundation

/// Loader for the arm64 Linux boot Image format (Documentation/arch/arm64/booting.rst).
public struct KernelImage {
    public let data: Data
    public let textOffset: UInt64
    public let imageSize: UInt64

    private static let magicOffset = 56
    private static let magic: UInt32 = 0x644D_5241  // "ARM\x64"

    public init(contentsOf path: String) throws {
        try self.init(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public init(data: Data) throws {
        guard data.count > 64 else {
            throw VMError.bootFailure("kernel image too small: \(data.count) bytes")
        }
        let magic = data.readLittleEndian(UInt32.self, at: Self.magicOffset)
        guard magic == Self.magic else {
            throw VMError.bootFailure("not an arm64 boot Image (magic 0x\(String(magic, radix: 16)))")
        }
        self.data = data
        let declaredSize = data.readLittleEndian(UInt64.self, at: 16)
        // Pre-v3.17 headers have unspecified text_offset endianness. The boot
        // protocol defines the legacy offset whenever image_size is zero.
        self.textOffset = declaredSize == 0 ? 0x80000
            : data.readLittleEndian(UInt64.self, at: 8)
        self.imageSize = max(declaredSize, UInt64(data.count))
    }

    /// Copies the image into guest RAM and returns the entry point.
    public func load(
        into memory: GuestMemory, reservedRanges: [Range<UInt64>] = []
    ) throws -> UInt64 {
        guard memory.guestBase.isMultiple(of: 2 * 1024 * 1024) else {
            throw VMError.bootFailure("kernel RAM base must be 2 MiB aligned")
        }
        let (loadAddress, addressOverflowed) = memory.guestBase.addingReportingOverflow(textOffset)
        guard !addressOverflowed else {
            throw VMError.bootFailure("kernel load address overflows")
        }
        guard memory.contains(loadAddress, count: imageSize) else {
            throw VMError.bootFailure("kernel does not fit in guest RAM")
        }
        let (loadEnd, endOverflowed) = loadAddress.addingReportingOverflow(imageSize)
        guard !endOverflowed else {
            throw VMError.bootFailure("kernel loaded extent overflows")
        }
        // Reject reserved boot structures before any image byte can overwrite RAM.
        let loadedRange = loadAddress..<loadEnd
        guard !reservedRanges.contains(where: { $0.overlaps(loadedRange) }) else {
            throw VMError.bootFailure("kernel image overlaps reserved boot memory")
        }
        let destination = try memory.hostPointer(at: loadAddress, count: UInt64(data.count))
        data.withUnsafeBytes { source in
            destination.copyMemory(from: source.baseAddress!, byteCount: data.count)
        }
        return loadAddress
    }
}

extension Data {
    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value = T.zero
        for byteIndex in 0..<MemoryLayout<T>.size {
            let byte = self[startIndex + offset + byteIndex]
            value |= T(truncatingIfNeeded: UInt64(byte) << (8 * UInt64(byteIndex)))
        }
        return value
    }
}
