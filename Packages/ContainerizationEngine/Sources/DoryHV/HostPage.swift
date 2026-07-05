import Darwin

public enum HostPage {
    public static let size: UInt64 = UInt64(Darwin.getpagesize())
}
