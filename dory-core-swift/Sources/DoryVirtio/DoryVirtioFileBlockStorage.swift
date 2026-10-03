import Darwin
import Dispatch
import Foundation

struct DoryVirtioFileBlockIOResult: Sendable {
  let count: Int
  let code: Int32
}

/// Internal syscall seam; the immutable operations remain attached to one owned descriptor.
/// Storage's existing lock serializes calls, and production never resolves the pathname again.
struct DoryVirtioFileBlockIOOperations: @unchecked Sendable {
  var read: (Int32, UnsafeMutableRawBufferPointer, UInt64) -> DoryVirtioFileBlockIOResult
  var write: (Int32, UnsafeRawBufferPointer, UInt64) -> DoryVirtioFileBlockIOResult
  var fullFlush: (Int32) -> DoryVirtioFileBlockIOResult
  var monotonicNanoseconds: () -> UInt64

  static var production: Self {
    .init(
      read: { descriptor, buffer, offset in
        let count = pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        return .init(count: count, code: count < 0 ? errno : 0)
      },
      write: { descriptor, buffer, offset in
        let count = pwrite(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        return .init(count: count, code: count < 0 ? errno : 0)
      },
      fullFlush: { descriptor in
        let result = fcntl(descriptor, F_FULLFSYNC, 0)
        return .init(count: Int(result), code: result < 0 ? errno : 0)
      },
      monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
    )
  }
}

public enum DoryVirtioFileBlockStorageError: Error, Sendable, Equatable {
  case invalidCapacity(UInt64)
  case notRegularFile
  case systemCall(operation: String, code: Int32)
  case shortRead(expected: Int, actual: Int)
}

/// Durable regular-file storage for the transport-neutral block device. Files are opened without
/// following a final symlink, all I/O uses positional system calls, and every short transfer is
/// handled explicitly.
public final class DoryVirtioFileBlockStorage: DoryVirtioBlockStorage, @unchecked Sendable {
  public let capacityBytes: UInt64
  public let logicalBlockSize: UInt32
  public let readOnly: Bool

  private let descriptor: Int32
  private let lock = NSLock()
  private let ioOperations: DoryVirtioFileBlockIOOperations

  // Bound consecutive no-progress signal retries, not valid positive short transfers.
  // The attempt cap also bounds a stopped/backward injected clock. Neither bound can
  // preempt a syscall already blocked inside the kernel or promise a total I/O deadline.
  static let maximumConsecutiveInterruptions = 1_024
  static let maximumNoProgressNanoseconds: UInt64 = 5_000_000_000

  private struct NoProgressBudget {
    var firstInterruption: UInt64?
    var interruptions = 0

    mutating func madeProgress() {
      firstInterruption = nil
      interruptions = 0
    }

    mutating func interrupted(
      operation: String,
      operations: DoryVirtioFileBlockIOOperations
    ) throws {
      interruptions += 1
      guard interruptions < DoryVirtioFileBlockStorage.maximumConsecutiveInterruptions else {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: operation, code: EINTR)
      }
      if firstInterruption == nil { firstInterruption = operations.monotonicNanoseconds() }
    }

