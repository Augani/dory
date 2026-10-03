import Darwin
import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacSavedStateRetirementTests: XCTestCase {
  private enum Interrupted: Error { case test }

  func testConsumedOnlyPolicyPreservesUnconsumedSnapshotButExplicitDiscardCanRetireIt() throws {
    try withFixture { fixture in
      try FileManager.default.removeItem(at: fixture.marker)
      XCTAssertThrowsError(try fixture.retire(policy: .consumedOnly))
      XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
      try fixture.retire()
      try fixture.assertRetired()
    }
  }

  func testAllRetirementCheckpointsLeaveNonReplayableStateAndRetryIdempotently() throws {
    for point in DoryVZMacSavedStateRetirement.Checkpoint.allCases {
      try withFixture { fixture in
        var io = DoryVZMacSavedStateRetirement.IO()
        io.checkpoint = { if $0 == point { throw Interrupted.test } }
        XCTAssertThrowsError(try fixture.retire(io: io))
        if point == .validated {
          XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
        } else { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path)) }
        if [.receiptRemoved, .receiptInvalidationDurable].contains(point) {
          XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
          XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
        }
        try fixture.retire(policy: .consumedOnly)
        try fixture.retire(policy: .consumedOnly)
        try fixture.assertRetired()
      }
    }
  }

  func testEveryFlushFailurePropagatesAndDoesNotRearmRAM() throws {
    for failureIndex in 1...6 {
      try withFixture { fixture in
        var count = 0
        var io = DoryVZMacSavedStateRetirement.IO()
        let realSync = io.metadata.sync
        io.metadata.sync = { descriptor, kind in
          count += 1
          if count == failureIndex { errno = EIO; return -1 }
          return realSync(descriptor, kind)
        }
        XCTAssertThrowsError(try fixture.retire(io: io))
        XCTAssertEqual(count, failureIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        try fixture.retire(policy: .consumedOnly)
        try fixture.assertRetired()
      }
    }
  }

  func testEveryUnlinkFailureKeepsKnownOldOrInvalidatedStateAndCanRetry() throws {
    for failureIndex in 1...4 {
      try withFixture { fixture in
        var count = 0
        var io = DoryVZMacSavedStateRetirement.IO()
        let realUnlink = io.unlink
        io.unlink = { directory, name, flags in
          count += 1
          if count == failureIndex { errno = EBUSY; return -1 }
          return realUnlink(directory, name, flags)
        }
        XCTAssertThrowsError(try fixture.retire(io: io))
        XCTAssertEqual(count, failureIndex)
        if failureIndex == 1 {
          XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
          XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
        } else { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path)) }
        try fixture.retire(policy: .consumedOnly)
        try fixture.assertRetired()
      }
    }
  }

  func testReceiptInvalidationIsFullyFlushedBeforeMarkerOrPayloadUnlink() throws {
    try withFixture { fixture in
      var kinds = [DoryVZMacMetadataFile.SyncKind]()
      var removals = [String]()
      var io = DoryVZMacSavedStateRetirement.IO()
      let realSync = io.metadata.sync
      let realUnlink = io.unlink
      io.metadata.sync = { descriptor, kind in kinds.append(kind); return realSync(descriptor, kind) }
      io.unlink = { directory, name, flags in
        if name != DoryVZMacSavedStateArtifact.receiptName {
          XCTAssertEqual(Array(kinds.prefix(2)), [.directory, .drive])
        }
        removals.append(name)
        return realUnlink(directory, name, flags)
      }
      try fixture.retire(io: io)
      XCTAssertEqual(removals.first, DoryVZMacSavedStateArtifact.receiptName)
      XCTAssertEqual(kinds, [.directory, .drive, .directory, .drive, .directory, .drive])
    }
  }

  func testInterruptedUnlinkAndFlushRetryRatherThanDroppingErrors() throws {
    try withFixture { fixture in
      var unlinkInterrupted = false
      var syncInterrupted = false
      var io = DoryVZMacSavedStateRetirement.IO()
      let realSync = io.metadata.sync
      let realUnlink = io.unlink
      io.metadata.sync = { descriptor, kind in
        if !syncInterrupted { syncInterrupted = true; errno = EINTR; return -1 }
        return realSync(descriptor, kind)
      }
      io.unlink = { directory, name, flags in
        if !unlinkInterrupted { unlinkInterrupted = true; errno = EINTR; return -1 }
        return realUnlink(directory, name, flags)
      }
      try fixture.retire(io: io)
      XCTAssertTrue(unlinkInterrupted)
      XCTAssertTrue(syncInterrupted)
      try fixture.assertRetired()
    }
  }

  func testUnknownFilesDirectoriesAndTemporaryImitationsBlockBeforeAnyDeletion() throws {
    for kind in ["file", "directory", "imitation"] {
      try withFixture { fixture in
        let unknown = fixture.root.appendingPathComponent(kind == "imitation" ? ".dory-metadata-not-a-uuid.tmp" : "future-data")
        if kind == "directory" {
          try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        } else { try Data("preserve".utf8).write(to: unknown) }
        XCTAssertThrowsError(try fixture.retire())
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
      }
    }
  }

  func testLinkedNonregularWritableAndUnsharedViolationsArePreserved() throws {
    for kind in ["receipt-symlink", "state-symlink", "marker-symlink", "hardlink", "fifo", "writable"] {
      try withFixture { fixture in
        let file = kind == "receipt-symlink" ? fixture.receipt : kind == "marker-symlink" ? fixture.marker : fixture.state
        if kind != "writable" { try FileManager.default.removeItem(at: file) }
        switch kind {
        case "hardlink": XCTAssertEqual(link(fixture.disk.path, file.path), 0)
        case "fifo": XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        case "writable": XCTAssertEqual(chmod(file.path, 0o666), 0)
        default: XCTAssertEqual(symlink("absent-target", file.path), 0)
        }
        XCTAssertThrowsError(try fixture.retire())
        var information = stat()
        XCTAssertEqual(lstat(file.path, &information), 0)
        if kind != "receipt-symlink" { XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes) }
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.diskBytes)
      }
    }
  }

  func testExactPrivateAbandonedMetadataCanRetireButNonprivateCopyCannot() throws {
    try withFixture { fixture in
      let orphan = fixture.root.appendingPathComponent(".dory-metadata-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.tmp")
      XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
      XCTAssertThrowsError(try fixture.retire())
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
      XCTAssertEqual(chmod(orphan.path, 0o600), 0)
      try fixture.retire()
      try fixture.assertRetired()
    }
  }

  func testNewUnknownFileAfterReceiptRetirementIsPreservedAndBlocksPayloadRemoval() throws {
    try withFixture { fixture in
      let unknown = fixture.root.appendingPathComponent("future-format")
      var io = DoryVZMacSavedStateRetirement.IO()
      io.checkpoint = { point in
        if point == .receiptInvalidationDurable { try Data("preserve".utf8).write(to: unknown) }
      }
      XCTAssertThrowsError(try fixture.retire(io: io))
      XCTAssertEqual(try Data(contentsOf: unknown), Data("preserve".utf8))
      XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
    }
  }

  func testReplacedArtifactAndRootCannotBeDeletedUnderPinnedIdentity() throws {
    for replaceRoot in [false, true] {
      try withFixture { fixture in
        let retained = fixture.parent.appendingPathComponent("retained")
        var io = DoryVZMacSavedStateRetirement.IO()
        io.checkpoint = { point in
          guard point == .validated else { return }
          if replaceRoot {
            try FileManager.default.moveItem(at: fixture.root, to: retained)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: fixture.root.appendingPathComponent("unrelated"))
          } else {
            try FileManager.default.moveItem(at: fixture.state, to: retained)
            try Data("replacement".utf8).write(to: fixture.state)
          }
        }
        XCTAssertThrowsError(try fixture.retire(io: io))
        if replaceRoot {
          XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("unrelated")), Data("replacement".utf8))
          XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)), fixture.receiptBytes)
        } else {
          XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.receiptBytes)
          XCTAssertEqual(try Data(contentsOf: retained), fixture.ram)
          XCTAssertEqual(try Data(contentsOf: fixture.state), Data("replacement".utf8))
        }
      }
    }
  }

  func testEmptyAndAbsentDirectoryRetryFlushesParentWithoutRecreatingRAM() throws {
    try withFixture { fixture in
      for file in [fixture.receipt, fixture.state, fixture.marker] { try FileManager.default.removeItem(at: file) }
      try fixture.retire()
      try fixture.retire()
      try fixture.assertRetired()
    }
  }

  func testEveryFailedRAMPublicationBoundaryRetiresBothPathsBeforeLiveResumeIsAllowed() throws {
    for point in DoryVZMacBundlePublication.Checkpoint.allCases {
      try withFixture { fixture in
        let staging = fixture.parent.appendingPathComponent(".suspended-state.creating-owned-test", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: staging)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(DoryVZSavedStateConsumption.markerName))
        var publication = DoryVZMacBundlePublication.IO()
        publication.checkpoint = { if $0 == point { throw Interrupted.test } }
        XCTAssertThrowsError(try DoryVZMacBundlePublication.publish(
          staging: staging, to: fixture.root,
          relativeFiles: [DoryVZMacSavedStateArtifact.stateName, DoryVZMacSavedStateArtifact.receiptName],
          barrierFile: DoryVZMacSavedStateArtifact.receiptName, io: publication
        ))
        try DoryVZMacSavedStateRetirement.retireFailedSuspension(
          staging: staging, published: fixture.root, barrierFileURL: fixture.manifest
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        try fixture.assertRetired()
      }
    }
  }

  func testFailedSuspensionRetirementCannotAllowResumeWhenUnknownFilesOrFlushErrorsRemain() throws {
    for unknown in [false, true] {
      try withFixture { fixture in
        let staging = fixture.parent.appendingPathComponent("absent-staging", isDirectory: true)
        let future = fixture.root.appendingPathComponent("future-data")
        if unknown { try Data("preserve".utf8).write(to: future) }
        var io = DoryVZMacSavedStateRetirement.IO()
        if !unknown { io.metadata.sync = { _, _ in errno = EIO; return -1 } }
        XCTAssertThrowsError(try DoryVZMacSavedStateRetirement.retireFailedSuspension(
          staging: staging, published: fixture.root, barrierFileURL: fixture.manifest, io: io
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ram)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.diskBytes)
        if unknown { XCTAssertEqual(try Data(contentsOf: future), Data("preserve".utf8)) }
      }
    }
  }

  private struct Fixture {
    let parent: URL
    let root: URL
    let ram = Data("known-RAM".utf8)
    let receiptBytes = Data("owned-receipt".utf8)
    let diskBytes = Data("guest-disk-must-survive".utf8)
    var state: URL { root.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName) }
    var receipt: URL { root.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName) }
    var marker: URL { root.appendingPathComponent(DoryVZSavedStateConsumption.markerName) }
    var disk: URL { parent.appendingPathComponent(DoryVZMacMachineBundle.diskName) }
    var manifest: URL { parent.appendingPathComponent(DoryVZMacMachineBundle.manifestName) }
    func retire(policy: DoryVZMacSavedStateRetirement.Policy = .explicitColdRecovery, io: DoryVZMacSavedStateRetirement.IO = .init()) throws {
      try DoryVZMacSavedStateRetirement.retire(at: root, policy: policy, barrierFileURL: manifest, io: io)
    }
    func assertRetired() throws {
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
      XCTAssertEqual(try Data(contentsOf: disk), diskBytes)
      XCTAssertEqual(try Data(contentsOf: manifest), Data("owned-manifest".utf8))
    }
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent(DoryVZMacMachineBundle.suspendedStateDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: parent) }
    let fixture = Fixture(parent: parent, root: root)
    for (file, data) in [(fixture.state, fixture.ram), (fixture.receipt, fixture.receiptBytes),
                         (fixture.marker, Data("deny-only".utf8)), (fixture.manifest, Data("owned-manifest".utf8)), (fixture.disk, fixture.diskBytes)] {
      try data.write(to: file)
      XCTAssertEqual(chmod(file.path, 0o600), 0)
    }
    try body(fixture)
  }
}
