import DoryDBTX86
import DoryPlatformC
import Foundation

public enum DoryPCLegacyInterruptError: Error, Sendable, Equatable {
  case invalidIRQ(UInt8)
  case unsupportedPortWidth(DoryX86OperandWidth)
}

public struct DoryPCPIC8259Snapshot: Sendable, Hashable {
  public let masterVectorOffset: UInt8
  public let slaveVectorOffset: UInt8
  public let masterMask: UInt8
  public let slaveMask: UInt8
  public let masterRequest: UInt8
  public let slaveRequest: UInt8
  public let masterInService: UInt8
  public let slaveInService: UInt8
  public let masterLevelTriggered: UInt8
  public let slaveLevelTriggered: UInt8
  public let masterAssertedLines: UInt8
  public let slaveAssertedLines: UInt8
}

/// Cascaded PC/AT 8259 pair. The command/data port frontends are split from this shared core so
/// the sealed PIO router does not claim the unused range between 0x22 and 0x9f.
public final class DoryPCPIC8259Pair: @unchecked Sendable {
  fileprivate enum Controller { case master, slave }

  private struct Chip {
    var vectorOffset: UInt8
    var mask: UInt8 = 0xFF
    var request: UInt8 = 0
    var inService: UInt8 = 0
    var levelTriggered: UInt8 = 0
    var assertedLines: UInt8 = 0
    var initializationStep: UInt8 = 0
    var requiresICW4 = false
    var readInService = false
  }

  private let lock = NSLock()
  private let hasPendingRequest: UnsafeMutablePointer<UInt8>
  private var master = Chip(vectorOffset: 0x08)
  private var slave = Chip(vectorOffset: 0x70)

  public init() {
    hasPendingRequest = .allocate(capacity: 1)
    hasPendingRequest.initialize(to: 0)
  }

  deinit {
    hasPendingRequest.deinitialize(count: 1)
    hasPendingRequest.deallocate()
  }

  public func raise(irq: UInt8) throws {
    guard irq < 16 else { throw DoryPCLegacyInterruptError.invalidIRQ(irq) }
    lock.withLock {
      requestLocked(irq: irq)
      publishPendingRequestLocked()
    }
  }

  public func setAsserted(_ asserted: Bool, irq: UInt8) throws {
    guard irq < 16 else { throw DoryPCLegacyInterruptError.invalidIRQ(irq) }
    lock.withLock {
      if irq < 8 {
        setAssertedLocked(asserted: asserted, irq: irq, chip: &master)
      } else {
        setAssertedLocked(asserted: asserted, irq: irq - 8, chip: &slave)
        updateCascadeLocked()
      }
      publishPendingRequestLocked()
    }
  }

  public func configureLevelTriggeredIRQs(_ mask: UInt16) {
    lock.withLock {
      master.levelTriggered = UInt8(truncatingIfNeeded: mask)
      slave.levelTriggered = UInt8(truncatingIfNeeded: mask >> 8)
      reconcileLevelRequestsLocked(chip: &master)
      reconcileLevelRequestsLocked(chip: &slave)
      updateCascadeLocked()
      publishPendingRequestLocked()
    }
  }

  public func acknowledge(interruptsEnabled: Bool) -> UInt8? {
    guard interruptsEnabled, dory_atomic_u8_load_acquire(hasPendingRequest) != 0 else {
      return nil
    }
    return lock.withLock {
      defer { publishPendingRequestLocked() }
      guard var masterIRQ = highestDeliverable(master) else { return nil }
      if masterIRQ == 2 {
        if let slaveIRQ = highestDeliverable(slave) {
          slave.request &= ~(UInt8(1) << slaveIRQ)
          slave.inService |= UInt8(1) << slaveIRQ
          master.request &= ~(UInt8(1) << 2)
          master.inService |= UInt8(1) << 2
          updateCascadeLocked()
          return slave.vectorOffset &+ slaveIRQ
        }
        master.request &= ~(UInt8(1) << 2)
        guard let next = highestDeliverable(master) else { return nil }
        masterIRQ = next
      }
      master.request &= ~(UInt8(1) << masterIRQ)
      master.inService |= UInt8(1) << masterIRQ
      return master.vectorOffset &+ masterIRQ
    }
  }

