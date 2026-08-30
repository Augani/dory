import DoryDBTX86
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
    var initializationStep: UInt8 = 0
    var requiresICW4 = false
    var readInService = false
  }

  private let lock = NSLock()
  private var master = Chip(vectorOffset: 0x08)
  private var slave = Chip(vectorOffset: 0x70)

  public init() {}

  public func raise(irq: UInt8) throws {
    guard irq < 16 else { throw DoryPCLegacyInterruptError.invalidIRQ(irq) }
    lock.withLock {
      if irq < 8 {
        master.request |= UInt8(1) << irq
      } else {
        slave.request |= UInt8(1) << (irq - 8)
        updateCascadeLocked()
      }
    }
  }

  public func acknowledge(interruptsEnabled: Bool) -> UInt8? {
    lock.withLock {
      guard interruptsEnabled else { return nil }
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
        slaveInService: slave.inService
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
      if let irq { chip.inService &= ~(UInt8(1) << irq) }
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

/// Channel-0 PC interval timer. Channels 1/2 remain inert until their owning devices are added.
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

  public init(onInterrupt: @escaping @Sendable () -> Void) {
    self.onInterrupt = onInterrupt
  }

  public func advance(by clocks: UInt64) {
    guard clocks > 0 else { return }
    let shouldInterrupt = lock.withLock {
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

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else {
      throw DoryPCLegacyInterruptError.unsupportedPortWidth(width)
    }
    guard portOffset == 0 else { return 0 }
    return UInt32(lock.withLock { readCounterLocked() })
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
      }
    }
  }

  private func writeControlLocked(_ value: UInt8) {
    guard value >> 6 == 0 else { return }
    let access = (value >> 4) & 3
    if access == 0 {
      latchedCount = current
      readHighNext = false
      return
    }
    accessMode = access
    let rawMode = (value >> 1) & 7
    mode = DoryPCPITMode(rawValue: rawMode & 3) ?? .interruptOnTerminalCount
    writeLowByte = nil
    readHighNext = false
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
}
