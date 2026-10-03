import Darwin
import Foundation

/// The final filesystem step of the existing create/clone/portable operations. Their
/// machine lease and operation journal remain the owners; this is not another transaction
/// coordinator. Only a complete, bounded, caller-declared staging tree is published.
enum DoryVZMacBundlePublication {
  enum Checkpoint: CaseIterable { case validated, filesSynced, bundleSynced, published, parentSynced }
  enum SyncKind: Equatable { case file, directory, drive }

  struct IO {
    var sync: (Int32, SyncKind) -> Int32 = { descriptor, kind in
      kind == .drive ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)
    }
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
  }

  static func publish(
    staging: URL, to destination: URL, relativeFiles: [String],
    barrierFile: String = DoryVZMacMachineBundle.manifestName, io: IO = IO()
  ) throws {
    guard staging.isFileURL, destination.isFileURL,
      !staging.path.contains("\0"), !destination.path.contains("\0"),
      staging.deletingLastPathComponent().standardizedFileURL
        == destination.deletingLastPathComponent().standardizedFileURL,
      validName(staging.lastPathComponent), validName(destination.lastPathComponent),
      staging.lastPathComponent != destination.lastPathComponent,
      !relativeFiles.isEmpty, relativeFiles.count <= 32,
      Set(relativeFiles).count == relativeFiles.count, relativeFiles.contains(barrierFile)
    else { throw invalid("invalid staging, destination or artifact set") }
    let paths = relativeFiles.sorted().map { $0.components(separatedBy: "/") }
    guard paths.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(validName) }) else {
      throw invalid("artifact paths must be direct files or one-level managed data disks")
    }
    let parentURL = destination.deletingLastPathComponent().standardizedFileURL
    let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw failure("open publication parent") }
    var descriptors = [parentFD]
    defer { for descriptor in descriptors.reversed() { close(descriptor) } }
    let parentIdentity = try status(parentFD)
    try validateDirectory(parentIdentity)
    let stagingFD = openat(
      parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard stagingFD >= 0 else { throw failure("open staging bundle") }
    descriptors.append(stagingFD)
    let root = Node(
      descriptor: stagingFD, parent: parentFD, name: staging.lastPathComponent,
      identity: try status(stagingFD), relativePath: ""
    )
    try validateDirectory(root.identity)
    guard root.identity.st_dev == parentIdentity.st_dev else { throw invalid("staging volume differs") }
    var directories = [root]
    for name in Set(paths.filter { $0.count == 2 }.map { $0[0] }).sorted() {
      let descriptor = openat(stagingFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw failure("open staging data directory") }
      descriptors.append(descriptor)
      let node = Node(
        descriptor: descriptor, parent: stagingFD, name: name,
        identity: try status(descriptor), relativePath: name
      )
      try validateDirectory(node.identity)
      guard node.identity.st_dev == root.identity.st_dev else { throw invalid("data volume differs") }
      directories.append(node)
    }
    var files = [Node]()
    for components in paths {
      let parent = components.count == 1 ? root : directories.first { $0.name == components[0] }!
      let name = components.last!
      let descriptor = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw failure("open staging artifact") }
      descriptors.append(descriptor)
      let node = Node(
        descriptor: descriptor, parent: parent.descriptor, name: name,
        identity: try status(descriptor), relativePath: components.joined(separator: "/")
      )
      try validateFile(node.identity)
      guard node.identity.st_dev == root.identity.st_dev else { throw invalid("artifact volume differs") }
      files.append(node)
    }
    let barrier = files.first { $0.relativePath == barrierFile }!
    try validateTree(directories, files: files)
    try validateParent(parentURL, identity: parentIdentity)
    try io.checkpoint(.validated)
    for file in files { try synchronize(file.descriptor, kind: .file, io: io) }
    try io.checkpoint(.filesSynced)
    // Commit children before the root. Flush the drive using a regular file on this
    // volume: not every filesystem accepts F_FULLFSYNC on a directory descriptor.
    for directory in directories.reversed() {
      try synchronize(directory.descriptor, kind: .directory, io: io)
    }
    try synchronize(barrier.descriptor, kind: .drive, io: io)
    try io.checkpoint(.bundleSynced)
    try validateParent(parentURL, identity: parentIdentity)
    try validateTree(directories, files: files)
    // An earlier fileExists check is not authority. Exclusive rename must reject even a
    // dangling symlink or an empty directory created by another operation in the interim.
    guard renameatx_np(
      parentFD, root.name, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)
    ) == 0 else { throw failure("publish bundle exclusively") }
    try io.checkpoint(.published)
    try synchronize(parentFD, kind: .directory, io: io)
    try synchronize(barrier.descriptor, kind: .drive, io: io)
    try io.checkpoint(.parentSynced)
    try validateParent(parentURL, identity: parentIdentity)
    let publishedRoot = Node(
      descriptor: stagingFD, parent: parentFD, name: destination.lastPathComponent,
      identity: root.identity, relativePath: ""
    )
    try validateTree([publishedRoot] + directories.dropFirst(), files: files)
    // Any error after rename leaves the complete destination intact. Never erase or
    // replace it on retry: the owning operation can inspect that published result.
  }

  private struct Node {
    let descriptor: Int32
    let parent: Int32
    let name: String
    let identity: stat
    let relativePath: String
  }

  private static func validateTree(_ directories: [Node], files: [Node]) throws {
    for directory in directories {
      let current = try status(directory.descriptor)
      try validateDirectory(current)
      guard sameIdentity(current, directory.identity),
        sameIdentity(try namedStatus(directory.parent, directory.name), current)
      else { throw invalid("staging directory was replaced") }
      let expected = Set(files.filter { $0.parent == directory.descriptor }.map(\.name))
        .union(directories.filter { $0.parent == directory.descriptor }.map(\.name))
      guard try entries(directory.descriptor) == expected else {
        throw invalid("staging directory has missing or unexpected entries")
      }
    }
    for file in files {
      let current = try status(file.descriptor)
      try validateFile(current)
      guard sameIdentity(current, file.identity), current.st_size == file.identity.st_size,
        sameTime(current.st_mtimespec, file.identity.st_mtimespec),
        sameTime(current.st_ctimespec, file.identity.st_ctimespec),
        sameIdentity(try namedStatus(file.parent, file.name), current)
      else { throw invalid("staging artifact changed during publication") }
    }
  }

  private static func entries(_ descriptor: Int32) throws -> Set<String> {
    try DoryVZMacMetadataFile.directoryEntryNames(descriptor)
  }

  private static func validateParent(_ url: URL, identity: stat) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0, sameIdentity(current, identity) else {
      throw invalid("publication parent changed")
    }
    try validateDirectory(current)
  }

  private static func validateDirectory(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o022 == 0
    else { throw invalid("directory is not owned and protected") }
  }

  private static func validateFile(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
      value.st_mode & 0o022 == 0, value.st_size > 0
    else { throw invalid("artifact is not owned, unshared and nonempty") }
  }

  private static func status(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw failure("inspect staging descriptor") }
    return value
  }

  private static func namedStatus(_ parent: Int32, _ name: String) throws -> stat {
    var value = stat()
    guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw failure("inspect staging entry")
    }
    return value
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
    lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
  }

  private static func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && !name.contains("\0") && name.utf8.count <= Int(NAME_MAX)
  }

  private static func synchronize(_ descriptor: Int32, kind: SyncKind, io: IO) throws {
    while io.sync(descriptor, kind) != 0 {
      if errno == EINTR { continue }
      throw failure("synchronize bundle \(kind)")
    }
  }

  private static func invalid(_ detail: String) -> DoryVZMacMachineBundleError {
    .invalidBundle(detail)
  }

  private static func failure(_ operation: String) -> DoryVZMacMachineBundleError {
    .filesystem(operation, errno)
  }
}
