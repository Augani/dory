import Darwin
import Foundation

enum DoryVZMacMetadataFileError: Error, Equatable, CustomStringConvertible {
  case invalid(String)
  case filesystem(String, Int32)

  var description: String {
    switch self {
    case .invalid(let detail): "invalid VZMac metadata file: \(detail)"
    case .filesystem(let operation, let code): "\(operation) failed with errno \(code)"
    }
  }
}

/// Small bundle-owned files only. Writers are serialized by the existing machine lease or
/// runtime actor; this does not introduce a second lifecycle/transaction coordinator.
enum DoryVZMacMetadataFile {
  static let maximumBytes = 1_048_576

  enum Checkpoint: Equatable {
    case temporaryCreated, bytesWritten, fileSynced, published, directorySynced
  }

  enum SyncKind: Equatable { case file, directory, drive }

  // Per-call seams exercise short writes and real failure boundaries without global hooks or
  // touching a running VM. Production always uses the POSIX operations below.
  struct WriteIO {
    var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var sync: (Int32, SyncKind) -> Int32 = { descriptor, kind in
      kind == .drive ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)
    }
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
  }

  static func write(
    _ data: Data,
    to url: URL,
    maximumBytes: Int = maximumBytes,
    replacingExisting: Bool = true,
    io: WriteIO = WriteIO()
  ) throws {
    guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes else {
      throw DoryVZMacMetadataFileError.invalid("contents exceed the metadata size limit")
    }
    let directory = try Directory(containing: url)
    let temporaryName = ".dory-metadata-\(UUID().uuidString).tmp"
    let descriptor = openat(
      directory.descriptor, temporaryName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard descriptor >= 0 else { throw failure("create metadata temporary file") }
    let temporaryIdentity: stat
    do {
      temporaryIdentity = try status(of: descriptor)
    } catch {
      close(descriptor)
      // Without an inode identity, don't risk removing a replaced directory entry.
      throw error
    }
    var published = false
    defer {
      close(descriptor)
      if !published, let named = try? directory.status(of: temporaryName),
        sameIdentity(temporaryIdentity, named)
      { _ = unlinkat(directory.descriptor, temporaryName, 0) }
    }
    try io.checkpoint(.temporaryCreated)
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else {
        throw DoryVZMacMetadataFileError.invalid("metadata is empty")
      }
      var offset = 0
      while offset < bytes.count {
        let requested = min(65_536, bytes.count - offset)
        let count = io.write(descriptor, base.advanced(by: offset), requested)
        if count < 0 && errno == EINTR { continue }
        guard count > 0, count <= requested else {
          throw failure("write metadata", code: count < 0 ? errno : EIO)
        }
        offset += count
        try io.checkpoint(.bytesWritten)
      }
    }
    // Flush the complete new inode before making it discoverable. fsync alone may leave
    // writes in a drive cache; don't silently downgrade if full synchronization fails.
    try sync(descriptor, kind: .file, io: io)
    try sync(descriptor, kind: .drive, io: io)
    try io.checkpoint(.fileSynced)
    try directory.validatePath()
    let completed = try status(of: descriptor)
    try validateRegular(completed)
    guard completed.st_size == data.count,
      let namedTemporary = try directory.status(of: temporaryName),
      sameIdentity(completed, namedTemporary)
    else { throw DoryVZMacMetadataFileError.invalid("temporary file changed before publication") }
    if let existing = try directory.status(of: directory.name) {
      try validateRegular(existing)
    }
    let result = replacingExisting
      ? renameat(directory.descriptor, temporaryName, directory.descriptor, directory.name)
      : renameatx_np(
        directory.descriptor, temporaryName, directory.descriptor, directory.name,
        UInt32(RENAME_EXCL)
      )
    guard result == 0 else { throw failure("publish metadata") }
    published = true
    try io.checkpoint(.published)
    try sync(directory.descriptor, kind: .directory, io: io)
    // A full flush on the still-open file also drains preceding directory fsync writes on
    // the same volume. Some filesystems don't accept F_FULLFSYNC on a directory itself.
    try sync(descriptor, kind: .drive, io: io)
    try io.checkpoint(.directorySynced)
    try directory.validatePath()
    let final = try status(of: descriptor)
    try validateRegular(final)
    guard final.st_size == data.count, sameTime(completed.st_mtimespec, final.st_mtimespec),
      let namedFinal = try directory.status(of: directory.name), sameIdentity(final, namedFinal)
    else { throw DoryVZMacMetadataFileError.invalid("published file changed before commit") }
    // A post-rename error means a valid new file may already be present. Never roll it back
    // or unlink the destination here; its owning journal recovers the published state.
  }

  static func read(
    from url: URL,
    maximumBytes: Int = maximumBytes,
    afterOpen: () throws -> Void = {},
    afterRead: () throws -> Void = {}
  ) throws -> Data {
    guard let bytes = try readIfPresent(
      from: url, maximumBytes: maximumBytes, afterOpen: afterOpen, afterRead: afterRead
    ) else { throw failure("open metadata", code: ENOENT) }
    return bytes
  }

  static func entryExists(at url: URL) throws -> Bool {
    let directory = try Directory(containing: url)
    let exists = try directory.status(of: directory.name) != nil
    try directory.validatePath()
    return exists
  }

  static func isAbandonedTemporaryFile(at url: URL) throws -> Bool {
    let name = url.lastPathComponent
    let prefix = ".dory-metadata-"
    let suffix = ".tmp"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let nonce = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    guard let uuid = UUID(uuidString: nonce), uuid.uuidString == nonce else { return false }
    let directory = try Directory(containing: url)
    let descriptor = openat(
      directory.descriptor, directory.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw failure("open abandoned metadata") }
    defer { close(descriptor) }
    let information = try status(of: descriptor)
    try validateRegular(information)
    guard information.st_mode & 0o077 == 0,
      information.st_size >= 0, information.st_size <= maximumBytes,
      let named = try directory.status(of: directory.name), sameIdentity(information, named)
    else { throw DoryVZMacMetadataFileError.invalid("abandoned metadata is not private and bounded") }
    try directory.validatePath()
    return true
  }

  static func readIfPresent(
    from url: URL,
    maximumBytes: Int = maximumBytes,
    afterOpen: () throws -> Void = {},
    afterRead: () throws -> Void = {}
  ) throws -> Data? {
    guard maximumBytes > 0 else {
      throw DoryVZMacMetadataFileError.invalid("metadata size limit is invalid")
    }
    let directory = try Directory(containing: url)
    let descriptor = openat(
      directory.descriptor, directory.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT {
        try directory.validatePath()
        return nil
      }
      throw failure("open metadata")
    }
    defer { close(descriptor) }
    let initial = try status(of: descriptor)
    try validateRegular(initial)
    guard initial.st_size > 0, initial.st_size <= maximumBytes else {
      throw DoryVZMacMetadataFileError.invalid("file is not bounded nonempty metadata")
    }
    try afterOpen()
    var data = Data(count: Int(initial.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw failure("read metadata", code: count < 0 ? errno : EIO) }
        offset += count
      }
    }
    try afterRead()
    let final = try status(of: descriptor)
    try validateRegular(final)
    guard sameIdentity(initial, final), initial.st_size == final.st_size,
      sameTime(initial.st_mtimespec, final.st_mtimespec),
      sameTime(initial.st_ctimespec, final.st_ctimespec),
      let named = try directory.status(of: directory.name), sameIdentity(initial, named)
    else { throw DoryVZMacMetadataFileError.invalid("file changed while reading") }
    try directory.validatePath()
    return data
  }

  /// Retire a committed resize journal only after its manifest is durable. A crash before
  /// this unlink reaches disk merely replays the idempotent journal, never loses the resize.
  static func remove(at url: URL, io: WriteIO = WriteIO()) throws {
    let directory = try Directory(containing: url)
    let descriptor = openat(
      directory.descriptor, directory.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw failure("open metadata for removal") }
    defer { close(descriptor) }
    let initial = try status(of: descriptor)
    try validateRegular(initial)
    try directory.validatePath()
    guard let named = try directory.status(of: directory.name), sameIdentity(initial, named) else {
      throw DoryVZMacMetadataFileError.invalid("file changed before removal")
    }
    guard unlinkat(directory.descriptor, directory.name, 0) == 0 else {
      throw failure("remove metadata")
    }
    try sync(directory.descriptor, kind: .directory, io: io)
    try sync(descriptor, kind: .drive, io: io)
    try directory.validatePath()
  }

  static func synchronizeFileDescriptor(_ descriptor: Int32) throws {
    try sync(descriptor, kind: .file, io: WriteIO())
    try sync(descriptor, kind: .drive, io: WriteIO())
  }

  static func directoryEntryNames(_ descriptor: Int32, maximumCount: Int = 32) throws -> Set<String> {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else { throw failure("duplicate owned directory") }
    guard let stream = fdopendir(duplicate) else {
      close(duplicate)
      throw failure("enumerate owned directory")
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names = Set<String>()
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw failure("read owned directory") }
        return names
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      guard let name else { throw DoryVZMacMetadataFileError.invalid("directory entry is not UTF-8") }
      if name == "." || name == ".." { continue }
      guard names.count < maximumCount else { throw DoryVZMacMetadataFileError.invalid("directory is not bounded") }
      names.insert(name)
    }
  }

  private static func sync(_ descriptor: Int32, kind: SyncKind, io: WriteIO) throws {
    while io.sync(descriptor, kind) != 0 {
      if errno == EINTR { continue }
      throw failure("synchronize metadata \(kind)")
    }
  }

  private static func status(of descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw failure("inspect metadata") }
    return result
  }

  private static func validateRegular(_ status: stat) throws {
    // Existing 0644 metadata remains readable. Newly published metadata is private (0600).
    guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_nlink == 1, status.st_mode & 0o022 == 0
    else { throw DoryVZMacMetadataFileError.invalid("file is not an owned, unshared regular file") }
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
    lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
  }

  private static func failure(_ operation: String, code: Int32 = errno) -> DoryVZMacMetadataFileError {
    .filesystem(operation, code)
  }

  private final class Directory {
    let descriptor: Int32
    let path: String
    let name: String
    let identity: stat

    init(containing url: URL) throws {
      let name = url.lastPathComponent
      guard url.isFileURL, !url.hasDirectoryPath, !name.isEmpty, name != ".", name != "..",
        name.utf8.count <= Int(NAME_MAX), !name.contains("/"), !name.contains("\0"),
        !url.path.contains("\0")
      else { throw DoryVZMacMetadataFileError.invalid("destination is not a local file name") }
      let path = url.deletingLastPathComponent().standardizedFileURL.path
      let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw failure("open metadata directory") }
      do {
        let identity = try DoryVZMacMetadataFile.status(of: descriptor)
        guard identity.st_mode & S_IFMT == S_IFDIR, identity.st_uid == geteuid(),
          identity.st_mode & 0o022 == 0
        else { throw DoryVZMacMetadataFileError.invalid("directory is not owned and protected") }
        self.descriptor = descriptor
        self.path = path
        self.name = name
        self.identity = identity
      } catch {
        close(descriptor)
        throw error
      }
    }

    func validatePath() throws {
      var current = stat()
      guard lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
        sameIdentity(identity, current), current.st_uid == geteuid(), current.st_mode & 0o022 == 0
      else { throw DoryVZMacMetadataFileError.invalid("directory changed during metadata operation") }
    }

    func status(of name: String) throws -> stat? {
      var result = stat()
      guard fstatat(descriptor, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { return nil }
        throw failure("inspect metadata directory entry")
      }
      return result
    }

    deinit { close(descriptor) }
  }
}
