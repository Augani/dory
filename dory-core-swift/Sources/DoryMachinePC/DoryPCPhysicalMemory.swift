import DoryDBTX86
import DoryVirtio
import Foundation

public enum DoryPCPhysicalMemoryError: Error, Sendable, Equatable {
  case sealed
  case invalidRange(base: UInt64, byteCount: UInt64)
  case overlappingRange(base: UInt64, byteCount: UInt64)
  case unsupportedAccess(offset: UInt64, byteCount: Int, write: Bool)
}

public protocol DoryPCMMIODevice: AnyObject, Sendable {
  var baseAddress: UInt64 { get }
  var byteCount: UInt64 { get }
  var allowsInstructionFetch: Bool { get }
  func read(offset: UInt64, byteCount: Int) throws -> [UInt8]
  func write(offset: UInt64, bytes: [UInt8]) throws
  func validateWrite(offset: UInt64, byteCount: Int) throws
  func synchronize()
}

extension DoryPCMMIODevice {
  public var allowsInstructionFetch: Bool { false }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    guard byteCount > 0, offset <= self.byteCount, UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: true)
    }
  }

  public func synchronize() {}
}

/// Sealed physical address router. RAM and devices share one DoryX86Memory boundary, so paging,
/// interpreter, and every future JIT helper observe an identical DoryPC-v1 memory map.
public final class DoryPCPhysicalMemoryBus: DoryX86Memory, @unchecked Sendable {
  private struct Mapping {
    let lowerBound: UInt64
    let upperBound: UInt64
    let device: any DoryPCMMIODevice
  }

  public let ram: DoryX86ByteArrayMemory
  private let lock = NSLock()
  private var mappings: [Mapping] = []
  private var isSealed = false

  public init(ram: DoryX86ByteArrayMemory) { self.ram = ram }

  public func attach(_ device: any DoryPCMMIODevice) throws {
    try lock.withLock {
      guard !isSealed else { throw DoryPCPhysicalMemoryError.sealed }
      let (upper, overflow) = device.baseAddress.addingReportingOverflow(device.byteCount)
      guard device.byteCount > 0, !overflow else {
        throw DoryPCPhysicalMemoryError.invalidRange(
          base: device.baseAddress, byteCount: device.byteCount)
      }
      guard
        !mappings.contains(where: {
          device.baseAddress < $0.upperBound && $0.lowerBound < upper
        })
      else {
        throw DoryPCPhysicalMemoryError.overlappingRange(
          base: device.baseAddress, byteCount: device.byteCount)
      }
      mappings.append(.init(lowerBound: device.baseAddress, upperBound: upper, device: device))
      mappings.sort { $0.lowerBound < $1.lowerBound }
    }
  }

  public func seal() { lock.withLock { isSealed = true } }

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    if let resolved = try resolve(address: address, byteCount: 1) {
      guard resolved.device.allowsInstructionFetch else {
        throw DoryX86MemoryError.unmapped(
          address: address,
          byteCount: maximumCount,
          access: .instructionFetch
        )
      }
      let available = resolved.device.byteCount - resolved.offset
      return try resolved.device.read(
        offset: resolved.offset,
        byteCount: min(maximumCount, Int(available))
      )
    }
    return try ram.instructionBytes(at: address, maximumCount: maximumCount)
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount > 0 else { return [] }
    if let resolved = try resolve(address: address, byteCount: byteCount) {
      return try resolved.device.read(offset: resolved.offset, byteCount: byteCount)
    }
    return try ram.read(at: address, byteCount: byteCount)
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    if let resolved = try resolve(address: address, byteCount: bytes.count) {
      try resolved.device.write(offset: resolved.offset, bytes: bytes)
      return
    }
    try ram.write(at: address, bytes: bytes)
  }

  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    guard byteCount > 0 else { return }
    if let resolved = try resolve(address: address, byteCount: byteCount) {
      try resolved.device.validateWrite(offset: resolved.offset, byteCount: byteCount)
      return
    }
    try ram.validateWrite(at: address, byteCount: byteCount)
  }

  public func synchronize() {
    let devices = lock.withLock { mappings.map(\.device) }
    ram.synchronize()
    for device in devices { device.synchronize() }
  }

  /// VirtIO DMA is deliberately RAM-only. A descriptor can never trigger an APIC, PCI, or other
  /// MMIO register read as a side effect of validation or device processing.
  public func validateDMA(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    guard try resolve(address: address, byteCount: byteCount) == nil else {
      throw DoryX86MemoryError.unmapped(
        address: address,
        byteCount: byteCount,
        access: deviceWillWrite ? .write : .read
      )
    }
    if deviceWillWrite {
      try ram.validateWrite(at: address, byteCount: byteCount)
    } else {
      _ = try ram.read(at: address, byteCount: byteCount)
    }
  }

  private func resolve(
    address: UInt64,
    byteCount: Int
  ) throws -> (device: any DoryPCMMIODevice, offset: UInt64)? {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    let (upper, overflow) = address.addingReportingOverflow(UInt64(byteCount))
    guard !overflow else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    return try lock.withLock {
      guard
        let mapping = mappings.first(where: {
          address >= $0.lowerBound && address < $0.upperBound
        })
      else { return nil }
      guard upper <= mapping.upperBound else {
        throw DoryX86MemoryError.unmapped(
          address: address,
          byteCount: byteCount,
          access: .read
        )
      }
      return (mapping.device, address - mapping.lowerBound)
    }
  }
}

