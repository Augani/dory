public enum Phase0ADeterministicBytePattern {
    public static func byte(at offset: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (offset * 31) + 17)
    }
}
