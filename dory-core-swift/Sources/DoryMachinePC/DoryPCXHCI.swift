import DoryVirtio
import Foundation

public enum DoryPCXHCIError: Error, Sendable, Equatable {
  case invalidPort(Int)
  case invalidBARAccess(offset: UInt64, byteCount: Int, write: Bool)
  case invalidRegisterWrite(offset: UInt64, byteCount: Int)
  case eventRingUnavailable
}

public enum DoryPCXHCIPortSpeed: UInt8, Codable, CaseIterable, Sendable, Hashable {
  case full = 1
  case low = 2
  case high = 3
  case superSpeed = 4
  case superSpeedPlus = 5
}

public struct DoryPCXHCIPortState: Sendable, Hashable {
  public let connected: Bool
  public let enabled: Bool
  public let powered: Bool
  public let speed: DoryPCXHCIPortSpeed?
  public let statusChangePending: Bool
}

/// A bounded xHCI 1.2 PCI function for the frozen DoryPC-v1 machine contract.
///
/// The controller owns guest register and event-ring mechanics. Physical USB authority remains in
/// the host broker; callers may only reflect an already-authorized attachment into a root port.
public final class DoryPCXHCIController: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public static let barBytes: UInt64 = 0x4000
  public static let capabilityBytes: UInt8 = 0x40
  public static let operationalOffset: UInt64 = 0x40
  public static let runtimeOffset: UInt64 = 0x1000
  public static let doorbellOffset: UInt64 = 0x2000
  public static let portRegisterOffset: UInt64 = operationalOffset + 0x400
  public static let maximumSlots: UInt8 = 32
  public static let portCount = 8

  public let configurationFunction: DoryPCPCIConfigurationFunction
  public let barIndex = 0

  public var pciAddress: DoryPCPCIAddress { configurationFunction.pciAddress }

  private static let usbStatusHalted: UInt32 = 1 << 0
  private static let usbStatusEventInterrupt: UInt32 = 1 << 3
  private static let usbStatusPortChange: UInt32 = 1 << 4
  private static let portConnectStatus: UInt32 = 1 << 0
  private static let portEnabled: UInt32 = 1 << 1
  private static let portReset: UInt32 = 1 << 4
  private static let portPower: UInt32 = 1 << 9
  private static let portConnectChange: UInt32 = 1 << 17
  private static let portEnableChange: UInt32 = 1 << 18
  private static let portWarmResetChange: UInt32 = 1 << 19
  private static let portResetChange: UInt32 = 1 << 21
  private static let portChangeMask: UInt32 =
    portConnectChange | portEnableChange | portWarmResetChange | portResetChange | (0xF << 20)

  private let lock = NSLock()
  private var guestMemory: (any DoryVirtioGuestMemory)?
  private var usbCommand: UInt32 = 0
  private var usbStatus: UInt32 = usbStatusHalted
  private var deviceNotificationControl: UInt32 = 0
  private var commandRingControl: UInt64 = 0
  private var deviceContextBaseAddress: UInt64 = 0
  private var configuredSlots: UInt32 = 0
  private var interrupterManagement: UInt32 = 0
  private var interrupterModeration: UInt32 = 4_000
  private var eventRingSegmentTableSize: UInt32 = 0
  private var eventRingSegmentTableAddress: UInt64 = 0
  private var eventRingDequeuePointer: UInt64 = 0
  private var eventRingEnqueueAddress: UInt64 = 0
  private var eventRingSegmentBase: UInt64 = 0
  private var eventRingSegmentSize: UInt32 = 0
  private var eventRingEnqueueIndex: UInt32 = 0
  private var eventRingCycle = true
  private var ports = [UInt32](repeating: portPower, count: portCount)

  public init(
    address: DoryPCPCIAddress = DoryPCV1ABI.xhciPCIAddress,
    initialBARAddress: UInt64 = DoryPCV1ABI.xhciBARAddress
  ) throws {
    configurationFunction = try .init(
      address: address,
      vendorID: 0x1AF4,
      deviceID: 0x1100,
      classCode: 0x0C_03_30,
      revisionID: 1,
      subsystemVendorID: 0x1AF4,
      subsystemID: 0x1100,
      interruptLine: DoryPCV1ABI.interruptLine(device: address.device, pin: 1),
      interruptPin: 1,
      supportsMSI: true,
      bars: [
        .init(
          index: 0,
          kind: .memory64(prefetchable: false),
          size: Self.barBytes,
          address: initialBARAddress
        )
      ]
    )
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    lock.withLock { guestMemory = memory }
  }

  public func connect(port: Int, speed: DoryPCXHCIPortSpeed) throws {
    let shouldSignal = try lock.withLock {
      let index = try portIndex(port)
      let old = ports[index]
      var value = old & Self.portChangeMask
      value |= Self.portPower | Self.portConnectStatus | Self.portConnectChange
      value |= UInt32(speed.rawValue) << 10
      ports[index] = value
      return old & Self.portConnectStatus == 0
    }
    if shouldSignal { postPortStatusChange(port: port) }
  }

  public func disconnect(port: Int) throws {
    let shouldSignal = try lock.withLock {
      let index = try portIndex(port)
      let old = ports[index]
      var value = old & Self.portChangeMask
      value |= Self.portPower | Self.portConnectChange
      if old & Self.portEnabled != 0 { value |= Self.portEnableChange }
      ports[index] = value
      return old & Self.portConnectStatus != 0
    }
    if shouldSignal { postPortStatusChange(port: port) }
  }

  public func portState(_ port: Int) throws -> DoryPCXHCIPortState {
    try lock.withLock {
      let value = ports[try portIndex(port)]
      return .init(
        connected: value & Self.portConnectStatus != 0,
        enabled: value & Self.portEnabled != 0,
        powered: value & Self.portPower != 0,
        speed: DoryPCXHCIPortSpeed(rawValue: UInt8((value >> 10) & 0xF)),
        statusChangePending: value & Self.portChangeMask != 0
      )
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try configurationFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try configurationFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    configurationFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try validateAccess(offset: offset, byteCount: byteCount, write: false)
    let image = lock.withLock { registerImageLocked() }
    return Array(image[Int(offset)..<(Int(offset) + byteCount)])
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try validateAccess(offset: offset, byteCount: bytes.count, write: true)
    guard !bytes.isEmpty else {
      throw DoryPCXHCIError.invalidRegisterWrite(offset: offset, byteCount: bytes.count)
    }
    if offset == Self.operationalOffset, bytes.count == 4 {
      writeUSBCommand(uint32(bytes))
      return
    }
    if offset == Self.operationalOffset + 0x04, bytes.count == 4 {
      clearUSBStatus(uint32(bytes))
      return
    }
    if offset == Self.operationalOffset + 0x14, bytes.count == 4 {
      lock.withLock { deviceNotificationControl = uint32(bytes) & 0xFFFF }
      return
    }
    if offset == Self.operationalOffset + 0x18, bytes.count == 8 {
      lock.withLock { commandRingControl = uint64(bytes) & ~UInt64(0x30) }
      return
    }
    if offset == Self.operationalOffset + 0x30, bytes.count == 8 {
      lock.withLock { deviceContextBaseAddress = uint64(bytes) & ~UInt64(0x3F) }
      return
    }
    if offset == Self.operationalOffset + 0x38, bytes.count == 4 {
      lock.withLock {
        configuredSlots = min(uint32(bytes) & 0xFF, UInt32(Self.maximumSlots))
      }
      return
    }
    if offset == Self.runtimeOffset + 0x20, bytes.count == 4 {
      writeInterrupterManagement(uint32(bytes))
      return
    }
    if offset == Self.runtimeOffset + 0x24, bytes.count == 4 {
      lock.withLock { interrupterModeration = uint32(bytes) }
      return
    }
    if offset == Self.runtimeOffset + 0x28, bytes.count == 4 {
      lock.withLock {
        eventRingSegmentTableSize = min(uint32(bytes) & 0xFFFF, 1)
        invalidateEventRingLocked()
      }
      return
    }
    if offset == Self.runtimeOffset + 0x30, bytes.count == 8 {
      lock.withLock {
        eventRingSegmentTableAddress = uint64(bytes) & ~UInt64(0x3F)
        invalidateEventRingLocked()
      }
      return
    }
    if offset == Self.runtimeOffset + 0x38, bytes.count == 8 {
      writeEventRingDequeuePointer(uint64(bytes))
      return
    }
    if offset >= Self.portRegisterOffset,
      offset < Self.portRegisterOffset + UInt64(Self.portCount * 0x10),
      (offset - Self.portRegisterOffset) % 0x10 == 0,
      bytes.count == 4
    {
      try writePort(
        Int((offset - Self.portRegisterOffset) / 0x10) + 1,
        value: uint32(bytes)
      )
      return
    }
    if offset >= Self.doorbellOffset,
      offset < Self.doorbellOffset + UInt64((Int(Self.maximumSlots) + 1) * 4),
      offset % 4 == 0,
      bytes.count == 4
    {
      return
    }
    throw DoryPCXHCIError.invalidRegisterWrite(offset: offset, byteCount: bytes.count)
  }

  public func validateBARWrite(offset: UInt64, byteCount: Int) throws {
    try validateAccess(offset: offset, byteCount: byteCount, write: true)
  }

  private func writeUSBCommand(_ value: UInt32) {
    if value & (1 << 1) != 0 {
      resetController()
      return
    }
    let pendingPorts = lock.withLock {
      usbCommand = value & 0x0000_0F0D
      if usbCommand & 1 != 0 {
        usbStatus &= ~Self.usbStatusHalted
      } else {
        usbStatus |= Self.usbStatusHalted
      }
      return ports.enumerated().compactMap { index, port in
        port & Self.portChangeMask != 0 ? index + 1 : nil
      }
    }
    if value & 1 != 0 {
      for port in pendingPorts { postPortStatusChange(port: port) }
    }
    updateInterruptLine()
  }

  private func clearUSBStatus(_ value: UInt32) {
    lock.withLock {
      usbStatus &= ~(value & (Self.usbStatusEventInterrupt | Self.usbStatusPortChange))
    }
    updateInterruptLine()
  }

  private func writeInterrupterManagement(_ value: UInt32) {
    lock.withLock {
      if value & 1 != 0 { interrupterManagement &= ~UInt32(1) }
      interrupterManagement = (interrupterManagement & 1) | (value & 2)
    }
    updateInterruptLine()
  }

  private func writeEventRingDequeuePointer(_ value: UInt64) {
    lock.withLock {
      eventRingDequeuePointer = value & ~UInt64(0x8)
      if value & 0x8 != 0 { interrupterManagement &= ~UInt32(1) }
    }
    updateInterruptLine()
  }

  private func writePort(_ port: Int, value: UInt32) throws {
    let changed = try lock.withLock {
      let index = try portIndex(port)
      var current = ports[index]
      current &= ~(value & Self.portChangeMask)
      guard value & Self.portReset != 0 else {
        ports[index] = current
        return false
      }
      if current & Self.portConnectStatus != 0 {
        current |= Self.portEnabled | Self.portResetChange
      }
      current &= ~Self.portReset
      ports[index] = current
      return true
    }
    if changed { postPortStatusChange(port: port) }
  }

  private func resetController() {
    lock.withLock {
      usbCommand = 0
      usbStatus = Self.usbStatusHalted
      deviceNotificationControl = 0
      commandRingControl = 0
      deviceContextBaseAddress = 0
      configuredSlots = 0
      interrupterManagement = 0
      interrupterModeration = 4_000
      eventRingSegmentTableSize = 0
      eventRingSegmentTableAddress = 0
      eventRingDequeuePointer = 0
      invalidateEventRingLocked()
      for index in ports.indices {
        let attachment = ports[index] & (Self.portConnectStatus | (0xF << 10))
        ports[index] = Self.portPower | attachment
      }
    }
    configurationFunction.setINTx(asserted: false)
  }

  private func postPortStatusChange(port: Int) {
    lock.withLock { usbStatus |= Self.usbStatusPortChange }
    var event = [UInt8](repeating: 0, count: 16)
    put(UInt32(port) << 24, at: 0, in: &event)
    put(UInt32(1) << 24, at: 8, in: &event)
    put(UInt32(34) << 10, at: 12, in: &event)
    _ = try? postEvent(event)
  }

  private func postEvent(_ event: [UInt8]) throws {
    let write: (memory: any DoryVirtioGuestMemory, address: UInt64, bytes: [UInt8]) =
      try lock.withLock {
        guard usbCommand & 1 != 0, let guestMemory else {
          throw DoryPCXHCIError.eventRingUnavailable
        }
        try configureEventRingLocked(memory: guestMemory)
        guard eventRingSegmentSize > 0 else { throw DoryPCXHCIError.eventRingUnavailable }
        var bytes = event
        if eventRingCycle { bytes[12] |= 1 } else { bytes[12] &= 0xFE }
        let address = eventRingEnqueueAddress
        eventRingEnqueueIndex += 1
        if eventRingEnqueueIndex == eventRingSegmentSize {
          eventRingEnqueueIndex = 0
          eventRingEnqueueAddress = eventRingSegmentBase
          eventRingCycle.toggle()
        } else {
          eventRingEnqueueAddress += 16
        }
        usbStatus |= Self.usbStatusEventInterrupt
        interrupterManagement |= 1
        return (guestMemory, address, bytes)
      }
    try write.memory.validate(at: write.address, byteCount: 16, deviceWillWrite: true)
    try write.memory.write(at: write.address, bytes: write.bytes)
    write.memory.synchronize()
    updateInterruptLine()
  }

  private func configureEventRingLocked(memory: any DoryVirtioGuestMemory) throws {
    guard eventRingEnqueueAddress == 0 else { return }
    guard eventRingSegmentTableSize == 1, eventRingSegmentTableAddress != 0 else {
      throw DoryPCXHCIError.eventRingUnavailable
    }
    try memory.validate(at: eventRingSegmentTableAddress, byteCount: 16, deviceWillWrite: false)
    let entry = try memory.read(at: eventRingSegmentTableAddress, byteCount: 16)
    guard entry.count == 16 else { throw DoryPCXHCIError.eventRingUnavailable }
    let base = uint64(Array(entry[0..<8])) & ~UInt64(0x3F)
    let size = uint32(Array(entry[8..<12]))
    guard base != 0, (16...4096).contains(size) else {
      throw DoryPCXHCIError.eventRingUnavailable
    }
    eventRingSegmentBase = base
    eventRingSegmentSize = size
    eventRingEnqueueIndex = 0
    eventRingEnqueueAddress = base
    eventRingCycle = true
  }

  private func invalidateEventRingLocked() {
    eventRingEnqueueAddress = 0
    eventRingSegmentBase = 0
    eventRingSegmentSize = 0
    eventRingEnqueueIndex = 0
    eventRingCycle = true
  }

  private func updateInterruptLine() {
    let active = lock.withLock {
      usbCommand & (1 << 2) != 0
        && interrupterManagement & 3 == 3
        && usbStatus & Self.usbStatusEventInterrupt != 0
    }
    guard active else {
      configurationFunction.setINTx(asserted: false)
      return
    }
    if configurationFunction.raiseMSI() {
      configurationFunction.setINTx(asserted: false)
    } else {
      configurationFunction.setINTx(asserted: true)
    }
  }

  private func registerImageLocked() -> [UInt8] {
    var image = [UInt8](repeating: 0, count: Int(Self.barBytes))
    image[0] = Self.capabilityBytes
    put(UInt16(0x0120), at: 0x02, in: &image)
    put(
      UInt32(Self.maximumSlots) | UInt32(1) << 8 | UInt32(Self.portCount) << 24,
      at: 0x04,
      in: &image
    )
    put(UInt32(0), at: 0x08, in: &image)
    put(UInt32(0), at: 0x0C, in: &image)
    put(UInt32(1 | (1 << 7) | (1 << 10) | (0x40 << 16)), at: 0x10, in: &image)
    put(UInt32(Self.doorbellOffset), at: 0x14, in: &image)
    put(UInt32(Self.runtimeOffset), at: 0x18, in: &image)
    put(UInt32(0), at: 0x1C, in: &image)

    put(UInt32(0x02_00_04_02), at: 0x100, in: &image)
    put(UInt32(0x2042_5355), at: 0x104, in: &image)
    put(UInt32(0x0000_0401), at: 0x108, in: &image)
    put(UInt32(0), at: 0x10C, in: &image)
    put(UInt32(0x03_20_00_02), at: 0x110, in: &image)
    put(UInt32(0x2042_5355), at: 0x114, in: &image)
    put(UInt32(0x0000_0405), at: 0x118, in: &image)
    put(UInt32(1), at: 0x11C, in: &image)

    let operational = Int(Self.operationalOffset)
    put(usbCommand, at: operational, in: &image)
    put(usbStatus, at: operational + 0x04, in: &image)
    put(UInt32(1), at: operational + 0x08, in: &image)
    put(deviceNotificationControl, at: operational + 0x14, in: &image)
    put(commandRingControl, at: operational + 0x18, in: &image)
    put(deviceContextBaseAddress, at: operational + 0x30, in: &image)
    put(configuredSlots, at: operational + 0x38, in: &image)
    for (index, port) in ports.enumerated() {
      put(port, at: Int(Self.portRegisterOffset) + index * 0x10, in: &image)
    }

    let runtime = Int(Self.runtimeOffset)
    put(interrupterManagement, at: runtime + 0x20, in: &image)
    put(interrupterModeration, at: runtime + 0x24, in: &image)
    put(eventRingSegmentTableSize, at: runtime + 0x28, in: &image)
    put(eventRingSegmentTableAddress, at: runtime + 0x30, in: &image)
    put(eventRingDequeuePointer, at: runtime + 0x38, in: &image)
    return image
  }

  private func portIndex(_ port: Int) throws -> Int {
    guard (1...Self.portCount).contains(port) else { throw DoryPCXHCIError.invalidPort(port) }
    return port - 1
  }

  private func validateAccess(offset: UInt64, byteCount: Int, write: Bool) throws {
    guard byteCount > 0, offset < Self.barBytes, UInt64(byteCount) <= Self.barBytes - offset else {
      throw DoryPCXHCIError.invalidBARAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
  }
}

private func uint32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func uint64(_ bytes: [UInt8]) -> UInt64 {
  bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
}

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
  for index in 0..<MemoryLayout<T>.size {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
