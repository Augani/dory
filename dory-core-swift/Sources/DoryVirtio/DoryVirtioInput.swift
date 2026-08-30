import Foundation

public struct DoryVirtioInputEvent: Sendable, Hashable {
  public let type: UInt16
  public let code: UInt16
  public let value: UInt32

  public init(type: UInt16, code: UInt16, value: UInt32) {
    self.type = type
    self.code = code
    self.value = value
  }

  public static let synchronize = Self(type: 0, code: 0, value: 0)
}

public struct DoryVirtioInputAbsoluteAxis: Sendable, Hashable {
  public let minimum: Int32
  public let maximum: Int32
  public let fuzz: Int32
  public let flat: Int32
  public let resolution: Int32

  public init(
    minimum: Int32,
    maximum: Int32,
    fuzz: Int32 = 0,
    flat: Int32 = 0,
    resolution: Int32 = 0
  ) {
    self.minimum = minimum
    self.maximum = maximum
    self.fuzz = fuzz
    self.flat = flat
    self.resolution = resolution
  }
}

public struct DoryVirtioInputIdentity: Sendable, Hashable {
  public let busType: UInt16
  public let vendor: UInt16
  public let product: UInt16
  public let version: UInt16

  public init(busType: UInt16 = 0x06, vendor: UInt16 = 0x1AF4, product: UInt16, version: UInt16 = 1)
  {
    self.busType = busType
    self.vendor = vendor
    self.product = product
    self.version = version
  }
}

public struct DoryVirtioInputDescriptor: Sendable, Hashable {
  public let name: String
  public let serial: String
  public let identity: DoryVirtioInputIdentity
  public let properties: Set<UInt16>
  public let eventCodes: [UInt16: Set<UInt16>]
  public let absoluteAxes: [UInt16: DoryVirtioInputAbsoluteAxis]

  public init(
    name: String,
    serial: String,
    identity: DoryVirtioInputIdentity,
    properties: Set<UInt16> = [],
    eventCodes: [UInt16: Set<UInt16>],
    absoluteAxes: [UInt16: DoryVirtioInputAbsoluteAxis] = [:]
  ) {
    self.name = name
    self.serial = serial
    self.identity = identity
    self.properties = properties
    self.eventCodes = eventCodes
    self.absoluteAxes = absoluteAxes
  }

  public static func keyboard(serial: String = "dory-keyboard") -> Self {
    .init(
      name: "Dory Virtual Keyboard",
      serial: serial,
      identity: .init(product: 1),
      eventCodes: [1: Set(UInt16(1)...UInt16(0xFF))]
    )
  }

  public static func relativePointer(serial: String = "dory-pointer") -> Self {
    .init(
      name: "Dory Virtual Pointer",
      serial: serial,
      identity: .init(product: 2),
      eventCodes: [
        1: [0x110, 0x111, 0x112],
        2: [0, 1, 6, 8],
      ]
    )
  }

  public static func absolutePointer(serial: String = "dory-tablet") -> Self {
    .init(
      name: "Dory Virtual Tablet",
      serial: serial,
      identity: .init(product: 3),
      properties: [1],
      eventCodes: [
        1: [0x110, 0x111, 0x112],
        3: [0, 1],
      ],
      absoluteAxes: [
        0: .init(minimum: 0, maximum: 32_767),
        1: .init(minimum: 0, maximum: 32_767),
      ]
    )
  }
}

public protocol DoryVirtioInputStatusSink: AnyObject, Sendable {
  func inputDeviceDidReceiveStatus(_ event: DoryVirtioInputEvent)
}

public enum DoryVirtioInputError: Error, Sendable, Equatable {
  case invalidDescriptor
  case invalidDescriptorDirection
  case noPendingEvent
  case eventBufferTooSmall(UInt64)
  case malformedStatus
}

/// Transport-neutral VirtIO input device. Host events are bounded and delivered only into posted
/// eventq buffers; statusq feedback is forwarded to an optional narrow host sink.
public final class DoryVirtioInputDevice: @unchecked Sendable {
  public static let eventQueue: UInt16 = 0
  public static let statusQueue: UInt16 = 1
  public static let eventByteCount = 8

  public let descriptor: DoryVirtioInputDescriptor
  public let maximumPendingEvents: Int

  private let lock = NSLock()
  private weak var statusSink: (any DoryVirtioInputStatusSink)?
  private var pendingEvents: [DoryVirtioInputEvent] = []
  private var eventReadySink: (@Sendable () -> Void)?
  private var droppedEvents = 0

  public init(
    descriptor: DoryVirtioInputDescriptor,
    maximumPendingEvents: Int = 4_096,
    statusSink: (any DoryVirtioInputStatusSink)? = nil
  ) throws {
    guard !descriptor.name.utf8.isEmpty, descriptor.name.utf8.count <= 128,
      descriptor.serial.utf8.count <= 128,
      descriptor.properties.allSatisfy({ $0 < 1_024 }),
      descriptor.eventCodes.allSatisfy({ type, codes in
        type < 1_024 && codes.allSatisfy({ $0 < 1_024 })
      }),
      descriptor.absoluteAxes.keys.allSatisfy({ $0 < 1_024 }),
      descriptor.absoluteAxes.values.allSatisfy({ $0.minimum <= $0.maximum }),
      maximumPendingEvents > 0
    else { throw DoryVirtioInputError.invalidDescriptor }
    self.descriptor = descriptor
    self.maximumPendingEvents = maximumPendingEvents
    self.statusSink = statusSink
  }

