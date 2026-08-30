import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioEntropyTests {
  @Test func fillsScatterGatherBuffersFromOneBoundedSourceRequest() throws {
    let source = CountingEntropySource(bytes: Array(0..<12))
    let device = DoryVirtioEntropyDevice(source: source, maximumRequestBytes: 16)
    let memory = EntropyGuestMemory(byteCount: 256)
    let request = chain([
      descriptor(address: 0x20, length: 5, writable: true),
      descriptor(address: 0x80, length: 7, writable: true),
    ])

    #expect(try device.process(request, memory: memory) == 12)
    #expect(try memory.read(at: 0x20, byteCount: 5) == Array(0..<5))
    #expect(try memory.read(at: 0x80, byteCount: 7) == Array(5..<12))
    #expect(source.requests == [12])
  }

  @Test func rejectsReadableOversizedAndShortSourceRequestsBeforePublication() throws {
    let source = CountingEntropySource(bytes: [1, 2, 3])
    let device = DoryVirtioEntropyDevice(source: source, maximumRequestBytes: 8)
    let memory = EntropyGuestMemory(byteCount: 256)

    #expect(throws: DoryVirtioEntropyError.invalidDescriptorDirection) {
      try device.process(
        chain([descriptor(address: 0x10, length: 4, writable: false)]),
        memory: memory
      )
    }
    #expect(throws: DoryVirtioEntropyError.requestTooLarge(requested: 9, maximum: 8)) {
      try device.process(
        chain([descriptor(address: 0x20, length: 9, writable: true)]),
        memory: memory
      )
    }
    #expect(source.requests.isEmpty)

    #expect(throws: DoryVirtioEntropyError.invalidSourceResponse(expected: 4, actual: 3)) {
      try device.process(
        chain([descriptor(address: 0x30, length: 4, writable: true)]),
        memory: memory
      )
    }
    #expect(try memory.read(at: 0x30, byteCount: 4) == [0, 0, 0, 0])
  }

  private func descriptor(address: UInt64, length: UInt32, writable: Bool) -> DoryVirtioDescriptor {
    .init(address: address, length: length, flags: writable ? 2 : 0, next: 0)
  }

  private func chain(_ descriptors: [DoryVirtioDescriptor]) -> DoryVirtioDescriptorChain {
    .init(
      headIndex: 0,
      descriptors: descriptors,
      readableByteCount: descriptors.filter { !$0.deviceWillWrite }.reduce(0) {
        $0 + UInt64($1.length)
      },
      writableByteCount: descriptors.filter(\.deviceWillWrite).reduce(0) {
        $0 + UInt64($1.length)
      }
    )
  }
}

private final class CountingEntropySource: DoryVirtioEntropySource, @unchecked Sendable {
  private let lock = NSLock()
  private let bytes: [UInt8]
  private var recordedRequests: [Int] = []

  init(bytes: [UInt8]) { self.bytes = bytes }

  var requests: [Int] { lock.withLock { recordedRequests } }

  func randomBytes(byteCount: Int) throws -> [UInt8] {
    lock.withLock {
      recordedRequests.append(byteCount)
      return bytes
    }
  }
}

private final class EntropyGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]

  init(byteCount: Int) { bytes = .init(repeating: 0, count: byteCount) }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try checked(address, byteCount)]) }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    _ = try lock.withLock { try checked(address, byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try lock.withLock {
      self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes)
    }
  }

  func synchronize() {}

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioEntropyError.emptyRequest }
    return Int(address)..<(Int(address) + count)
  }
}
