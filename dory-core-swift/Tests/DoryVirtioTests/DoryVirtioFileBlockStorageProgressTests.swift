import Darwin
@testable import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioFileBlockStorageProgressTests {
  @Test(arguments: Operation.allCases)
  func interruptedIOExpiresAtOriginalNoProgressDeadline(operation: Operation) throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = interruptedOperations { calls += 1 }
    operations.monotonicNanoseconds = {
      defer { clockReads += 1 }
      return 123 + UInt64(clockReads) * DoryVirtioFileBlockStorage.maximumNoProgressNanoseconds
    }
    let storage = try fixture.storage(operations)
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(
      operation: operation.syscallName, code: EINTR)) {
      try operation.perform(storage)
    }
    #expect(calls == 1)
    #expect(clockReads == 2)
    #expect(try fixture.bytes() == fixture.initialBytes)
  }

  @Test(arguments: Operation.allCases, [false, true])
  func interruptedIOIsBoundedWithStoppedOrBackwardClock(
    operation: Operation, backwardClock: Bool
  ) throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = interruptedOperations { calls += 1 }
    operations.monotonicNanoseconds = {
      defer { clockReads += 1 }
      return backwardClock && clockReads == 0 ? UInt64.max : 0
    }
    let storage = try fixture.storage(operations)
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(
      operation: operation.syscallName, code: EINTR)) {
      try operation.perform(storage)
    }
    #expect(calls == DoryVirtioFileBlockStorage.maximumConsecutiveInterruptions)
    #expect(clockReads == calls)
    #expect(try fixture.bytes() == fixture.initialBytes)
  }

  @Test(arguments: [Operation.read, .write])
  func positiveShortIOResetsOnlyTheNoProgressBudget(operation: Operation) throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var offsets: [UInt64] = []
    var operations = DoryVirtioFileBlockIOOperations.production
    let read = operations.read
    let write = operations.write
    operations.read = { descriptor, buffer, offset in
      calls += 1
      offsets.append(offset)
      guard calls % 3 == 0 else { return .init(count: -1, code: EINTR) }
      return read(descriptor, .init(rebasing: buffer.prefix(2)), offset)
    }
    operations.write = { descriptor, buffer, offset in
      calls += 1
      offsets.append(offset)
      guard calls % 3 == 0 else { return .init(count: -1, code: EINTR) }
      return write(descriptor, .init(rebasing: buffer.prefix(2)), offset)
    }
    operations.monotonicNanoseconds = {
      defer { clockReads += 1 }
      return UInt64(clockReads) * 2_000_000_000
    }
    let storage = try fixture.storage(operations)
    if operation == .read {
      #expect(try storage.read(offset: 512, byteCount: 8) == [UInt8](repeating: 0xA5, count: 8))
    } else {
      try storage.write(offset: 512, bytes: Array(0..<8))
      #expect(Array(try fixture.bytes()[512..<520]) == Array(0..<8))
    }
    #expect(calls == 12)
    #expect(clockReads == 12)
    #expect(offsets == [512, 512, 512, 514, 514, 514, 516, 516, 516, 518, 518, 518])
    // Total elapsed time exceeds five seconds, but every interrupted interval made progress.
    #expect(UInt64(clockReads - 1) * 2_000_000_000 >
      DoryVirtioFileBlockStorage.maximumNoProgressNanoseconds)
  }

  @Test(arguments: [Operation.read, .write])
  func validPositiveShortIOIsNotLimitedByTheInterruptAttemptCap(operation: Operation) throws {
    let fixture = try Fixture()
    let count = DoryVirtioFileBlockStorage.maximumConsecutiveInterruptions + 1
    var calls = 0
    var clockReads = 0
    var operations = DoryVirtioFileBlockIOOperations.production
    let read = operations.read
    let write = operations.write
    operations.read = { descriptor, buffer, offset in
      calls += 1
      return read(descriptor, .init(rebasing: buffer.prefix(1)), offset)
    }
    operations.write = { descriptor, buffer, offset in
      calls += 1
      return write(descriptor, .init(rebasing: buffer.prefix(1)), offset)
    }
    operations.monotonicNanoseconds = { clockReads += 1; return 0 }
    let storage = try fixture.storage(operations)
    if operation == .read {
      #expect(try storage.read(offset: 0, byteCount: count) ==
        [UInt8](repeating: 0xA5, count: count))
    } else {
      try storage.write(offset: 0, bytes: [UInt8](repeating: 0x5A, count: count))
      #expect(Array(try fixture.bytes().prefix(count)) ==
        [UInt8](repeating: 0x5A, count: count))
    }
    #expect(calls == count)
    #expect(clockReads == 0)
  }

  @Test func finiteFlushInterruptionsRecoverWithoutChangingDurabilityOperation() throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = DoryVirtioFileBlockIOOperations.production
    operations.fullFlush = { _ in
      calls += 1
      return .init(count: calls == 3 ? 0 : -1, code: calls == 3 ? 0 : EINTR)
    }
    operations.monotonicNanoseconds = { clockReads += 1; return UInt64(clockReads) }
    let storage = try fixture.storage(operations)
    try storage.flush()
    #expect(calls == 3)
    #expect(clockReads == 3)
  }

  @Test func nonInterruptedErrorsAndZeroProgressRemainExactWithoutClockReads() throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = DoryVirtioFileBlockIOOperations.production
    let write = operations.write
    operations.write = { descriptor, buffer, offset in
      calls += 1
      if calls == 1 { return write(descriptor, .init(rebasing: buffer.prefix(2)), offset) }
      return .init(count: -1, code: ENOSPC)
    }
    operations.monotonicNanoseconds = { clockReads += 1; return 0 }
    let storage = try fixture.storage(operations)
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: ENOSPC)) {
      try storage.write(offset: 512, bytes: [1, 2, 3, 4])
    }
    #expect(calls == 2)
    #expect(Array(try fixture.bytes()[512..<516]) == [1, 2, 0xA5, 0xA5])

    operations.write = { _, _, _ in .init(count: 0, code: 0) }
    operations.read = { _, _, _ in .init(count: 0, code: 0) }
    operations.fullFlush = { _ in .init(count: -1, code: ENOSPC) }
    let zeroProgress = try fixture.storage(operations)
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(operation: "pwrite", code: EIO)) {
      try zeroProgress.write(offset: 0, bytes: [1])
    }
    #expect(throws: DoryVirtioFileBlockStorageError.shortRead(expected: 1, actual: 0)) {
      try zeroProgress.read(offset: 0, byteCount: 1)
    }
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(
      operation: "fcntl(F_FULLFSYNC)", code: ENOSPC)) {
      try zeroProgress.flush()
    }
    #expect(clockReads == 0)
  }

  @Test func readOnlyAndEmptyIOStillDoNotEnterHostRetryPolicy() throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = interruptedOperations { calls += 1 }
    operations.monotonicNanoseconds = { clockReads += 1; return 0 }
    let storage = try fixture.storage(operations, readOnly: true)
    #expect(try storage.read(offset: 0, byteCount: 0).isEmpty)
    try storage.flush()
    #expect(throws: DoryVirtioBlockError.malformedRequest) {
      try storage.write(offset: 0, bytes: [1])
    }
    #expect(throws: DoryVirtioBlockError.malformedRequest) {
      try storage.writeZeroes(offset: 0, byteCount: 1, mayUnmap: false)
    }
    #expect(throws: DoryVirtioBlockError.malformedRequest) {
      try storage.discard(offset: 0, byteCount: 1)
    }
    #expect(calls == 0)
    #expect(clockReads == 0)
    #expect(try fixture.bytes() == fixture.initialBytes)
  }

  @Test(arguments: [Operation.read, .write, .flush], [EINTR, ENOSPC])
  func storageFailurePublishesGuestIOErrorInsteadOfSuccess(
    operation: Operation, code: Int32
  ) throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = interruptedOperations { calls += 1 }
    operations.read = { _, _, _ in calls += 1; return .init(count: -1, code: code) }
    operations.write = { _, _, _ in calls += 1; return .init(count: -1, code: code) }
    operations.fullFlush = { _ in calls += 1; return .init(count: -1, code: code) }
    operations.monotonicNanoseconds = {
      defer { clockReads += 1 }
      return UInt64(clockReads) * DoryVirtioFileBlockStorage.maximumNoProgressNanoseconds
    }
    let storage = try fixture.storage(operations)
    let device = try DoryVirtioBlockDevice(storage: storage, identifier: "interrupted-disk")
    let memory = RequestMemory(type: operation.requestType)
    let result = try device.process(memory.chain, memory: memory)
    #expect(result.status == DoryVirtioBlockDevice.ioErrorStatus)
    #expect(memory.status == DoryVirtioBlockDevice.ioErrorStatus)
    #expect(device.diagnostics.failedRequestCount == 1)
    #expect(device.diagnostics.successfulRequestCount == 0)
    #expect(calls == 1)
    #expect(clockReads == (code == EINTR ? 2 : 0))
    #expect(try fixture.bytes() == fixture.initialBytes)
  }

  @Test(arguments: [Operation.read, .write, .flush])
  func expiredRetryNeverEntersALateSuccessfulHostCall(operation: Operation) throws {
    let fixture = try Fixture()
    var calls = 0
    var clockReads = 0
    var operations = DoryVirtioFileBlockIOOperations.production
    let read = operations.read
    let write = operations.write
    operations.read = { descriptor, buffer, offset in
      calls += 1
      if calls == 1 { return .init(count: -1, code: EINTR) }
      return read(descriptor, buffer, offset)
    }
    operations.write = { descriptor, buffer, offset in
      calls += 1
      if calls == 1 { return .init(count: -1, code: EINTR) }
      return write(descriptor, buffer, offset)
    }
    operations.fullFlush = { descriptor in
      calls += 1
      if calls == 1 { return .init(count: -1, code: EINTR) }
      // If the expired callback were entered it would both succeed and mutate this fixture.
      let marker: UInt8 = 0x5A
      _ = withUnsafeBytes(of: marker) { pwrite(descriptor, $0.baseAddress, 1, 0) }
      return .init(count: 0, code: 0)
    }
    operations.monotonicNanoseconds = {
      defer { clockReads += 1 }
      return 123 + UInt64(clockReads) * DoryVirtioFileBlockStorage.maximumNoProgressNanoseconds
    }
    let storage = try fixture.storage(operations)
    #expect(throws: DoryVirtioFileBlockStorageError.systemCall(
      operation: operation.syscallName, code: EINTR)) {
      try operation.perform(storage)
    }
    #expect(calls == 1)
    #expect(clockReads == 2)
    #expect(try fixture.bytes() == fixture.initialBytes)
  }

  enum Operation: CaseIterable, Sendable, Equatable {
    case read, write, flush, zeroes, discard

    var syscallName: String {
      switch self {
      case .read: "pread"
      case .flush: "fcntl(F_FULLFSYNC)"
      case .write, .zeroes, .discard: "pwrite"
      }
    }

    var requestType: UInt32 {
      switch self {
      case .read: 0
      case .write: 1
      case .flush: 4
      case .discard: 11
      case .zeroes: 13
      }
    }

    func perform(_ storage: DoryVirtioFileBlockStorage) throws {
      switch self {
      case .read: _ = try storage.read(offset: 512, byteCount: 8)
      case .write: try storage.write(offset: 512, bytes: Array(0..<8))
      case .flush: try storage.flush()
      case .zeroes: try storage.writeZeroes(offset: 512, byteCount: 8, mayUnmap: false)
      case .discard: try storage.discard(offset: 512, byteCount: 8)
      }
    }
  }

  private func interruptedOperations(_ called: @escaping () -> Void)
    -> DoryVirtioFileBlockIOOperations {
    .init(
      read: { _, _, _ in called(); return .init(count: -1, code: EINTR) },
      write: { _, _, _ in called(); return .init(count: -1, code: EINTR) },
      fullFlush: { _ in called(); return .init(count: -1, code: EINTR) },
      monotonicNanoseconds: { 0 }
    )
  }
}

