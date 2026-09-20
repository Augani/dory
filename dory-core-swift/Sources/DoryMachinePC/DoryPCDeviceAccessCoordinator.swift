import Foundation

/// Conservative machine-scoped serialization for guest CPU device accesses.
///
/// Device models retain their own locks for asynchronous backend work and diagnostics. This
/// domain prevents two vCPUs from concurrently entering MMIO, port-I/O, or PCI callbacks until a
/// model has a stronger independently qualified concurrency contract. It is recursive because a
/// device callback may synchronously route a second access within the same machine.
///
/// The domain is never used for ordinary RAM. A device callback may therefore acquire RAM range
/// authority for DMA while holding this lock, matching the device-before-RAM lock order. Callbacks
/// must release device-local configuration locks before waiting on RAM authority. Memory
/// synchronization is also outside this domain because asynchronous device work uses it to publish
/// DMA while a guest access may still be waiting for that work to complete.
final class DoryPCDeviceAccessCoordinator: @unchecked Sendable {
  private let lock = NSRecursiveLock()

  func withAccess<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
