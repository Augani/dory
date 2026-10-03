import Darwin
import Foundation

/// A private, append-only observation trace for one daemon-authorized VZMac launch. The
/// recorder never grants runtime authority: release verification independently binds its
/// bytes, exact process/operation, and challenged window capture to a signed campaign.
final class DoryVZMacLifecycleTraceRecorder: @unchecked Sendable {
  static let schema = "dory.vzmac-lifecycle-event@1"

  enum Event: String, Sendable {
    case launchStarted = "launch-started"
    case running
    case suspended
    case stopped
    case failed
    case windowResized = "window-resized"
    case windowMiniaturized = "window-miniaturized"
    case windowRestored = "window-restored"
    case hostWillSleep = "host-will-sleep"
    case hostWoke = "host-woke"
    case restoreCompleted = "restore-completed"
    case processEnded = "process-ended"
  }

  private struct Record: Encodable {
    let schema: String
    let machineID: String
    let operationID: String
    let launchOperation: String
    let vmmProcessIdentifier: Int32
    let sequence: UInt64
    let wallTimeUnixMilliseconds: UInt64
    let monotonicNanoseconds: UInt64
    let event: String
  }

  let path: String
  private let machineID: String
  private let operationID: String
  private let launchOperation: String
  private let processID: Int32
  private let queue = DispatchQueue(label: "dev.dory.vzmac-lifecycle-trace", qos: .utility)
  /// Owned exclusively by `queue` after initialization.
  private var descriptor: Int32
  private var sequence: UInt64 = 0
  private var lastMonotonicNanoseconds: UInt64 = 0

  init(
    stateDirectoryURL: URL, machineID: String, operationID: UUID,
    launchOperation: DoryVZMacDesktopOperation
  ) throws {
    let canonical = stateDirectoryURL.standardizedFileURL
    guard canonical.isFileURL, canonical.path == stateDirectoryURL.path else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let directory = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(directory) }
    var directoryStat = stat()
    guard fstat(directory, &directoryStat) == 0,
      (directoryStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    else { throw CocoaError(.fileReadUnknown) }

    let canonicalOperation = operationID.uuidString.lowercased()
    let pid = getpid()
    let leaf = "mac-lifecycle-\(canonicalOperation)-\(pid).ndjson"
    let opened = openat(
      directory, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
    )
    guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    path = canonical.appendingPathComponent(leaf).path
    self.machineID = machineID
    self.operationID = canonicalOperation
    self.launchOperation = launchOperation.rawValue
    processID = pid
    descriptor = opened
  }

  deinit {
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  func record(_ event: Event) {
    queue.async { [self] in
      guard descriptor >= 0, sequence < .max, lastMonotonicNanoseconds < .max else { return }
      sequence += 1
      // Stamp after entering the serial writer. Concurrent producers cannot reverse timestamp
      // order relative to the durable sequence used by the lifecycle verifier.
      let wallTime = UInt64(max(1, Int64(Date().timeIntervalSince1970 * 1_000)))
      let monotonic = max(lastMonotonicNanoseconds + 1, DispatchTime.now().uptimeNanoseconds)
      lastMonotonicNanoseconds = monotonic
      let record = Record(
        schema: Self.schema,
        machineID: machineID,
        operationID: operationID,
        launchOperation: launchOperation,
        vmmProcessIdentifier: processID,
        sequence: sequence,
        wallTimeUnixMilliseconds: wallTime,
        monotonicNanoseconds: monotonic,
        event: event.rawValue
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard var payload = try? encoder.encode(record) else { return }
      payload.append(0x0a)
      var written = 0
      let success = payload.withUnsafeBytes { bytes -> Bool in
        guard let base = bytes.baseAddress else { return false }
        while written < bytes.count {
          let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
          if count <= 0 { return false }
          written += count
        }
        return true
      }
      if !success || fsync(descriptor) != 0 {
        FileHandle.standardError.write(Data("dory-vmm VZMac lifecycle trace write failed\n".utf8))
      }
    }
  }

  /// Drain all scheduled records before process exit; idempotent.
  func close() {
    queue.sync {
      guard descriptor >= 0 else { return }
      _ = fsync(descriptor)
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
}