  /// Reports whether a future assertion of `irq` could pass the cascaded priority resolvers.
  public func canAccept(irq: UInt8, interruptsEnabled: Bool) -> Bool {
    guard irq < 16, interruptsEnabled else { return false }
    return lock.withLock {
      if irq < 8 {
        return isDeliverable(irq, by: master)
      }
      return isDeliverable(2, by: master) && isDeliverable(irq - 8, by: slave)
    }
  }

  public func snapshot() -> DoryPCPIC8259Snapshot {
    lock.withLock {
      .init(
        masterVectorOffset: master.vectorOffset,
        slaveVectorOffset: slave.vectorOffset,
        masterMask: master.mask,
        slaveMask: slave.mask,
        masterRequest: master.request,
        slaveRequest: slave.request,
        masterInService: master.inService,
        slaveInService: slave.inService,
        masterLevelTriggered: master.levelTriggered,
        slaveLevelTriggered: slave.levelTriggered,
        masterAssertedLines: master.assertedLines,
        slaveAssertedLines: slave.assertedLines
      )
    }
  }

  fileprivate func read(_ controller: Controller, data: Bool) -> UInt8 {
    lock.withLock {
      let chip = controller == .master ? master : slave
      return data ? chip.mask : (chip.readInService ? chip.inService : chip.request)
    }
  }

  fileprivate func write(_ value: UInt8, controller: Controller, data: Bool) {
    lock.withLock {
      defer { publishPendingRequestLocked() }
      if data {
        writeDataLocked(value, controller: controller)
      } else {
        writeCommandLocked(value, controller: controller)
      }
    }
  }

  private func writeCommandLocked(_ value: UInt8, controller: Controller) {
    if value & 0x10 != 0 {
      withChip(controller) { chip in
        chip.initializationStep = 1
        chip.requiresICW4 = value & 1 != 0
        chip.mask = 0
        chip.request = 0
        chip.inService = 0
        reconcileLevelRequestsLocked(chip: &chip)
      }
      if controller == .slave { updateCascadeLocked() }
      return
    }
    if value & 0x18 == 0x08 {
      withChip(controller) { $0.readInService = value & 1 != 0 }
      return
    }
    guard value & 0x20 != 0 else { return }
    let specific = value & 0x40 != 0
    let requestedIRQ = value & 7
    withChip(controller) { chip in
      let irq = specific ? requestedIRQ : lowestSetBit(chip.inService)
      if let irq {
        let bit = UInt8(1) << irq
        chip.inService &= ~bit
        if chip.levelTriggered & bit != 0, chip.assertedLines & bit != 0 {
          chip.request |= bit
        }
      }
    }
    if controller == .slave { updateCascadeLocked() }
  }

  private func writeDataLocked(_ value: UInt8, controller: Controller) {
    let step = controller == .master ? master.initializationStep : slave.initializationStep
    switch step {
    case 1:
      withChip(controller) {
        $0.vectorOffset = value & 0xF8
        $0.initializationStep = 2
      }
    case 2:
      withChip(controller) { $0.initializationStep = $0.requiresICW4 ? 3 : 0 }
    case 3:
      withChip(controller) { $0.initializationStep = 0 }
    default:
      withChip(controller) { $0.mask = value }
      if controller == .slave { updateCascadeLocked() }
    }
  }

  private func highestDeliverable(_ chip: Chip) -> UInt8? {
    let pending = chip.request & ~chip.mask
    guard pending != 0 else { return nil }
    let servicePriority = lowestSetBit(chip.inService) ?? 8
    return (0..<servicePriority).first(where: { pending & (UInt8(1) << $0) != 0 })
  }

  private func isDeliverable(_ irq: UInt8, by chip: Chip) -> Bool {
    chip.mask & (UInt8(1) << irq) == 0
      && irq < (lowestSetBit(chip.inService) ?? 8)
  }

  private func lowestSetBit(_ value: UInt8) -> UInt8? {
    (0..<8).first(where: { value & (UInt8(1) << $0) != 0 })
  }

  private func updateCascadeLocked() {
    if slave.request & ~slave.mask != 0 {
      master.request |= 1 << 2
    } else {
      master.request &= ~(1 << 2)
    }
  }

