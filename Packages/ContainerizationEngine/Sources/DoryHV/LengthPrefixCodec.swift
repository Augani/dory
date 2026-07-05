import Foundation

public enum LengthPrefixCodecError: Error, Equatable {
    case frameTooLarge(Int)
    case malformedPrefix
}

public enum LengthPrefixCodec {
    public static let prefixByteCount = 4

    public static func encode(_ payload: [UInt8], maximumFrameBytes: Int) throws -> [UInt8] {
        guard payload.count <= maximumFrameBytes else {
            throw LengthPrefixCodecError.frameTooLarge(payload.count)
        }
        let length = UInt32(payload.count)
        var frame = [UInt8]()
        frame.reserveCapacity(prefixByteCount + payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(contentsOf: payload)
        return frame
    }

    public static func decodeLength(_ prefix: [UInt8], maximumFrameBytes: Int) throws -> Int {
        guard prefix.count == prefixByteCount else { throw LengthPrefixCodecError.malformedPrefix }
        let length = (UInt32(prefix[0]) << 24) | (UInt32(prefix[1]) << 16)
            | (UInt32(prefix[2]) << 8) | UInt32(prefix[3])
        guard length <= UInt32(maximumFrameBytes) else {
            throw LengthPrefixCodecError.frameTooLarge(Int(length))
        }
        return Int(length)
    }
}