extension DoryPCPhysicalMemoryBus: DoryVirtioGuestMemory {
  public func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    try validateDMA(at: address, byteCount: byteCount, deviceWillWrite: deviceWillWrite)
  }
}

public final class DoryPCLocalAPICMMIO: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: UInt64 = 0x1000
  public let apic: DoryPCLocalAPIC

  private let lock = NSLock()
  private var timerLVT: UInt32 = 1 << 16
  private var timerInitialCount: UInt32 = 0
  private var timerDivideConfiguration: UInt32 = 0
  private var interruptCommandLow: UInt32 = 0
  private var interruptCommandHigh: UInt32 = 0
  private let onEndOfInterrupt: @Sendable (UInt8) throws -> Void
  private let onInterruptCommand: @Sendable (_ high: UInt32, _ low: UInt32) throws -> Void

  public init(
    apic: DoryPCLocalAPIC,
    baseAddress: UInt64 = DoryPCV1ABI.localAPICBase,
    onEndOfInterrupt: @escaping @Sendable (UInt8) throws -> Void = { _ in },
    onInterruptCommand: @escaping @Sendable (_ high: UInt32, _ low: UInt32) throws -> Void = {
      _, _ in
    }
  ) {
    self.apic = apic
    self.baseAddress = baseAddress
    self.onEndOfInterrupt = onEndOfInterrupt
    self.onInterruptCommand = onInterruptCommand
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount == 4, offset & 0xF == 0, offset < self.byteCount else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: false)
    }
    let snapshot = apic.snapshot()
    let value: UInt32 = lock.withLock {
      switch offset {
      case 0x20: snapshot.apicID << 24
      case 0x30: 0x0005_0014
      case 0x80: UInt32(snapshot.taskPriority)
      case 0xA0:
        UInt32(
          max(snapshot.taskPriority & 0xF0, snapshot.inService.max().map { $0 & 0xF0 } ?? 0))
      case 0xF0:
        UInt32(snapshot.spuriousVector) | (snapshot.softwareEnabled ? 1 << 8 : 0)
      case 0x100...0x170:
        bitmapRegister(snapshot.inService, offset: offset, base: 0x100)
      case 0x180...0x1F0:
        bitmapRegister(snapshot.levelTriggered, offset: offset, base: 0x180)
      case 0x200...0x270:
        bitmapRegister(snapshot.interruptRequest, offset: offset, base: 0x200)
      case 0x280: 0
      case 0x300: interruptCommandLow
      case 0x310: interruptCommandHigh
      case 0x320: timerLVT
      case 0x380: timerInitialCount
      case 0x390: snapshot.timer.currentCount
      case 0x3E0: timerDivideConfiguration
      default: 0
      }
    }
    return littleEndian(value)
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    guard bytes.count == 4, offset & 0xF == 0, offset < byteCount else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: bytes.count, write: true)
    }
    let value = uint32(bytes)
    switch offset {
    case 0x80:
      apic.setTaskPriority(UInt8(truncatingIfNeeded: value))
    case 0xB0:
      if let vector = apic.endOfInterrupt() { try onEndOfInterrupt(vector) }
    case 0xF0:
      try apic.configureSpuriousVector(
        UInt8(truncatingIfNeeded: value), softwareEnabled: value & (1 << 8) != 0)
    case 0x300:
      let high = lock.withLock {
        interruptCommandLow = value & ~(1 << 12)
        return interruptCommandHigh
      }
      try onInterruptCommand(high, value)
    case 0x310:
      lock.withLock { interruptCommandHigh = value }
    case 0x320:
      lock.withLock {
        timerLVT = value & 0x0003_07FF
        applyTimerConfiguration()
      }
    case 0x380:
      lock.withLock {
        timerInitialCount = value
        applyTimerConfiguration()
      }
    case 0x3E0:
      lock.withLock { timerDivideConfiguration = value & 0xB }
    default:
      break
    }
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    guard byteCount == 4, offset & 0xF == 0, offset < self.byteCount else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: true)
    }
  }

  private func applyTimerConfiguration() {
    let mode: DoryPCLocalAPICTimerMode = timerLVT & (1 << 17) != 0 ? .periodic : .oneShot
    let vector = UInt8(truncatingIfNeeded: timerLVT)
    // xAPIC register writes do not become CPU exceptions. Firmware may temporarily program an
    // illegal vector while probing the timer; retain the raw LVT and activate it only once valid.
    guard vector >= 0x10 else { return }
    try? apic.configureTimer(
      vector: vector,
      masked: timerLVT & (1 << 16) != 0,
      mode: mode,
      initialCount: timerInitialCount
    )
  }

  private func bitmapRegister(_ values: Set<UInt8>, offset: UInt64, base: UInt64) -> UInt32 {
    let register = Int((offset - base) / 0x10)
    let vectorBase = register * 32
    return values.reduce(into: UInt32(0)) { result, vector in
      let index = Int(vector) - vectorBase
      if (0..<32).contains(index) { result |= UInt32(1) << UInt32(index) }
    }
  }
}