    func admitAttempt(operation: String, operations: DoryVirtioFileBlockIOOperations) throws {
      guard let firstInterruption else { return }
      let now = operations.monotonicNanoseconds()
      guard now < firstInterruption
        || now - firstInterruption < DoryVirtioFileBlockStorage.maximumNoProgressNanoseconds
      else {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: operation, code: EINTR)
      }
    }
  }

  public init(
    existingFileURL url: URL,
    logicalBlockSize: UInt32 = 512,
    readOnly: Bool = false
  ) throws {
    let flags = (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW
    let descriptor = Darwin.open(url.path, flags)
    guard descriptor >= 0 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "open", code: errno)
    }
    do {
      let capacity = try Self.regularFileCapacity(descriptor)
      try Self.validate(capacity: capacity, logicalBlockSize: logicalBlockSize)
      self.descriptor = descriptor
      capacityBytes = capacity
      self.logicalBlockSize = logicalBlockSize
      self.readOnly = readOnly
      ioOperations = .production
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  /// Duplicates an already admitted file descriptor without resolving a pathname. The caller
  /// remains responsible for its descriptor; this storage object owns only the duplicate.
  public convenience init(
    duplicatingFileDescriptor source: Int32,
    expectedCapacityBytes: UInt64,
    logicalBlockSize: UInt32 = 512,
    readOnly: Bool
  ) throws {
    try self.init(
      duplicatingFileDescriptor: source,
      expectedCapacityBytes: expectedCapacityBytes,
      logicalBlockSize: logicalBlockSize,
      readOnly: readOnly,
      ioOperations: .production
    )
  }

  init(
    duplicatingFileDescriptor source: Int32,
    expectedCapacityBytes: UInt64,
    logicalBlockSize: UInt32 = 512,
    readOnly: Bool,
    ioOperations: DoryVirtioFileBlockIOOperations
  ) throws {
    guard source >= 3 else { throw DoryVirtioFileBlockStorageError.notRegularFile }
    // Capture our authority first. Inspecting the source before duplication would validate a
    // different file if another owner closed and reused that descriptor during admission.
    let duplicate = fcntl(source, F_DUPFD_CLOEXEC, 3)
    guard duplicate >= 3 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "fcntl", code: errno)
    }
    do {
      let access = fcntl(duplicate, F_GETFL)
      guard access >= 0,
        (readOnly ? access & O_ACCMODE == O_RDONLY : access & O_ACCMODE == O_RDWR),
        access & O_APPEND == 0,
        try Self.regularFileCapacity(duplicate) == expectedCapacityBytes
      else { throw DoryVirtioFileBlockStorageError.notRegularFile }
      try Self.validate(capacity: expectedCapacityBytes, logicalBlockSize: logicalBlockSize)
      descriptor = duplicate
      capacityBytes = expectedCapacityBytes
      self.logicalBlockSize = logicalBlockSize
      self.readOnly = readOnly
      self.ioOperations = ioOperations
    } catch {
      Darwin.close(duplicate)
      throw error
    }
  }

  private init(
    descriptor: Int32,
    capacityBytes: UInt64,
    logicalBlockSize: UInt32
  ) {
    self.descriptor = descriptor
    self.capacityBytes = capacityBytes
    self.logicalBlockSize = logicalBlockSize
    readOnly = false
    ioOperations = .production
  }

  deinit { Darwin.close(descriptor) }

  public static func create(
    at url: URL,
    capacityBytes: UInt64,
    logicalBlockSize: UInt32 = 512
  ) throws -> DoryVirtioFileBlockStorage {
    try validate(capacity: capacityBytes, logicalBlockSize: logicalBlockSize)
    guard capacityBytes <= UInt64(Int64.max) else {
      throw DoryVirtioFileBlockStorageError.invalidCapacity(capacityBytes)
    }
    let descriptor = Darwin.open(
      url.path,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "open", code: errno)
    }
    guard ftruncate(descriptor, off_t(capacityBytes)) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "ftruncate", code: code)
    }
    return .init(
      descriptor: descriptor,
      capacityBytes: capacityBytes,
      logicalBlockSize: logicalBlockSize
    )
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount >= 0 else { throw DoryVirtioBlockError.invalidByteCount(byteCount) }
    try checkedRange(offset: offset, byteCount: UInt64(byteCount))
    guard byteCount > 0 else { return [] }
    return try lock.withLock {
      var bytes = [UInt8](repeating: 0, count: byteCount)
      let completed = try bytes.withUnsafeMutableBytes { buffer in
        try transferRead(buffer, offset: offset)
      }
      guard completed == byteCount else {
        throw DoryVirtioFileBlockStorageError.shortRead(expected: byteCount, actual: completed)
      }
      return bytes
    }
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    guard !readOnly else { throw DoryVirtioBlockError.malformedRequest }
    try checkedRange(offset: offset, byteCount: UInt64(bytes.count))
    try lock.withLock {
      try bytes.withUnsafeBytes { buffer in
        try transferWrite(buffer, offset: offset)
      }
    }
  }

  public func flush() throws {
    guard !readOnly else { return }
    try lock.withLock {
      // A virtio FLUSH is a guest durability barrier, not merely a request to
      // hand dirty pages to the host drive cache. On macOS F_FULLFSYNC is the
      // durable operation; fsync() alone may return before the device cache is
      // committed. Treat an unsupported full flush as an I/O error rather than
      // falsely acknowledging a barrier to the guest.
      var budget = NoProgressBudget()
      while true {
        try budget.admitAttempt(operation: "fcntl(F_FULLFSYNC)", operations: ioOperations)
        let result = ioOperations.fullFlush(descriptor)
        if result.count == 0 { return }
        guard result.count < 0, result.code == EINTR else {
          throw DoryVirtioFileBlockStorageError.systemCall(
            operation: "fcntl(F_FULLFSYNC)",
            code: result.count < 0 ? result.code : EIO
          )
        }
        try budget.interrupted(operation: "fcntl(F_FULLFSYNC)", operations: ioOperations)
      }
    }
  }

  public func discard(offset: UInt64, byteCount: UInt64) throws {
    try writeZeroes(offset: offset, byteCount: byteCount, mayUnmap: true)
  }

  public func writeZeroes(offset: UInt64, byteCount: UInt64, mayUnmap: Bool) throws {
    guard !readOnly else { throw DoryVirtioBlockError.malformedRequest }
    try checkedRange(offset: offset, byteCount: byteCount)
    guard byteCount > 0 else { return }
    let zeroChunk = [UInt8](repeating: 0, count: 1024 * 1024)
    try lock.withLock {
      var written: UInt64 = 0
      while written < byteCount {
        let count = Int(min(UInt64(zeroChunk.count), byteCount - written))
        try zeroChunk.withUnsafeBytes { buffer in
          try transferWrite(
            UnsafeRawBufferPointer(rebasing: buffer.prefix(count)),
            offset: offset + written
          )
        }
        written += UInt64(count)
      }
    }
  }

  private static func regularFileCapacity(_ descriptor: Int32) throws -> UInt64 {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "fstat", code: errno)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw DoryVirtioFileBlockStorageError.notRegularFile
    }
    guard status.st_size >= 0 else {
      throw DoryVirtioFileBlockStorageError.invalidCapacity(0)
    }
    return UInt64(status.st_size)
  }

  private static func validate(capacity: UInt64, logicalBlockSize: UInt32) throws {
    guard capacity > 0,
      capacity % DoryVirtioBlockDevice.sectorSize == 0,
      logicalBlockSize >= 512,
      logicalBlockSize.nonzeroBitCount == 1,
      capacity % UInt64(logicalBlockSize) == 0
    else { throw DoryVirtioFileBlockStorageError.invalidCapacity(capacity) }
  }

  private func checkedRange(offset: UInt64, byteCount: UInt64) throws {
    guard offset <= capacityBytes, byteCount <= capacityBytes - offset,
      offset <= UInt64(Int64.max), byteCount <= UInt64(Int64.max) - offset,
      byteCount <= DoryVirtioBlockDevice.maximumPayloadByteCount
    else {
      throw DoryVirtioBlockError.requestOutOfBounds(offset: offset, byteCount: byteCount)
    }
  }

  private func transferRead(
    _ buffer: UnsafeMutableRawBufferPointer,
    offset: UInt64
  ) throws -> Int {
    guard let base = buffer.baseAddress else { return 0 }
    var completed = 0
    var budget = NoProgressBudget()
    while completed < buffer.count {
      try budget.admitAttempt(operation: "pread", operations: ioOperations)
      let remaining = buffer.count - completed
      let result = ioOperations.read(descriptor,
        .init(start: base.advanced(by: completed), count: remaining), offset + UInt64(completed))
      if result.count > 0 {
        guard result.count <= remaining else {
          throw DoryVirtioFileBlockStorageError.systemCall(operation: "pread", code: EIO)
        }
        completed += result.count
        budget.madeProgress()
      } else if result.count == 0 {
        break
      } else if result.code == EINTR {
        try budget.interrupted(operation: "pread", operations: ioOperations)
      } else {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pread", code: result.code)
      }
    }
    return completed
  }

  private func transferWrite(_ buffer: UnsafeRawBufferPointer, offset: UInt64) throws {
    guard let base = buffer.baseAddress else { return }
    var completed = 0
    var budget = NoProgressBudget()
    while completed < buffer.count {
      try budget.admitAttempt(operation: "pwrite", operations: ioOperations)
      let remaining = buffer.count - completed
      let result = ioOperations.write(descriptor,
        .init(start: base.advanced(by: completed), count: remaining), offset + UInt64(completed))
      if result.count > 0 {
        guard result.count <= remaining else {
          throw DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: EIO)
        }
        completed += result.count
        budget.madeProgress()
      } else if result.count == 0 {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: EIO)
      } else if result.code == EINTR {
        try budget.interrupted(operation: "pwrite", operations: ioOperations)
      } else {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: result.code)
      }
    }
  }
}
