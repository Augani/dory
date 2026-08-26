import Foundation

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
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}

extension UUID {
    var doryRendererBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    init(doryRendererBytes bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 16)
        self.init(uuid: (
            bytes[bytes.startIndex],
            bytes[bytes.startIndex + 1],
            bytes[bytes.startIndex + 2],
            bytes[bytes.startIndex + 3],
            bytes[bytes.startIndex + 4],
            bytes[bytes.startIndex + 5],
            bytes[bytes.startIndex + 6],
            bytes[bytes.startIndex + 7],
            bytes[bytes.startIndex + 8],
            bytes[bytes.startIndex + 9],
            bytes[bytes.startIndex + 10],
            bytes[bytes.startIndex + 11],
            bytes[bytes.startIndex + 12],
            bytes[bytes.startIndex + 13],
            bytes[bytes.startIndex + 14],
            bytes[bytes.startIndex + 15]
        ))
    }
}
