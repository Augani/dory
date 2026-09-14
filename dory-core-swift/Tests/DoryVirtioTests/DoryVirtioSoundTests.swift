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

  @Test func backendCapabilityRestrictsAdvertisedAndAcceptedFormats() throws {
    let device = DoryVirtioSoundDevice(backend: Signed16SoundBackend())
    let memory = SoundGuestMemory(byteCount: 0x8000)
    let query = littleEndian(UInt32(0x0100)) + littleEndian(UInt32(0))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(32))
    let information = try control(device, request: query, responseBytes: 36, memory: memory)
    #expect(read64(information, 12) == UInt64(1) << 5)

    var unsupported = parameters(streamID: 0)
    unsupported[21] = DoryVirtioSoundPCMFormat.float32.rawValue
    #expect(read32(try control(device, request: unsupported, memory: memory), 0) == 0x8002)
  }

  @Test func controlPreflightsInvalidLaterOutputBeforeLifecycle() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    // Configure stream 0 so pcmPrepare would otherwise call backend.prepare.
    _ = try control(device, request: parameters(streamID: 0), memory: memory)
    // pcmPrepare request with a split writable response buffer whose second
    // segment is out of range; preflight must fail before backend.prepare and
    // before any partial scatter into the earlier valid segment.
    memory.put(littleEndian(UInt32(0x0102)) + littleEndian(UInt32(0)), at: 0x5000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x5000, length: 8, flags: 0, next: 1),
        .init(address: 0x6100, length: 2, flags: 2, next: 2),
        .init(address: 0x9000, length: 2, flags: 2, next: 0),
      ],
      readableByteCount: 8,
      writableByteCount: 4
    )
    #expect(throws: DoryVirtioSoundError.malformedRequest) {
      _ = try device.processControl(chain, memory: memory)
    }
    #expect(backend.prepareCount == 0)
    #expect(try memory.read(at: 0x6100, byteCount: 2) == [0, 0])
  }

  @Test func transmitPreflightsInvalidLaterStatusBeforePlay() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    _ = try control(device, request: parameters(streamID: 0), memory: memory)
    _ = try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory)
    let pcm = [UInt8](repeating: 0x5A, count: 16)
    memory.put(littleEndian(UInt32(0)) + pcm, at: 0x1000)
    // Status output split across two writable segments; the second is out of
    // range. Preflight must fail before backend.play and before any status DMA.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: 20, flags: 0, next: 1),
        .init(address: 0x2000, length: 4, flags: 2, next: 2),
        .init(address: 0x9000, length: 4, flags: 2, next: 0),
      ],
      readableByteCount: 20,
      writableByteCount: 8
    )
    #expect(throws: DoryVirtioSoundError.malformedRequest) {
      _ = try device.processTransmit(chain, memory: memory)
    }
    #expect(backend.playCount == 0)
    #expect(try memory.read(at: 0x2000, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func receivePreflightsInvalidLaterAudioBeforeCapture() throws {
    let backend = RecordingSoundBackend()
    backend.enqueueCapture(Array(0..<16))
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    _ = try control(device, request: parameters(streamID: 1), memory: memory)
    _ = try control(device, request: pcmCommand(0x0102, streamID: 1), memory: memory)
    _ = try control(device, request: pcmCommand(0x0104, streamID: 1), memory: memory)
    memory.put(littleEndian(UInt32(1)), at: 0x1000)
    // Audio output split across two writable segments; the second audio segment
    // is out of range. Preflight must fail before backend.capture consumes any
    // bytes and before any audio/status DMA.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: 4, flags: 0, next: 1),
        .init(address: 0x3000, length: 8, flags: 2, next: 2),
        .init(address: 0x9000, length: 8, flags: 2, next: 3),
        .init(address: 0x4000, length: 8, flags: 2, next: 0),
      ],
      readableByteCount: 4,
      writableByteCount: 24
    )
    #expect(throws: DoryVirtioSoundError.malformedRequest) {
      _ = try device.processReceive(chain, memory: memory)
    }
    #expect(backend.captureCount == 0)
    #expect(try memory.read(at: 0x3000, byteCount: 8) == [UInt8](repeating: 0, count: 8))
    #expect(try memory.read(at: 0x4000, byteCount: 8) == [UInt8](repeating: 0, count: 8))
  }

  @Test func eventPreflightsInvalidLaterOutputAndRetainsEvent() throws {
    let backend = DoryVirtioInMemorySoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    _ = device.enqueueEvent(DoryVirtioSoundEvent(code: 0x10, data: 0x20))
    // Event output split across two writable segments; the second is out of
    // range. Preflight must fail before any partial scatter and the event must
    // remain pending for a later (valid) dequeue.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x6000, length: 4, flags: 2, next: 1),
        .init(address: 0x9000, length: 4, flags: 2, next: 0),
      ],
      readableByteCount: 0,
      writableByteCount: 8
    )
    #expect(throws: DoryVirtioSoundError.malformedRequest) {
      _ = try device.processEvent(chain, memory: memory)
    }
    #expect(device.pendingEventCount == 1)
    #expect(try memory.read(at: 0x6000, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func resetStopsRunningStreamReleasesBackendAndRequiresReconfiguration() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0104, streamID: 0), memory: memory), 0)
        == 0x8000)

    device.reset()
    #expect(backend.stopCount == 1)
    #expect(backend.releaseCount == 1)

    // Post-reset lifecycles are unconfigured: control transitions are rejected.
    #expect(
      read32(try control(device, request: pcmCommand(0x0105, streamID: 0), memory: memory), 0)
        == 0x8001)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8001)

    // Post-reset playback is rejected until the stream is configured again.
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
    #expect(read32(try memory.read(at: 0x2000, byteCount: 8), 0) == 0x8003)
    #expect(backend.playCount == 0)

    // Reconfiguration restores the lifecycle.
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)
  }

  @Test func resetReleasesPreparedStreamWithoutStop() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)

    device.reset()
    #expect(backend.stopCount == 0)
    #expect(backend.releaseCount == 1)
    #expect(
      read32(try control(device, request: pcmCommand(0x0104, streamID: 0), memory: memory), 0)
        == 0x8001)
  }

  @Test func resetReleasesConfiguredStreamWithoutStop() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)

    device.reset()
    #expect(backend.stopCount == 0)
    #expect(backend.releaseCount == 1)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8001)
  }

  @Test func resetReleasesStoppedStreamWithoutAdditionalStop() throws {
    let backend = RecordingSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0104, streamID: 0), memory: memory), 0)
        == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0105, streamID: 0), memory: memory), 0)
        == 0x8000)
    #expect(backend.stopCount == 1)

    device.reset()
    #expect(backend.stopCount == 1)
    #expect(backend.releaseCount == 1)
  }

  @Test func resetReturnsUnconfiguredWhenBackendCleanupThrows() throws {
    let backend = ThrowingCleanupSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    #expect(
      read32(try control(device, request: parameters(streamID: 0), memory: memory), 0) == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0102, streamID: 0), memory: memory), 0)
        == 0x8000)
    #expect(
      read32(try control(device, request: pcmCommand(0x0104, streamID: 0), memory: memory), 0)
        == 0x8000)

    device.reset()
    #expect(backend.stopAttempts == 1)
    #expect(backend.releaseAttempts == 1)
    #expect(
      read32(try control(device, request: pcmCommand(0x0105, streamID: 0), memory: memory), 0)
        == 0x8001)
  }

  @Test func resetContinuesOtherLiveStreamCleanupAfterStreamFailure() throws {
    let backend = OrderedThrowingCleanupSoundBackend()
    let device = DoryVirtioSoundDevice(backend: backend)
    let memory = SoundGuestMemory(byteCount: 0x8000)
    for streamID: UInt32 in 0...1 {
      #expect(
        read32(try control(device, request: parameters(streamID: streamID), memory: memory), 0)
          == 0x8000)
      #expect(
        read32(
          try control(device, request: pcmCommand(0x0102, streamID: streamID), memory: memory), 0
        ) == 0x8000)
      #expect(
        read32(
          try control(device, request: pcmCommand(0x0104, streamID: streamID), memory: memory), 0
        ) == 0x8000)
    }

    device.reset()
    #expect(backend.cleanupOperations == [.stop(0), .release(0), .stop(1), .release(1)])
    #expect(
      read32(try control(device, request: pcmCommand(0x0105, streamID: 1), memory: memory), 0)
        == 0x8001)
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

