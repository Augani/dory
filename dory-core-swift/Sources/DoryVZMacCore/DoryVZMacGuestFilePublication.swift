import Darwin
import DoryMacGuestIntegrationWire
import Foundation

/// Publishes a verified guest transfer relative to the directory selected by NSSavePanel.
/// Keeping the open directory handle through the transfer prevents a replaced path component
/// from redirecting the final rename into another host directory.
final class DoryVZMacGuestFilePublication {
  let output: FileHandle

  private let directoryDescriptor: Int32
  private let directoryPath: String
  private let directoryDevice: dev_t
  private let directoryInode: ino_t
  private let destinationName: String
  private let temporaryName: String
  private var published = false

  init(destination: URL) throws {
    let name = destination.lastPathComponent
    guard destination.isFileURL, !destination.hasDirectoryPath,
      !name.isEmpty, name != ".", name != "..",
      name.utf8.count <= Int(NAME_MAX), !name.contains("/"), !name.contains("\0")
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    let parent = destination.deletingLastPathComponent().standardizedFileURL
    let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
    var directory = stat()
    guard fstat(descriptor, &directory) == 0 else {
      let code = errno
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(code)
    }
    guard directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let temporary = ".dory-transfer-\(UUID().uuidString).partial"
    let fileDescriptor = openat(
      descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard fileDescriptor >= 0 else {
      let code = errno
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(code)
    }
    output = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    directoryDescriptor = descriptor
    directoryPath = parent.path
    directoryDevice = directory.st_dev
    directoryInode = directory.st_ino
    destinationName = name
    temporaryName = temporary
  }

  func publish(
    authorizePublication: (_ mutation: () throws -> Void) throws -> Void = { try $0() }
  ) throws {
    guard !published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    try output.synchronize()
    try output.close()

    // Preparation can block on filesystem I/O. Only the final atomic publication runs while
    // the request/session owner holds its admission lock and checks the original deadline.
    try authorizePublication {
      guard !published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
      // Check inside admission: its callback may have waited while the selected directory
      // was replaced. The held original directory remains authoritative only for cleanup.
      var currentDirectory = stat()
      guard lstat(directoryPath, &currentDirectory) == 0,
        currentDirectory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        currentDirectory.st_dev == directoryDevice,
        currentDirectory.st_ino == directoryInode
      else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
      var existing = stat()
      if fstatat(directoryDescriptor, destinationName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
      } else if errno != ENOENT {
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      guard renameat(
        directoryDescriptor, temporaryName, directoryDescriptor, destinationName
      ) == 0 else {
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      published = true
    }
    guard published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
  }

  deinit {
    try? output.close()
    if !published { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    close(directoryDescriptor)
  }
}
