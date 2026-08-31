import Foundation

public enum DoryVirtioSoundDirection: UInt8, Sendable, Hashable {
  case output = 0
  case input = 1
}

public enum DoryVirtioSoundPCMFormat: UInt8, CaseIterable, Sendable, Hashable {
  case signed16 = 5
  case signed32 = 17
  case float32 = 19

  public var bytesPerSample: Int {
    switch self {
    case .signed16: 2
    case .signed32, .float32: 4
    }
  }
}

public enum DoryVirtioSoundPCMRate: UInt8, CaseIterable, Sendable, Hashable {
  case hz44100 = 6
  case hz48000 = 7
  case hz96000 = 10

  public var hertz: UInt32 {
    switch self {
    case .hz44100: 44_100
    case .hz48000: 48_000
    case .hz96000: 96_000
    }
  }
}

public struct DoryVirtioSoundPCMParameters: Sendable, Hashable {
  public let bufferBytes: UInt32
  public let periodBytes: UInt32
  public let channels: UInt8
  public let format: DoryVirtioSoundPCMFormat
  public let rate: DoryVirtioSoundPCMRate

  public init(
    bufferBytes: UInt32,
    periodBytes: UInt32,
    channels: UInt8,
    format: DoryVirtioSoundPCMFormat,
    rate: DoryVirtioSoundPCMRate
  ) {
    self.bufferBytes = bufferBytes
    self.periodBytes = periodBytes
    self.channels = channels
    self.format = format
    self.rate = rate
  }

  public var frameBytes: Int { Int(channels) * format.bytesPerSample }
}

public protocol DoryVirtioSoundBackend: AnyObject, Sendable {
  func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws
  func prepare(streamID: UInt32) throws
  func start(streamID: UInt32) throws
  func stop(streamID: UInt32) throws
  func release(streamID: UInt32) throws
  func play(streamID: UInt32, pcmBytes: [UInt8]) throws
  func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8]
}

/// Optional backend capability projection. When absent, the transport retains the complete
/// format set for in-memory and test backends; production adapters publish only formats they can
/// execute without a late host-side rejection.
public protocol DoryVirtioSoundFormatCapability: AnyObject, Sendable {
  var supportedPCMFormats: Set<DoryVirtioSoundPCMFormat> { get }
}

public enum DoryVirtioSoundError: Error, Sendable, Equatable {
  case invalidDescriptorDirection
  case malformedRequest
  case responseBufferTooSmall(required: UInt64, actual: UInt64)
  case noPendingEvent
  case backendCaptureSize(expected: Int, actual: Int)
}

public struct DoryVirtioSoundEvent: Sendable, Hashable {
  public let code: UInt32
  public let data: UInt32

  public init(code: UInt32, data: UInt32) {
    self.code = code
    self.data = data
  }
}

/// Transport-neutral VirtIO sound PCM engine. It implements the standard control lifecycle and
/// message transport while leaving CoreAudio conversion and route ownership behind a narrow backend.
public final class DoryVirtioSoundDevice: @unchecked Sendable {
  public static let controlQueue: UInt16 = 0
  public static let eventQueue: UInt16 = 1
  public static let transmitQueue: UInt16 = 2
  public static let receiveQueue: UInt16 = 3

  private enum Code: UInt32 {
    case pcmInfo = 0x0100
    case pcmSetParameters = 0x0101
    case pcmPrepare = 0x0102
    case pcmRelease = 0x0103
    case pcmStart = 0x0104
    case pcmStop = 0x0105
  }

  private enum Status: UInt32 {
    case ok = 0x8000
    case badMessage = 0x8001
    case notSupported = 0x8002
    case ioError = 0x8003
  }

  private enum Lifecycle {
    case unconfigured
    case configured(DoryVirtioSoundPCMParameters)
    case prepared(DoryVirtioSoundPCMParameters)
    case running(DoryVirtioSoundPCMParameters)
    case stopped(DoryVirtioSoundPCMParameters)

    var parameters: DoryVirtioSoundPCMParameters? {
      switch self {
      case .unconfigured: nil
      case .configured(let value), .prepared(let value), .running(let value), .stopped(let value):
        value
      }
    }
  }

  public let backend: any DoryVirtioSoundBackend
  public let maximumBufferBytes: UInt32
  public let maximumPendingEvents: Int
  public let supportedPCMFormats: Set<DoryVirtioSoundPCMFormat>

  private let lock = NSLock()
  private var lifecycles: [Lifecycle] = [.unconfigured, .unconfigured]
  private var pendingEvents: [DoryVirtioSoundEvent] = []
  private var eventReadySink: (@Sendable () -> Void)?
  private var droppedEvents = 0

