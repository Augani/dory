import Darwin
import Foundation

/// Shared retirement for consumed standalone RAM and explicitly authorized cold recovery.
/// It neither touches guest disks nor grants restore authority. The existing runtime actor
/// or machine lease must exclude writers for the complete operation.
enum DoryVZMacSavedStateRetirement {
  enum Policy { case consumedOnly, explicitColdRecovery }
  enum Checkpoint: CaseIterable {
    case validated, receiptRemoved, receiptInvalidationDurable, artifactsRemoved, directoryRemoved, completed
  }
  struct IO {
    var metadata = DoryVZMacMetadataFile.WriteIO()
    var unlink: (Int32, String, Int32) -> Int32 = { unlinkat($0, $1, $2) }
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
  }

  private struct Entry {
    let name: String
    let descriptor: Int32
    let identity: stat
  }

  static func retireFailedSuspension(
    staging: URL, published: URL, barrierFileURL: URL, io: IO = IO()
  ) throws {
    // Publication may have renamed the staging directory before returning an error.
    // Both paths belong to this suspension attempt; neither may remain replayable when
    // the runtime resumes its original live RAM. Never swallow a retirement failure.
    for root in [staging, published] {
      try retire(at: root, policy: .explicitColdRecovery, barrierFileURL: barrierFileURL, io: io)
    }
  }

