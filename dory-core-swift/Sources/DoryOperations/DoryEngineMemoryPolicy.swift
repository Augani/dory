import Foundation

/// One source of truth for the RawHV engine's ARM guest-RAM aperture.
///
/// Hypervisor.framework maps Dory's ARM RAM at the QEMU-compatible 2-GiB guest-physical base.
/// Current Apple silicon hosts reject a mapping whose exclusive end crosses the 64-GiB GPA
/// boundary. The largest representable RAM mapping is therefore exactly 62 GiB.
public enum DoryEngineMemoryPolicy {
    public static let guestPhysicalAddressLimitBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
    public static let guestRAMBaseBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumMemoryMB = Int(
        (guestPhysicalAddressLimitBytes - guestRAMBaseBytes) / (1_024 * 1_024)
    )
    public static let hostReserveMB = 4 * 1_024

    public static func hostScaledMemoryMB(
        physicalMemory: UInt64,
        minimumMemoryMB: Int = 2 * 1_024
    ) -> Int {
        let hostMemoryMB = Int(clamping: physicalMemory / (1_024 * 1_024))
        let hostScaled = max(
            minimumMemoryMB,
            min(hostMemoryMB / 2, hostMemoryMB - hostReserveMB)
        )
        return min(maximumMemoryMB, hostScaled)
    }

    public static func maximumConfigurableMemoryMB(
        physicalMemory: UInt64,
        minimumMemoryMB: Int = 2 * 1_024
    ) -> Int {
        let hostMemoryMB = Int(clamping: physicalMemory / (1_024 * 1_024))
        return max(
            minimumMemoryMB,
            min(maximumMemoryMB, hostMemoryMB - hostReserveMB)
        )
    }

    public static func clampedMemoryMB<T: BinaryInteger>(
        _ requestedMemoryMB: T,
        minimumMemoryMB: Int = 256
    ) -> Int {
        min(maximumMemoryMB, max(minimumMemoryMB, Int(clamping: requestedMemoryMB)))
    }
}