public final class DoryPCIOAPICMMIO: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: UInt64 = 0x1000
  public let ioAPIC: DoryPCIOAPIC

  private let lock = NSLock()
  private var selectedRegister: UInt8 = 0
  private var ioAPICID: UInt8

  public init(
    ioAPIC: DoryPCIOAPIC,
    ioAPICID: UInt8 = 0,
    baseAddress: UInt64 = DoryPCV1ABI.ioAPICBase
  ) {
    self.ioAPIC = ioAPIC
    self.ioAPICID = ioAPICID & 0x0F
    self.baseAddress = baseAddress
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount == 4, offset == 0 || offset == 0x10 else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: false)
    }
    let value: UInt32
    if offset == 0 {
      value = UInt32(lock.withLock { selectedRegister })
    } else {
      let register = lock.withLock { selectedRegister }
      value = try readWindow(register)
    }
    return littleEndian(value)
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    guard bytes.count == 4, offset == 0 || offset == 0x10 else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: bytes.count, write: true)
    }
    let value = uint32(bytes)
    if offset == 0 {
      lock.withLock { selectedRegister = UInt8(truncatingIfNeeded: value) }
    } else {
      let register = lock.withLock { selectedRegister }
      try writeWindow(register, value: value)
    }
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    guard byteCount == 4, offset == 0 || offset == 0x10 else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: true)
    }
  }

  private func readWindow(_ register: UInt8) throws -> UInt32 {
    switch register {
    case 0: UInt32(lock.withLock { ioAPICID }) << 24
    case 1: 0x20 | UInt32(ioAPIC.pinCount - 1) << 16
    case 2: UInt32(lock.withLock { ioAPICID }) << 24
    case 0x10...0x3F:
      try redirectionValue(register)
    default: 0
    }
  }

  private func writeWindow(_ register: UInt8, value: UInt32) throws {
    switch register {
    case 0:
      lock.withLock { ioAPICID = UInt8(truncatingIfNeeded: value >> 24) & 0x0F }
    case 0x10...0x3F:
      let index = Int(register - 0x10)
      let pin = index / 2
      guard pin < ioAPIC.pinCount else { return }
      var route = try ioAPIC.route(for: pin)
      if index.isMultiple(of: 2) {
        route.vector = UInt8(truncatingIfNeeded: value)
        route.activeLow = value & (1 << 13) != 0
        route.levelTriggered = value & (1 << 15) != 0
        route.masked = value & (1 << 16) != 0
      } else {
        route.destinationAPICID = value >> 24
      }
      try ioAPIC.configure(pin: pin, route: route)
    default:
      break
    }
  }

  private func redirectionValue(_ register: UInt8) throws -> UInt32 {
    let index = Int(register - 0x10)
    let pin = index / 2
    guard pin < ioAPIC.pinCount else { return 0 }
    let route = try ioAPIC.route(for: pin)
    if !index.isMultiple(of: 2) { return route.destinationAPICID << 24 }
    return UInt32(route.vector)
      | (route.activeLow ? 1 << 13 : 0)
      | (route.levelTriggered ? 1 << 15 : 0)
      | (route.masked ? 1 << 16 : 0)
  }
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
  [
    UInt8(truncatingIfNeeded: value),
    UInt8(truncatingIfNeeded: value >> 8),
    UInt8(truncatingIfNeeded: value >> 16),
    UInt8(truncatingIfNeeded: value >> 24),
  ]
}

private func uint32(_ bytes: [UInt8]) -> UInt32 {
  UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}
