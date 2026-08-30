import Darwin
import Foundation

/// Path-free, crash-safe UEFI variable persistence rooted at one inherited directory capability.
public final class DoryUEFIVariableStoreDirectoryDescriptor: @unchecked Sendable {
  private let descriptor: Int32

  public init(inheritedDescriptor: Int32) throws {
    guard inheritedDescriptor >= 3 else {
      throw DoryUEFIVariableStoreFileError.unsafePath("inherited-directory")
    }
    let duplicate = fcntl(inheritedDescriptor, F_DUPFD_CLOEXEC, 3)
    guard duplicate >= 3 else {
      throw Self.filesystem("duplicate", "inherited-directory")
    }
    do {
      try Self.validatePrivateDirectory(descriptor: duplicate)
    } catch {
      Darwin.close(duplicate)
      throw error
    }
    self.descriptor = duplicate
  }

  deinit {
    Darwin.close(descriptor)
  }

  public func initialize(_ snapshot: DoryUEFIVariableStoreSnapshot) throws {
    guard snapshot.generation == 1 else {
      throw DoryUEFIVariableStoreFileError.invalidSuccessorGeneration(
        expected: 1,
        actual: snapshot.generation
      )
    }
    try validateDirectory()
    try withExclusiveLock {
      guard try secureReadIfPresent(DoryUEFIVariableStoreFile.primaryFileName) == nil,
        try secureReadIfPresent(DoryUEFIVariableStoreFile.backupFileName) == nil
      else { throw DoryUEFIVariableStoreFileError.alreadyInitialized }
      try publish(
        try DoryUEFIVariableStoreFile.canonicalData(snapshot),
        to: DoryUEFIVariableStoreFile.primaryFileName
      )
    }
  }

  public func load() throws -> DoryUEFIVariableStoreLoad {
    try validateDirectory()
    if let primary = try secureReadIfPresent(DoryUEFIVariableStoreFile.primaryFileName) {
      do {
        return DoryUEFIVariableStoreLoad(
          snapshot: try DoryUEFIVariableStoreFile.decodeCanonical(
            primary,
            path: DoryUEFIVariableStoreFile.primaryFileName
          ),
          source: .primary
        )
      } catch let error as DoryUEFIVariableStoreFileError {
        guard case .invalidStore = error else { throw error }
      }
    }
    if let backup = try secureReadIfPresent(DoryUEFIVariableStoreFile.backupFileName) {
      return DoryUEFIVariableStoreLoad(
        snapshot: try DoryUEFIVariableStoreFile.decodeCanonical(
          backup,
          path: DoryUEFIVariableStoreFile.backupFileName
        ),
        source: .backupRecoveryRequired
      )
    }
    throw DoryUEFIVariableStoreFileError.storeNotInitialized
  }

  public func commit(
    _ snapshot: DoryUEFIVariableStoreSnapshot,
    expectedGeneration: UInt64
  ) throws {
    try validateDirectory()
    try withExclusiveLock {
      guard let currentData = try secureReadIfPresent(
        DoryUEFIVariableStoreFile.primaryFileName
      ) else { throw DoryUEFIVariableStoreFileError.recoveryRequired }
      let current: DoryUEFIVariableStoreSnapshot
      do {
        current = try DoryUEFIVariableStoreFile.decodeCanonical(
          currentData,
          path: DoryUEFIVariableStoreFile.primaryFileName
        )
      } catch let error as DoryUEFIVariableStoreFileError {
        guard case .invalidStore = error else { throw error }
        throw DoryUEFIVariableStoreFileError.recoveryRequired
      }
      guard current.generation == expectedGeneration else {
        throw DoryUEFIVariableStoreFileError.generationConflict(
          expected: expectedGeneration,
          actual: current.generation
        )
      }
      let (successor, overflow) = expectedGeneration.addingReportingOverflow(1)
      guard !overflow, snapshot.generation == successor else {
        throw DoryUEFIVariableStoreFileError.invalidSuccessorGeneration(
          expected: overflow ? UInt64.max : successor,
          actual: snapshot.generation
        )
      }
      try publish(currentData, to: DoryUEFIVariableStoreFile.backupFileName)
      try publish(
        try DoryUEFIVariableStoreFile.canonicalData(snapshot),
        to: DoryUEFIVariableStoreFile.primaryFileName
      )
    }
  }

