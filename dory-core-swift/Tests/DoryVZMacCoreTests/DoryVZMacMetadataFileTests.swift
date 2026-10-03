import Darwin
import Foundation
import XCTest

@testable import DoryVZMacCore

final class DoryVZMacMetadataFileTests: XCTestCase {
  func testPublicationFlushesDataBeforeRenameAndDirectoryBeforeSuccess() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("machine.json")
      let old = Data("old".utf8)
      let new = Data("new".utf8)
      try old.write(to: url)
      var events: [String] = []
      var io = DoryVZMacMetadataFile.WriteIO()
      let systemSync = io.sync
      io.sync = { descriptor, kind in
        events.append("\(kind)")
        return systemSync(descriptor, kind)
      }
      io.checkpoint = { point in
        if point == .fileSynced { XCTAssertEqual(try Data(contentsOf: url), old) }
        if point == .published {
          events.append("rename")
          XCTAssertEqual(try Data(contentsOf: url), new)
        }
      }
      try DoryVZMacMetadataFile.write(new, to: url, io: io)
      XCTAssertEqual(events, ["file", "drive", "rename", "directory", "drive"])
      XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), new)
      var status = stat()
      XCTAssertEqual(lstat(url.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o777, 0o600)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["machine.json"])
    }
  }

  func testShortWritesAndInterruptionsCannotPublishTruncatedMetadata() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      let bytes = Data(repeating: 0x5a, count: 150_000)
      var io = DoryVZMacMetadataFile.WriteIO()
      var writeCount = 0
      var syncInterrupted = false
      let systemSync = io.sync
      io.write = { descriptor, buffer, count in
        writeCount += 1
        if writeCount == 1 { errno = EINTR; return -1 }
        return Darwin.write(descriptor, buffer, min(count, 997))
      }
      io.sync = { descriptor, kind in
        if !syncInterrupted { syncInterrupted = true; errno = EINTR; return -1 }
        return systemSync(descriptor, kind)
      }
      try DoryVZMacMetadataFile.write(bytes, to: url, io: io)
      XCTAssertGreaterThan(writeCount, 100)
      XCTAssertTrue(syncInterrupted)
      XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), bytes)
    }
  }

  func testFullDiskAfterPartialWritePreservesPreviousJournal() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      let old = Data("previous complete journal".utf8)
      try old.write(to: url)
      var io = DoryVZMacMetadataFile.WriteIO()
      var calls = 0
      io.write = { descriptor, buffer, count in
        calls += 1
        if calls == 1 { return Darwin.write(descriptor, buffer, min(count, 3)) }
        errno = ENOSPC
        return -1
      }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data(repeating: 1, count: 200), to: url, io: io)) {
        XCTAssertEqual($0 as? DoryVZMacMetadataFileError, .filesystem("write metadata", ENOSPC))
      }
      XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), old)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["journal.json"])
    }
  }

  func testZeroWriteFailsInsteadOfSpinningOrPublishing() throws {
    try withDirectory { root in
      var io = DoryVZMacMetadataFile.WriteIO()
      io.write = { _, _, _ in 0 }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(
        Data("new".utf8), to: root.appendingPathComponent("journal.json"), io: io
      ))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
  }

  func testEveryInterruptedPublicationBoundaryLeavesOldOrNewCompleteBytes() throws {
    for boundary in [DoryVZMacMetadataFile.Checkpoint.temporaryCreated,
      .bytesWritten, .fileSynced, .published, .directorySynced]
    {
      try withDirectory { root in
        let url = root.appendingPathComponent("journal.json")
        let old = Data("old complete journal".utf8)
        let new = Data("new complete journal".utf8)
        try old.write(to: url)
        var io = DoryVZMacMetadataFile.WriteIO()
        io.checkpoint = { if $0 == boundary { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try DoryVZMacMetadataFile.write(new, to: url, io: io))
        let expected = boundary == .published || boundary == .directorySynced ? new : old
        XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), expected, "\(boundary)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["journal.json"])
      }
    }
  }

  func testSyncErrorsArePropagatedWithoutFalseSuccessOrRollback() throws {
    // file fsync, pre-publication full flush, directory fsync, post-publication full flush.
    for failingCall in 1...4 {
      try withDirectory { root in
        let url = root.appendingPathComponent("journal.json")
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        try old.write(to: url)
        var io = DoryVZMacMetadataFile.WriteIO()
        let systemSync = io.sync
        var calls = 0
        io.sync = { descriptor, kind in
          calls += 1
          if calls == failingCall { errno = EIO; return -1 }
          return systemSync(descriptor, kind)
        }
        XCTAssertThrowsError(try DoryVZMacMetadataFile.write(new, to: url, io: io))
        XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), failingCall < 3 ? old : new)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["journal.json"])
      }
    }
  }

  func testExclusivePublicationNeverOverwritesExistingReceipt() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("receipt.json")
      try DoryVZMacMetadataFile.write(Data("original".utf8), to: url, replacingExisting: false)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(
        Data("replacement".utf8), to: url, replacingExisting: false
      ))
      XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), Data("original".utf8))
    }
  }

  func testRejectsSymlinkHardlinkAndFIFOForReadWriteAndRemoval() throws {
    try withDirectory { root in
      let target = root.appendingPathComponent("target.json")
      let original = Data("do not change".utf8)
      try original.write(to: target)
      let symlinkURL = root.appendingPathComponent("symlink.json")
      XCTAssertEqual(symlink(target.path, symlinkURL.path), 0)
      let hardlinkURL = root.appendingPathComponent("hardlink.json")
      XCTAssertEqual(link(target.path, hardlinkURL.path), 0)
      let fifoURL = root.appendingPathComponent("fifo.json")
      XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0)
      for url in [symlinkURL, hardlinkURL, fifoURL] {
        XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url))
        XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url))
        XCTAssertThrowsError(try DoryVZMacMetadataFile.remove(at: url))
      }
      XCTAssertEqual(try Data(contentsOf: target), original)
    }
  }

  func testDanglingSymlinkIsNotTreatedAsMissingJournal() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      XCTAssertEqual(symlink(root.appendingPathComponent("missing").path, url.path), 0)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.readIfPresent(from: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url))
      XCTAssertNil(try DoryVZMacMetadataFile.readIfPresent(from: root.appendingPathComponent("absent.json")))
    }
  }

  func testLegacyReadableMetadataIsAcceptedButSharedWritableMetadataIsRejected() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      try Data("legacy".utf8).write(to: url)
      XCTAssertEqual(chmod(url.path, 0o644), 0)
      XCTAssertEqual(try DoryVZMacMetadataFile.read(from: url), Data("legacy".utf8))
      XCTAssertEqual(chmod(url.path, 0o664), 0)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.remove(at: url))
    }
  }

  func testEmptyOversizeAndNonFileDestinationsAreRejected() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data(), to: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data(repeating: 1, count: 5), to: url, maximumBytes: 4))
      try Data(repeating: 1, count: 5).write(to: url)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url, maximumBytes: 4))
      try Data().write(to: url)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url, maximumBytes: 0))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("x".utf8), to: URL(string: "https://example.invalid/file")!))
    }
  }

  func testReadDetectsSameLengthMutationAndPathReplacement() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      try Data("old".utf8).write(to: url)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url, afterRead: {
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("new".utf8))
        try handle.close()
      }))
      let replacement = root.appendingPathComponent("replacement.json")
      try Data("replacement".utf8).write(to: replacement)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url, afterOpen: {
        XCTAssertEqual(rename(replacement.path, url.path), 0)
      }))
    }
  }

  func testParentReplacementCannotRedirectPublicationOrCleanup() throws {
    try withDirectory { parent in
      let root = parent.appendingPathComponent("bundle", isDirectory: true)
      let moved = parent.appendingPathComponent("moved", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let url = root.appendingPathComponent("journal.json")
      try Data("old".utf8).write(to: url)
      var io = DoryVZMacMetadataFile.WriteIO()
      io.checkpoint = { point in
        if point == .bytesWritten {
          try FileManager.default.moveItem(at: root, to: moved)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
          try Data("unrelated".utf8).write(to: url)
        }
      }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url, io: io))
      XCTAssertEqual(try Data(contentsOf: url), Data("unrelated".utf8))
      XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("journal.json")), Data("old".utf8))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["journal.json"])
    }
  }

  func testReplacedTemporaryEntryIsNotPublishedOrDeleted() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      try Data("old".utf8).write(to: url)
      var replacedURL: URL?
      var io = DoryVZMacMetadataFile.WriteIO()
      io.checkpoint = { point in
        if point == .fileSynced {
          let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix(".dory-metadata-") })
          let temporary = root.appendingPathComponent(name)
          XCTAssertEqual(unlink(temporary.path), 0)
          try Data("unrelated replacement".utf8).write(to: temporary)
          replacedURL = temporary
        }
      }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url, io: io))
      XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacedURL)), Data("unrelated replacement".utf8))
    }
  }

  func testDestinationReplacedAfterRenameIsNotReportedCommittedOrRolledBack() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      try Data("old".utf8).write(to: url)
      var io = DoryVZMacMetadataFile.WriteIO()
      io.checkpoint = { point in
        if point == .published {
          XCTAssertEqual(unlink(url.path), 0)
          try Data("unrelated replacement".utf8).write(to: url)
        }
      }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url, io: io))
      XCTAssertEqual(try Data(contentsOf: url), Data("unrelated replacement".utf8))
    }
  }

  func testSymlinkOrSharedWritableParentIsRejected() throws {
    try withDirectory { parent in
      let root = parent.appendingPathComponent("bundle", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let url = root.appendingPathComponent("journal.json")
      try Data("old".utf8).write(to: url)
      let alias = parent.appendingPathComponent("alias", isDirectory: true)
      XCTAssertEqual(symlink(root.path, alias.path), 0)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: alias.appendingPathComponent("journal.json")))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: alias.appendingPathComponent("journal.json")))
      XCTAssertEqual(chmod(root.path, 0o775), 0)
      XCTAssertThrowsError(try DoryVZMacMetadataFile.read(from: url))
      XCTAssertThrowsError(try DoryVZMacMetadataFile.write(Data("new".utf8), to: url))
    }
  }

  func testJournalRemovalFlushesDirectoryAndReportsFlushFailure() throws {
    try withDirectory { root in
      let url = root.appendingPathComponent("journal.json")
      try DoryVZMacMetadataFile.write(Data("committed".utf8), to: url)
      var kinds: [DoryVZMacMetadataFile.SyncKind] = []
      var io = DoryVZMacMetadataFile.WriteIO()
      let systemSync = io.sync
      io.sync = { descriptor, kind in
        kinds.append(kind)
        return systemSync(descriptor, kind)
      }
      try DoryVZMacMetadataFile.remove(at: url, io: io)
      XCTAssertEqual(kinds, [.directory, .drive])
      XCTAssertNil(try DoryVZMacMetadataFile.readIfPresent(from: url))
      try DoryVZMacMetadataFile.write(Data("committed".utf8), to: url)
      io.sync = { _, _ in errno = EIO; return -1 }
      XCTAssertThrowsError(try DoryVZMacMetadataFile.remove(at: url, io: io))
    }
  }

  private enum InjectedFailure: Error { case interrupted }

  private func withDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }
}