  private func requestLocked(irq: UInt8) {
    if irq < 8 {
      master.request |= UInt8(1) << irq
    } else {
      slave.request |= UInt8(1) << (irq - 8)
      updateCascadeLocked()
    }
  }

  private func setAssertedLocked(asserted: Bool, irq: UInt8, chip: inout Chip) {
    let bit = UInt8(1) << irq
    let wasAsserted = chip.assertedLines & bit != 0
    if asserted {
      chip.assertedLines |= bit
    } else {
      chip.assertedLines &= ~bit
    }
    guard chip.levelTriggered & bit != 0 else {
      if asserted && !wasAsserted { chip.request |= bit }
      return
    }
    if asserted {
      chip.request |= bit
    } else {
      chip.request &= ~bit
    }
  }

  private func reconcileLevelRequestsLocked(chip: inout Chip) {
    chip.request = (chip.request & ~chip.levelTriggered) | (chip.assertedLines & chip.levelTriggered)
  }

  private func publishPendingRequestLocked() {
    dory_atomic_u8_store_release(hasPendingRequest, master.request == 0 ? 0 : 1)
  }

  private func withChip(_ controller: Controller, _ body: (inout Chip) -> Void) {
    if controller == .master { body(&master) } else { body(&slave) }
  }
}

public final class DoryPCPIC8259Port: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16
  public let portCount: UInt16 = 2
  private let pair: DoryPCPIC8259Pair
  private let controller: DoryPCPIC8259Pair.Controller

  public init(pair: DoryPCPIC8259Pair, slave: Bool) {
    self.pair = pair
    controller = slave ? .slave : .master
    basePort = slave ? 0xA0 : 0x20
  }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    return UInt32(pair.read(controller, data: portOffset == 1))
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    pair.write(UInt8(truncatingIfNeeded: value), controller: controller, data: portOffset == 1)
  }
}

/// Edge/level control register for the cascaded ISA PICs at the PC/AT-compatible ports 0x4d0
/// and 0x4d1. Without this device Linux reads the board's open-bus value and concludes that every
/// legacy IRQ is level-triggered, which pollutes interrupt routing before APIC handoff.
public final class DoryPCELCRPort: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16 = 0x4D0
  public let portCount: UInt16 = 2

  private static let writableMask: UInt16 = 0xDEF8

  private let lock = NSLock()
  private let pic: DoryPCPIC8259Pair
  private var value: UInt16 = 0

  public init(pic: DoryPCPIC8259Pair) {
    self.pic = pic
  }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    try validate(portOffset: portOffset, width: width)
    let current = lock.withLock { value }
    switch width {
    case .byte:
      return UInt32(byte(at: portOffset, in: current))
    case .word:
      return UInt32(current)
    case .doubleword, .quadword:
      preconditionFailure("DoryPCELCRPort.validate should reject unsupported widths")
    }
  }

  public func write(
    portOffset: UInt16,
    value newValue: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    try validate(portOffset: portOffset, width: width)
    lock.withLock {
      switch width {
      case .byte:
        let mask = UInt16(0xFF) << UInt16(portOffset * 8)
        let merged = (value & ~mask) | (UInt16(UInt8(truncatingIfNeeded: newValue)) << (portOffset * 8))
        value = merged & Self.writableMask
      case .word:
        value = UInt16(truncatingIfNeeded: newValue) & Self.writableMask
      case .doubleword, .quadword:
        preconditionFailure("DoryPCELCRPort.validate should reject unsupported widths")
      }
      pic.configureLevelTriggeredIRQs(value)
    }
  }

  private func validate(portOffset: UInt16, width: DoryX86OperandWidth) throws {
    let end = UInt32(portOffset) + UInt32(width.byteCount)
    guard (width == .byte || width == .word), end <= UInt32(portCount) else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
  }

  private func byte(at offset: UInt16, in value: UInt16) -> UInt8 {
    UInt8(truncatingIfNeeded: value >> UInt16(offset * 8))
  }
}

public enum DoryPCPITMode: UInt8, Sendable, Hashable {
  case interruptOnTerminalCount = 0
  case rateGenerator = 2
  case squareWave = 3
}

