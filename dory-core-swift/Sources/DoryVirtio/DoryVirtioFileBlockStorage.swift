import Darwin
import Foundation

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
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  /// Duplicates an already admitted file descriptor without resolving a pathname. The caller
  /// remains responsible for its descriptor; this storage object owns only the duplicate.
  public init(
    duplicatingFileDescriptor source: Int32,
    expectedCapacityBytes: UInt64,
    logicalBlockSize: UInt32 = 512,
    readOnly: Bool
  ) throws {
    let access = fcntl(source, F_GETFL)
    var status = stat()
    guard source >= 3,
      access >= 0,
      (readOnly ? access & O_ACCMODE == O_RDONLY : access & O_ACCMODE == O_RDWR),
      fstat(source, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0,
      UInt64(status.st_size) == expectedCapacityBytes
    else { throw DoryVirtioFileBlockStorageError.notRegularFile }
    try Self.validate(capacity: expectedCapacityBytes, logicalBlockSize: logicalBlockSize)
    let duplicate = fcntl(source, F_DUPFD_CLOEXEC, 3)
    guard duplicate >= 3 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "fcntl", code: errno)
    }
    descriptor = duplicate
    capacityBytes = expectedCapacityBytes
    self.logicalBlockSize = logicalBlockSize
    self.readOnly = readOnly
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
      while fsync(descriptor) != 0 {
        guard errno == EINTR else {
          throw DoryVirtioFileBlockStorageError.systemCall(operation: "fsync", code: errno)
        }
      }
    }
  }

  public func discard(offset: UInt64, byteCount: UInt64) throws {
    try writeZeroes(offset: offset, byteCount: byteCount, mayUnmap: true)
  }

  public func writeZeroes(offset: UInt64, byteCount: UInt64, mayUnmap: Bool) throws {
    guard !readOnly else { throw DoryVirtioBlockError.malformedRequest }
    try checkedRange(offset: offset, byteCount: byteCount)
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
      offset <= UInt64(Int64.max), byteCount <= UInt64(Int.max)
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
    while completed < buffer.count {
      let result = pread(
        descriptor,
        base.advanced(by: completed),
        buffer.count - completed,
        off_t(offset + UInt64(completed))
      )
      if result > 0 {
        completed += result
      } else if result == 0 {
        break
      } else if errno != EINTR {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pread", code: errno)
      }
    }
    return completed
  }

  private func transferWrite(_ buffer: UnsafeRawBufferPointer, offset: UInt64) throws {
    guard let base = buffer.baseAddress else { return }
    var completed = 0
    while completed < buffer.count {
      let result = pwrite(
        descriptor,
        base.advanced(by: completed),
        buffer.count - completed,
        off_t(offset + UInt64(completed))
      )
      if result > 0 {
        completed += result
      } else if result == 0 {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: EIO)
      } else if errno != EINTR {
        throw DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: errno)
      }
    }
  }
}
