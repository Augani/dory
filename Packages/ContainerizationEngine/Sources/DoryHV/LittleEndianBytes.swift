extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func leUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < count else { return 0 }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}

extension ArraySlice where Element == UInt8 {
    func leUInt16(at offset: Int) -> UInt16 {
        let index = startIndex + offset
        guard offset >= 0, index + 1 < endIndex else { return 0 }
        return UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        guard offset >= 0, index + 3 < endIndex else { return 0 }
        return UInt32(self[index])
            | UInt32(self[index + 1]) << 8
            | UInt32(self[index + 2]) << 16
            | UInt32(self[index + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}
