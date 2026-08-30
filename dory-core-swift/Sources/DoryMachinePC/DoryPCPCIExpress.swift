import DoryDBTX86
import Foundation

public struct DoryPCPCIAddress: Codable, Sendable, Hashable, Comparable {
  public let segment: UInt16
  public let bus: UInt8
  public let device: UInt8
  public let function: UInt8

  public init(segment: UInt16 = 0, bus: UInt8, device: UInt8, function: UInt8) {
    precondition(device < 32 && function < 8)
    self.segment = segment
    self.bus = bus
    self.device = device
    self.function = function
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.segment, lhs.bus, lhs.device, lhs.function)
      < (rhs.segment, rhs.bus, rhs.device, rhs.function)
  }
}

public enum DoryPCPCIBARKind: Sendable, Hashable {
  case memory32(prefetchable: Bool)
  case memory64(prefetchable: Bool)
  case io
}

public struct DoryPCPCIBARDescriptor: Sendable, Hashable {
  public let index: Int
  public let kind: DoryPCPCIBARKind
  public let size: UInt64
  public let address: UInt64

  public init(index: Int, kind: DoryPCPCIBARKind, size: UInt64, address: UInt64 = 0) {
    precondition((0..<6).contains(index))
    precondition(size >= 4 && size.nonzeroBitCount == 1)
    self.index = index
    self.kind = kind
    self.size = size
    self.address = address
  }
}

public enum DoryPCPCIError: Error, Sendable, Equatable {
  case sealed
  case duplicateAddress(DoryPCPCIAddress)
  case addressOutsideHost(DoryPCPCIAddress)
  case invalidBAR(index: Int)
  case overlappingBAR(index: Int)
  case unsupportedConfigurationAccess(offset: Int, byteCount: Int)
}

public protocol DoryPCPCIFunction: AnyObject, Sendable {
  var pciAddress: DoryPCPCIAddress { get }
  func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8]
  func writeConfiguration(offset: Int, bytes: [UInt8]) throws
}

public protocol DoryPCPCIMSIControllable: DoryPCPCIFunction {
  func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  )
}

public protocol DoryPCPCIBARMemoryDevice: AnyObject, Sendable {
  var configurationFunction: DoryPCPCIConfigurationFunction { get }
  var barIndex: Int { get }
  func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8]
  func writeBAR(offset: UInt64, bytes: [UInt8]) throws
  func validateBARWrite(offset: UInt64, byteCount: Int) throws
}

extension DoryPCPCIBARMemoryDevice {
  public func validateBARWrite(offset: UInt64, byteCount: Int) throws {
    guard let bar = try configurationFunction.bar(at: barIndex),
      byteCount > 0,
      offset <= bar.size,
      UInt64(byteCount) <= bar.size - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: true
      )
    }
  }
}

public struct DoryPCPCIMSIState: Sendable, Hashable {
  public let enabled: Bool
  public let messageAddress: UInt64
  public let messageData: UInt16
}

public struct DoryPCPCIMSIMessage: Sendable, Hashable {
  public let destinationAPICID: UInt32
  public let vector: UInt8

  public static func decode(address: UInt64, data: UInt16) -> Self? {
    guard address >> 32 == 0,
      address & 0xFFF0_0000 == 0xFEE0_0000,
      address & (1 << 2) == 0,
      data & 0x0700 == 0,
      data & (1 << 15) == 0
    else { return nil }
    let vector = UInt8(truncatingIfNeeded: data)
    guard vector >= 0x10 else { return nil }
    return .init(
      destinationAPICID: UInt32(truncatingIfNeeded: address >> 12) & 0xFF,
      vector: vector
    )
  }
}

/// PCI type-0 configuration header with architectural BAR probing and programming behavior.
public final class DoryPCPCIConfigurationFunction: DoryPCPCIMSIControllable, @unchecked Sendable {
  private struct BARState {
    let kind: DoryPCPCIBARKind
    let size: UInt64
    var address: UInt64
    var probeLow = false
    var probeHigh = false
  }

  public let pciAddress: DoryPCPCIAddress
  private let lock = NSLock()
  private var configuration = [UInt8](repeating: 0, count: 4096)
  private var bars: [Int: BARState] = [:]
  private var upperBARSlots: Set<Int> = []
  private let supportsMSI: Bool
  private var msiSink: (@Sendable (UInt64, UInt16) -> Bool)?

