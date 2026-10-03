import DoryMacGuestIntegrationWire
import Foundation

/// Owns the selected file's sequential descriptor independently of the client/session lock.
/// Retirement revokes admission immediately, but never closes a descriptor underneath a read.
/// The reader also holds its lease through the caller's exact post-I/O authorization/commit.
final class DoryGuestFileOfferReader: @unchecked Sendable {
  private final class Cleanup: @unchecked Sendable {
    let handle: FileHandle
    let onClose: @Sendable () -> Void

    init(handle: FileHandle, onClose: @escaping @Sendable () -> Void) {
      self.handle = handle
      self.onClose = onClose
    }

    func run() {
      try? handle.close()
      onClose()
    }
  }

  private let lock = NSLock()
  private let cleanup: Cleanup
  private var reading = false
  private var retired = false
  private var cleanupScheduled = false

  init(handle: FileHandle, onClose: @escaping @Sendable () -> Void = {}) {
    cleanup = Cleanup(handle: handle, onClose: onClose)
  }

  deinit { retire() }

  func read<Result>(
    _ operation: (FileHandle) throws -> Data,
    authorizeResult: (Data) throws -> Result
  ) throws -> Result {
    try lock.withLock {
      guard !retired, !reading else {
        throw DoryMacGuestIntegrationWire.WireError.connectionClosed
      }
      reading = true
    }
    defer {
      lock.withLock { reading = false }
      scheduleCleanupIfQuiescent()
    }
    let bytes = try operation(cleanup.handle)
    try lock.withLock {
      guard !retired else { throw DoryMacGuestIntegrationWire.WireError.connectionClosed }
    }
    // The client supplies its original deadline, connection, console and offer/offset gate.
    // Retirement can race this callback; that owner gate must therefore remain atomic.
    return try authorizeResult(bytes)
  }

  func retire() {
    lock.withLock { retired = true }
    scheduleCleanupIfQuiescent()
  }

  private func scheduleCleanupIfQuiescent() {
    let detached = lock.withLock { () -> Cleanup? in
      guard retired, !reading, !cleanupScheduled else { return nil }
      cleanupScheduled = true
      return cleanup
    }
    guard let detached else { return }
    // A close or security-scope release is foreign I/O. Never invoke it synchronously from
    // retire(), which may itself be called while the client's ownership lock is held.
    DispatchQueue.global(qos: .utility).async { detached.run() }
  }
}
