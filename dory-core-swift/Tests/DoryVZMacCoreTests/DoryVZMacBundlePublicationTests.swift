import Darwin
import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacBundlePublicationTests: XCTestCase {
  private enum Injected: Error { case failure }

  func testPublishesCompleteNestedBundleWithoutChangingBytes() throws {
    try withFixture { fixture in
      var checkpoints = [DoryVZMacBundlePublication.Checkpoint]()
      var io = DoryVZMacBundlePublication.IO()
      io.checkpoint = { checkpoints.append($0) }
      try fixture.publish(io: io)
      XCTAssertEqual(checkpoints, [.validated, .filesSynced, .bundleSynced, .published, .parentSynced])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
      try fixture.assertComplete(at: fixture.destination)
    }
  }

  func testFlushesEveryFileAndChildDirectoryBeforePublishingAndParentAfterward() throws {
    try withFixture { fixture in
      var kinds = [DoryVZMacBundlePublication.SyncKind]()
      var io = DoryVZMacBundlePublication.IO()
      let realSync = io.sync
      io.sync = { descriptor, kind in
        kinds.append(kind)
        return realSync(descriptor, kind)
      }
      io.checkpoint = { point in
        if point == .bundleSynced {
          XCTAssertEqual(kinds, [.file, .file, .directory, .directory, .drive])
          XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        }
        if point == .published { XCTAssertEqual(kinds.count, 5) }
      }
      try fixture.publish(io: io)
      XCTAssertEqual(kinds, [.file, .file, .directory, .directory, .drive, .directory, .drive])
    }
  }

  func testEveryCheckpointFailureLeavesEitherStagingOrCompleteDestination() throws {
    for point in DoryVZMacBundlePublication.Checkpoint.allCases {
      try withFixture { fixture in
        var io = DoryVZMacBundlePublication.IO()
        io.checkpoint = { if $0 == point { throw Injected.failure } }
        XCTAssertThrowsError(try fixture.publish(io: io))
        let published = point == .published || point == .parentSynced
        XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.destination.path), published)
        try fixture.assertComplete(at: published ? fixture.destination : fixture.staging)
        if published {
          // A retry never rolls back the intact destination or silently creates another VM.
          XCTAssertThrowsError(try fixture.publish())
          try fixture.assertComplete(at: fixture.destination)
        } else {
          try fixture.publish()
          try fixture.assertComplete(at: fixture.destination)
        }
      }
    }
  }

  func testEachSynchronizationFailurePropagatesWithoutPartialDestination() throws {
    for failureIndex in 1...7 {
      try withFixture { fixture in
        var count = 0
        var io = DoryVZMacBundlePublication.IO()
        let realSync = io.sync
        io.sync = { descriptor, kind in
          count += 1
          if count == failureIndex { errno = ENOSPC; return -1 }
          return realSync(descriptor, kind)
        }
        XCTAssertThrowsError(try fixture.publish(io: io))
        let published = failureIndex >= 6
        XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.destination.path), published)
        try fixture.assertComplete(at: published ? fixture.destination : fixture.staging)
      }
    }
  }

  func testInterruptedSynchronizationRetriesTheSameDescriptor() throws {
    try withFixture { fixture in
      var interrupted = false
      var firstDescriptor: Int32?
      var io = DoryVZMacBundlePublication.IO()
      let realSync = io.sync
      io.sync = { descriptor, kind in
        if !interrupted {
          interrupted = true
          firstDescriptor = descriptor
          errno = EINTR
          return -1
        }
        if let first = firstDescriptor { XCTAssertEqual(first, descriptor); firstDescriptor = nil }
        return realSync(descriptor, kind)
      }
      try fixture.publish(io: io)
      try fixture.assertComplete(at: fixture.destination)
    }
  }

  func testExclusivePublicationPreservesFilesDirectoriesAndDanglingSymlinks() throws {
    for kind in ["file", "directory", "symlink"] {
      try withFixture { fixture in
        var io = DoryVZMacBundlePublication.IO()
        io.checkpoint = { point in
          guard point == .bundleSynced else { return }
          switch kind {
          case "file": try Data("existing-user-file".utf8).write(to: fixture.destination)
          case "directory":
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
          default: XCTAssertEqual(symlink("absent-target", fixture.destination.path), 0)
          }
        }
        XCTAssertThrowsError(try fixture.publish(io: io))
        try fixture.assertComplete(at: fixture.staging)
        var information = stat()
        XCTAssertEqual(lstat(fixture.destination.path, &information), 0)
        if kind == "file" {
          XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("existing-user-file".utf8))
        }
        if kind == "symlink" { XCTAssertEqual(information.st_mode & S_IFMT, S_IFLNK) }
      }
    }
  }

  func testUnknownEntryIsPreservedAndBlocksPublication() throws {
    try withFixture { fixture in
      let unknown = fixture.staging.appendingPathComponent("future-user-data")
      let data = Data("preserve".utf8)
      try data.write(to: unknown)
      XCTAssertThrowsError(try fixture.publish())
      XCTAssertEqual(try Data(contentsOf: unknown), data)
      try fixture.assertComplete(at: fixture.staging)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  func testEmptyMissingLinkedNonregularOrWritableArtifactCannotPublish() throws {
    for kind in ["empty", "missing", "symlink", "hardlink", "fifo", "writable"] {
      try withFixture { fixture in
        let file = fixture.staging.appendingPathComponent(fixture.files[0])
        if kind != "writable" { try FileManager.default.removeItem(at: file) }
        switch kind {
        case "empty": try Data().write(to: file)
        case "symlink": XCTAssertEqual(symlink("data-disks/data-01.img", file.path), 0)
        case "hardlink":
          XCTAssertEqual(link(fixture.staging.appendingPathComponent(fixture.files[1]).path, file.path), 0)
        case "fifo": XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        case "writable": XCTAssertEqual(chmod(file.path, 0o666), 0)
        default: break
        }
        XCTAssertThrowsError(try fixture.publish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
      }
    }
  }

  func testReplacementOrMutationAfterValidationCannotPublish() throws {
    for replacement in [false, true] {
      try withFixture { fixture in
        var io = DoryVZMacBundlePublication.IO()
        io.checkpoint = { point in
          guard point == .filesSynced else { return }
          let file = fixture.staging.appendingPathComponent(fixture.files[0])
          if replacement { try FileManager.default.removeItem(at: file) }
          try Data("different-payload".utf8).write(to: file)
        }
        XCTAssertThrowsError(try fixture.publish(io: io))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(
          try Data(contentsOf: fixture.staging.appendingPathComponent(fixture.files[0])),
          Data("different-payload".utf8)
        )
      }
    }
  }

  func testReplacingParentCannotRedirectPublication() throws {
    try withFixture { fixture in
      let relocated = fixture.root.appendingPathComponent("relocated", isDirectory: true)
      var io = DoryVZMacBundlePublication.IO()
      io.checkpoint = { point in
        guard point == .bundleSynced else { return }
        try FileManager.default.moveItem(at: fixture.parent, to: relocated)
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: false)
      }
      XCTAssertThrowsError(try fixture.publish(io: io))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
      try fixture.assertComplete(at: relocated.appendingPathComponent(fixture.staging.lastPathComponent))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path), [])
    }
  }

  func testReplacingDataDirectoryCannotPublishOrFollowSymlink() throws {
    try withFixture { fixture in
      var io = DoryVZMacBundlePublication.IO()
      io.checkpoint = { point in
        guard point == .filesSynced else { return }
        let data = fixture.staging.appendingPathComponent("data-disks")
        try FileManager.default.moveItem(at: data, to: fixture.root.appendingPathComponent("retained"))
        XCTAssertEqual(symlink(fixture.root.appendingPathComponent("retained").path, data.path), 0)
      }
      XCTAssertThrowsError(try fixture.publish(io: io))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
      XCTAssertEqual(
        try Data(contentsOf: fixture.root.appendingPathComponent("retained/data-01.img")),
        fixture.payload
      )
    }
  }

  func testRejectsUnsafePathsAndUnboundedOrDuplicateSetsBeforeMutation() throws {
    for files in [["../machine.json"], ["machine.json", "machine.json"],
                  Array(repeating: "machine.json", count: 33), ["a/b/c"], ["machine.json\0suffix"]] {
      try withFixture { fixture in
        XCTAssertThrowsError(try DoryVZMacBundlePublication.publish(
          staging: fixture.staging, to: fixture.destination, relativeFiles: files
        ))
        try fixture.assertComplete(at: fixture.staging)
      }
    }
    try withFixture { fixture in
      XCTAssertThrowsError(try DoryVZMacBundlePublication.publish(
        staging: fixture.staging, to: fixture.root.appendingPathComponent("other"), relativeFiles: fixture.files
      ))
      XCTAssertThrowsError(try DoryVZMacBundlePublication.publish(
        staging: fixture.staging, to: fixture.staging, relativeFiles: fixture.files
      ))
    }
  }

  private struct Fixture {
    let root: URL
    let parent: URL
    let staging: URL
    let destination: URL
    let files = [DoryVZMacMachineBundle.manifestName, "data-disks/data-01.img"]
    let payload = Data("owned-test-payload".utf8)

    func publish(io: DoryVZMacBundlePublication.IO = .init()) throws {
      try DoryVZMacBundlePublication.publish(
        staging: staging, to: destination, relativeFiles: files, io: io
      )
    }

    func assertComplete(at directory: URL) throws {
      for path in files { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)), payload) }
    }
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let parent = root.appendingPathComponent("parent", isDirectory: true)
    let staging = parent.appendingPathComponent(".owned-staging", isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging.appendingPathComponent("data-disks", isDirectory: true),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture(root: root, parent: parent, staging: staging,
                          destination: parent.appendingPathComponent("published", isDirectory: true))
    for file in fixture.files {
      let url = staging.appendingPathComponent(file)
      try fixture.payload.write(to: url)
      XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    try body(fixture)
  }
}
