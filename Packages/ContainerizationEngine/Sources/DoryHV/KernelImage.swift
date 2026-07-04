import Foundation

/// Loader for the arm64 Linux boot Image format (Documentation/arch/arm64/booting.rst).
public struct KernelImage {
    public let data: Data
    public let textOffset: UInt64
    public let imageSize: UInt64

    private static let magicOffset = 56
    private static let magic: UInt32 = 0x644D_5241  // "ARM\x64"

    public init(contentsOf path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 64 else {
            throw VMError.bootFailure("kernel image too small: \(data.count) bytes")
        }
        let magic = data.readLittleEndian(UInt32.self, at: Self.magicOffset)
        guard magic == Self.magic else {
            throw VMError.bootFailure("not an arm64 boot Image (magic 0x\(String(magic, radix: 16)))")
        }
        self.data = data
        self.textOffset = data.readLittleEndian(UInt64.self, at: 8)
        let declaredSize = data.readLittleEndian(UInt64.self, at: 16)
        self.imageSize = max(declaredSize, UInt64(data.count))
    }

    /// Copies the image into guest RAM and returns the entry point.
    public func load(into memory: GuestMemory) throws -> UInt64 {
        let loadAddress = memory.guestBase + textOffset
        guard memory.contains(loadAddress, count: imageSize) else {
            throw VMError.bootFailure("kernel does not fit in guest RAM")
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
