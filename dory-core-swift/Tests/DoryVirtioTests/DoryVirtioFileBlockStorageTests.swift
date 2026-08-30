import Darwin
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioFileBlockStorageTests {
  @Test func persistsWritesFlushesZeroesAndReadOnlyReopens() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "disk.raw")

    do {
      let storage = try DoryVirtioFileBlockStorage.create(at: url, capacityBytes: 4096)
      try storage.write(offset: 512, bytes: [1, 2, 3, 4])
      try storage.flush()
      #expect(try storage.read(offset: 512, byteCount: 4) == [1, 2, 3, 4])
      try storage.writeZeroes(offset: 513, byteCount: 2, mayUnmap: false)
      #expect(try storage.read(offset: 512, byteCount: 4) == [1, 0, 0, 4])
      try storage.discard(offset: 512, byteCount: 4)
      #expect(try storage.read(offset: 512, byteCount: 4) == [0, 0, 0, 0])
    }

    let readOnly = try DoryVirtioFileBlockStorage(
      existingFileURL: url,
      readOnly: true
    )
    #expect(readOnly.capacityBytes == 4096)
    #expect(throws: DoryVirtioBlockError.malformedRequest) {
      try readOnly.write(offset: 0, bytes: [1])
    }
  }

  @Test func rejectsSymlinksExistingTargetsAndInvalidCapacities() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-validation-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = directory.appending(path: "disk.raw")
    _ = try DoryVirtioFileBlockStorage.create(at: disk, capacityBytes: 4096)

    #expect(throws: DoryVirtioFileBlockStorageError.self) {
      try DoryVirtioFileBlockStorage.create(at: disk, capacityBytes: 4096)
    }
    #expect(throws: DoryVirtioFileBlockStorageError.invalidCapacity(513)) {
      try DoryVirtioFileBlockStorage.create(
        at: directory.appending(path: "invalid.raw"),
        capacityBytes: 513
      )
    }

    let link = directory.appending(path: "link.raw")
    #expect(symlink(disk.path, link.path) == 0)
    #expect(throws: DoryVirtioFileBlockStorageError.self) {
      try DoryVirtioFileBlockStorage(existingFileURL: link)
    }
  }
}
