import Darwin
import DoryFirmware
import Foundation
import Testing

@Suite struct DoryUEFIVariableStoreFileTests {
  private let globalVendor = UUID(uuidString: "8be4df61-93ca-11d2-aa0d-00e098032b8c")!

  @Test func initializeAndLoadCanonicalPrivatePrimary() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let initial = try DoryUEFIVariableStoreSnapshot()

    try fixture.store.initialize(initial)
    let loaded = try fixture.store.load()

    #expect(loaded == DoryUEFIVariableStoreLoad(snapshot: initial, source: .primary))
    #expect(try permissions(fixture.store.directory) == 0o700)
    #expect(try permissions(fixture.store.primaryPath) == 0o600)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.store.primaryPath)).last == 0x0a)
  }

  @Test func commitUsesGenerationCASAndBacksUpPriorPrimary() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let initial = try DoryUEFIVariableStoreSnapshot()
    let next = try initial.setting(variable(name: "BootOrder", bytes: [0, 0]))

    try fixture.store.initialize(initial)
    try fixture.store.commit(next, expectedGeneration: initial.generation)

    #expect(try fixture.store.load().snapshot == next)
    #expect(try decoded(fixture.store.backupPath) == initial)
    #expect(try permissions(fixture.store.backupPath) == 0o600)
    #expect(throws: DoryUEFIVariableStoreFileError.generationConflict(expected: 1, actual: 2)) {
      try fixture.store.commit(next, expectedGeneration: 1)
    }
  }

  @Test func coldSnapshotInitializationRetainsExactGeneration() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let initial = try DoryUEFIVariableStoreSnapshot()
    let generationTwo = try initial.setting(variable(name: "BootOrder", bytes: [0, 0]))

    try fixture.store.initializeFromColdSnapshot(generationTwo)

    #expect(try fixture.store.load().snapshot == generationTwo)
    #expect(try fixture.store.load().source == .primary)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.backupPath))
  }

  @Test func coldSnapshotReplacementCanMoveBackwardAndRetainsRollbackAuthority() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let generationOne = try DoryUEFIVariableStoreSnapshot()
    let generationTwo = try generationOne.setting(variable(name: "BootOrder", bytes: [0, 0]))
    try fixture.store.initialize(generationOne)
    try fixture.store.commit(generationTwo, expectedGeneration: generationOne.generation)

    let encoded = try DoryUEFIVariableStoreFile.encodeColdSnapshot(generationOne)
    let coldSnapshot = try DoryUEFIVariableStoreFile.decodeColdSnapshot(encoded)
    let previous = try fixture.store.replaceFromColdSnapshot(coldSnapshot)

    #expect(previous == generationTwo)
    #expect(try fixture.store.load().snapshot == generationOne)
    #expect(try decoded(fixture.store.backupPath) == generationTwo)
    _ = try fixture.store.replaceFromColdSnapshot(previous)
    #expect(try fixture.store.load().snapshot == generationTwo)
  }

  @Test func corruptPrimaryRequiresExplicitBackupRepair() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let initial = try DoryUEFIVariableStoreSnapshot()
    let next = try initial.setting(variable(name: "BootOrder", bytes: [0, 0]))
    try fixture.store.initialize(initial)
    try fixture.store.commit(next, expectedGeneration: 1)
    try overwrite(Data("corrupt\n".utf8), path: fixture.store.primaryPath)

    let recovery = try fixture.store.load()
    #expect(recovery.source == .backupRecoveryRequired)
    #expect(recovery.snapshot == initial)
    #expect(throws: DoryUEFIVariableStoreFileError.recoveryRequired) {
      try fixture.store.commit(next, expectedGeneration: 1)
    }

    let repaired = try fixture.store.repairFromBackup()
    #expect(repaired == initial)
    #expect(try fixture.store.load().source == .primary)
    #expect(try fixture.store.load().snapshot == initial)
  }

  @Test func missingPrimaryCanBeRepairedButMissingEverythingCannot() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let initial = try DoryUEFIVariableStoreSnapshot()
    let next = try initial.setting(variable(name: "BootOrder", bytes: [0, 0]))
    try fixture.store.initialize(initial)
    try fixture.store.commit(next, expectedGeneration: 1)
    try FileManager.default.removeItem(atPath: fixture.store.primaryPath)

    #expect(try fixture.store.load().source == .backupRecoveryRequired)
    #expect(try fixture.store.repairFromBackup() == initial)

    let empty = try Fixture()
    defer { empty.cleanup() }
    try empty.store.prepare()
    #expect(throws: DoryUEFIVariableStoreFileError.storeNotInitialized) {
      _ = try empty.store.load()
    }
    #expect(throws: DoryUEFIVariableStoreFileError.noRecoverableBackup) {
      _ = try empty.store.repairFromBackup()
    }
  }

  @Test func unsafePrimaryNeverFallsBackToBackup() throws {
    for kind in UnsafeLinkKind.allCases {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let initial = try DoryUEFIVariableStoreSnapshot()
      let next = try initial.setting(variable(name: "BootOrder", bytes: [0, 0]))
      try fixture.store.initialize(initial)
      try fixture.store.commit(next, expectedGeneration: 1)
      let foreign = fixture.root.appendingPathComponent("foreign.json").path
      try Data("foreign".utf8).write(to: URL(fileURLWithPath: foreign))
      try FileManager.default.removeItem(atPath: fixture.store.primaryPath)
      switch kind {
      case .symbolic:
        try FileManager.default.createSymbolicLink(
          atPath: fixture.store.primaryPath,
          withDestinationPath: foreign
        )
      case .hard:
        try FileManager.default.linkItem(atPath: foreign, toPath: fixture.store.primaryPath)
      }

      #expect(throws: DoryUEFIVariableStoreFileError.unsafePath(fixture.store.primaryPath)) {
        _ = try fixture.store.load()
      }
    }
  }

  @Test func publicModesAndUnsafeDirectoryAreRejected() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.store.initialize(DoryUEFIVariableStoreSnapshot())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.store.primaryPath
    )
    #expect(throws: DoryUEFIVariableStoreFileError.unsafePath(fixture.store.primaryPath)) {
      _ = try fixture.store.load()
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.store.directory
    )
    #expect(throws: DoryUEFIVariableStoreFileError.unsafePath(fixture.store.directory)) {
      _ = try fixture.store.load()
    }
  }

  private func variable(name: String, bytes: [UInt8]) throws -> DoryUEFIVariable {
    try DoryUEFIVariable(
      key: DoryUEFIVariableKey(vendor: globalVendor, name: name),
      attributes: [.nonVolatile, .bootServiceAccess, .runtimeAccess],
      data: Data(bytes)
    )
  }

  private func decoded(_ path: String) throws -> DoryUEFIVariableStoreSnapshot {
    try JSONDecoder().decode(
      DoryUEFIVariableStoreSnapshot.self,
      from: Data(contentsOf: URL(fileURLWithPath: path))
    )
  }

  private func permissions(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  private func overwrite(_ data: Data, path: String) throws {
    let descriptor = path.withCString {
      Darwin.open($0, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      guard Darwin.write(descriptor, base, bytes.count) == bytes.count else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }
}

private enum UnsafeLinkKind: CaseIterable {
  case symbolic
  case hard
}

private struct Fixture {
  let root: URL
  let store: DoryUEFIVariableStoreFile

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-firmware-tests-" + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    store = try DoryUEFIVariableStoreFile(directory: root.appendingPathComponent("nvram").path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