  public init(
    address: DoryPCPCIAddress,
    vendorID: UInt16,
    deviceID: UInt16,
    classCode: UInt32,
    revisionID: UInt8 = 0,
    subsystemVendorID: UInt16 = 0,
    subsystemID: UInt16 = 0,
    interruptPin: UInt8 = 0,
    supportsMSI: Bool = false,
    msiNextCapabilityOffset: UInt8 = 0,
    bars descriptors: [DoryPCPCIBARDescriptor] = []
  ) throws {
    pciAddress = address
    self.supportsMSI = supportsMSI
    put(vendorID, at: 0x00, in: &configuration)
    put(deviceID, at: 0x02, in: &configuration)
    configuration[0x08] = revisionID
    configuration[0x09] = UInt8(truncatingIfNeeded: classCode)
    configuration[0x0A] = UInt8(truncatingIfNeeded: classCode >> 8)
    configuration[0x0B] = UInt8(truncatingIfNeeded: classCode >> 16)
    configuration[0x0E] = 0
    put(subsystemVendorID, at: 0x2C, in: &configuration)
    put(subsystemID, at: 0x2E, in: &configuration)
    configuration[0x3C] = 0xFF
    configuration[0x3D] = interruptPin
    if supportsMSI {
      configuration[0x06] |= 1 << 4
      configuration[0x34] = 0x50
      configuration[0x50] = 0x05
      configuration[0x51] = msiNextCapabilityOffset
      // One 64-bit message, no per-vector mask, one vector.
      put(UInt16(1 << 7), at: 0x52, in: &configuration)
    }

    for descriptor in descriptors.sorted(by: { $0.index < $1.index }) {
      guard bars[descriptor.index] == nil, !upperBARSlots.contains(descriptor.index) else {
        throw DoryPCPCIError.overlappingBAR(index: descriptor.index)
      }
      if case .memory64 = descriptor.kind {
        guard descriptor.index < 5, bars[descriptor.index + 1] == nil,
          !upperBARSlots.contains(descriptor.index + 1)
        else { throw DoryPCPCIError.invalidBAR(index: descriptor.index) }
        upperBARSlots.insert(descriptor.index + 1)
      }
      bars[descriptor.index] = .init(
        kind: descriptor.kind,
        size: descriptor.size,
        address: descriptor.address & ~(descriptor.size - 1)
      )
    }
  }

  public var command: UInt16 {
    lock.withLock { get(UInt16.self, at: 0x04, in: configuration) }
  }

  public var msiState: DoryPCPCIMSIState? {
    lock.withLock {
      guard supportsMSI else { return nil }
      return .init(
        enabled: get(UInt16.self, at: 0x52, in: configuration) & 1 != 0,
        messageAddress: UInt64(get(UInt32.self, at: 0x54, in: configuration))
          | UInt64(get(UInt32.self, at: 0x58, in: configuration)) << 32,
        messageData: get(UInt16.self, at: 0x5C, in: configuration)
      )
    }
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    lock.withLock { msiSink = sink }
  }

  @discardableResult
  public func raiseMSI() -> Bool {
    let delivery: (sink: @Sendable (UInt64, UInt16) -> Bool, address: UInt64, data: UInt16)? =
      lock.withLock {
        guard supportsMSI, configuration[0x52] & 1 != 0, let msiSink else { return nil }
        let address =
          UInt64(get(UInt32.self, at: 0x54, in: configuration))
          | UInt64(get(UInt32.self, at: 0x58, in: configuration)) << 32
        return (msiSink, address, get(UInt16.self, at: 0x5C, in: configuration))
      }
    guard let delivery else { return false }
    return delivery.sink(delivery.address, delivery.data)
  }