private final class Signed16SoundBackend: DoryVirtioSoundBackend,
  DoryVirtioSoundFormatCapability, @unchecked Sendable
{
  let supportedPCMFormats: Set<DoryVirtioSoundPCMFormat> = [.signed16]
  func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws {}
  func prepare(streamID: UInt32) throws {}
  func start(streamID: UInt32) throws {}
  func stop(streamID: UInt32) throws {}
  func release(streamID: UInt32) throws {}
  func play(streamID: UInt32, pcmBytes: [UInt8]) throws {}
  func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
    [UInt8](repeating: 0, count: byteCount)
  }
}

private final class RecordingSoundBackend: DoryVirtioSoundBackend, @unchecked Sendable {
  var configureCount = 0
  var prepareCount = 0
  var startCount = 0
  var stopCount = 0
  var releaseCount = 0
  var playCount = 0
  var captureCount = 0
  private var captureBytes: [UInt8] = []

  func enqueueCapture(_ bytes: [UInt8]) { captureBytes += bytes }

  func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws { configureCount += 1 }
  func prepare(streamID: UInt32) throws { prepareCount += 1 }
  func start(streamID: UInt32) throws { startCount += 1 }
  func stop(streamID: UInt32) throws { stopCount += 1 }
  func release(streamID: UInt32) throws { releaseCount += 1 }
  func play(streamID: UInt32, pcmBytes: [UInt8]) throws { playCount += 1 }
  func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
    captureCount += 1
    let count = min(byteCount, captureBytes.count)
    let result = Array(captureBytes.prefix(count))
    captureBytes.removeFirst(count)
    return result + [UInt8](repeating: 0, count: byteCount - count)
  }
}

