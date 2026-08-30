import Darwin
import DoryFirmware
import Foundation
import Testing

@Suite struct DoryUEFIVariableStoreDirectoryDescriptorTests {
  @Test func duplicatedDirectoryCapabilityPersistsAndRecoversWithoutAPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-uefi-dirfd-\(UUID().uuidString)", isDirectory: true).path
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    #expect(chmod(directory, 0o700) == 0)
    let descriptor = directory.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    #expect(descriptor >= 3)
    guard descriptor >= 3 else { return }
    let store = try DoryUEFIVariableStoreDirectoryDescriptor(
      inheritedDescriptor: descriptor
    )
    #expect(close(descriptor) == 0)

    let initial = try DoryUEFIVariableStoreSnapshot()
    try store.initialize(initial)
    #expect(try store.load().snapshot == initial)
    let variable = try DoryUEFIVariable(
      key: DoryUEFIVariableKey(vendor: UUID(), name: "BootOrder"),
      attributes: [.nonVolatile, .bootServiceAccess],
      data: Data([0, 1])
    )
    let successor = try initial.setting(variable)
    try store.commit(successor, expectedGeneration: initial.generation)
    #expect(try store.load().snapshot == successor)

    let primary = try FileHandle(
      forWritingTo: URL(fileURLWithPath: directory)
        .appendingPathComponent(DoryUEFIVariableStoreFile.primaryFileName)
    )
    try primary.truncate(atOffset: 0)
    try primary.write(contentsOf: Data("corrupt\n".utf8))
    try primary.close()
    let recovery = try store.load()
    #expect(recovery.source == .backupRecoveryRequired)
    #expect(recovery.snapshot == initial)
    #expect(try store.repairFromBackup() == initial)
    #expect(try store.load().source == .primary)
  }

  @Test func rejectsPublicOrNonDirectoryCapabilities() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-uefi-unsafe-dirfd-\(UUID().uuidString)", isDirectory: true).path
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    #expect(chmod(directory, 0o755) == 0)
    let descriptor = directory.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    #expect(descriptor >= 3)
    guard descriptor >= 3 else { return }
    defer { close(descriptor) }
    #expect(throws: DoryUEFIVariableStoreFileError.self) {
      _ = try DoryUEFIVariableStoreDirectoryDescriptor(inheritedDescriptor: descriptor)
    }
  }
}
