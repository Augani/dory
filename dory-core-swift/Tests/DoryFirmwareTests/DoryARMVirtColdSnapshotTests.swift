import DoryFirmware
import Foundation
import Testing

@Suite struct DoryARMVirtColdSnapshotTests {
  @Test func capturesVerifiesAndRestoresStoppedDiskAndVariables() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let firmware = try makeFirmware(buildIdentifier: "dory-armvirt-test").manifest
    let diskBytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
    try fixture.writePrivate(diskBytes, to: fixture.diskPath)
    let firstVariables = try DoryUEFIVariableStoreSnapshot()
    let variables = try firstVariables.setting(
      DoryUEFIVariable(
        key: DoryUEFIVariableKey(
          vendor: #require(UUID(uuidString: "8be4df61-93ca-11d2-aa0d-00e098032b8c")),
          name: "BootOrder"
        ),
        attributes: [.nonVolatile, .bootServiceAccess, .runtimeAccess],
        data: Data([0, 0])
      )
    )
    try fixture.variableStore.initializeFromColdSnapshot(variables)

    let captured = try DoryARMVirtColdSnapshotStore.capture(
      firmware: firmware,
      systemDiskPath: fixture.diskPath,
      variableStore: fixture.variableStore,
      destinationDirectory: fixture.snapshotPath
    )

    #expect(captured.systemDiskByteCount == 4_096)
    #expect(captured.variableStoreGeneration == 2)
    #expect(
      try DoryARMVirtColdSnapshotStore.loadVerified(
        directory: fixture.snapshotPath,
        expectedFirmware: firmware
      ) == captured
    )

    let sourceHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.diskPath))
    try sourceHandle.write(contentsOf: Data([0xee]))
    try sourceHandle.close()
    let restored = try DoryARMVirtColdSnapshotStore.restore(
      bundleDirectory: fixture.snapshotPath,
      expectedFirmware: firmware,
      destinationDirectory: fixture.restorePath
    )

    #expect(try Data(contentsOf: URL(fileURLWithPath: restored.systemDiskPath)) == diskBytes)
    #expect(try restored.variableStore.load().snapshot == variables)
    #expect(restored.manifest == captured)
    #expect(try fixture.permissions(fixture.snapshotPath) == 0o700)
    #expect(
      try fixture.permissions(
        fixture.snapshotPath + "/" + DoryARMVirtColdSnapshotStore.systemDiskFileName)
        == 0o600
    )
  }

  @Test func rejectsTamperedBytesAndFirmwareIdentity() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let firmware = try makeFirmware(buildIdentifier: "dory-armvirt-test").manifest
    try fixture.writePrivate(Data(repeating: 0xa5, count: 4_096), to: fixture.diskPath)
    try fixture.variableStore.initialize(DoryUEFIVariableStoreSnapshot())
    _ = try DoryARMVirtColdSnapshotStore.capture(
      firmware: firmware,
      systemDiskPath: fixture.diskPath,
      variableStore: fixture.variableStore,
      destinationDirectory: fixture.snapshotPath
    )

    let otherFirmware = try makeFirmware(buildIdentifier: "other-build").manifest
    #expect(throws: DoryARMVirtColdSnapshotError.incompatibleFirmware) {
      _ = try DoryARMVirtColdSnapshotStore.loadVerified(
        directory: fixture.snapshotPath,
        expectedFirmware: otherFirmware
      )
    }

    let snapshotDisk = fixture.snapshotPath + "/" + DoryARMVirtColdSnapshotStore.systemDiskFileName
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: snapshotDisk))
    try handle.write(contentsOf: Data([0xff]))
    try handle.close()
    #expect(
      throws: DoryARMVirtColdSnapshotError.digestMismatch(
        DoryARMVirtColdSnapshotStore.systemDiskFileName
      )
    ) {
      _ = try DoryARMVirtColdSnapshotStore.loadVerified(
        directory: fixture.snapshotPath,
        expectedFirmware: firmware
      )
    }
  }

  private func makeFirmware(buildIdentifier: String) throws -> DoryFirmwareBundle {
    try DoryFirmwareBundleBuilder.build(
      DoryFirmwareBundleBuildInput(
        buildIdentifier: buildIdentifier,
        source: DoryFirmwareSourcePin(
          repository: "https://github.com/tianocore/edk2.git",
          revision: "2970e5699ba6267f3384ffab20f96647578aebc8"
        ),
        sourceDateEpoch: 1_786_522_436,
        platformConfiguration: Data("platform".utf8),
        toolchainDescriptor: Data("toolchain".utf8),
        firmwareCode: Data(repeating: 0xff, count: 4_096),
        secureBootPolicy: .userManagedKeys
      )
    )
  }
}

private struct Fixture {
  let root: String
  let diskPath: String
  let variableStore: DoryUEFIVariableStoreFile
  let snapshotPath: String
  let restorePath: String

  init() throws {
    root =
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "dory-armvirt-cold-snapshot-tests-" + UUID().uuidString.lowercased(),
        isDirectory: true
      ).path
    try FileManager.default.createDirectory(
      atPath: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    diskPath = root + "/system.raw"
    variableStore = try DoryUEFIVariableStoreFile(directory: root + "/variables")
    snapshotPath = root + "/snapshot"
    restorePath = root + "/restore"
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: root)
  }

  func writePrivate(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  func permissions(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