private final class ThrowingCleanupSoundBackend: DoryVirtioSoundBackend, @unchecked Sendable {
  struct CleanupFailure: Error {}
  var stopAttempts = 0
  var releaseAttempts = 0

  func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws {}
  func prepare(streamID: UInt32) throws {}
  func start(streamID: UInt32) throws {}
  func stop(streamID: UInt32) throws {
    stopAttempts += 1
    throw CleanupFailure()
  }
  func release(streamID: UInt32) throws {
    releaseAttempts += 1
    throw CleanupFailure()
  }
  func play(streamID: UInt32, pcmBytes: [UInt8]) throws {}
  func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
    [UInt8](repeating: 0, count: byteCount)
  }
}

private final class OrderedThrowingCleanupSoundBackend: DoryVirtioSoundBackend, @unchecked Sendable {
  enum CleanupOperation: Equatable {
    case stop(UInt32)
    case release(UInt32)
  }

  private(set) var cleanupOperations: [CleanupOperation] = []

  func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws {}
  func prepare(streamID: UInt32) throws {}
  func start(streamID: UInt32) throws {}
  func stop(streamID: UInt32) throws {
    cleanupOperations.append(.stop(streamID))
    if streamID == 0 { throw ThrowingCleanupSoundBackend.CleanupFailure() }
  }
  func release(streamID: UInt32) throws {
    cleanupOperations.append(.release(streamID))
    if streamID == 0 { throw ThrowingCleanupSoundBackend.CleanupFailure() }
  }
  func play(streamID: UInt32, pcmBytes: [UInt8]) throws {}
  func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
    [UInt8](repeating: 0, count: byteCount)
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

private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