  public func bar(at index: Int) throws -> DoryPCPCIBARDescriptor? {
    try lock.withLock {
      guard (0..<6).contains(index) else { throw DoryPCPCIError.invalidBAR(index: index) }
      guard let bar = bars[index] else { return nil }
      return .init(index: index, kind: bar.kind, size: bar.size, address: bar.address)
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try validate(offset: offset, byteCount: byteCount)
    return lock.withLock {
      var bytes = Array(configuration[offset..<(offset + byteCount)])
      for byteIndex in bytes.indices {
        let absoluteOffset = offset + byteIndex
        guard (0x10..<0x28).contains(absoluteOffset) else { continue }
        let slot = (absoluteOffset - 0x10) / 4
        let slotByte = (absoluteOffset - 0x10) % 4
        let value = barRegisterLocked(slot: slot)
        bytes[byteIndex] = UInt8(truncatingIfNeeded: value >> UInt32(slotByte * 8))
      }
      return bytes
    }
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try validate(offset: offset, byteCount: bytes.count)
    try lock.withLock {
      if offset >= 0x10, offset < 0x28, bytes.count == 4, offset % 4 == 0 {
        try writeBARLocked(slot: (offset - 0x10) / 4, value: uint32(bytes))
        return
      }
      if supportsMSI, offset < 0x5E, offset + bytes.count > 0x52 {
        for (index, value) in bytes.enumerated() {
          let register = offset + index
          switch register {
          case 0x52:
            configuration[register] = (configuration[register] & 0xFE) | (value & 1)
          case 0x54...0x5D:
            configuration[register] = value
          default:
            break
          }
        }
        return
      }
      for (index, value) in bytes.enumerated() where writableConfigurationByte(offset + index) {
        configuration[offset + index] = value
      }
    }
  }

  private func barRegisterLocked(slot: Int) -> UInt32 {
    if let bar = bars[slot] {
      let type = typeBits(bar.kind)
      if bar.probeLow {
        return UInt32(truncatingIfNeeded: ~(bar.size - 1)) & addressMask(bar.kind) | type
      }
      return UInt32(truncatingIfNeeded: bar.address) & addressMask(bar.kind) | type
    }
    guard upperBARSlots.contains(slot), let lowerIndex = bars.keys.first(where: { $0 + 1 == slot }),
      let bar = bars[lowerIndex]
    else { return 0 }
    if bar.probeHigh { return UInt32(truncatingIfNeeded: ~(bar.size - 1) >> 32) }
    return UInt32(truncatingIfNeeded: bar.address >> 32)
  }

  private func writeBARLocked(slot: Int, value: UInt32) throws {
    if var bar = bars[slot] {
      if value == .max {
        bar.probeLow = true
      } else {
        bar.probeLow = false
        let low = UInt64(value & addressMask(bar.kind))
        bar.address = ((bar.address & 0xFFFF_FFFF_0000_0000) | low) & ~(bar.size - 1)
      }
      bars[slot] = bar
      return
    }
    guard upperBARSlots.contains(slot), let lowerIndex = bars.keys.first(where: { $0 + 1 == slot }),
      var bar = bars[lowerIndex]
    else { return }
    if value == .max {
      bar.probeHigh = true
    } else {
      bar.probeHigh = false
      bar.address = ((UInt64(value) << 32) | (bar.address & 0xFFFF_FFFF)) & ~(bar.size - 1)
    }
    bars[lowerIndex] = bar
  }

  private func writableConfigurationByte(_ offset: Int) -> Bool {
    (0x04...0x05).contains(offset) || (0x0C...0x0D).contains(offset) || offset == 0x3C
  }

  private func typeBits(_ kind: DoryPCPCIBARKind) -> UInt32 {
    switch kind {
    case .memory32(let prefetchable): return prefetchable ? 0x8 : 0
    case .memory64(let prefetchable): return 0x4 | (prefetchable ? 0x8 : 0)
    case .io: return 1
    }
  }

  private func addressMask(_ kind: DoryPCPCIBARKind) -> UInt32 {
    switch kind {
    case .memory32, .memory64: return 0xFFFF_FFF0
    case .io: return 0xFFFF_FFFC
    }
  }

  private func validate(offset: Int, byteCount: Int) throws {
    guard byteCount > 0, offset >= 0, offset <= configuration.count,
      byteCount <= configuration.count - offset
    else {
      throw DoryPCPCIError.unsupportedConfigurationAccess(offset: offset, byteCount: byteCount)
    }
  }
}

/// Enhanced Configuration Access Mechanism for segment zero and the full 256-bus PCIe domain.
public final class DoryPCPCIExpressECAM: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: UInt64
  public let segment: UInt16
  public let startBus: UInt8
  public let endBus: UInt8

  private let lock = NSLock()
  private var functions: [DoryPCPCIAddress: any DoryPCPCIFunction] = [:]
  private var isSealed = false

  public init(
    baseAddress: UInt64 = 0xE000_0000,
    segment: UInt16 = 0,
    startBus: UInt8 = 0,
    endBus: UInt8 = 0xFF
  ) {
    precondition(startBus <= endBus)
    self.baseAddress = baseAddress
    self.segment = segment
    self.startBus = startBus
    self.endBus = endBus
    byteCount = UInt64(Int(endBus) - Int(startBus) + 1) << 20
  }

  public func attach(_ function: any DoryPCPCIFunction) throws {
    try lock.withLock {
      guard !isSealed else { throw DoryPCPCIError.sealed }
      let address = function.pciAddress
      guard address.segment == segment, address.bus >= startBus, address.bus <= endBus else {
        throw DoryPCPCIError.addressOutsideHost(address)
      }
      guard functions[address] == nil else { throw DoryPCPCIError.duplicateAddress(address) }
      functions[address] = function
    }
  }

