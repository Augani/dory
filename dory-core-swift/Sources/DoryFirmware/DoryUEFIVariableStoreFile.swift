import Darwin
import Foundation

public enum DoryUEFIVariableStoreSource: Sendable, Equatable {
  case primary
  case backupRecoveryRequired
}

public struct DoryUEFIVariableStoreLoad: Sendable, Equatable {
  public let snapshot: DoryUEFIVariableStoreSnapshot
  public let source: DoryUEFIVariableStoreSource

  public init(
    snapshot: DoryUEFIVariableStoreSnapshot,
    source: DoryUEFIVariableStoreSource
  ) {
    self.snapshot = snapshot
    self.source = source
  }
}

public enum DoryUEFIVariableStoreFileError: Error, Sendable, Equatable {
  case invalidDirectory(String)
  case unsafePath(String)
  case storeNotInitialized
  case alreadyInitialized
  case invalidStore(String)
  case recoveryRequired
  case noRecoverableBackup
  case generationConflict(expected: UInt64, actual: UInt64)
  case invalidSuccessorGeneration(expected: UInt64, actual: UInt64)
  case filesystem(operation: String, path: String, code: Int32)
}

/// Crash-safe storage for one VM's Dory-owned UEFI variable state.
///
/// The primary file is always canonical schema-1 JSON. Each successful commit first publishes
/// the prior primary as a durable backup, then atomically replaces the primary. Corrupt or missing
/// primary data is never repaired implicitly: callers must observe `backupRecoveryRequired` and
/// explicitly invoke `repairFromBackup()`.
public struct DoryUEFIVariableStoreFile: Sendable, Equatable {
  public static let primaryFileName = "uefi-variables.json"
  public static let backupFileName = "uefi-variables.backup.json"
  public static let lockFileName = ".uefi-variables.lock"
  public static let maximumEncodedBytes = 32 << 20

  public let directory: String
  public let primaryPath: String
  public let backupPath: String

  public init(directory: String) throws {
    guard !directory.isEmpty,
      directory.utf8.count <= 4_096,
      !directory.utf8.contains(0),
      directory.hasPrefix("/")
    else {
      throw DoryUEFIVariableStoreFileError.invalidDirectory(directory)
    }
    let canonical = URL(fileURLWithPath: directory).standardizedFileURL.path
    guard canonical == directory, canonical != "/" else {
      throw DoryUEFIVariableStoreFileError.invalidDirectory(directory)
    }
    self.directory = canonical
    self.primaryPath = canonical + "/" + Self.primaryFileName
    self.backupPath = canonical + "/" + Self.backupFileName
  }