  static func retire(
    at rootURL: URL, policy: Policy, barrierFileURL: URL? = nil, io: IO = IO()
  ) throws {
    guard rootURL.isFileURL, !rootURL.path.contains("\0"),
      !rootURL.lastPathComponent.isEmpty, rootURL.lastPathComponent != "/"
    else { throw invalid("retirement root is not a local bundle directory") }
    let parentURL = rootURL.deletingLastPathComponent().standardizedFileURL
    let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw failure("open saved-state parent") }
    var descriptors = [parentFD]
    defer { for descriptor in descriptors.reversed() { close(descriptor) } }
    let parentIdentity = try status(parentFD)
    try requireDirectory(parentIdentity)
    let rootName = rootURL.lastPathComponent
    let existing = try namedStatus(parentFD, rootName)
    let externalBarrier = barrierFileURL ?? parentURL.appendingPathComponent(
      DoryVZMacMachineBundle.manifestName, isDirectory: false
    )
    if existing == nil {
      // Retry after rmdir but before its final barrier: drain the parent again using the
      // still-owned machine manifest. Never create a replacement RAM directory.
      let barrier = try openBarrier(externalBarrier, on: parentIdentity.st_dev)
      descriptors.append(barrier)
      try validateParent(parentURL, identity: parentIdentity)
      try synchronize(parentFD, kind: .directory, io: io)
      try synchronize(barrier, kind: .drive, io: io)
      try validateParent(parentURL, identity: parentIdentity)
      return
    }
    try requireDirectory(existing!)
    let rootFD = openat(parentFD, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw failure("open saved-state retirement root") }
    descriptors.append(rootFD)
    let rootIdentity = try status(rootFD)
    try requireDirectory(rootIdentity)
    guard sameIdentity(rootIdentity, existing!), rootIdentity.st_dev == parentIdentity.st_dev else {
      throw invalid("saved-state root changed or is on another volume")
    }
    let names = try DoryVZMacMetadataFile.directoryEntryNames(rootFD)
    let receiptName = DoryVZMacSavedStateArtifact.receiptName
    let known = Set([receiptName, DoryVZMacSavedStateArtifact.stateName, DoryVZSavedStateConsumption.markerName])
    if policy == .consumedOnly, names.contains(receiptName),
      !names.contains(DoryVZSavedStateConsumption.markerName) {
      throw invalid("artifact has not been consumed; explicit cold recovery is required")
    }
    var entries = [Entry]()
    for name in names.sorted() {
      guard try known.contains(name) || DoryVZMacMetadataFile.isAbandonedTemporaryFile(
        at: rootURL.appendingPathComponent(name, isDirectory: false)
      ) else { throw invalid("saved-state artifact contains unknown files") }
      let descriptor = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw failure("open owned saved-state artifact") }
      descriptors.append(descriptor)
      let identity = try status(descriptor)
      try requireFile(identity)
      guard identity.st_dev == rootIdentity.st_dev else { throw invalid("saved-state volume differs") }
      entries.append(Entry(name: name, descriptor: descriptor, identity: identity))
    }
    let barrier: Int32
    if let receipt = entries.first(where: { $0.name == receiptName }) {
      barrier = receipt.descriptor
    } else if let first = entries.first { barrier = first.descriptor }
    else {
      barrier = try openBarrier(externalBarrier, on: parentIdentity.st_dev)
      descriptors.append(barrier)
    }
    try validateRoot(parentFD, rootName, identity: rootIdentity)
    try validateParent(parentURL, identity: parentIdentity)
    try validateEntries(rootFD, entries)
    try io.checkpoint(.validated)
    try validateRoot(parentFD, rootName, identity: rootIdentity)
    try validateParent(parentURL, identity: parentIdentity)
    try validateEntries(rootFD, entries)
    if let receipt = entries.first(where: { $0.name == receiptName }) {
      try remove(rootFD, receipt.name, io: io)
    }
    try io.checkpoint(.receiptRemoved)
    try synchronize(rootFD, kind: .directory, io: io)
    try synchronize(barrier, kind: .drive, io: io)
    try io.checkpoint(.receiptInvalidationDurable)
    try validateRoot(parentFD, rootName, identity: rootIdentity)
    try validateParent(parentURL, identity: parentIdentity)
    let remaining = entries.filter { $0.name != receiptName }
    try validateEntries(rootFD, remaining)
    for entry in remaining { try remove(rootFD, entry.name, io: io) }
    try synchronize(rootFD, kind: .directory, io: io)
    try synchronize(barrier, kind: .drive, io: io)
    try io.checkpoint(.artifactsRemoved)
    try validateRoot(parentFD, rootName, identity: rootIdentity)
    try validateParent(parentURL, identity: parentIdentity)
    guard try DoryVZMacMetadataFile.directoryEntryNames(rootFD).isEmpty else {
      throw invalid("unknown files appeared after saved-state retirement")
    }
    try remove(parentFD, rootName, flags: AT_REMOVEDIR, io: io)
    try io.checkpoint(.directoryRemoved)
    try synchronize(parentFD, kind: .directory, io: io)
    try synchronize(barrier, kind: .drive, io: io)
    try validateParent(parentURL, identity: parentIdentity)
    guard try namedStatus(parentFD, rootName) == nil else { throw invalid("saved-state root was replaced after retirement") }
    try io.checkpoint(.completed)
  }

  private static func validateEntries(_ descriptor: Int32, _ entries: [Entry]) throws {
    guard try DoryVZMacMetadataFile.directoryEntryNames(descriptor) == Set(entries.map(\.name)) else {
      throw invalid("saved-state directory changed during retirement")
    }
    for entry in entries {
      guard let named = try namedStatus(descriptor, entry.name), sameIdentity(named, entry.identity) else {
        throw invalid("saved-state artifact was replaced")
      }
      try requireFile(named)
    }
  }

  private static func openBarrier(_ url: URL, on device: dev_t) throws -> Int32 {
    guard url.isFileURL, !url.path.contains("\0") else { throw invalid("nonlocal retirement barrier") }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open saved-state retirement barrier") }
    do {
      let value = try status(descriptor)
      try requireFile(value)
      guard value.st_dev == device else { throw invalid("retirement barrier volume differs") }
      return descriptor
    } catch { close(descriptor); throw error }
  }

  private static func requireFile(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
      value.st_mode & 0o022 == 0, value.st_size >= 0 else {
      throw invalid("saved-state file is not owned, unshared and protected")
    }
  }

  private static func requireDirectory(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o022 == 0 else {
      throw invalid("saved-state directory is not owned and protected")
    }
  }

  private static func status(_ descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw failure("inspect saved-state descriptor") }
    return result
  }

  private static func namedStatus(_ descriptor: Int32, _ name: String) throws -> stat? {
    var result = stat()
    guard fstatat(descriptor, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw failure("inspect saved-state entry")
    }
    return result
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }

  private static func validateRoot(_ parent: Int32, _ name: String, identity: stat) throws {
    guard let current = try namedStatus(parent, name), sameIdentity(current, identity) else {
      throw invalid("saved-state root changed during retirement")
    }
    try requireDirectory(current)
  }

  private static func validateParent(_ url: URL, identity: stat) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0, sameIdentity(current, identity) else {
      throw invalid("saved-state parent changed during retirement")
    }
    try requireDirectory(current)
  }

  private static func remove(_ parent: Int32, _ name: String, flags: Int32 = 0, io: IO) throws {
    while io.unlink(parent, name, flags) != 0 {
      if errno == EINTR { continue }
      throw failure("retire saved-state entry")
    }
  }

  private static func synchronize(_ descriptor: Int32, kind: DoryVZMacMetadataFile.SyncKind, io: IO) throws {
    while io.metadata.sync(descriptor, kind) != 0 {
      if errno == EINTR { continue }
      throw failure("synchronize saved-state retirement \(kind)")
    }
  }

  private static func invalid(_ detail: String) -> DoryVZMacSavedStateError { .invalidArtifact(detail) }
  private static func failure(_ operation: String) -> DoryVZMacSavedStateError { .filesystem(operation, errno) }
}
