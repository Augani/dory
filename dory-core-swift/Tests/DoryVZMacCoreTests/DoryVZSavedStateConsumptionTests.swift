import Darwin
import Foundation
import XCTest

@testable import DoryVZMacCore

final class DoryVZSavedStateConsumptionTests: XCTestCase {
  func testConsumptionIsDurableExclusiveAndDoesNotChangeRAMBytes() throws {
    try withState { url in
      let original = try Data(contentsOf: url)
      XCTAssertFalse(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(
        stateURL: URL(fileURLWithPath: url.path + "\0suffix")
      ))
      try DoryVZSavedStateConsumption.consume(stateURL: url)
      XCTAssertTrue(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.requireUnconsumed(stateURL: url)) {
        XCTAssertEqual($0 as? DoryVZMacSavedStateError, .alreadyConsumed)
      }
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertEqual(try Data(contentsOf: url), original)
      let marker = url.deletingLastPathComponent().appendingPathComponent(DoryVZSavedStateConsumption.markerName)
      var status = stat()
      XCTAssertEqual(lstat(marker.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o777, 0o600)
      let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
      XCTAssertEqual(receipt["stateFileName"] as? String, "state.bin")
      XCTAssertEqual(receipt["stateBytes"] as? Int, original.count)
    }
  }

  func testEveryPublicationInterruptionForbidsReplayIfMarkerBecameVisible() throws {
    for boundary in [DoryVZMacMetadataFile.Checkpoint.temporaryCreated,
      .bytesWritten, .fileSynced, .published, .directorySynced]
    {
      try withState { url in
        var io = DoryVZMacMetadataFile.WriteIO()
        io.checkpoint = { if $0 == boundary { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url, io: io))
        let published = boundary == .published || boundary == .directorySynced
        XCTAssertEqual(try DoryVZSavedStateConsumption.isConsumed(stateURL: url), published)
        if published {
          XCTAssertThrowsError(try DoryVZSavedStateConsumption.requireUnconsumed(stateURL: url))
        } else {
          XCTAssertNoThrow(try DoryVZSavedStateConsumption.requireUnconsumed(stateURL: url))
        }
      }
    }
  }

  func testConsumptionFlushFailureNeverReportsSuccessOrRemovesPublishedFence() throws {
    for failureCall in 1...4 {
      try withState { url in
        var io = DoryVZMacMetadataFile.WriteIO()
        let systemSync = io.sync
        var calls = 0
        io.sync = { descriptor, kind in
          calls += 1
          if calls == failureCall { errno = EIO; return -1 }
          return systemSync(descriptor, kind)
        }
        XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url, io: io))
        XCTAssertEqual(try DoryVZSavedStateConsumption.isConsumed(stateURL: url), failureCall >= 3)
      }
    }
  }

  func testFullDiskCannotConsumeOrMutatePayload() throws {
    try withState { url in
      let original = try Data(contentsOf: url)
      var io = DoryVZMacMetadataFile.WriteIO()
      io.write = { _, _, _ in errno = ENOSPC; return -1 }
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url, io: io))
      XCTAssertFalse(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
      XCTAssertEqual(try Data(contentsOf: url), original)
    }
  }

  func testAnyMarkerEntryIncludingDanglingLinkIsDenyOnly() throws {
    try withState { url in
      let root = url.deletingLastPathComponent()
      let marker = root.appendingPathComponent(DoryVZSavedStateConsumption.markerName)
      XCTAssertEqual(symlink(root.appendingPathComponent("absent").path, marker.path), 0)
      XCTAssertTrue(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertEqual(unlink(marker.path), 0)
      try Data().write(to: marker)
      XCTAssertTrue(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.requireUnconsumed(stateURL: url))
    }
  }

  func testNonPrivateLinkedEmptyAndMissingPayloadsCannotBeConsumed() throws {
    try withState { url in
      XCTAssertEqual(chmod(url.path, 0o644), 0)
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertEqual(chmod(url.path, 0o600), 0)
      let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
      XCTAssertEqual(link(url.path, alias.path), 0)
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertEqual(unlink(alias.path), 0)
      try Data().write(to: url)
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertEqual(unlink(url.path), 0)
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.consume(stateURL: url))
      XCTAssertFalse(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
    }
  }

  func testOrdinaryResumeRejectsUncommittedRestoreAndSuspendManifests() throws {
    XCTAssertNoThrow(try DoryVZMacRuntime.validateResumeInstallationState(.stopped))
    for state in [DoryVZMacMachineInstallationState.suspended, .restoring, .suspending,
      .prepared, .installing, .installFailed]
    {
      XCTAssertThrowsError(try DoryVZMacRuntime.validateResumeInstallationState(state))
    }
  }

  func testStandaloneRetirementInvalidatesReceiptBeforeRetiringConsumptionFence() throws {
    try withState(fileName: DoryVZMacSavedStateArtifact.stateName) { url in
      let root = url.deletingLastPathComponent()
      let receipt = root.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)
      try Data("receipt".utf8).write(to: receipt)
      try DoryVZSavedStateConsumption.consume(stateURL: url)
      XCTAssertThrowsError(try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root, afterReceiptRetirement: {
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertTrue(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        throw InjectedFailure.interrupted
      }))
      try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
  }

  func testPartialStandaloneCleanupWithNoReceiptOrMarkerCanFinishIdempotently() throws {
    try withState(fileName: DoryVZMacSavedStateArtifact.stateName) { url in
      let root = url.deletingLastPathComponent()
      // The receipt was durably retired, then cleanup removed the marker before interruption.
      try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
  }

  func testStandaloneCleanupPreservesUnconsumedSnapshotsAndUnknownFiles() throws {
    try withState(fileName: DoryVZMacSavedStateArtifact.stateName) { url in
      let root = url.deletingLastPathComponent()
      let receipt = root.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)
      let receiptBytes = Data("receipt".utf8)
      try receiptBytes.write(to: receipt)
      XCTAssertThrowsError(try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root))
      XCTAssertEqual(try Data(contentsOf: receipt), receiptBytes)
      try DoryVZSavedStateConsumption.consume(stateURL: url)
      let unknown = root.appendingPathComponent("future-format.json")
      try Data("preserve".utf8).write(to: unknown)
      XCTAssertThrowsError(try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root))
      XCTAssertEqual(try Data(contentsOf: receipt), receiptBytes)
      XCTAssertEqual(try Data(contentsOf: unknown), Data("preserve".utf8))
      XCTAssertTrue(try DoryVZSavedStateConsumption.isConsumed(stateURL: url))
    }
  }

  func testKilledWriterTemporaryMetadataIsRetiredButImitationsArePreserved() throws {
    try withState(fileName: DoryVZMacSavedStateArtifact.stateName) { url in
      let root = url.deletingLastPathComponent()
      let orphan = root.appendingPathComponent(".dory-metadata-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.tmp")
      XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data(),
        attributes: [.posixPermissions: 0o600]))
      XCTAssertTrue(try DoryVZSavedStateConsumption.isAbandonedMetadataFile(at: orphan))
      let imitation = root.appendingPathComponent(".dory-metadata-not-a-uuid.tmp")
      try Data("unrelated".utf8).write(to: imitation)
      XCTAssertFalse(try DoryVZSavedStateConsumption.isAbandonedMetadataFile(at: imitation))
      XCTAssertThrowsError(try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root))
      XCTAssertEqual(try Data(contentsOf: imitation), Data("unrelated".utf8))
      XCTAssertEqual(chmod(orphan.path, 0o644), 0)
      XCTAssertThrowsError(try DoryVZSavedStateConsumption.isAbandonedMetadataFile(at: orphan))
      XCTAssertEqual(chmod(orphan.path, 0o600), 0)
      XCTAssertEqual(unlink(imitation.path), 0)
      try DoryVZMacSavedStateArtifact.retireConsumedArtifact(at: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
  }

  private enum InjectedFailure: Error { case interrupted }

  private func withState(fileName: String = "state.bin", _ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-state-consume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent(fileName)
    try Data("saved RAM remains intact".utf8).write(to: url)
    XCTAssertEqual(chmod(url.path, 0o600), 0)
    try body(url)
  }
}
