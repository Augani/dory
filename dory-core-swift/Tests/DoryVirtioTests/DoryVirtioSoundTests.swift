import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioSoundTests {
  @Test func publishesTwoPCMStreamsAndInformation() throws {
    let backend = DoryVirtioInMemorySoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    #expect(read32(device.configuration, 4) == 2)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    let query =
      littleEndian(UInt32(0x0100)) + littleEndian(UInt32(0))
      + littleEndian(UInt32(2)) + littleEndian(UInt32(32))
    let response = try control(device, request: query, responseBytes: 68, memory: memory)
    #expect(read32(response, 0) == 0x8000)
    #expect(response[28] == 0)
    #expect(response[60] == 1)
    #expect(response[29] == 1 && response[30] == 2)
  }

  @Test func configuresPreparesAndTransfersPlaybackPCM() throws {
    let backend = DoryVirtioInMemorySoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)

    let pcm = [UInt8](repeating: 0x5A, count: 16)
    memory.put(littleEndian(UInt32(0)) + pcm, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: 20, flags: 0, next: 1),
        .init(address: 0x2000, length: 8, flags: 2, next: 0),
      ],
      readableByteCount: 20,
      writableByteCount: 8
    )
    #expect(try device.processTransmit(chain, memory: memory) == 8)
    #expect(backend.playedBuffers == [pcm])
    #expect(read32(try memory.read(at: 0x2000, byteCount: 8), 0) == 0x8000)
  }

  @Test func capturesPCMAndEnforcesLifecycle() throws {
    let backend = DoryVirtioInMemorySoundBackend()
    backend.enqueueCaptureBytes(Array(0..<16))
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    _ = try control(device, request: parameters(streamID: 1), memory: memory)
    _ = try control(device, request: pcmCommand(0x0102, streamID: 1), memory: memory)
    _ = try control(device, request: pcmCommand(0x0104, streamID: 1), memory: memory)

    memory.put(littleEndian(UInt32(1)), at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: 4, flags: 0, next: 1),
        .init(address: 0x3000, length: 16, flags: 2, next: 2),
        .init(address: 0x4000, length: 8, flags: 2, next: 0),
      ],
      readableByteCount: 4,
      writableByteCount: 24
    )
    #expect(try device.processReceive(chain, memory: memory) == 24)
    #expect(try memory.read(at: 0x3000, byteCount: 16) == Array(0..<16))
    #expect(read32(try memory.read(at: 0x4000, byteCount: 8), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0105, streamID: 1), memory: memory), 0)
        == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0103, streamID: 1), memory: memory), 0)
        == 0x8000)
  }

  private func control(
    _ device: DoryVirtioSoundDevice,
    request: [UInt8],
    responseBytes: Int = 4,
    memory: SoundGuestMemory
  ) throws -> [UInt8] {
    memory.put(request, at: 0x5000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x5000, length: UInt32(request.count), flags: 0, next: 1),
        .init(address: 0x6000, length: UInt32(responseBytes), flags: 2, next: 0),
      ],
      readableByteCount: UInt64(request.count),
      writableByteCount: UInt64(responseBytes)
    )
    let count = try device.processControl(chain, memory: memory)
    return try memory.read(at: 0x6000, byteCount: Int(count))
  }

  private func parameters(streamID: UInt32) -> [UInt8] {
    littleEndian(UInt32(0x0101)) + littleEndian(streamID)
      + littleEndian(UInt32(4_096)) + littleEndian(UInt32(1_024))
      + littleEndian(UInt32(0)) + [2, 5, 7, 0]
  }

  private func pcmCommand(_ code: UInt32, streamID: UInt32) -> [UInt8] {
    littleEndian(code) + littleEndian(streamID)
  }
}

private final class SoundGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
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
    else { throw DoryVirtioSoundError.malformedRequest }
    return Int(address)..<(Int(address) + count)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