  public func seal() { lock.withLock { isSealed = true } }

  public func function(at address: DoryPCPCIAddress) -> (any DoryPCPCIFunction)? {
    lock.withLock { functions[address] }
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let resolved = try resolve(offset: offset, byteCount: byteCount)
    guard let function = resolved.function else {
      return [UInt8](repeating: 0xFF, count: byteCount)
    }
    return try function.readConfiguration(offset: resolved.register, byteCount: byteCount)
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    let resolved = try resolve(offset: offset, byteCount: bytes.count)
    try resolved.function?.writeConfiguration(offset: resolved.register, bytes: bytes)
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    _ = try resolve(offset: offset, byteCount: byteCount)
  }

  private func resolve(
    offset: UInt64,
    byteCount: Int
  ) throws -> (function: (any DoryPCPCIFunction)?, register: Int) {
    guard byteCount > 0, offset < self.byteCount, UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: false
      )
    }
    let register = Int(offset & 0xFFF)
    guard byteCount <= 4096 - register else {
      throw DoryPCPCIError.unsupportedConfigurationAccess(offset: register, byteCount: byteCount)
    }
    let bus = UInt8(truncatingIfNeeded: UInt64(startBus) + (offset >> 20))
    let device = UInt8(truncatingIfNeeded: (offset >> 15) & 0x1F)
    let functionNumber = UInt8(truncatingIfNeeded: (offset >> 12) & 7)
    let address = DoryPCPCIAddress(
      segment: segment,
      bus: bus,
      device: device,
      function: functionNumber
    )
    return (lock.withLock { functions[address] }, register)
  }
}

/// Frozen DoryPC PCI MMIO aperture. Routing is resolved from live BAR registers on every access,
/// so firmware and the OS may size and relocate devices without mutating the sealed physical bus.
public final class DoryPCPCIBARWindow: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: UInt64

  private let lock = NSLock()
  private var devices: [any DoryPCPCIBARMemoryDevice] = []
  private var isSealed = false

  public init(baseAddress: UInt64 = 0xD000_0000, byteCount: UInt64 = 0x1000_0000) {
    precondition(byteCount > 0 && baseAddress <= UInt64.max - byteCount)
    self.baseAddress = baseAddress
    self.byteCount = byteCount
  }

  public func attach(_ device: any DoryPCPCIBARMemoryDevice) throws {
    try lock.withLock {
      guard !isSealed else { throw DoryPCPCIError.sealed }
      devices.append(device)
    }
  }

  public func seal() { lock.withLock { isSealed = true } }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let resolved = try resolve(offset: offset, byteCount: byteCount, write: false)
    return try resolved.device.readBAR(offset: resolved.barOffset, byteCount: byteCount)
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    let resolved = try resolve(offset: offset, byteCount: bytes.count, write: true)
    try resolved.device.writeBAR(offset: resolved.barOffset, bytes: bytes)
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    let resolved = try resolve(offset: offset, byteCount: byteCount, write: true)
    try resolved.device.validateBARWrite(offset: resolved.barOffset, byteCount: byteCount)
  }

  private func resolve(
    offset: UInt64,
    byteCount: Int,
    write: Bool
  ) throws -> (device: any DoryPCPCIBARMemoryDevice, barOffset: UInt64) {
    guard byteCount > 0, offset <= self.byteCount, UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
    let (address, addressOverflow) = baseAddress.addingReportingOverflow(offset)
    let (accessEnd, endOverflow) = address.addingReportingOverflow(UInt64(byteCount))
    guard !addressOverflow, !endOverflow else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
    let snapshot = lock.withLock { devices }
    let matches = try snapshot.compactMap { device -> (any DoryPCPCIBARMemoryDevice, UInt64)? in
      guard device.configurationFunction.command & 2 != 0,
        let bar = try device.configurationFunction.bar(at: device.barIndex),
        bar.address >= baseAddress,
        bar.address < baseAddress + self.byteCount
      else { return nil }
      let (barEnd, overflow) = bar.address.addingReportingOverflow(bar.size)
      guard !overflow, address >= bar.address, accessEnd <= barEnd else { return nil }
      return (device, address - bar.address)
    }
    guard matches.count == 1, let match = matches.first else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
    return match
  }
}

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
  for index in 0..<MemoryLayout<T>.size {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}

private func get<T: FixedWidthInteger>(_ type: T.Type, at offset: Int, in bytes: [UInt8]) -> T {
  (0..<MemoryLayout<T>.size).reduce(0) {
    $0 | T(bytes[offset + $1]) << T($1 * 8)
  }
}

private func uint32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}
