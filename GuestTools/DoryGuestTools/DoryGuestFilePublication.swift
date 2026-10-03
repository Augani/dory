import Darwin
import DoryMacGuestIntegrationWire
import Foundation

/// Keeps an incoming host file inside the Guest Tools private received-files directory even if
/// its pathname is replaced while a transfer is in flight. The destination appears only after
/// all bytes and the digest have been verified; an existing entry is never overwritten.
final class DoryGuestFilePublication {
  let output: FileHandle

  private let directoryDescriptor: Int32
  private let directoryPath: String
  private let directoryDevice: dev_t
  private let directoryInode: ino_t
  private let temporaryName: String
  private let destinationName: String
  private var published = false
  private var stagingExists = true

  init(directory: URL, transferID: UUID, name: String) throws {
    let temporaryName = ".transfer-\(transferID.uuidString).partial"
    let destinationName = "\(transferID.uuidString)-\(name)"
    guard directory.isFileURL, directory.hasDirectoryPath,
      !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\0"),
      destinationName.utf8.count <= Int(NAME_MAX)
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }

    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let path = directory.standardizedFileURL.path
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      let code = errno
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(code)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    guard fchmod(descriptor, 0o700) == 0 else {
      let code = errno
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(code)
    }
    let fileDescriptor = openat(
      descriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard fileDescriptor >= 0 else {
      let code = errno
      close(descriptor)
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(code)
    }
    output = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    directoryDescriptor = descriptor
    directoryPath = path
    directoryDevice = metadata.st_dev
    directoryInode = metadata.st_ino
    self.temporaryName = temporaryName
    self.destinationName = destinationName
  }

  func publish(
    authorizePublication: (_ mutation: () throws -> Void) throws -> Void = { try $0() }
  ) throws {
    guard !published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    try output.synchronize()
    try output.close()

    // linkat is an atomic create-only publication: a concurrent destination insertion cannot
    // be overwritten between an existence check and rename. The source stays hidden until this
    // point, and the held directory descriptor pins both names to the original directory.
    // Flush/close must not hold the console owner's lock. Revalidate its exact original
    // request immediately at this create-only publication, not before slow preparation.
    try authorizePublication {
      guard !published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
      var current = stat()
      guard lstat(directoryPath, &current) == 0,
        current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        current.st_dev == directoryDevice,
        current.st_ino == directoryInode
      else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
      guard linkat(directoryDescriptor, temporaryName, directoryDescriptor, destinationName, 0) == 0
      else {
        if errno == EEXIST { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      published = true
    }
    guard published else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    guard unlinkat(directoryDescriptor, temporaryName, 0) == 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
    stagingExists = false
    guard fsync(directoryDescriptor) == 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
  }

  deinit {
    try? output.close()
    if stagingExists { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    close(directoryDescriptor)
  }
}
