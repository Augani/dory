import Darwin
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioFileBlockStorageTests {
  @Test func rejectsNegativeAndOversizedDirectReadsWithoutAllocating() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-counts-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capacity = DoryVirtioBlockDevice.maximumPayloadByteCount + 512
    let storage = try DoryVirtioFileBlockStorage.create(
      at: directory.appending(path: "disk.raw"), capacityBytes: capacity)
    for count in [-1, Int.min] {
      #expect(throws: DoryVirtioBlockError.invalidByteCount(count)) {
        try storage.read(offset: 0, byteCount: count)
      }
    }
    #expect(throws: DoryVirtioBlockError.requestOutOfBounds(offset: 0, byteCount: capacity)) {
      try storage.read(offset: 0, byteCount: Int(capacity))
    }
    #expect(throws: DoryVirtioBlockError.requestOutOfBounds(offset: 0, byteCount: capacity)) {
      try storage.writeZeroes(offset: 0, byteCount: capacity, mayUnmap: false)
    }
    #expect(try storage.read(offset: capacity, byteCount: 0).isEmpty)
    #expect(throws: DoryVirtioBlockError.requestOutOfBounds(offset: capacity, byteCount: 1)) {
      try storage.read(offset: capacity, byteCount: 1)
    }
    #expect(throws: DoryVirtioBlockError.requestOutOfBounds(offset: UInt64.max, byteCount: 1)) {
      try storage.writeZeroes(offset: UInt64.max, byteCount: 1, mayUnmap: false)
    }
    try storage.write(offset: capacity - 1, bytes: [0xA5])
    #expect(try storage.read(offset: capacity - 1, byteCount: 1) == [0xA5])
  }

  @Test func rejectsAppendDescriptorsWithoutChangingTheirFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-append-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "disk.raw")
    let storage = try DoryVirtioFileBlockStorage.create(at: url, capacityBytes: 4096)
    try storage.write(offset: 0, bytes: [0xA5])
    let descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
    #expect(descriptor >= 3)
    defer { Darwin.close(descriptor) }
    #expect(throws: DoryVirtioFileBlockStorageError.notRegularFile) {
      try DoryVirtioFileBlockStorage(
        duplicatingFileDescriptor: descriptor, expectedCapacityBytes: 4096, readOnly: false)
    }
    #expect(try storage.read(offset: 0, byteCount: 1) == [0xA5])
    var status = stat()
    #expect(fstat(descriptor, &status) == 0)
    #expect(status.st_size == 4096)
  }

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

  @Test func duplicatesAnAdmittedDescriptorAndPreservesItsOwnLifetime() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-descriptor-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = directory.appending(path: "disk.raw")
    _ = try DoryVirtioFileBlockStorage.create(at: disk, capacityBytes: 4096)

    let descriptor = Darwin.open(disk.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    #expect(descriptor >= 3)
    let storage = try DoryVirtioFileBlockStorage(
      duplicatingFileDescriptor: descriptor,
      expectedCapacityBytes: 4096,
      readOnly: false
    )
    Darwin.close(descriptor)

    try storage.write(offset: 512, bytes: [0x44, 0x4F, 0x52, 0x59])
    #expect(try storage.read(offset: 512, byteCount: 4) == [0x44, 0x4F, 0x52, 0x59])
  }

  @Test func rejectsDescriptorCapacityAndAccessMismatches() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-file-block-descriptor-validation-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = directory.appending(path: "disk.raw")
    _ = try DoryVirtioFileBlockStorage.create(at: disk, capacityBytes: 4096)

    let descriptor = Darwin.open(disk.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    #expect(descriptor >= 3)
    defer { Darwin.close(descriptor) }
    #expect(throws: DoryVirtioFileBlockStorageError.notRegularFile) {
      _ = try DoryVirtioFileBlockStorage(
        duplicatingFileDescriptor: descriptor,
        expectedCapacityBytes: 4096,
        readOnly: false
      )
    }
    #expect(throws: DoryVirtioFileBlockStorageError.notRegularFile) {
      _ = try DoryVirtioFileBlockStorage(
        duplicatingFileDescriptor: descriptor,
        expectedCapacityBytes: 8192,
        readOnly: true
      )
    }
  }
}