  public init(
    backend: any DoryVirtioSoundBackend,
    maximumBufferBytes: UInt32 = 16 * 1024 * 1024,
    maximumPendingEvents: Int = 1_024
  ) {
    precondition(maximumBufferBytes >= 4_096 && maximumPendingEvents > 0)
    self.backend = backend
    self.maximumBufferBytes = maximumBufferBytes
    self.maximumPendingEvents = maximumPendingEvents
    let backendFormats = (backend as? any DoryVirtioSoundFormatCapability)?
      .supportedPCMFormats ?? Set(DoryVirtioSoundPCMFormat.allCases)
    precondition(!backendFormats.isEmpty, "virtio-sound backend must support at least one format")
    supportedPCMFormats = backendFormats
  }

  public var offeredFeatures: DoryVirtioFeatures { [] }
  public var configuration: [UInt8] {
    littleEndian(UInt32(0)) + littleEndian(UInt32(2))
      + littleEndian(UInt32(0)) + littleEndian(UInt32(0))
  }
  public var hasPendingEvent: Bool { lock.withLock { !pendingEvents.isEmpty } }
  public var pendingEventCount: Int { lock.withLock { pendingEvents.count } }
  public var droppedEventCount: Int { lock.withLock { droppedEvents } }

  public func connectEventReadySink(_ sink: @escaping @Sendable () -> Void) {
    let ready = lock.withLock {
      eventReadySink = sink
      return !pendingEvents.isEmpty
    }
    if ready { sink() }
  }

  @discardableResult
  public func enqueueEvent(_ event: DoryVirtioSoundEvent) -> Bool {
    let delivery: (Bool, (@Sendable () -> Void)?) = lock.withLock {
      guard pendingEvents.count < maximumPendingEvents else {
        droppedEvents += 1
        return (false, nil)
      }
      pendingEvents.append(event)
      return (true, eventReadySink)
    }
    delivery.1?()
    return delivery.0
  }

  public func processControl(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    let (readable, writable) = try split(chain)
    let request = try gather(readable, memory: memory)
    guard request.count >= 4 else { throw DoryVirtioSoundError.malformedRequest }
    let response: [UInt8]
    switch Code(rawValue: read32(request, 0)) {
    case .pcmInfo:
      response = pcmInformation(request)
    case .pcmSetParameters:
      response = setParameters(request)
    case .pcmPrepare:
      response = transition(request, operation: .pcmPrepare)
    case .pcmRelease:
      response = transition(request, operation: .pcmRelease)
    case .pcmStart:
      response = transition(request, operation: .pcmStart)
    case .pcmStop:
      response = transition(request, operation: .pcmStop)
    case nil:
      response = littleEndian(Status.notSupported.rawValue)
    }
    try require(response.count, writable: chain.writableByteCount)
    try scatter(response, into: writable, memory: memory)
    return UInt32(response.count)
  }

  public func processEvent(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard chain.readableByteCount == 0, chain.descriptors.allSatisfy(\.deviceWillWrite) else {
      throw DoryVirtioSoundError.invalidDescriptorDirection
    }
    try require(8, writable: chain.writableByteCount)
    guard let event = lock.withLock({ pendingEvents.first }) else {
      throw DoryVirtioSoundError.noPendingEvent
    }
    try scatter(
      littleEndian(event.code) + littleEndian(event.data),
      into: chain.descriptors,
      memory: memory
    )
    lock.withLock {
      if pendingEvents.first == event { pendingEvents.removeFirst() }
    }
    return 8
  }

  public func processTransmit(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    let (readable, writable) = try split(chain)
    let request = try gather(readable, memory: memory)
    guard request.count >= 4 else { throw DoryVirtioSoundError.malformedRequest }
    let streamID = read32(request, 0)
    let state = lifecycle(streamID)
    guard streamID == 0, let parameters = state.parameters,
      isTransferReady(state), request.count > 4,
      (request.count - 4) % parameters.frameBytes == 0
    else {
      return try writeIOStatus(.ioError, to: writable, chain: chain, memory: memory)
    }
    do {
      try backend.play(streamID: streamID, pcmBytes: Array(request.dropFirst(4)))
      return try writeIOStatus(.ok, to: writable, chain: chain, memory: memory)
    } catch {
      return try writeIOStatus(.ioError, to: writable, chain: chain, memory: memory)
    }
  }

