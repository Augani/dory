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
  case invalidMSIXConfiguration
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

public protocol DoryPCPCIINTxControllable: DoryPCPCIFunction {
  var interruptLine: UInt8 { get }
  func connectINTxSink(
    _ sink: @escaping @Sendable (_ interruptLine: UInt8, _ asserted: Bool) -> Void
  )
}

public protocol DoryPCPCIBARMemoryDevice: AnyObject, Sendable {
  var configurationFunction: DoryPCPCIConfigurationFunction { get }
  var barIndex: Int { get }
  func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8]
  func validateBARRead(offset: UInt64, byteCount: Int) throws
  func writeBAR(offset: UInt64, bytes: [UInt8]) throws
  func validateBARWrite(offset: UInt64, byteCount: Int) throws
}

extension DoryPCPCIBARMemoryDevice {
  public func validateBARRead(offset: UInt64, byteCount: Int) throws {
    guard let bar = try configurationFunction.bar(at: barIndex),
      byteCount > 0,
      offset <= bar.size,
      UInt64(byteCount) <= bar.size - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: false
      )
    }
  }

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

extension DoryPCPCIINTxControllable where Self: DoryPCPCIBARMemoryDevice {
  public var interruptLine: UInt8 { configurationFunction.interruptLine }

  public func connectINTxSink(
    _ sink: @escaping @Sendable (_ interruptLine: UInt8, _ asserted: Bool) -> Void
  ) {
    configurationFunction.connectINTxSink(sink)
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

public struct DoryPCPCIINTxState: Sendable, Hashable {
  public let asserted: Bool
  public let externallyAsserted: Bool
  public let interruptLine: UInt8
  public let interruptPin: UInt8
}

public struct DoryPCPCIMSIXEntry: Sendable, Hashable {
  public let messageAddress: UInt64
  public let messageData: UInt32
  public let masked: Bool
  public let pending: Bool
}

public struct DoryPCPCIMSIXState: Sendable, Hashable {
  public let enabled: Bool
  public let functionMasked: Bool
  public let entries: [DoryPCPCIMSIXEntry]
}

private final class DoryPCPCIMSIXController: @unchecked Sendable {
  private struct Entry {
    var messageAddress: UInt64 = 0
    var messageData: UInt32 = 0
    var masked = true
  }

  let tableBAR: UInt8
  let tableOffset: UInt32
  let pendingBAR: UInt8
  let pendingOffset: UInt32

  private let lock = NSLock()
  private var enabled = false
  private var functionMasked = false
  private var entries: [Entry]
  private var pending: Set<Int> = []
  private var sink: (@Sendable (UInt64, UInt16) -> Bool)?

  init(
    vectorCount: Int,
    tableBAR: UInt8,
    tableOffset: UInt32,
    pendingBAR: UInt8,
    pendingOffset: UInt32
  ) {
    precondition((1...2048).contains(vectorCount))
    self.tableBAR = tableBAR
    self.tableOffset = tableOffset
    self.pendingBAR = pendingBAR
    self.pendingOffset = pendingOffset
    entries = .init(repeating: .init(), count: vectorCount)
  }

  var vectorCount: Int { entries.count }

  var control: UInt16 {
    lock.withLock {
      UInt16(entries.count - 1) | (functionMasked ? 1 << 14 : 0) | (enabled ? 1 << 15 : 0)
    }
  }

  var state: DoryPCPCIMSIXState {
    lock.withLock {
      .init(
        enabled: enabled,
        functionMasked: functionMasked,
        entries: entries.enumerated().map { index, entry in
          .init(
            messageAddress: entry.messageAddress,
            messageData: entry.messageData,
            masked: entry.masked,
            pending: pending.contains(index)
          )
        }
      )
    }
  }

  func connectSink(_ sink: @escaping @Sendable (UInt64, UInt16) -> Bool) {
    lock.withLock { self.sink = sink }
  }

  func writeControl(_ value: UInt16) {
    lock.withLock {
      enabled = value & (1 << 15) != 0
      functionMasked = value & (1 << 14) != 0
    }
    deliverPending()
  }

  func raise(vector: UInt16) -> Bool {
    let delivery: (sink: @Sendable (UInt64, UInt16) -> Bool, address: UInt64, data: UInt16)? =
      lock.withLock {
        let index = Int(vector)
        guard enabled, entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        guard !functionMasked, !entry.masked, let sink else {
          pending.insert(index)
          return nil
        }
        return (sink, entry.messageAddress, UInt16(truncatingIfNeeded: entry.messageData))
      }
    guard let delivery else { return false }
    let delivered = delivery.sink(delivery.address, delivery.data)
    if delivered { lock.withLock { _ = pending.remove(Int(vector)) } }
    return delivered
  }

  func readBAR(bar: Int, offset: UInt64, byteCount: Int) -> [UInt8]? {
    lock.withLock {
      if bar == Int(tableBAR),
        let relative = relativeOffset(
          offset: offset,
          byteCount: byteCount,
          base: UInt64(tableOffset),
          length: entries.count * 16
        )
      {
        let bytes = tableBytesLocked()
        return Array(bytes[relative..<(relative + byteCount)])
      }
      let pendingByteCount = (entries.count + 63) / 64 * 8
      if bar == Int(pendingBAR),
        let relative = relativeOffset(
          offset: offset,
          byteCount: byteCount,
          base: UInt64(pendingOffset),
          length: pendingByteCount
        )
      {
        let bytes = pendingBytesLocked(byteCount: pendingByteCount)
        return Array(bytes[relative..<(relative + byteCount)])
      }
      return nil
    }
  }

  func writeBAR(bar: Int, offset: UInt64, bytes: [UInt8]) -> Bool {
    let handled = lock.withLock {
      guard bar == Int(tableBAR),
        let relative = relativeOffset(
          offset: offset,
          byteCount: bytes.count,
          base: UInt64(tableOffset),
          length: entries.count * 16
        )
      else {
        let pendingByteCount = (entries.count + 63) / 64 * 8
        return bar == Int(pendingBAR)
          && relativeOffset(
            offset: offset,
            byteCount: bytes.count,
            base: UInt64(pendingOffset),
            length: pendingByteCount
          ) != nil
      }
      var table = tableBytesLocked()
      table.replaceSubrange(relative..<(relative + bytes.count), with: bytes)
      for index in entries.indices {
        let base = index * 16
        entries[index].messageAddress = get(UInt64.self, at: base, in: table)
        entries[index].messageData = get(UInt32.self, at: base + 8, in: table)
        entries[index].masked = get(UInt32.self, at: base + 12, in: table) & 1 != 0
      }
      return true
    }
    if handled { deliverPending() }
    return handled
  }

  private func deliverPending() {
    let candidates: [(Int, @Sendable (UInt64, UInt16) -> Bool, UInt64, UInt16)] = lock.withLock {
      guard enabled, !functionMasked, let sink else { return [] }
      return pending.sorted().compactMap { index in
        let entry = entries[index]
        guard !entry.masked else { return nil }
        return (index, sink, entry.messageAddress, UInt16(truncatingIfNeeded: entry.messageData))
      }
    }
    for (index, sink, address, data) in candidates where sink(address, data) {
      lock.withLock { _ = pending.remove(index) }
    }
  }

  private func tableBytesLocked() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: entries.count * 16)
    for (index, entry) in entries.enumerated() {
      let base = index * 16
      put(entry.messageAddress, at: base, in: &bytes)
      put(entry.messageData, at: base + 8, in: &bytes)
      put(UInt32(entry.masked ? 1 : 0), at: base + 12, in: &bytes)
    }
    return bytes
  }