  public func prepare() throws {
    var status = stat()
    if directory.withCString({ lstat($0, &status) }) != 0 {
      guard errno == ENOENT else { throw filesystem("inspect", directory) }
      guard directory.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
        throw filesystem("create", directory)
      }
    }
    try validatePrivateDirectory()
  }

  public func initialize(_ snapshot: DoryUEFIVariableStoreSnapshot) throws {
    guard snapshot.generation == 1 else {
      throw DoryUEFIVariableStoreFileError.invalidSuccessorGeneration(
        expected: 1,
        actual: snapshot.generation
      )
    }
    try prepare()
    try withExclusiveLock {
      guard try secureReadIfPresent(primaryPath) == nil,
        try secureReadIfPresent(backupPath) == nil
      else {
        throw DoryUEFIVariableStoreFileError.alreadyInitialized
      }
      try publish(try Self.canonicalData(snapshot), to: primaryPath)
    }
  }

  public func load() throws -> DoryUEFIVariableStoreLoad {
    try validatePrivateDirectory()
    if let primary = try secureReadIfPresent(primaryPath) {
      do {
        return DoryUEFIVariableStoreLoad(
          snapshot: try Self.decodeCanonical(primary, path: primaryPath),
          source: .primary
        )
      } catch let error as DoryUEFIVariableStoreFileError {
        guard case .invalidStore = error else { throw error }
      }
    }
    if let backup = try secureReadIfPresent(backupPath) {
      return DoryUEFIVariableStoreLoad(
        snapshot: try Self.decodeCanonical(backup, path: backupPath),
        source: .backupRecoveryRequired
      )
    }
    throw DoryUEFIVariableStoreFileError.storeNotInitialized
  }

  public func commit(
    _ snapshot: DoryUEFIVariableStoreSnapshot,
    expectedGeneration: UInt64
  ) throws {
    try validatePrivateDirectory()
    try withExclusiveLock {
      guard let currentData = try secureReadIfPresent(primaryPath) else {
        throw DoryUEFIVariableStoreFileError.recoveryRequired
      }
      let current: DoryUEFIVariableStoreSnapshot
      do {
        current = try Self.decodeCanonical(currentData, path: primaryPath)
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
      try publish(currentData, to: backupPath)
      try publish(try Self.canonicalData(snapshot), to: primaryPath)
    }
  }

  @discardableResult
  public func repairFromBackup() throws -> DoryUEFIVariableStoreSnapshot {
    try validatePrivateDirectory()
    return try withExclusiveLock {
      if let primary = try secureReadIfPresent(primaryPath),
        let decoded = try? Self.decodeCanonical(primary, path: primaryPath)
      {
        return decoded
      }
      guard let backup = try secureReadIfPresent(backupPath) else {
        throw DoryUEFIVariableStoreFileError.noRecoverableBackup
      }
      let snapshot = try Self.decodeCanonical(backup, path: backupPath)
      try publish(backup, to: primaryPath)
      return snapshot
    }
  }

  private func validatePrivateDirectory() throws {
    var status = stat()
    guard directory.withCString({ lstat($0, &status) }) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == getuid(),
      status.st_mode & 0o077 == 0
    else {
      throw DoryUEFIVariableStoreFileError.unsafePath(directory)
    }
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let lockPath = directory + "/" + Self.lockFileName
    let descriptor = lockPath.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw DoryUEFIVariableStoreFileError.unsafePath(lockPath) }
    defer { Darwin.close(descriptor) }
    _ = try validatePrivateFile(descriptor: descriptor, path: lockPath, maximumBytes: 0)
    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw filesystem("lock", lockPath)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }

  private func secureReadIfPresent(_ path: String) throws -> Data? {
    var entry = stat()
    guard path.withCString({ lstat($0, &entry) }) == 0 else {
      if errno == ENOENT { return nil }
      throw filesystem("inspect", path)
    }
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw DoryUEFIVariableStoreFileError.unsafePath(path) }
    defer { Darwin.close(descriptor) }
    let size = try validatePrivateFile(
      descriptor: descriptor,
      path: path,
      maximumBytes: Self.maximumEncodedBytes
    )
    var data = Data()
    data.reserveCapacity(size)
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw filesystem("read", path) }
      if count == 0 { break }
      guard data.count <= Self.maximumEncodedBytes - count else {
        throw DoryUEFIVariableStoreFileError.invalidStore(path)
      }
      data.append(buffer, count: count)
    }
    return data
  }

  private func validatePrivateFile(
    descriptor: Int32,
    path: String,
    maximumBytes: Int
  ) throws -> Int {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == getuid(),
      status.st_mode & 0o077 == 0,
      status.st_nlink == 1,
      status.st_size >= 0,
      status.st_size <= maximumBytes
    else {
      throw DoryUEFIVariableStoreFileError.unsafePath(path)
    }
    return Int(status.st_size)
  }

  private static func canonicalData(_ snapshot: DoryUEFIVariableStoreSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot) + Data("\n".utf8)
    guard data.count <= maximumEncodedBytes else {
      throw DoryUEFIVariableStoreFileError.invalidStore("encoded variable store exceeds limit")
    }
    return data
  }

  private static func decodeCanonical(
    _ data: Data,
    path: String
  ) throws -> DoryUEFIVariableStoreSnapshot {
    do {
      let snapshot = try JSONDecoder().decode(DoryUEFIVariableStoreSnapshot.self, from: data)
      guard try canonicalData(snapshot) == data else {
        throw DoryUEFIVariableStoreFileError.invalidStore(path)
      }
      return snapshot
    } catch let error as DoryUEFIVariableStoreFileError {
      throw error
    } catch {
      throw DoryUEFIVariableStoreFileError.invalidStore(path)
    }
  }

  private func publish(_ data: Data, to destination: String) throws {
    _ = try secureReadIfPresent(destination)
    let temporary = directory + "/." + URL(fileURLWithPath: destination).lastPathComponent
      + "." + UUID().uuidString.lowercased() + ".partial"
    let descriptor = temporary.withCString {
      Darwin.open(
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
      )
    }
    guard descriptor >= 0 else { throw filesystem("create", temporary) }
    var published = false
    defer {
      Darwin.close(descriptor)
      if !published { _ = Darwin.unlink(temporary) }
    }
    try writeAll(data, descriptor: descriptor, path: temporary)
    guard Darwin.fsync(descriptor) == 0 else { throw filesystem("sync", temporary) }
    guard Darwin.rename(temporary, destination) == 0 else {
      throw filesystem("publish", destination)
    }
    published = true
    try syncDirectory()
  }

  private func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw filesystem("write", path) }
        offset += count
      }
    }
  }

  private func syncDirectory() throws {
    let descriptor = directory.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw DoryUEFIVariableStoreFileError.unsafePath(directory) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw filesystem("sync", directory) }
  }

  private func filesystem(_ operation: String, _ path: String) -> DoryUEFIVariableStoreFileError {
    .filesystem(operation: operation, path: path, code: errno)
  }
}