  public var offeredFeatures: DoryVirtioFeatures { [] }
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
  public func enqueue(_ events: [DoryVirtioInputEvent]) -> Bool {
    guard !events.isEmpty else { return true }
    let delivery: (Bool, (@Sendable () -> Void)?) = lock.withLock {
      guard events.count <= maximumPendingEvents - pendingEvents.count else {
        droppedEvents += events.count
        return (false, nil)
      }
      pendingEvents += events
      return (true, eventReadySink)
    }
    delivery.1?()
    return delivery.0
  }

  @discardableResult
  public func enqueueSynchronized(_ events: [DoryVirtioInputEvent]) -> Bool {
    enqueue(events + [.synchronize])
  }

  public func configuration(select: UInt8, subselect: UInt8) -> [UInt8] {
    var payload: [UInt8]
    switch select {
    case 0x01: payload = Array(descriptor.name.utf8)
    case 0x02: payload = Array(descriptor.serial.utf8)
    case 0x03:
      payload =
        littleEndian(descriptor.identity.busType)
        + littleEndian(descriptor.identity.vendor)
        + littleEndian(descriptor.identity.product)
        + littleEndian(descriptor.identity.version)
    case 0x10: payload = bitmap(descriptor.properties)
    case 0x11: payload = bitmap(descriptor.eventCodes[UInt16(subselect)] ?? [])
    case 0x12:
      if let axis = descriptor.absoluteAxes[UInt16(subselect)] {
        payload =
          littleEndian(UInt32(bitPattern: axis.minimum))
          + littleEndian(UInt32(bitPattern: axis.maximum))
          + littleEndian(UInt32(bitPattern: axis.fuzz))
          + littleEndian(UInt32(bitPattern: axis.flat))
          + littleEndian(UInt32(bitPattern: axis.resolution))
      } else {
        payload = []
      }
    default: payload = []
    }
    payload = Array(payload.prefix(128))
    return [select, subselect, UInt8(payload.count)] + [UInt8](repeating: 0, count: 5)
      + payload + [UInt8](repeating: 0, count: 128 - payload.count)
  }

  public func processEvent(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard !chain.descriptors.isEmpty, chain.readableByteCount == 0,
      chain.descriptors.allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioInputError.invalidDescriptorDirection }
    guard chain.writableByteCount >= UInt64(Self.eventByteCount) else {
      throw DoryVirtioInputError.eventBufferTooSmall(chain.writableByteCount)
    }
    guard let event = lock.withLock({ pendingEvents.first }) else {
      throw DoryVirtioInputError.noPendingEvent
    }
    let bytes = eventBytes(event)
    try scatter(bytes, into: chain.descriptors, memory: memory)
    lock.withLock {
      if pendingEvents.first == event { pendingEvents.removeFirst() }
    }
    return UInt32(bytes.count)
  }

  public func processStatus(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard !chain.descriptors.isEmpty, chain.writableByteCount == 0,
      chain.descriptors.allSatisfy({ !$0.deviceWillWrite })
    else { throw DoryVirtioInputError.invalidDescriptorDirection }
    var bytes: [UInt8] = []
    for descriptor in chain.descriptors {
      let part = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
      guard part.count == Int(descriptor.length) else {
        throw DoryVirtioInputError.malformedStatus
      }
      bytes += part
    }
    guard !bytes.isEmpty, bytes.count % Self.eventByteCount == 0 else {
      throw DoryVirtioInputError.malformedStatus
    }
    let sink = lock.withLock { statusSink }
    for offset in stride(from: 0, to: bytes.count, by: Self.eventByteCount) {
      sink?.inputDeviceDidReceiveStatus(
        .init(
          type: read16(bytes, offset),
          code: read16(bytes, offset + 2),
          value: read32(bytes, offset + 4)
        )
      )
    }
    return 0
  }

  public func reset() {
    lock.withLock { pendingEvents.removeAll(keepingCapacity: true) }
  }

  private func bitmap(_ values: Set<UInt16>) -> [UInt8] {
    guard let maximum = values.max() else { return [] }
    var bytes = [UInt8](repeating: 0, count: Int(maximum / 8) + 1)
    for value in values { bytes[Int(value / 8)] |= 1 << UInt8(value % 8) }
    return bytes
  }

  private func eventBytes(_ event: DoryVirtioInputEvent) -> [UInt8] {
    littleEndian(event.type) + littleEndian(event.code) + littleEndian(event.value)
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
    guard offset == bytes.count else {
      throw DoryVirtioInputError.eventBufferTooSmall(UInt64(offset))
    }
  }
}

private func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
  UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