  private func pendingBytesLocked(byteCount: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for index in pending { bytes[index / 8] |= 1 << UInt8(index % 8) }
    return bytes
  }

  private func relativeOffset(
    offset: UInt64,
    byteCount: Int,
    base: UInt64,
    length: Int
  ) -> Int? {
    guard byteCount > 0, offset >= base, offset - base <= UInt64(length),
      UInt64(byteCount) <= UInt64(length) - (offset - base)
    else { return nil }
    return Int(offset - base)
  }
}

/// PCI type-0 configuration header with architectural BAR probing and programming behavior.
public final class DoryPCPCIConfigurationFunction: DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, @unchecked Sendable
{
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
  private let msix: DoryPCPCIMSIXController?
  private let msixCapabilityOffset: Int
  private let interruptPin: UInt8
  private var intxAsserted = false
  private var intxSink: (@Sendable (UInt8, Bool) -> Void)?
  private var msiSink: (@Sendable (UInt64, UInt16) -> Bool)?

  public init(
    address: DoryPCPCIAddress,
    vendorID: UInt16,
    deviceID: UInt16,
    classCode: UInt32,
    revisionID: UInt8 = 0,
    subsystemVendorID: UInt16 = 0,
    subsystemID: UInt16 = 0,
    interruptLine: UInt8 = 0xFF,
    interruptPin: UInt8 = 0,
    supportsMSI: Bool = false,
    msiNextCapabilityOffset: UInt8 = 0,
    msixVectorCount: Int = 0,
    msixCapabilityOffset: UInt8 = 0x60,
    msixNextCapabilityOffset: UInt8 = 0,
    msixTableBAR: UInt8 = 0,
    msixTableOffset: UInt32 = 0x800,
    msixPendingBAR: UInt8 = 0,
    msixPendingOffset: UInt32 = 0xC00,
    bars descriptors: [DoryPCPCIBARDescriptor] = []
  ) throws {
    pciAddress = address
    self.supportsMSI = supportsMSI
    self.msixCapabilityOffset = Int(msixCapabilityOffset)
    self.interruptPin = interruptPin
    if msixVectorCount > 0 {
      let tableByteCount = UInt64(msixVectorCount * 16)
      let pendingByteCount = UInt64((msixVectorCount + 63) / 64 * 8)
      let tableDescriptor = descriptors.first { $0.index == Int(msixTableBAR) }
      let pendingDescriptor = descriptors.first { $0.index == Int(msixPendingBAR) }
      let tableEnd = UInt64(msixTableOffset) + tableByteCount
      let pendingEnd = UInt64(msixPendingOffset) + pendingByteCount
      guard (1...2048).contains(msixVectorCount), msixCapabilityOffset >= 0x40,
        msixCapabilityOffset <= 0xF4,
        msixCapabilityOffset & 3 == 0,
        msixTableBAR < 6, msixPendingBAR < 6,
        msixTableOffset & 7 == 0, msixPendingOffset & 7 == 0,
        let tableDescriptor, let pendingDescriptor,
        tableEnd <= tableDescriptor.size,
        pendingEnd <= pendingDescriptor.size,
        msixTableBAR != msixPendingBAR
          || tableEnd <= UInt64(msixPendingOffset)
          || pendingEnd <= UInt64(msixTableOffset)
      else { throw DoryPCPCIError.invalidMSIXConfiguration }
      msix = .init(
        vectorCount: msixVectorCount,
        tableBAR: msixTableBAR,
        tableOffset: msixTableOffset,
        pendingBAR: msixPendingBAR,
        pendingOffset: msixPendingOffset
      )
    } else {
      msix = nil
    }
    put(vendorID, at: 0x00, in: &configuration)
    put(deviceID, at: 0x02, in: &configuration)
    configuration[0x08] = revisionID
    configuration[0x09] = UInt8(truncatingIfNeeded: classCode)
    configuration[0x0A] = UInt8(truncatingIfNeeded: classCode >> 8)
    configuration[0x0B] = UInt8(truncatingIfNeeded: classCode >> 16)
    configuration[0x0E] = 0
    put(subsystemVendorID, at: 0x2C, in: &configuration)
    put(subsystemID, at: 0x2E, in: &configuration)
    configuration[0x3C] = interruptLine
    configuration[0x3D] = interruptPin
    if supportsMSI {
      configuration[0x06] |= 1 << 4
      configuration[0x34] = 0x50
      configuration[0x50] = 0x05
      configuration[0x51] = msiNextCapabilityOffset
      // One 64-bit message, no per-vector mask, one vector.
      put(UInt16(1 << 7), at: 0x52, in: &configuration)
    }
    if let msix {
      configuration[0x06] |= 1 << 4
      let capability = Int(msixCapabilityOffset)
      configuration[capability] = 0x11
      configuration[capability + 1] = msixNextCapabilityOffset
      put(msix.control, at: capability + 2, in: &configuration)
      put(msixTableOffset | UInt32(msixTableBAR), at: capability + 4, in: &configuration)
      put(msixPendingOffset | UInt32(msixPendingBAR), at: capability + 8, in: &configuration)
      if !supportsMSI { configuration[0x34] = msixCapabilityOffset }
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

  public var interruptLine: UInt8 { lock.withLock { configuration[0x3C] } }

  public var intxState: DoryPCPCIINTxState {
    let route = intxRoute()
    return .init(
      asserted: route.pending,
      externallyAsserted: route.asserted,
      interruptLine: route.line,
      interruptPin: interruptPin
    )
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

  public var msixState: DoryPCPCIMSIXState? { msix?.state }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    lock.withLock { msiSink = sink }
    msix?.connectSink(sink)
  }

  public func connectINTxSink(
    _ sink: @escaping @Sendable (_ interruptLine: UInt8, _ asserted: Bool) -> Void
  ) {
    lock.withLock { intxSink = sink }
    let route = intxRoute()
    if route.asserted { sink(route.line, true) }
  }

  @discardableResult
  public func setINTx(asserted: Bool) -> Bool {
    let previous = intxRoute()
    lock.withLock { intxAsserted = asserted }
    notifyINTxTransition(from: previous)
    return intxRoute().asserted
  }

  @discardableResult
  public func raiseMSI() -> Bool {
    let delivery: (sink: @Sendable (UInt64, UInt16) -> Bool, address: UInt64, data: UInt16)? =
      lock.withLock {
        guard supportsMSI, msix?.state.enabled != true, configuration[0x52] & 1 != 0, let msiSink
        else { return nil }
        let address =
          UInt64(get(UInt32.self, at: 0x54, in: configuration))
          | UInt64(get(UInt32.self, at: 0x58, in: configuration)) << 32
        return (msiSink, address, get(UInt16.self, at: 0x5C, in: configuration))
      }
    guard let delivery else { return false }
    return delivery.sink(delivery.address, delivery.data)
  }

  @discardableResult
  public func raiseMSIX(vector: UInt16) -> Bool { msix?.raise(vector: vector) ?? false }

  public func readMSIXBAR(bar: Int, offset: UInt64, byteCount: Int) -> [UInt8]? {
    msix?.readBAR(bar: bar, offset: offset, byteCount: byteCount)
  }

  @discardableResult
  public func writeMSIXBAR(bar: Int, offset: UInt64, bytes: [UInt8]) -> Bool {
    msix?.writeBAR(bar: bar, offset: offset, bytes: bytes) ?? false
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
    var result = lock.withLock {
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
    if let msix {
      let controlOffset = msixCapabilityOffset + 2
      let control = msix.control
      for index in result.indices {
        let register = offset + index
        if register == controlOffset {
          result[index] = UInt8(truncatingIfNeeded: control)
        } else if register == controlOffset + 1 {
          result[index] = UInt8(truncatingIfNeeded: control >> 8)
        }
      }
    }
    let intx = intxState
    for index in result.indices where offset + index == 0x06 {
      if intx.asserted {
        result[index] |= 1 << 3
      } else {
        result[index] &= ~(1 << 3)
      }
    }
    return result
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try validate(offset: offset, byteCount: bytes.count)
    let previousINTx = intxRoute()
    defer { notifyINTxTransition(from: previousINTx) }
    if let msix {
      let controlOffset = msixCapabilityOffset + 2
      if offset < controlOffset + 2, offset + bytes.count > controlOffset {
        var controlBytes = [
          UInt8(truncatingIfNeeded: msix.control),
          UInt8(truncatingIfNeeded: msix.control >> 8),
        ]
        for (index, value) in bytes.enumerated() {
          let register = offset + index
          if (controlOffset..<(controlOffset + 2)).contains(register) {
            controlBytes[register - controlOffset] = value
          }
        }
        msix.writeControl(UInt16(controlBytes[0]) | UInt16(controlBytes[1]) << 8)
        return
      }
    }
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

  private func intxRoute() -> (line: UInt8, pending: Bool, asserted: Bool) {
    let configurationState = lock.withLock {
      (
        line: configuration[0x3C],
        pending: intxAsserted,
        interruptDisabled: get(UInt16.self, at: 0x04, in: configuration) & (1 << 10) != 0,
        msiEnabled: supportsMSI && configuration[0x52] & 1 != 0
      )
    }
    let asserted =
      configurationState.pending
      && !configurationState.interruptDisabled
      && !configurationState.msiEnabled
      && msix?.state.enabled != true
      && configurationState.line != 0xFF
      && interruptPin != 0
    return (configurationState.line, configurationState.pending, asserted)
  }

  private func notifyINTxTransition(from previous: (line: UInt8, pending: Bool, asserted: Bool)) {
    let current = intxRoute()
    guard previous.line != current.line || previous.asserted != current.asserted else { return }
    let sink = lock.withLock { intxSink }
    if previous.asserted { sink?(previous.line, false) }
    if current.asserted { sink?(current.line, true) }
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
    baseAddress: UInt64 = DoryPCV1ABI.pcieECAMBase,
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

  public func validateRead(offset: UInt64, byteCount: Int) throws {
    _ = try resolve(offset: offset, byteCount: byteCount)
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

  public init(
    baseAddress: UInt64 = DoryPCV1ABI.pcieMMIOBase,
    byteCount: UInt64 = DoryPCV1ABI.pcieMMIOBytes
  ) {
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

  public func validateRead(offset: UInt64, byteCount: Int) throws {
    let resolved = try resolve(offset: offset, byteCount: byteCount, write: false)
    try resolved.device.validateBARRead(offset: resolved.barOffset, byteCount: byteCount)
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
