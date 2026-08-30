import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioGPUTests {
  @Test func publishesDisplayConfigurationAndDisplayInfo() throws {
    let device = try makeDevice()
    #expect(read32(device.configuration, 8) == 2)
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let response = try command(
      device,
      bytes: header(0x0100),
      responseBytes: 24 + 16 * 24,
      memory: memory
    )
    #expect(read32(response, 0) == 0x1101)
    #expect(read32(response, 24 + 8) == 800)
    #expect(read32(response, 24 + 12) == 600)
    #expect(read32(response, 24 + 16) == 1)
    #expect(read32(response, 48 + 8) == 1_920)
    #expect(read32(response, 48 + 12) == 1_080)
  }

  @Test func createsBacksTransfersBindsAndFlushesA2DResource() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)

    let create =
      header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    memory.put(Array(0..<32), at: 0x8000)
    let attach =
      header(0x0106) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(32)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)

    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let transfer =
      header(0x0105) + rectangle + littleEndian(UInt64(0))
      + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)

    let bind = header(0x0103) + rectangle + littleEndian(UInt32(0)) + littleEndian(UInt32(7))
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)

    let flush = header(0x0104) + rectangle + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(sink.frames.count == 1)
    #expect(sink.frames[0].scanoutID == 0)
    #expect(sink.frames[0].pixels == Array(0..<32))
  }

  @Test func supportsScatterBackingAndFencedResponses() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let fencedHeader = header(0x0101, flags: 1, fence: 0x1234)
    let create =
      fencedHeader + littleEndian(UInt32(9)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    let createResponse = try command(device, bytes: create, memory: memory)
    #expect(read32(createResponse, 4) == 1)
    #expect(read64(createResponse, 8) == 0x1234)

    memory.put(Array(0..<12), at: 0x9000)
    memory.put(Array(12..<32), at: 0xA000)
    let attach =
      header(0x0106) + littleEndian(UInt32(9)) + littleEndian(UInt32(2))
      + littleEndian(UInt64(0x9000)) + littleEndian(UInt32(12)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0xA000)) + littleEndian(UInt32(20)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)

    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let transfer =
      header(0x0105) + rectangle + littleEndian(UInt64(0))
      + littleEndian(UInt32(9)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)
    let bind = header(0x0103) + rectangle + littleEndian(UInt32(1)) + littleEndian(UInt32(9))
    _ = try command(device, bytes: bind, memory: memory)
    let flush = header(0x0104) + rectangle + littleEndian(UInt32(9)) + littleEndian(UInt32(0))
    _ = try command(device, bytes: flush, memory: memory)
    #expect(sink.frames[0].pixels == Array(0..<32))
  }

  @Test func rejectsOversizedResourcesAndInvalidScanoutsWithoutAllocating() throws {
    let device = try DoryVirtioGPUDevice(
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      maximumResourceBytes: 4_096
    )
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let create =
      header(0x0101) + littleEndian(UInt32(1)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(1_024)) + littleEndian(UInt32(1_024))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1205)

    let bind =
      header(0x0103) + rect(x: 0, y: 0, width: 1, height: 1)
      + littleEndian(UInt32(3)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1202)
  }

  private func makeDevice(sink: GPUDisplaySink? = nil) throws -> DoryVirtioGPUDevice {
    try .init(
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600)),
        .init(id: 1, rectangle: .init(x: 800, y: 0, width: 1_920, height: 1_080)),
      ],
      displaySink: sink
    )
  }

  private func command(
    _ device: DoryVirtioGPUDevice,
    bytes: [UInt8],
    responseBytes: Int = 24,
    memory: GPUGuestMemory
  ) throws -> [UInt8] {
    memory.put(bytes, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(bytes.count), flags: 0, next: 1),
        .init(address: 0x4000, length: UInt32(responseBytes), flags: 2, next: 0),
      ],
      readableByteCount: UInt64(bytes.count),
      writableByteCount: UInt64(responseBytes)
    )
    let written = try device.process(queue: 0, chain: chain, memory: memory)
    return try memory.read(at: 0x4000, byteCount: Int(written))
  }

  private func header(_ command: UInt32, flags: UInt32 = 0, fence: UInt64 = 0) -> [UInt8] {
    littleEndian(command) + littleEndian(flags) + littleEndian(fence)
      + littleEndian(UInt32(0)) + [0, 0, 0, 0]
  }

  private func rect(x: UInt32, y: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
    littleEndian(x) + littleEndian(y) + littleEndian(width) + littleEndian(height)
  }
}

private final class GPUDisplaySink: DoryVirtioGPUDisplaySink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DoryVirtioGPUFrame] = []
  var frames: [DoryVirtioGPUFrame] { lock.withLock { storage } }
  func present(_ frame: DoryVirtioGPUFrame) { lock.withLock { storage.append(frame) } }
}

private final class GPUGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
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
    else { throw DoryVirtioGPUError.malformedRequest }
    return Int(address)..<(Int(address) + count)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