  public func processReceive(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard let first = chain.descriptors.first, !first.deviceWillWrite, first.length == 4,
      chain.descriptors.dropFirst().allSatisfy(\.deviceWillWrite),
      let statusDescriptor = chain.descriptors.last, statusDescriptor.deviceWillWrite,
      statusDescriptor.length >= 8
    else { throw DoryVirtioSoundError.invalidDescriptorDirection }
    let streamID = read32(try memory.read(at: first.address, byteCount: 4), 0)
    let state = lifecycle(streamID)
    let audioDescriptors = Array(chain.descriptors.dropFirst().dropLast())
    let audioBytes = audioDescriptors.reduce(0) { $0 + Int($1.length) }
    guard streamID == 1, let parameters = state.parameters, isTransferReady(state),
      audioBytes > 0, audioBytes % parameters.frameBytes == 0
    else {
      try memory.write(
        at: statusDescriptor.address,
        bytes: littleEndian(Status.ioError.rawValue) + littleEndian(UInt32(0))
      )
      return 8
    }
    do {
      let captured = try backend.capture(streamID: streamID, byteCount: audioBytes)
      guard captured.count == audioBytes else {
        throw DoryVirtioSoundError.backendCaptureSize(
          expected: audioBytes,
          actual: captured.count
        )
      }
      try scatter(captured, into: audioDescriptors, memory: memory)
      try memory.write(
        at: statusDescriptor.address,
        bytes: littleEndian(Status.ok.rawValue) + littleEndian(UInt32(0))
      )
      return UInt32(audioBytes + 8)
    } catch {
      try memory.write(
        at: statusDescriptor.address,
        bytes: littleEndian(Status.ioError.rawValue) + littleEndian(UInt32(0))
      )
      return 8
    }
  }

  public func reset() {
    lock.withLock {
      lifecycles = [.unconfigured, .unconfigured]
      pendingEvents.removeAll(keepingCapacity: true)
    }
  }

  private func pcmInformation(_ request: [UInt8]) -> [UInt8] {
    guard request.count == 16 else { return littleEndian(Status.badMessage.rawValue) }
    let start = read32(request, 4)
    let count = read32(request, 8)
    let size = read32(request, 12)
    guard count > 0, start < 2, count <= 2 - start, size >= 32 else {
      return littleEndian(Status.badMessage.rawValue)
    }
    var response = littleEndian(Status.ok.rawValue)
    for streamID in start..<(start + count) { response += streamInformation(streamID) }
    return response
  }

  private func streamInformation(_ streamID: UInt32) -> [UInt8] {
    let formats = supportedPCMFormats.reduce(UInt64(0)) {
      $0 | (UInt64(1) << UInt64($1.rawValue))
    }
    let rates = DoryVirtioSoundPCMRate.allCases.reduce(UInt64(0)) {
      $0 | (UInt64(1) << UInt64($1.rawValue))
    }
    return littleEndian(UInt32(0)) + littleEndian(UInt32(0))
      + littleEndian(formats) + littleEndian(rates)
      + [
        streamID == 0
          ? DoryVirtioSoundDirection.output.rawValue : DoryVirtioSoundDirection.input.rawValue
      ]
      + [1, 2] + [UInt8](repeating: 0, count: 5)
  }

  private func setParameters(_ request: [UInt8]) -> [UInt8] {
    guard request.count == 24 else { return littleEndian(Status.badMessage.rawValue) }
    let streamID = read32(request, 4)
    let bufferBytes = read32(request, 8)
    let periodBytes = read32(request, 12)
    let features = read32(request, 16)
    let channels = request[20]
    guard streamID < 2, features == 0, channels == 1 || channels == 2,
      let format = DoryVirtioSoundPCMFormat(rawValue: request[21]),
      supportedPCMFormats.contains(format),
      let rate = DoryVirtioSoundPCMRate(rawValue: request[22]), request[23] == 0,
      bufferBytes > 0, bufferBytes <= maximumBufferBytes, periodBytes > 0,
      bufferBytes % periodBytes == 0
    else { return littleEndian(Status.notSupported.rawValue) }
    let parameters = DoryVirtioSoundPCMParameters(
      bufferBytes: bufferBytes,
      periodBytes: periodBytes,
      channels: channels,
      format: format,
      rate: rate
    )
    guard periodBytes % UInt32(parameters.frameBytes) == 0 else {
      return littleEndian(Status.badMessage.rawValue)
    }
    do {
      try backend.configure(
        streamID: streamID,
        direction: streamID == 0 ? .output : .input,
        parameters: parameters
      )
      lock.withLock { lifecycles[Int(streamID)] = .configured(parameters) }
      return littleEndian(Status.ok.rawValue)
    } catch {
      return littleEndian(Status.ioError.rawValue)
    }
  }