public struct DoryPCPITSnapshot: Sendable, Hashable {
  public let mode: DoryPCPITMode
  public let reload: UInt32
  public let current: UInt32
  public let armed: Bool
}

/// PC interval timer with the interrupting channel 0 and the system-control-port-backed channel 2.
public final class DoryPCPIT8254: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16 = 0x40
  public let portCount: UInt16 = 4

  private let lock = NSLock()
  private let onInterrupt: @Sendable () -> Void
  private var mode: DoryPCPITMode = .interruptOnTerminalCount
  private var accessMode: UInt8 = 3
  private var reload: UInt32 = 65_536
  private var current: UInt32 = 0
  private var armed = false
  private var writeLowByte: UInt8?
  private var readHighNext = false
  private var latchedCount: UInt32?
  private var channel2Mode: DoryPCPITMode = .interruptOnTerminalCount
  private var channel2AccessMode: UInt8 = 3
  private var channel2Reload: UInt32 = 65_536
  private var channel2Current: UInt32 = 0
  private var channel2Armed = false
  private var channel2Gate = false
  private var channel2Output = false
  private var channel2WriteLowByte: UInt8?
  private var channel2ReadHighNext = false
  private var channel2LatchedCount: UInt32?
  private var elapsedClocks: UInt64 = 0

  public init(onInterrupt: @escaping @Sendable () -> Void) {
    self.onInterrupt = onInterrupt
  }

  public func advance(by clocks: UInt64) {
    guard clocks > 0 else { return }
    let shouldInterrupt = lock.withLock {
      elapsedClocks &+= clocks
      advanceChannel2Locked(by: clocks)
      guard armed, current > 0 else { return false }
      guard clocks >= UInt64(current) else {
        current -= UInt32(clocks)
        return false
      }
      switch mode {
      case .interruptOnTerminalCount:
        current = 0
        armed = false
      case .rateGenerator, .squareWave:
        let remaining = (clocks - UInt64(current)) % UInt64(reload)
        current = remaining == 0 ? reload : reload - UInt32(remaining)
      }
      return true
    }
    if shouldInterrupt { onInterrupt() }
  }

  public func snapshot() -> DoryPCPITSnapshot {
    lock.withLock { .init(mode: mode, reload: reload, current: current, armed: armed) }
  }

  public func setChannel2Gate(_ enabled: Bool) {
    lock.withLock {
      let risingEdge = !channel2Gate && enabled
      channel2Gate = enabled
      if risingEdge, channel2Mode == .rateGenerator || channel2Mode == .squareWave {
        channel2Current = channel2Reload
        channel2Armed = true
        channel2Output = true
      }
    }
  }

  public var channel2OutputHigh: Bool { lock.withLock { channel2Output } }

  /// The AT system-control port exposes the DRAM refresh divider on bit 4. A deterministic
  /// 18-input-clock half period is sufficiently precise for firmware delay/probe loops.
  public var refreshToggleHigh: Bool { lock.withLock { (elapsedClocks / 18) & 1 != 0 } }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    let value: UInt8 = lock.withLock {
      return switch portOffset {
      case 0: readCounterLocked()
      case 2: readChannel2CounterLocked()
      default: 0
      }
    }
    return UInt32(value)
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    let byte = UInt8(truncatingIfNeeded: value)
    lock.withLock {
      if portOffset == 3 {
        writeControlLocked(byte)
      } else if portOffset == 0 {
        writeCounterLocked(byte)
      } else if portOffset == 2 {
        writeChannel2CounterLocked(byte)
      }
    }
  }

  private func writeControlLocked(_ value: UInt8) {
    let channel = value >> 6
    guard channel == 0 || channel == 2 else { return }
    let access = (value >> 4) & 3
    if access == 0 {
      if channel == 0 {
        latchedCount = current
        readHighNext = false
      } else {
        channel2LatchedCount = channel2Current
        channel2ReadHighNext = false
      }
      return
    }
    let rawMode = (value >> 1) & 7
    let selectedMode = DoryPCPITMode(rawValue: rawMode & 3) ?? .interruptOnTerminalCount
    if channel == 0 {
      accessMode = access
      mode = selectedMode
      writeLowByte = nil
      readHighNext = false
    } else {
      channel2AccessMode = access
      channel2Mode = selectedMode
      channel2WriteLowByte = nil
      channel2ReadHighNext = false
      channel2Armed = false
      channel2Output = selectedMode != .interruptOnTerminalCount
    }
  }

  private func writeCounterLocked(_ value: UInt8) {
    switch accessMode {
    case 1:
      loadLocked(UInt16(value))
    case 2:
      loadLocked(UInt16(value) << 8)
    default:
      if let low = writeLowByte {
        loadLocked(UInt16(low) | UInt16(value) << 8)
        writeLowByte = nil
      } else {
        writeLowByte = value
      }
    }
  }

  private func loadLocked(_ value: UInt16) {
    reload = value == 0 ? 65_536 : UInt32(value)
    current = reload
    armed = true
  }

  private func readCounterLocked() -> UInt8 {
    let value = latchedCount ?? current
    switch accessMode {
    case 2: return UInt8(truncatingIfNeeded: value >> 8)
    case 3:
      if readHighNext {
        readHighNext = false
        latchedCount = nil
        return UInt8(truncatingIfNeeded: value >> 8)
      }
      readHighNext = true
      return UInt8(truncatingIfNeeded: value)
    default: return UInt8(truncatingIfNeeded: value)
    }
  }

  private func writeChannel2CounterLocked(_ value: UInt8) {
    switch channel2AccessMode {
    case 1:
      loadChannel2Locked(UInt16(value))
    case 2:
      loadChannel2Locked(UInt16(value) << 8)
    default:
      if let low = channel2WriteLowByte {
        loadChannel2Locked(UInt16(low) | UInt16(value) << 8)
        channel2WriteLowByte = nil
      } else {
        channel2WriteLowByte = value
      }
    }
  }

  private func loadChannel2Locked(_ value: UInt16) {
    channel2Reload = value == 0 ? 65_536 : UInt32(value)
    channel2Current = channel2Reload
    channel2Armed = true
    channel2Output = channel2Mode != .interruptOnTerminalCount
  }

  private func readChannel2CounterLocked() -> UInt8 {
    let value = channel2LatchedCount ?? channel2Current
    switch channel2AccessMode {
    case 2: return UInt8(truncatingIfNeeded: value >> 8)
    case 3:
      if channel2ReadHighNext {
        channel2ReadHighNext = false
        channel2LatchedCount = nil
        return UInt8(truncatingIfNeeded: value >> 8)
      }
      channel2ReadHighNext = true
      return UInt8(truncatingIfNeeded: value)
    default: return UInt8(truncatingIfNeeded: value)
    }
  }

  private func advanceChannel2Locked(by clocks: UInt64) {
    guard channel2Gate, channel2Armed, channel2Current > 0 else { return }
    guard clocks >= UInt64(channel2Current) else {
      channel2Current -= UInt32(clocks)
      return
    }
    switch channel2Mode {
    case .interruptOnTerminalCount:
      channel2Current = 0
      channel2Armed = false
      channel2Output = true
    case .rateGenerator, .squareWave:
      let remaining = (clocks - UInt64(channel2Current)) % UInt64(channel2Reload)
      channel2Current = remaining == 0 ? channel2Reload : channel2Reload - UInt32(remaining)
      channel2Output = true
    }
  }
}

/// AT-compatible system control port B. Bits 0/1 are software controlled; bits 4/5 expose the
/// refresh divider and PIT channel-2 output used by firmware and boot-loader calibration loops.
public final class DoryPCSystemControlPortB: DoryPCPortIODevice, @unchecked Sendable {
  public let basePort: UInt16 = 0x61
  public let portCount: UInt16 = 1

  private let lock = NSLock()
  private let pit: DoryPCPIT8254
  private var control: UInt8 = 0

  public init(pit: DoryPCPIT8254) { self.pit = pit }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    let writable = lock.withLock { control }
    let status = (pit.refreshToggleHigh ? UInt8(0x10) : 0)
      | (pit.channel2OutputHigh ? UInt8(0x20) : 0)
    return UInt32(writable | status)
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    let next = UInt8(truncatingIfNeeded: value) & 0x03
    lock.withLock { control = next }
    pit.setChannel2Gate(next & 1 != 0)
  }
}
