import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioBlockTests {
  @Test func publishesCapacityFeaturesAndBlockConfiguration() throws {
    let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
    let device = try DoryVirtioBlockDevice(storage: storage, identifier: "dory-disk")
    #expect(device.offeredFeatures.contains(.blockFlush))
    #expect(device.offeredFeatures.contains(.blockDiscard))
    #expect(read64(device.configuration, 0) == 8)
    #expect(read32(device.configuration, 20) == 512)
  }

  @Test func executesScatterGatherReadsWritesFlushAndIdentity() throws {
    let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
    let device = try DoryVirtioBlockDevice(storage: storage, identifier: "dory-disk")
    let memory = BlockGuestMemory(byteCount: 0x4000)

    memory.put(header(type: 1, sector: 1), at: 0x100)
    let sectorBytes = [1, 2, 3, 4] + [UInt8](repeating: 0xA5, count: 508)
    memory.put(sectorBytes, at: 0x200)
    let write = chain([
      descriptor(0x100, 16, false), descriptor(0x200, 512, false),
      descriptor(0x450, 1, true),
    ])
    #expect(try device.process(write, memory: memory).status == 0)
    #expect(try storage.read(offset: 512, byteCount: 4) == [1, 2, 3, 4])

    memory.put(header(type: 0, sector: 1), at: 0x500)
    let read = chain([
      descriptor(0x500, 16, false), descriptor(0x600, 256, true),
      descriptor(0x800, 256, true), descriptor(0xA00, 1, true),
    ])
    let readResult = try device.process(read, memory: memory)
    #expect(readResult.bytesWritten == 513)
    #expect(try memory.read(at: 0x600, byteCount: 256) == Array(sectorBytes.prefix(256)))
    #expect(try memory.read(at: 0x800, byteCount: 256) == Array(sectorBytes.suffix(256)))

    memory.put(header(type: 4, sector: 0), at: 0xB00)
    let flush = chain([descriptor(0xB00, 16, false), descriptor(0xC00, 1, true)])
    #expect(try device.process(flush, memory: memory).status == 0)
    #expect(storage.flushCount == 1)

    memory.put(header(type: 8, sector: 0), at: 0xD00)
    let identity = chain([
      descriptor(0xD00, 16, false), descriptor(0xE00, 20, true),
      descriptor(0xF00, 1, true),
    ])
    #expect(try device.process(identity, memory: memory).bytesWritten == 21)
    #expect(
      String(decoding: try memory.read(at: 0xE00, byteCount: 9), as: UTF8.self) == "dory-disk")
  }

  @Test func executesDiscardAndWriteZeroesRanges() throws {
    let storage = DoryVirtioInMemoryBlockStorage(
      byteCount: 4096,
      initialBytes: [UInt8](repeating: 0xAA, count: 4096)
    )
    let device = try DoryVirtioBlockDevice(storage: storage, identifier: "ranges")
    let memory = BlockGuestMemory(byteCount: 0x2000)

    memory.put(header(type: 11, sector: 0), at: 0x100)
    memory.put(range(sector: 2, sectors: 1, flags: 0), at: 0x200)
    let discard = chain([
      descriptor(0x100, 16, false), descriptor(0x200, 16, false), descriptor(0x300, 1, true),
    ])
    #expect(try device.process(discard, memory: memory).status == 0)
    #expect(try storage.read(offset: 1024, byteCount: 512) == [UInt8](repeating: 0, count: 512))

    memory.put(header(type: 13, sector: 0), at: 0x400)
    memory.put(range(sector: 4, sectors: 1, flags: 1), at: 0x500)
    let zeroes = chain([
      descriptor(0x400, 16, false), descriptor(0x500, 16, false), descriptor(0x600, 1, true),
    ])
    #expect(try device.process(zeroes, memory: memory).status == 0)
    #expect(try storage.read(offset: 2048, byteCount: 512) == [UInt8](repeating: 0, count: 512))
  }

  @Test func rejectsOutOfBoundsAndDirectionConfusionWithoutTouchingStorage() throws {
    let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
    let device = try DoryVirtioBlockDevice(storage: storage, identifier: "bounded")
    let memory = BlockGuestMemory(byteCount: 0x1000)
    memory.put(header(type: 1, sector: 8), at: 0x100)
    memory.put([UInt8](repeating: 7, count: 512), at: 0x200)
    let outOfBounds = chain([
      descriptor(0x100, 16, false), descriptor(0x200, 512, false),
      descriptor(0x500, 1, true),
    ])
    #expect(try device.process(outOfBounds, memory: memory).status == 1)
    #expect(try storage.read(offset: 0, byteCount: 4) == [0, 0, 0, 0])

    memory.put(header(type: 0, sector: 0), at: 0x600)
    let wrongDirection = chain([
      descriptor(0x600, 16, false), descriptor(0x700, 512, false),
      descriptor(0xA00, 1, true),
    ])
    #expect(try device.process(wrongDirection, memory: memory).status == 1)
  }

  private func descriptor(
    _ address: UInt64,
    _ length: UInt32,
    _ deviceWillWrite: Bool
  ) -> DoryVirtioDescriptor {
    .init(address: address, length: length, flags: deviceWillWrite ? 2 : 0, next: 0)
  }

  private func chain(_ descriptors: [DoryVirtioDescriptor]) -> DoryVirtioDescriptorChain {
    .init(
      headIndex: 0,
      descriptors: descriptors,
      readableByteCount: descriptors.filter { !$0.deviceWillWrite }.reduce(0) {
        $0 + UInt64($1.length)
      },
      writableByteCount: descriptors.filter(\.deviceWillWrite).reduce(0) { $0 + UInt64($1.length) }
    )
  }

  private func header(type: UInt32, sector: UInt64) -> [UInt8] {
    littleEndian(type) + [UInt8](repeating: 0, count: 4) + littleEndian(sector)
  }

  private func range(sector: UInt64, sectors: UInt32, flags: UInt32) -> [UInt8] {
    littleEndian(sector) + littleEndian(sectors) + littleEndian(flags)
  }

  private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
  }

  private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
  }
}

private final class BlockGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
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
    try lock.withLock { self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes) }
  }

  func synchronize() {}

  func put(_ value: [UInt8], at address: UInt64) {
    lock.withLock {
      bytes.replaceSubrange(Int(address)..<(Int(address) + value.count), with: value)
    }
  }

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioBlockError.malformedRequest }
    return Int(address)..<(Int(address) + count)
  }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