  @discardableResult
  public func repairFromBackup() throws -> DoryUEFIVariableStoreSnapshot {
    try validateDirectory()
    return try withExclusiveLock {
      if let primary = try secureReadIfPresent(DoryUEFIVariableStoreFile.primaryFileName),
        let decoded = try? DoryUEFIVariableStoreFile.decodeCanonical(
          primary,
          path: DoryUEFIVariableStoreFile.primaryFileName
        ) {
        return decoded
      }
      guard let backup = try secureReadIfPresent(
        DoryUEFIVariableStoreFile.backupFileName
      ) else { throw DoryUEFIVariableStoreFileError.noRecoverableBackup }
      let snapshot = try DoryUEFIVariableStoreFile.decodeCanonical(
        backup,
        path: DoryUEFIVariableStoreFile.backupFileName
      )
      try publish(backup, to: DoryUEFIVariableStoreFile.primaryFileName)
      return snapshot
    }
  }

  private func validateDirectory() throws {
    try Self.validatePrivateDirectory(descriptor: descriptor)
  }

  private static func validatePrivateDirectory(descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else { throw DoryUEFIVariableStoreFileError.unsafePath("inherited-directory") }
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let name = DoryUEFIVariableStoreFile.lockFileName
    let lock = name.withCString {
      openat(descriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    }
    guard lock >= 0 else { throw unsafe(name) }
    defer { Darwin.close(lock) }
    _ = try validatePrivateFile(descriptor: lock, name: name, maximumBytes: 0)
    while flock(lock, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw filesystem("lock", name)
    }
    defer { _ = flock(lock, LOCK_UN) }
    return try body()
  }

  private func secureReadIfPresent(_ name: String) throws -> Data? {
    var entry = stat()
    guard name.withCString({ fstatat(descriptor, $0, &entry, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      if errno == ENOENT { return nil }
      throw filesystem("inspect", name)
    }
    let file = name.withCString { openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard file >= 0 else { throw unsafe(name) }
    defer { Darwin.close(file) }
    let size = try validatePrivateFile(
      descriptor: file,
      name: name,
      maximumBytes: DoryUEFIVariableStoreFile.maximumEncodedBytes
    )
    var data = Data()
    data.reserveCapacity(size)
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw filesystem("read", name) }
      if count == 0 { break }
      guard data.count <= DoryUEFIVariableStoreFile.maximumEncodedBytes - count else {
        throw DoryUEFIVariableStoreFileError.invalidStore(name)
      }
      data.append(buffer, count: count)
    }
    return data
  }

  private func validatePrivateFile(
    descriptor: Int32,
    name: String,
    maximumBytes: Int
  ) throws -> Int {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      status.st_nlink == 1,
      status.st_size >= 0,
      status.st_size <= maximumBytes
    else { throw unsafe(name) }
    return Int(status.st_size)
  }

  private func publish(_ data: Data, to destination: String) throws {
    _ = try secureReadIfPresent(destination)
    let temporary = ".\(destination).\(UUID().uuidString.lowercased()).partial"
    let file = temporary.withCString {
      openat(
        descriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
      )
    }
    guard file >= 0 else { throw filesystem("create", temporary) }
    var published = false
    defer {
      Darwin.close(file)
      if !published { _ = temporary.withCString { unlinkat(descriptor, $0, 0) } }
    }
    try writeAll(data, descriptor: file, name: temporary)
    guard fsync(file) == 0 else { throw filesystem("sync", temporary) }
    let renamed = temporary.withCString { source in
      destination.withCString { target in renameat(descriptor, source, descriptor, target) }
    }
    guard renamed == 0 else { throw filesystem("publish", destination) }
    published = true
    guard fsync(descriptor) == 0 else { throw filesystem("sync", "inherited-directory") }
  }

  private func writeAll(_ data: Data, descriptor: Int32, name: String) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw filesystem("write", name) }
        offset += count
      }
    }
  }

  private func unsafe(_ name: String) -> DoryUEFIVariableStoreFileError {
    .unsafePath("inherited-directory/\(name)")
  }

  private func filesystem(
    _ operation: String,
    _ name: String
  ) -> DoryUEFIVariableStoreFileError {
    .filesystem(operation: operation, path: "inherited-directory/\(name)", code: errno)
  }

  private static func filesystem(
    _ operation: String,
    _ name: String
  ) -> DoryUEFIVariableStoreFileError {
    .filesystem(operation: operation, path: name, code: errno)
  }
}