private final class Fixture {
  let directory: URL
  let file: URL
  let initialBytes = [UInt8](repeating: 0xA5, count: 4096)

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "dory-block-progress-\(UUID().uuidString)", directoryHint: .isDirectory)
    file = directory.appending(path: "disk.raw")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do { try Data(initialBytes).write(to: file, options: .withoutOverwriting) }
    catch { try? FileManager.default.removeItem(at: directory); throw error }
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func storage(_ operations: DoryVirtioFileBlockIOOperations, readOnly: Bool = false) throws
    -> DoryVirtioFileBlockStorage {
    let descriptor = Darwin.open(file.path, (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 3 else {
      throw DoryVirtioFileBlockStorageError.systemCall(operation: "open", code: errno)
    }
    defer { Darwin.close(descriptor) }
    return try .init(
      duplicatingFileDescriptor: descriptor, expectedCapacityBytes: 4096,
      readOnly: readOnly, ioOperations: operations)
  }

  func bytes() throws -> [UInt8] { Array(try Data(contentsOf: file)) }
}

private final class RequestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = [UInt8](repeating: 0xCC, count: 0x800)
  let chain: DoryVirtioDescriptorChain

  init(type: UInt32) {
    let header = (0..<4).map { UInt8(truncatingIfNeeded: type >> ($0 * 8)) }
      + [UInt8](repeating: 0, count: 12)
    bytes.replaceSubrange(0x100..<0x110, with: header)
    var descriptors: [DoryVirtioDescriptor] = [
      .init(address: 0x100, length: 16, flags: 0, next: 0)
    ]
    if type != 4 {
      descriptors.append(.init(address: 0x200, length: 512,
        flags: type == 0 ? DoryVirtioDescriptor.writeFlag : 0, next: 0))
    }
    descriptors.append(.init(address: 0x500, length: 1,
      flags: DoryVirtioDescriptor.writeFlag, next: 0))
    chain = .init(headIndex: 0, descriptors: descriptors,
      readableByteCount: type == 1 ? 528 : 16, writableByteCount: type == 0 ? 513 : 1)
  }

  var status: UInt8 { lock.withLock { bytes[0x500] } }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try checked(address, byteCount)]) }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    _ = try lock.withLock { try checked(address, byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try lock.withLock { self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes) }
  }

  func synchronize() {}

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioBlockError.malformedRequest }
    return Int(address)..<(Int(address) + count)
  }
}