  private func transition(_ request: [UInt8], operation: Code) -> [UInt8] {
    guard request.count == 8 else { return littleEndian(Status.badMessage.rawValue) }
    let streamID = read32(request, 4)
    guard streamID < 2 else { return littleEndian(Status.badMessage.rawValue) }
    let current = lifecycle(streamID)
    guard let parameters = current.parameters else {
      return littleEndian(Status.badMessage.rawValue)
    }
    let next: Lifecycle
    do {
      switch operation {
      case .pcmPrepare:
        guard case .configured = current else {
          if case .prepared = current { return littleEndian(Status.ok.rawValue) }
          return littleEndian(Status.badMessage.rawValue)
        }
        try backend.prepare(streamID: streamID)
        next = .prepared(parameters)
      case .pcmStart:
        guard isStartable(current) else { return littleEndian(Status.badMessage.rawValue) }
        try backend.start(streamID: streamID)
        next = .running(parameters)
      case .pcmStop:
        guard case .running = current else { return littleEndian(Status.badMessage.rawValue) }
        try backend.stop(streamID: streamID)
        next = .stopped(parameters)
      case .pcmRelease:
        guard !isRunning(current) else { return littleEndian(Status.badMessage.rawValue) }
        try backend.release(streamID: streamID)
        next = .configured(parameters)
      default:
        return littleEndian(Status.notSupported.rawValue)
      }
    } catch {
      return littleEndian(Status.ioError.rawValue)
    }
    lock.withLock { lifecycles[Int(streamID)] = next }
    return littleEndian(Status.ok.rawValue)
  }

  private func lifecycle(_ streamID: UInt32) -> Lifecycle {
    lock.withLock {
      streamID < UInt32(lifecycles.count) ? lifecycles[Int(streamID)] : .unconfigured
    }
  }

  private func isTransferReady(_ lifecycle: Lifecycle) -> Bool {
    switch lifecycle {
    case .prepared, .running: true
    default: false
    }
  }

  private func isStartable(_ lifecycle: Lifecycle) -> Bool {
    switch lifecycle {
    case .prepared, .stopped: true
    default: false
    }
  }

  private func isRunning(_ lifecycle: Lifecycle) -> Bool {
    if case .running = lifecycle { return true }
    return false
  }

  private func writeIOStatus(
    _ status: Status,
    to writable: [DoryVirtioDescriptor],
    chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    try require(8, writable: chain.writableByteCount)
    try scatter(
      littleEndian(status.rawValue) + littleEndian(UInt32(0)),
      into: writable,
      memory: memory
    )
    return 8
  }

  private func split(
    _ chain: DoryVirtioDescriptorChain
  ) throws -> ([DoryVirtioDescriptor], [DoryVirtioDescriptor]) {
    let readable = chain.descriptors.prefix(while: { !$0.deviceWillWrite })
    let writable = chain.descriptors.dropFirst(readable.count)
    guard !readable.isEmpty, !writable.isEmpty, writable.allSatisfy(\.deviceWillWrite) else {
      throw DoryVirtioSoundError.invalidDescriptorDirection
    }
    return (Array(readable), Array(writable))
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var bytes: [UInt8] = []
    for descriptor in descriptors {
      let part = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
      guard part.count == Int(descriptor.length) else {
        throw DoryVirtioSoundError.malformedRequest
      }
      bytes += part
    }
    return bytes
  }

  private func scatter(
    _ bytes: [UInt8],
    into descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    var offset = 0
    for descriptor in descriptors where offset < bytes.count {
      let count = min(Int(descriptor.length), bytes.count - offset)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[offset..<(offset + count)])
      )
      offset += count
    }
    guard offset == bytes.count else { throw DoryVirtioSoundError.malformedRequest }
  }

  private func require(_ bytes: Int, writable: UInt64) throws {
    guard UInt64(bytes) <= writable else {
      throw DoryVirtioSoundError.responseBufferTooSmall(
        required: UInt64(bytes),
        actual: writable
      )
    }
  }
}

public final class DoryVirtioInMemorySoundBackend: DoryVirtioSoundBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var configurations: [UInt32: DoryVirtioSoundPCMParameters] = [:]
  private var playbackBuffers: [[UInt8]] = []
  private var captureBytes: [UInt8] = []

  public init() {}

  public var playedBuffers: [[UInt8]] { lock.withLock { playbackBuffers } }

  public func configure(
    streamID: UInt32,
    direction: DoryVirtioSoundDirection,
    parameters: DoryVirtioSoundPCMParameters
  ) throws {
    lock.withLock { configurations[streamID] = parameters }
  }
  public func prepare(streamID: UInt32) throws {}
  public func start(streamID: UInt32) throws {}
  public func stop(streamID: UInt32) throws {}
  public func release(streamID: UInt32) throws {}
  public func play(streamID: UInt32, pcmBytes: [UInt8]) throws {
    lock.withLock { playbackBuffers.append(pcmBytes) }
  }
  public func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
    lock.withLock {
      let count = min(byteCount, captureBytes.count)
      let result = Array(captureBytes.prefix(count))
      captureBytes.removeFirst(count)
      return result + [UInt8](repeating: 0, count: byteCount - count)
    }
  }
  public func enqueueCaptureBytes(_ bytes: [UInt8]) {
    lock.withLock { captureBytes += bytes }
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
