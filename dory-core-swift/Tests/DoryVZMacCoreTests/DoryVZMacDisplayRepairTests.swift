import Foundation
import Darwin
import XCTest

@testable import DoryVZMacCore

final class DoryVZMacDisplayRepairTests: XCTestCase {
  func testExplicitColdRepairKeepsOneDisplayAndPreservesSavedState() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try legacyManifest(displayCount: 2, state: .suspended)
    try original.write(to: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName))
    let savedState = root.appendingPathComponent(
      DoryVZMacMachineBundle.suspendedStateDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: savedState, withIntermediateDirectories: false)
    let sentinel = Data("preserve-me".utf8)
    try sentinel.write(to: savedState.appendingPathComponent("sentinel"))

    let receipt = try DoryVZMacMachineBundle.repairPersistedDisplayTopologyForColdBoot(
      at: root,
      keepingDisplayAt: 1
    )

    XCTAssertEqual(receipt.originalDisplayCount, 2)
    XCTAssertEqual(receipt.selectedDisplayIndex, 1)
    XCTAssertEqual(receipt.previousInstallationState, .suspended)
    XCTAssertEqual(receipt.repairedInstallationState, .stopped)
    let repaired = try JSONDecoder().decode(
      DoryVZMacMachineManifest.self,
      from: Data(contentsOf: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName))
    )
    XCTAssertEqual(
      repaired.resources.displays,
      [
        DoryVZMacDisplay(widthInPixels: 1_920, heightInPixels: 1_080, pixelsPerInch: 144)
      ])
    XCTAssertEqual(
      try Data(
        contentsOf:
          root
          .appendingPathComponent(DoryVZMacMachineBundle.incompatibleSavedStateName)
          .appendingPathComponent("sentinel")),
      sentinel
    )
    XCTAssertEqual(
      try Data(
        contentsOf: root.appendingPathComponent(
          DoryVZMacMachineBundle.preDisplayRepairManifestName
        )),
      original
    )
    XCTAssertThrowsError(
      try DoryVZMacMachineBundle.repairPersistedDisplayTopologyForColdBoot(at: root)
    )
  }

  func testOrdinaryLoadRejectsLegacyTopologyWithoutSilentlyRepairingIt() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try legacyManifest(displayCount: 2, state: .stopped).write(
      to: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName)
    )

    XCTAssertThrowsError(try DoryVZMacMachineBundle.load(from: root))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          DoryVZMacMachineBundle.displayRepairReceiptName
        ).path))
  }

  func testRealMacConfigurationPassesVirtualizationValidationWhenFixtureIsAvailable() throws {
    guard let path = ProcessInfo.processInfo.environment["DORY_VZMAC_TEST_BUNDLE"],
      !path.isEmpty
    else {
      throw XCTSkip("set DORY_VZMAC_TEST_BUNDLE to an owned prepared Mac machine bundle")
    }
    let bundle = try DoryVZMacMachineBundle.load(from: URL(fileURLWithPath: path))
    XCTAssertEqual(bundle.manifest.resources.displays.count, 1)
    let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(for: bundle)
    XCTAssertNoThrow(try configuration.validate())
  }

  func testEveryRepairBoundaryResumesWithoutChangingTheRecordedChoiceOrLosingRAM() throws {
    for point in DoryVZMacDisplayRepair.Checkpoint.allCases {
      try withRepairFixture { root, original in
        var io = DoryVZMacDisplayRepair.IO()
        io.checkpoint = { if $0 == point { throw Injected.failure } }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
        try assertRAMPreserved(root)
        if point == .completed {
          XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
          XCTAssertThrowsError(try repair(root))
        } else {
          XCTAssertTrue(FileManager.default.fileExists(atPath: url(root, .journal).path))
          XCTAssertThrowsError(try DoryVZMacMachineBundle.load(from: root)) { error in
            XCTAssertTrue(String(describing: error).contains("display-topology repair is unfinished"))
          }
          _ = try repair(root)
        }
        try assertCompleted(root, original: original)
      }
    }
  }

  func testEverySynchronizationFailurePreservesArtifactsAndAllowsExplicitRetry() throws {
    for failureIndex in 1...22 {
      try withRepairFixture { root, original in
        var calls = 0
        var io = DoryVZMacDisplayRepair.IO()
        let realSync = io.metadata.sync
        io.metadata.sync = { descriptor, kind in
          calls += 1
          if calls == failureIndex { errno = ENOSPC; return -1 }
          return realSync(descriptor, kind)
        }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
        XCTAssertEqual(calls, failureIndex)
        try assertRAMPreserved(root)
        if FileManager.default.fileExists(atPath: url(root, .receipt).path),
          !FileManager.default.fileExists(atPath: url(root, .journal).path) {
          XCTAssertThrowsError(try repair(root))
        } else { _ = try repair(root) }
        try assertCompleted(root, original: original)
      }
    }
  }

  func testEveryMetadataWriterInterruptionLeavesRecoverableOldOrNewBytes() throws {
    let points: [DoryVZMacMetadataFile.Checkpoint] = [
      .temporaryCreated, .bytesWritten, .fileSynced, .published, .directorySynced,
    ]
    for writer in 1...4 {
      for point in points {
        try withRepairFixture { root, original in
          var matches = 0
          var io = DoryVZMacDisplayRepair.IO()
          io.metadata.checkpoint = { current in
            if current == point {
              matches += 1
              if matches == writer { throw Injected.failure }
            }
          }
          XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
          XCTAssertEqual(matches, writer)
          try assertRAMPreserved(root)
          _ = try repair(root)
          try assertCompleted(root, original: original)
        }
      }
    }
  }

  func testPendingRepairRejectsADifferentSelectionWithoutMutatingAnything() throws {
    try withRepairFixture { root, original in
      var io = DoryVZMacDisplayRepair.IO()
      io.checkpoint = { if $0 == .intentCommitted { throw Injected.failure } }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
      let intent = try Data(contentsOf: url(root, .journal))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: intent) as? [String: Any])
      let recorded = try XCTUnwrap(object["receipt"] as? [String: Any])
      let repairedAt = try XCTUnwrap(recorded["repairedAt"] as? String)
      XCTAssertThrowsError(try DoryVZMacMachineBundle.repairPersistedDisplayTopologyForColdBoot(at: root)) { error in
        XCTAssertTrue(String(describing: error).contains("--keep-display-index 1"))
      }
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertEqual(try Data(contentsOf: url(root, .journal)), intent)
      try assertRAMPreserved(root)
      XCTAssertEqual(try repair(root).repairedAt, repairedAt)
      try assertCompleted(root, original: original)
    }
  }

  func testUnreadableMalformedLinkedOrUnknownIntentIsDenyOnlyAndPreserved() throws {
    for kind in ["empty", "oversize", "schema", "symlink", "directory"] {
      try withRepairFixture { root, original in
        let journal = url(root, .journal)
        switch kind {
        case "empty": try Data().write(to: journal)
        case "oversize": try Data(repeating: 0x20, count: 4 * 1_048_576).write(to: journal)
        case "schema": try Data("{\"schema\":\"future\"}".utf8).write(to: journal)
        case "directory": try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        default: XCTAssertEqual(symlink("absent-intent", journal.path), 0)
        }
        XCTAssertThrowsError(try repair(root))
        XCTAssertThrowsError(try DoryVZMacMachineBundle.load(from: root)) { error in
          XCTAssertTrue(String(describing: error).contains("display-topology repair is unfinished"))
        }
        var information = stat()
        XCTAssertEqual(lstat(journal.path, &information), 0)
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        try assertRAMPreserved(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .backup).path))
      }
    }
  }

  func testTamperedIntentCannotRedirectTheManifestReceiptOrSavedStateIdentity() throws {
    for key in ["schema", "repaired", "receipt", "savedState"] {
      try withRepairFixture { root, original in
        var io = DoryVZMacDisplayRepair.IO()
        io.checkpoint = { if $0 == .intentCommitted { throw Injected.failure } }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url(root, .journal))) as? [String: Any])
        switch key {
        case "schema": object[key] = "dory.vzmac-display-repair-intent@2"
        case "repaired": object[key] = Data("other-manifest".utf8).base64EncodedString()
        case "receipt":
          var receipt = try XCTUnwrap(object[key] as? [String: Any])
          receipt["originalManifestBackupName"] = "../external"
          object[key] = receipt
        default:
          var identity = try XCTUnwrap(object[key] as? [String: Any])
          identity["inode"] = 0
          object[key] = identity
        }
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        try corrupt.write(to: url(root, .journal))
        XCTAssertThrowsError(try repair(root))
        XCTAssertEqual(try Data(contentsOf: url(root, .journal)), corrupt)
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        try assertRAMPreserved(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .backup).path))
      }
    }
  }

  func testConflictingManifestBackupOrReceiptBlocksPendingRepairWithoutOverwriting() throws {
    for artifact in [Artifact.manifest, .backup, .receipt] {
      try withRepairFixture { root, _ in
        var io = DoryVZMacDisplayRepair.IO()
        io.checkpoint = { if $0 == .backupCommitted { throw Injected.failure } }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
        let unexpected = Data("preserve-user-or-future-artifact".utf8)
        try unexpected.write(to: url(root, artifact))
        XCTAssertThrowsError(try repair(root))
        XCTAssertEqual(try Data(contentsOf: url(root, artifact)), unexpected)
        try assertRAMPreserved(root)
      }
    }
  }

  func testReplacedRAMDirectoryCannotBeMovedUnderTheOriginalIdentity() throws {
    try withRepairFixture { root, original in
      var io = DoryVZMacDisplayRepair.IO()
      let retained = root.deletingLastPathComponent().appendingPathComponent("retained-original-RAM")
      io.checkpoint = { point in
        guard point == .backupCommitted else { return }
        try FileManager.default.moveItem(at: self.url(root, .sourceState), to: retained)
        try FileManager.default.createDirectory(at: self.url(root, .sourceState), withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: self.url(root, .sourceState).appendingPathComponent("sentinel"))
      }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
      XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("sentinel")), sentinel)
      XCTAssertEqual(try Data(contentsOf: url(root, .sourceState).appendingPathComponent("sentinel")), Data("replacement".utf8))
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .preservedState).path))
    }
  }

  func testReplacedRootCannotRedirectLaterRepairWrites() throws {
    try withRepairFixture { root, original in
      let retained = root.deletingLastPathComponent().appendingPathComponent("retained-root", isDirectory: true)
      var io = DoryVZMacDisplayRepair.IO()
      io.checkpoint = { point in
        guard point == .backupCommitted else { return }
        try FileManager.default.moveItem(at: root, to: retained)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
      XCTAssertEqual(try Data(contentsOf: url(retained, .manifest)), original)
      try assertRAMPreserved(retained)
    }
  }

  func testOriginalManifestCannotBeRepublishedAsACompletedRepair() throws {
    try withRepairFixture { root, original in
      var io = DoryVZMacDisplayRepair.IO()
      io.checkpoint = { point in
        if point == .manifestCommitted { try original.write(to: self.url(root, .manifest)) }
      }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
      XCTAssertTrue(FileManager.default.fileExists(atPath: url(root, .journal).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .receipt).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .sourceState).path))
      _ = try repair(root)
      try assertCompleted(root, original: original)
    }
  }

  func testChangedIntentIsNotRetiredAfterReceiptPublication() throws {
    try withRepairFixture { root, _ in
      let corrupt = Data("unrecognized-intent".utf8)
      var io = DoryVZMacDisplayRepair.IO()
      io.checkpoint = { point in
        if point == .receiptCommitted { try corrupt.write(to: self.url(root, .journal)) }
      }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, io: io))
      XCTAssertEqual(try Data(contentsOf: url(root, .journal)), corrupt)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url(root, .receipt).path))
      XCTAssertThrowsError(try repair(root))
      try assertRAMPreserved(root)
    }
  }

  func testLegacyPartialBackupAndPublishedManifestCanRecoverWithoutManualSurgery() throws {
    try withRepairFixture { root, original in
      try original.write(to: url(root, .backup))
      _ = try repair(root)
      try assertCompleted(root, original: original)
      // Model the previous implementation dying after manifest publication but before
      // its receipt, with the original backup and incompatible RAM still retained.
      try FileManager.default.removeItem(at: url(root, .receipt))
      _ = try repair(root)
      try assertCompleted(root, original: original)
    }
  }

  func testDanglingLinkedBackupReceiptAndStateTargetsAreNeverOverwritten() throws {
    for artifact in [Artifact.backup, .receipt, .preservedState] {
      try withRepairFixture { root, original in
        XCTAssertEqual(symlink("unavailable-target", url(root, artifact).path), 0)
        XCTAssertThrowsError(try repair(root))
        var information = stat()
        XCTAssertEqual(lstat(url(root, artifact).path, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        try assertRAMPreserved(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
      }
    }
  }

  func testInvalidSelectionAndMissingSuspendedRAMDoNotAllocateRepairIntent() throws {
    for index in [-1, 2, Int.max] {
      try withRepairFixture { root, original in
        XCTAssertThrowsError(try DoryVZMacMachineBundle.repairPersistedDisplayTopologyForColdBoot(at: root, keepingDisplayAt: index))
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
      }
    }
    try withRepairFixture(state: .suspended, withRAM: false) { root, original in
      XCTAssertThrowsError(try repair(root))
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
    }
  }

  func testColdRepairPreservesInstallationStateAndDoesNotPretendAnUninstalledDiskIsInstalled() throws {
    for state in [DoryVZMacMachineInstallationState.prepared, .installing, .installFailed, .stopped, .suspending, .restoring] {
      try withRepairFixture(state: state, withRAM: false) { root, _ in
        let receipt = try repair(root)
        XCTAssertEqual(receipt.previousInstallationState, state)
        XCTAssertEqual(receipt.repairedInstallationState, [.suspending, .restoring].contains(state) ? .stopped : state)
        XCTAssertNil(receipt.preservedSavedStateName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .preservedState).path))
      }
    }
    for state in [DoryVZMacMachineInstallationState.prepared, .installing, .installFailed] {
      try withRepairFixture(state: state) { root, original in
        XCTAssertThrowsError(try repair(root))
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        try assertRAMPreserved(root)
      }
    }
  }

  func testExistingMachineLeasePreventsRepairAndNewMetadataIsPrivate() throws {
    try withRepairFixture { root, original in
      do {
        let lease = try DoryVZMacMachineLease(rootURL: root)
        defer { withExtendedLifetime(lease) {} }
        XCTAssertThrowsError(try repair(root))
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
      }
      _ = try repair(root)
      for artifact in [Artifact.backup, .receipt, .manifest] {
        var information = stat()
        XCTAssertEqual(lstat(url(root, artifact).path, &information), 0)
        XCTAssertEqual(information.st_mode & 0o777, 0o600)
      }
    }
  }

  func testInspectionOffersValidatedChoicesWithoutCreatingLeaseOrRepairArtifacts() throws {
    try withManagedFixture { root, original, source, _ in
      let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
      let assessment = try XCTUnwrap(DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
      XCTAssertEqual(assessment.displays.count, 2)
      XCTAssertNil(assessment.pendingSelectedDisplayIndex)
      XCTAssertTrue(assessment.preservesSavedState)
      XCTAssertFalse(assessment.bundleRepairCompleted)
      XCTAssertEqual(assessment.candidateManifest.installationState, .stopped)
      XCTAssertEqual(assessment.candidateManifest.resources.displays.count, 1)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), sentinel)
      // Public product assessment also requires real disks and Apple identities. This
      // small metadata fixture is never admitted as a runnable or repairable VM there.
      XCTAssertThrowsError(try DoryVZMacMachineBundle.assessPersistedDisplayTopologyRepair(at: root, preserveManagedSavedState: true))
    }
  }

  func testManagedAndStandaloneRAMAreBothPreservedBeforeColdManifestPublication() throws {
    for standalone in [false, true] {
      try withManagedFixture(standalone: standalone) { root, original, source, preserved in
        var old = stat()
        XCTAssertEqual(lstat(source.path, &old), 0)
        var io = DoryVZMacDisplayRepair.IO()
        io.checkpoint = { point in
          if point == .statePreserved {
            XCTAssertEqual(try Data(contentsOf: self.url(root, .manifest)), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), self.sentinel)
            if standalone { XCTAssertFalse(FileManager.default.fileExists(atPath: self.url(root, .sourceState).path)) }
          }
        }
        let receipt = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, io: io)
        var new = stat()
        XCTAssertEqual(lstat(preserved.path, &new), 0)
        XCTAssertEqual(old.st_ino, new.st_ino)
        XCTAssertEqual(old.st_dev, new.st_dev)
        XCTAssertEqual(receipt.preservedManagedSavedStateName, DoryVZMacMachineBundle.incompatibleManagedSavedStateName)
        XCTAssertEqual(receipt.preservedSavedStateName, standalone ? DoryVZMacMachineBundle.incompatibleSavedStateName : nil)
        XCTAssertEqual(receipt.repairedInstallationState, .stopped)
        XCTAssertEqual(try Data(contentsOf: self.url(root, .backup)), original)
        if standalone { try assertRAMPreserved(root) }
        let assessment = try XCTUnwrap(DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
        XCTAssertTrue(assessment.bundleRepairCompleted)
        XCTAssertEqual(assessment.pendingSelectedDisplayIndex, 1)
      }
    }
  }

  func testEveryManagedRepairBoundaryRetainsOriginalChoiceAndBothRAMDirectories() throws {
    for point in DoryVZMacDisplayRepair.Checkpoint.allCases {
      try withManagedFixture(standalone: true) { root, original, source, preserved in
        var io = DoryVZMacDisplayRepair.IO()
        io.checkpoint = { if $0 == point { throw Injected.failure } }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, io: io))
        let exists = FileManager.default.fileExists(atPath: source.path)
        XCTAssertEqual(try Data(contentsOf: (exists ? source : preserved).appendingPathComponent("sentinel")), sentinel)
        try assertRAMPreserved(root)
        let assessment = try XCTUnwrap(DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
        XCTAssertEqual(assessment.pendingSelectedDisplayIndex, 1)
        XCTAssertEqual(assessment.bundleRepairCompleted, point == .completed)
        if point != .completed {
          XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 0, preserveManagedSavedState: true))
          XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1))
          _ = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try Data(contentsOf: url(root, .backup)), original)
      }
    }
  }

  func testEveryManagedRepairFlushFailurePreservesRAMAndAllowsExplicitRecovery() throws {
    var total = 0
    try withManagedFixture(standalone: true) { root, _, _, _ in
      var io = DoryVZMacDisplayRepair.IO()
      let sync = io.metadata.sync
      io.metadata.sync = { descriptor, kind in total += 1; return sync(descriptor, kind) }
      _ = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, io: io)
    }
    XCTAssertGreaterThan(total, 22)
    for failureIndex in 1...total {
      try withManagedFixture(standalone: true) { root, original, source, preserved in
        var calls = 0
        var io = DoryVZMacDisplayRepair.IO()
        let sync = io.metadata.sync
        io.metadata.sync = { descriptor, kind in
          calls += 1
          if calls == failureIndex { errno = ENOSPC; return -1 }
          return sync(descriptor, kind)
        }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, io: io))
        XCTAssertEqual(calls, failureIndex)
        let exists = FileManager.default.fileExists(atPath: source.path)
        XCTAssertEqual(try Data(contentsOf: (exists ? source : preserved).appendingPathComponent("sentinel")), sentinel)
        try assertRAMPreserved(root)
        if FileManager.default.fileExists(atPath: url(root, .journal).path)
          || !FileManager.default.fileExists(atPath: url(root, .receipt).path) {
          _ = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true)
        }
        let assessment = try XCTUnwrap(DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
        XCTAssertTrue(assessment.bundleRepairCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try Data(contentsOf: url(root, .backup)), original)
      }
    }
  }

  func testManagedRAMLinksConflictingArchiveAndWritableParentNeverMutateRepairSource() throws {
    for kind in ["linked-source", "linked-archive", "conflict", "parent-permissions"] {
      try withManagedFixture { root, original, source, preserved in
        if kind == "linked-source" {
          try FileManager.default.moveItem(at: source, to: preserved)
          XCTAssertEqual(symlink(preserved.path, source.path), 0)
        } else if kind == "linked-archive" { XCTAssertEqual(symlink("absent-target", preserved.path), 0) }
        else if kind == "conflict" { try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false) }
        else { XCTAssertEqual(chmod(root.deletingLastPathComponent().path, 0o777), 0) }
        defer { if kind == "parent-permissions" { _ = chmod(root.deletingLastPathComponent().path, 0o700) } }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true))
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), sentinel)
      }
    }
  }

  func testManagedRAMReplacementAfterIntentCannotBePreservedAsTheOriginalSnapshot() throws {
    try withManagedFixture { root, original, source, preserved in
      var io = DoryVZMacDisplayRepair.IO()
      io.checkpoint = { if $0 == .intentCommitted { throw Injected.failure } }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, io: io))
      let retained = root.deletingLastPathComponent().appendingPathComponent("original-RAM")
      try FileManager.default.moveItem(at: source, to: retained)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try Data("replacement".utf8).write(to: source.appendingPathComponent("sentinel"))
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true))
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("sentinel")), sentinel)
      XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), Data("replacement".utf8))
      XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.path))
    }
  }

  func testInspectionRejectsCorruptFutureMetadataAndEveryInvalidDisplayChoiceWithoutMutation() throws {
    for kind in ["intent", "receipt", "future", "second-display"] {
      try withRepairFixture { root, original in
        if kind == "second-display" {
          var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
          var resources = try XCTUnwrap(object["resources"] as? [String: Any])
          var displays = try XCTUnwrap(resources["displays"] as? [[String: Any]])
          displays[1]["widthInPixels"] = 0
          resources["displays"] = displays; object["resources"] = resources
          try JSONSerialization.data(withJSONObject: object).write(to: url(root, .manifest))
        } else {
          try Data((kind == "future" ? "{\"schema\":\"future\"}" : "corrupt").utf8)
            .write(to: url(root, kind == "receipt" ? .receipt : .journal))
        }
        let before = try Data(contentsOf: url(root, .manifest))
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.inspect(at: root))
        XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(DoryVZMacMachineLease.lockName).path))
        try assertRAMPreserved(root)
      }
    }
  }

  func testCompletedRetryCannotSubstituteAPreservedRAMArchive() throws {
    try withManagedFixture(standalone: true) { root, _, _, preserved in
      let receipt = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true)
      XCTAssertNotNil(receipt.preservedSavedStateIdentity)
      XCTAssertNotNil(receipt.preservedManagedSavedStateIdentity)
      let originalArchive = preserved.appendingPathExtension("original")
      try FileManager.default.moveItem(at: preserved, to: originalArchive)
      try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.inspect(at: root, preserveManagedSavedState: true))
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true,
        expectedOriginalManifestSHA256: receipt.originalManifestSHA256))
      XCTAssertEqual(try Data(contentsOf: originalArchive.appendingPathComponent("sentinel")), sentinel)
    }
  }

  func testProductLeaseRemainsOwnedAcrossRepairPublication() throws {
    try withManagedFixture { root, _, _, preserved in
      let lease = try DoryVZMacMachineLease(rootURL: root)
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true))
      _ = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true, holdingLease: lease)
      XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: root))
      XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), sentinel)
      withExtendedLifetime(lease) {}
    }
  }

  func testContentBoundCompletedRetryReflushesBothRAMPreservationDirectories() throws {
    try withManagedFixture(standalone: true) { root, _, source, preserved in
      let receipt = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true)
      var calls = 0
      var io = DoryVZMacDisplayRepair.IO()
      let realSync = io.metadata.sync
      io.metadata.sync = { fd, kind in calls += 1; return realSync(fd, kind) }
      XCTAssertEqual(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1,
        preserveManagedSavedState: true, expectedOriginalManifestSHA256: receipt.originalManifestSHA256, io: io), receipt)
      XCTAssertGreaterThanOrEqual(calls, 8)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), sentinel)
      for index in [0, 2] {
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: index,
          preserveManagedSavedState: true, expectedOriginalManifestSHA256: receipt.originalManifestSHA256))
      }
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1,
        preserveManagedSavedState: true, expectedOriginalManifestSHA256: String(repeating: "f", count: 64)))
    }
  }

  func testStaleConfirmedHashNeverCreatesRepairIntentOrMovesRAM() throws {
    try withManagedFixture { root, original, source, preserved in
      XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1,
        preserveManagedSavedState: true, expectedOriginalManifestSHA256: String(repeating: "f", count: 64)))
      XCTAssertEqual(try Data(contentsOf: url(root, .manifest)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.path))
      XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), sentinel)
    }
  }

  func testEveryCompletedRetryFlushFailureRemainsExplicitlyRecoverable() throws {
    for boundary in 1...8 {
      try withManagedFixture(standalone: true) { root, _, _, preserved in
        let receipt = try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1, preserveManagedSavedState: true)
        var calls = 0
        var io = DoryVZMacDisplayRepair.IO()
        let realSync = io.metadata.sync
        io.metadata.sync = { fd, kind in
          calls += 1
          if calls == boundary { errno = ENOSPC; return -1 }
          return realSync(fd, kind)
        }
        XCTAssertThrowsError(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1,
          preserveManagedSavedState: true, expectedOriginalManifestSHA256: receipt.originalManifestSHA256, io: io))
        XCTAssertEqual(try DoryVZMacDisplayRepair.perform(at: root, keepingDisplayAt: 1,
          preserveManagedSavedState: true, expectedOriginalManifestSHA256: receipt.originalManifestSHA256), receipt)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("sentinel")), sentinel)
      }
    }
  }

  private func withManagedFixture(standalone: Bool = false,
    _ body: (URL, Data, URL, URL) throws -> Void) throws {
    try withRepairFixture(withRAM: standalone) { root, original in
      let parent = root.deletingLastPathComponent()
      let source = parent.appendingPathComponent(DoryVZMacMachineBundle.managedSavedStateName)
      let preserved = parent.appendingPathComponent(DoryVZMacMachineBundle.incompatibleManagedSavedStateName)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try sentinel.write(to: source.appendingPathComponent("sentinel"))
      try body(root, original, source, preserved)
    }
  }

  private enum Injected: Error { case failure }
  private enum Artifact: String {
    case manifest = "machine.json"
    case backup = "machine.before-display-topology-repair.json"
    case receipt = "display-topology-repair.json"
    case journal = "display-topology-repair.pending.json"
    case sourceState = "suspended-state"
    case preservedState = "suspended-state.incompatible-display-topology"
  }
  private var sentinel: Data { Data("preserve-me".utf8) }

  private func url(_ root: URL, _ artifact: Artifact) -> URL {
    root.appendingPathComponent(artifact.rawValue, isDirectory: false)
  }

  private func repair(_ root: URL) throws -> DoryVZMacDisplayRepairReceipt {
    try DoryVZMacMachineBundle.repairPersistedDisplayTopologyForColdBoot(at: root, keepingDisplayAt: 1)
  }

  private func withRepairFixture(
    state: DoryVZMacMachineInstallationState = .suspended, withRAM: Bool = true,
    _ body: (URL, Data) throws -> Void
  ) throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = container.appendingPathComponent("owned-machine", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: container) }
    let original = try legacyManifest(displayCount: 2, state: state)
    try original.write(to: url(root, .manifest))
    if withRAM {
      try FileManager.default.createDirectory(at: url(root, .sourceState), withIntermediateDirectories: false)
      try sentinel.write(to: url(root, .sourceState).appendingPathComponent("sentinel"))
    }
    try body(root, original)
  }

  private func assertRAMPreserved(_ root: URL) throws {
    let source = url(root, .sourceState)
    let preserved = url(root, .preservedState)
    let originalExists = FileManager.default.fileExists(atPath: source.path)
    let preservedExists = FileManager.default.fileExists(atPath: preserved.path)
    XCTAssertNotEqual(originalExists, preservedExists)
    XCTAssertEqual(try Data(contentsOf: (originalExists ? source : preserved).appendingPathComponent("sentinel")), sentinel)
  }

  private func assertCompleted(_ root: URL, original: Data) throws {
    XCTAssertEqual(try Data(contentsOf: url(root, .backup)), original)
    let manifest = try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: Data(contentsOf: url(root, .manifest)))
    XCTAssertEqual(manifest.resources.displays.count, 1)
    XCTAssertEqual(manifest.resources.displays[0].widthInPixels, 1_920)
    XCTAssertEqual(manifest.installationState, .stopped)
    let receipt = try JSONDecoder().decode(DoryVZMacDisplayRepairReceipt.self, from: Data(contentsOf: url(root, .receipt)))
    XCTAssertEqual(receipt.selectedDisplayIndex, 1)
    XCTAssertEqual(receipt.originalManifestBackupName, DoryVZMacMachineBundle.preDisplayRepairManifestName)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .sourceState).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url(root, .journal).path))
    try assertRAMPreserved(root)
  }

  private func legacyManifest(
    displayCount: Int,
    state: DoryVZMacMachineInstallationState
  ) throws -> Data {
    let resources = try DoryVZMacResourcePlan(
      requestedCPUCount: 4,
      requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
      requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
      requestedDisplays: nil,
      minimumCPUCount: 2,
      minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
      maximumCPUCount: 8,
      maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
    )
    let manifest = DoryVZMacMachineManifest(
      createdAt: "2026-09-22T00:00:00Z",
      installationState: state,
      origin: .created,
      parentMachineIdentifierSHA256: nil,
      restoreImageBuild: "26A123",
      restoreImageVersion: "27.0",
      restoreImageSourceURL: "https://example.invalid/restore.ipsw",
      restoreImageBytes: 1,
      restoreImageSHA256: String(repeating: "a", count: 64),
      hardwareModelSHA256: String(repeating: "b", count: 64),
      machineIdentifierSHA256: String(repeating: "c", count: 64),
      macAddress: "02:11:22:33:44:55",
      resources: resources
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
    )
    var resourceObject = try XCTUnwrap(object["resources"] as? [String: Any])
    resourceObject["displays"] = [
      ["widthInPixels": 2_560, "heightInPixels": 1_600, "pixelsPerInch": 220],
      ["widthInPixels": 1_920, "heightInPixels": 1_080, "pixelsPerInch": 144],
    ].prefix(displayCount).map { $0 }
    object["resources"] = resourceObject
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
