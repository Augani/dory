import DoryVirtio
import Foundation

/// Internal provider capability for device-domain-before-controller lock ordering. Public
/// guest-memory implementations remain valid; production physical DMA supplies this guard.
protocol DoryPCGuestMemoryDeviceExecutionGuard: DoryVirtioGuestMemory {
  func withDeviceExecutionGuard(_ body: () -> Void)
}

public enum DoryPCXHCIError: Error, Sendable, Equatable {
  case invalidPort(Int)
  case portAlreadyConnected(Int)
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

public struct DoryPCXHCISlotState: Sendable, Hashable {
  public let slotID: UInt8
  public let addressed: Bool

  public init(slotID: UInt8, addressed: Bool) {
    self.slotID = slotID
    self.addressed = addressed
  }
}

/// A bounded xHCI 1.2 PCI function for the frozen DoryPC-v1 machine contract.
///
/// The controller owns guest register and event-ring mechanics. Physical USB authority remains in
/// the host broker; callers may only reflect an already-authorized attachment into a root port.
public final class DoryPCXHCIController: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  private struct Slot {
    struct Endpoint: Equatable {
      enum State: UInt32 {
        case disabled = 0
        case running = 1
        case halted = 2
        case stopped = 3
        case error = 4
      }

      var type: DoryPCUSBTransferType
      var direction: DoryPCUSBTransferDirection
      var number: UInt8
      var dequeueAddress: UInt64
      var cycle: Bool
      var state: State
      var generation = UUID()
    }

    var addressed = false
    var rootPort: UInt8 = 0
    var deviceAddress: UInt8 = 0
    var outputContextAddress: UInt64 = 0
    var endpoints: [UInt8: Endpoint] = [:]
    var generation = UUID()
  }

  private struct TransferSegment {
    let trbAddress: UInt64
    let bufferAddress: UInt64
    let byteCount: Int
    let control: UInt32
  }

  private struct TransferDescriptor {
    let segments: [TransferSegment]
    let eventData: UInt64?
    let eventDataControl: UInt32?
    let nextDequeueAddress: UInt64
    let nextCycle: Bool

    var requestedBytes: Int { segments.reduce(0) { $0 + $1.byteCount } }
    var interruptOnCompletion: Bool {
      eventDataControl.map { ($0 & (1 << 5)) != 0 }
        ?? (((segments.last?.control ?? 0) & (1 << 5)) != 0)
    }
    var interruptOnShortPacket: Bool {
      segments.contains { $0.control & (1 << 2) != 0 }
    }
    var eventPointer: UInt64 { eventData ?? segments.last?.trbAddress ?? 0 }
  }

  /// Captured with the original port transition, never reconstructed after a platform call.
  private struct PortStatusReceipt {
    let port: Int
    let portGeneration: UUID
    let memoryGeneration: UUID
  }

  private struct CommandReceipt {
    let owner: UUID
    let memoryGeneration: UUID
    let dequeueAddress: UInt64
    let cycle: Bool
  }

  private struct SlotCommandReceipt {
    let command: CommandReceipt
    let slotID: UInt8
    let slotGeneration: UUID
    let rootPort: UInt8
    let portGenerations: [UUID]
  }

  private enum CommandDrainDisposition {
    case stop
    case retry
    case schedule(UUID)
  }

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
  /// Serialize readiness-handler installation/removal without holding controller ownership
  /// while calling a device. Cancellation and transfers never hold this short-lived gate.
  private let deviceNotificationLock = NSRecursiveLock()
  private var guestMemory: (any DoryVirtioGuestMemory)?
  private var guestMemoryGeneration = UUID()
  private var usbCommand: UInt32 = 0
  private var usbStatus: UInt32 = usbStatusHalted
  private var deviceNotificationControl: UInt32 = 0
  private var commandRingControl: UInt64 = 0
  private var commandRingDequeueAddress: UInt64 = 0
  private var commandRingCycle = true
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
  private var portGenerations = (0..<portCount).map { _ in UUID() }
  private var devices: [Int: any DoryPCUSBDevice] = [:]
  private var deviceGenerations: [Int: UUID] = [:]
  private var slots: [UInt8: Slot] = [:]
  private var processingEndpoints: [UInt16: UUID] = [:]
  private var processingCommandRing: UUID?
  private var commandKickPending = false
  private let commandContinuationQueue = DispatchQueue(label: "DoryPC.xHCI.command-continuation")
  private var commandContinuationOwner: UUID?
  /// This bit follows the actual queued callback, even after its authority is retired.
  /// A new generation records its own pending owner without adding another queued callback.
  private var commandContinuationEnqueued = false

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
    lock.withLock {
      guestMemory = memory
      guestMemoryGeneration = UUID()
      processingCommandRing = nil
      commandKickPending = false
      commandContinuationOwner = nil
    }
  }

  public func connect(port: Int, speed: DoryPCXHCIPortSpeed) throws {
    let receipt = try lock.withLock { () -> PortStatusReceipt? in
      let index = try portIndex(port)
      let old = ports[index]
      var value = old & Self.portChangeMask
      value |= Self.portPower | Self.portConnectStatus | Self.portConnectChange
      value |= UInt32(speed.rawValue) << 10
      ports[index] = value
      portGenerations[index] = UUID()
      return old & Self.portConnectStatus == 0 ? portStatusReceiptLocked(port: port) : nil
    }
    if let receipt { postPortStatusChange(receipt) }
  }

  public func connect(port: Int, device: any DoryPCUSBDevice) throws {
    let generation = UUID()
    let receipt = try deviceNotificationLock.withLock {
      let receipt = try lock.withLock { () -> PortStatusReceipt? in
        let index = try portIndex(port)
        guard devices[index] == nil else { throw DoryPCXHCIError.portAlreadyConnected(port) }
        devices[index] = device
        deviceGenerations[index] = generation
        portGenerations[index] = UUID()
        let old = ports[index]
        ports[index] = (old & Self.portChangeMask) | Self.portPower | Self.portConnectStatus
          | Self.portConnectChange | UInt32(device.speed.rawValue) << 10
        return old & Self.portConnectStatus == 0 ? portStatusReceiptLocked(port: port) : nil
      }
      (device as? any DoryPCUSBTransferReadyNotifying)?.setTransferReadyHandler {
        [weak self] in
        self?.wakeTransfers(port: port, generation: generation)
      }
      return receipt
    }
    if let receipt { postPortStatusChange(receipt) }
  }

  public func disconnect(port: Int) throws {
    let result = try deviceNotificationLock.withLock {
      let result = try lock.withLock {
        let index = try portIndex(port)
        let device = devices.removeValue(forKey: index)
        deviceGenerations.removeValue(forKey: index)
        var endpoints: [(slotID: UInt8, dci: UInt8, endpoint: Slot.Endpoint)] = []
        for slotID in slots.keys.sorted() {
          guard var slot = slots[slotID], slot.addressed, slot.rootPort == UInt8(port) else {
            continue
          }
          for dci in slot.endpoints.keys.sorted() {
            guard var endpoint = slot.endpoints[dci],
              endpoint.state != .halted, endpoint.state != .error
            else { continue }
            endpoint.state = .error
            slot.endpoints[dci] = endpoint
            endpoints.append((slotID, dci, endpoint))
          }
          slots[slotID] = slot
        }
        let old = ports[index]
        var value = old & Self.portChangeMask
        value |= Self.portPower | Self.portConnectChange
        if old & Self.portEnabled != 0 { value |= Self.portEnableChange }
        ports[index] = value
        // Repeated no-op disconnects share the in-flight retirement, rather than suppressing
        // its completion while a platform cancellation is still outside controller ownership.
        if device != nil || old & Self.portConnectStatus != 0 {
          portGenerations[index] = UUID()
        }
        return (
          notifyPort: old & Self.portConnectStatus != 0, device: device,
          endpoints: endpoints, memory: guestMemory, memoryGeneration: guestMemoryGeneration,
          portGeneration: portGenerations[index], index: index
        )
      }
      (result.device as? any DoryPCUSBTransferReadyNotifying)?.setTransferReadyHandler(nil)
      return result
    }
    result.device?.cancelAll()
    let admitted = lock.withLock {
      guard guestMemoryGeneration == result.memoryGeneration,
        portGenerations[result.index] == result.portGeneration,
        devices[result.index] == nil
      else { return false }
      for endpoint in result.endpoints {
        guard let memory = result.memory,
          let slot = slots[endpoint.slotID], slot.rootPort == UInt8(port),
          slot.endpoints[endpoint.dci] == endpoint.endpoint,
          writeEndpointContext(
            endpoint.endpoint,
            at: slot.outputContextAddress + UInt64(endpoint.dci) * 32,
            memory: memory
          )
        else { continue }
        // Context and event share exact port, endpoint and memory ownership. No unlocked
        // cancellation return may publish old USB completions into a successor event ring.
        try? writeEventLocked(transferEvent(
          trbAddress: endpoint.endpoint.dequeueAddress, completionCode: 22,
          residualBytes: 0, slotID: endpoint.slotID, dci: endpoint.dci
        ))
      }
      if result.notifyPort {
        usbStatus |= Self.usbStatusPortChange
        try? writeEventLocked(portStatusChangeEvent(port: port))
      }
      return true
    }
    if admitted { updateInterruptLine() }
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

  public var slotStates: [DoryPCXHCISlotState] {
    lock.withLock {
      slots.keys.sorted().compactMap { slotID in
        slots[slotID].map { .init(slotID: slotID, addressed: $0.addressed) }
      }
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

  public func validateBARRead(offset: UInt64, byteCount: Int) throws {
    try validateAccess(offset: offset, byteCount: byteCount, write: false)
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
    if writeAddressRegister(offset: offset, bytes: bytes) { return }
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
      let doorbell = Int((offset - Self.doorbellOffset) / 4)
      let target = UInt8(truncatingIfNeeded: uint32(bytes))
      if doorbell == 0, target == 0 {
        processCommandRing()
      } else if doorbell > 0, target > 0 {
        processTransferRing(slotID: UInt8(doorbell), dci: target)
      }
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
        port & Self.portChangeMask != 0 ? portStatusReceiptLocked(port: index + 1) : nil
      }
    }
    if value & 1 != 0 {
      for receipt in pendingPorts { postPortStatusChange(receipt) }
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

  // xHCI address registers accept a Qword or low/high Dword writes (xHCI 1.2 §5.1).
  // Merge under the controller lock so each half preserves the other half and register flags.
  private func writeAddressRegister(offset: UInt64, bytes: [UInt8]) -> Bool {
    guard (bytes.count == 4 && offset % 4 == 0)
      || (bytes.count == 8 && offset % 8 == 0) else { return false }
    let base = offset & ~UInt64(7)
    let handled = lock.withLock {
      let current: UInt64
      switch base {
      case Self.operationalOffset + 0x18: current = commandRingControl
      case Self.operationalOffset + 0x30: current = deviceContextBaseAddress
      case Self.runtimeOffset + 0x30: current = eventRingSegmentTableAddress
      case Self.runtimeOffset + 0x38: current = eventRingDequeuePointer
      default: return false
      }
      let value: UInt64
      if bytes.count == 8 {
        value = uint64(bytes)
      } else if offset == base {
        value = (current & 0xFFFF_FFFF_0000_0000) | UInt64(uint32(bytes))
      } else {
        value = (current & 0xFFFF_FFFF) | (UInt64(uint32(bytes)) << 32)
      }
      switch base {
      case Self.operationalOffset + 0x18:
        if commandRingDequeueAddress != (value & ~UInt64(0x3F))
          || commandRingCycle != (value & 1 != 0) {
          processingCommandRing = nil
          commandKickPending = false
          commandContinuationOwner = nil
        }
        commandRingControl = value & ~UInt64(0x30)
        commandRingDequeueAddress = value & ~UInt64(0x3F)
        commandRingCycle = value & 1 != 0
      case Self.operationalOffset + 0x30:
        deviceContextBaseAddress = value & ~UInt64(0x3F)
      case Self.runtimeOffset + 0x30:
        eventRingSegmentTableAddress = value & ~UInt64(0x3F)
        invalidateEventRingLocked()
      default:
        eventRingDequeuePointer = value & ~UInt64(0x8)
        if value & 0x8 != 0 { interrupterManagement &= ~UInt32(1) }
      }
      return true
    }
    if handled && base == Self.runtimeOffset + 0x38 { updateInterruptLine() }
    return handled
  }

  private func writePort(_ port: Int, value: UInt32) throws {
    let result = try lock.withLock {
      let index = try portIndex(port)
      var current = ports[index]
      current &= ~(value & Self.portChangeMask)
      guard value & Self.portReset != 0 else {
        ports[index] = current
        return (nil as PortStatusReceipt?, nil as (any DoryPCUSBDevice)?)
      }
      portGenerations[index] = UUID()
      if current & Self.portConnectStatus != 0 {
        current |= Self.portEnabled | Self.portResetChange
      }
      for slotID in slots.keys {
        guard slots[slotID]?.rootPort == UInt8(port) else { continue }
        for dci in slots[slotID]?.endpoints.keys.sorted() ?? [] {
          slots[slotID]?.endpoints[dci]?.generation = UUID()
        }
      }
      current &= ~Self.portReset
      ports[index] = current
      return (portStatusReceiptLocked(port: port) as PortStatusReceipt?, devices[index])
    }
    result.1?.reset()
    if let receipt = result.0 { postPortStatusChange(receipt) }
  }

  private func resetController() {
    let connectedDevices = lock.withLock {
      usbCommand = 0
      usbStatus = Self.usbStatusHalted
      deviceNotificationControl = 0
      commandRingControl = 0
      commandRingDequeueAddress = 0
      commandRingCycle = true
      deviceContextBaseAddress = 0
      configuredSlots = 0
      slots.removeAll(keepingCapacity: true)
      guestMemoryGeneration = UUID()
      processingEndpoints.removeAll(keepingCapacity: true)
      processingCommandRing = nil
      commandKickPending = false
      commandContinuationOwner = nil
      interrupterManagement = 0
      interrupterModeration = 4_000
      eventRingSegmentTableSize = 0
      eventRingSegmentTableAddress = 0
      eventRingDequeuePointer = 0
      invalidateEventRingLocked()
      for index in ports.indices {
        let attachment = ports[index] & (Self.portConnectStatus | (0xF << 10))
        ports[index] = Self.portPower | attachment
        portGenerations[index] = UUID()
      }
      return Array(devices.values)
    }
    for device in connectedDevices { device.cancelAll() }
    configurationFunction.setINTx(asserted: false)
  }

  private func portStatusReceiptLocked(port: Int) -> PortStatusReceipt {
    .init(port: port, portGeneration: portGenerations[port - 1],
          memoryGeneration: guestMemoryGeneration)
  }

  private func postPortStatusChange(_ receipt: PortStatusReceipt) {
    let admitted = lock.withLock {
      guard guestMemoryGeneration == receipt.memoryGeneration,
        portGenerations[receipt.port - 1] == receipt.portGeneration
      else { return false }
      usbStatus |= Self.usbStatusPortChange
      try? writeEventLocked(portStatusChangeEvent(port: receipt.port))
      return true
    }
    if admitted { updateInterruptLine() }
  }

  private func portStatusChangeEvent(port: Int) -> [UInt8] {
    var event = [UInt8](repeating: 0, count: 16)
    put(UInt32(port) << 24, at: 0, in: &event)
    put(UInt32(1) << 24, at: 8, in: &event)
    put(UInt32(34) << 10, at: 12, in: &event)
    return event
  }

  private func processCommandRing() {
    let owner = UUID()
    guard lock.withLock({
      guard processingCommandRing == nil else {
        commandKickPending = true
        return false
      }
      processingCommandRing = owner
      commandKickPending = false
      return true
    }) else { return }
    drainCommandRing(owner: owner)
  }

  private func drainCommandRing(owner: UUID) {
    let admission = lock.withLock { () -> ((any DoryVirtioGuestMemory)?, UUID)? in
      guard processingCommandRing == owner else { return nil }
      return (guestMemory, guestMemoryGeneration)
    }
    guard let admission else { return }
    let execute = {
      // Memory replacement retires this owner. Never execute a successor through a guard
      // belonging to the captured old provider while waiting outside controller ownership.
      guard self.lock.withLock({
        self.processingCommandRing == owner && self.guestMemoryGeneration == admission.1
      }) else { return }
      self.drainCommandRingInExecutionDomain(owner: owner)
    }
    if let provider = admission.0 as? any DoryPCGuestMemoryDeviceExecutionGuard {
      // Acquiring the shared CPU/DMA domain must NEVER happen under the xHCI lock.
      provider.withDeviceExecutionGuard(execute)
    } else {
      execute()
    }
  }

  private func drainCommandRingInExecutionDomain(owner: UUID) {
    // Each synchronous turn is bounded. A pending kick beyond this budget retains the
    // same owner for one asynchronous turn instead of discarding that kick at unwind.
    for pass in 0..<2 {
      processOwnedCommandRing(owner: owner)
      let disposition = lock.withLock { () -> CommandDrainDisposition in
        guard processingCommandRing == owner else { return .stop }
        guard commandKickPending else {
          // Release in the SAME decision as observing no kick. A later doorbell must
          // acquire a new owner, rather than enqueue work that an old defer could erase.
          processingCommandRing = nil
          if commandContinuationOwner == owner { commandContinuationOwner = nil }
          return .stop
        }
        commandKickPending = false
        if pass == 0 { return .retry }
        commandContinuationOwner = owner
        guard !commandContinuationEnqueued else { return .stop }
        commandContinuationEnqueued = true
        return .schedule(owner)
      }
      switch disposition {
      case .stop: return
      case .retry: continue
      case .schedule(let continuationOwner):
        enqueueCommandContinuation(owner: continuationOwner)
        return
      }
    }
  }

  private func enqueueCommandContinuation(owner: UUID) {
    commandContinuationQueue.async { [weak self] in self?.runCommandContinuation(owner: owner) }
  }

  private func runCommandContinuation(owner: UUID) {
    let disposition = lock.withLock { () -> CommandDrainDisposition in
      commandContinuationEnqueued = false
      guard let pendingOwner = commandContinuationOwner,
        processingCommandRing == pendingOwner
      else {
        commandContinuationOwner = nil
        return .stop
      }
      guard pendingOwner == owner else {
        // A retired queued callback never reads or acquires a successor's authority.
        // It only reserves a NEW callback carrying that successor's exact owner.
        commandContinuationEnqueued = true
        return .schedule(pendingOwner)
      }
      commandContinuationOwner = nil
      return .retry
    }
    switch disposition {
    case .stop: return
    case .retry: drainCommandRing(owner: owner)
    case .schedule(let successorOwner): enqueueCommandContinuation(owner: successorOwner)
    }
  }

  private func processOwnedCommandRing(owner: UUID) {
    for _ in 0..<4_096 {
      let state = lock.withLock {
        (guestMemory, commandRingDequeueAddress, commandRingCycle,
         usbCommand & 1 != 0 && processingCommandRing == owner,
         guestMemoryGeneration)
      }
      guard state.3, let memory = state.0, state.1 != 0,
        let bytes = try? memory.read(at: state.1, byteCount: 16), bytes.count == 16
      else { return }
      let receipt = CommandReceipt(
        owner: owner, memoryGeneration: state.4, dequeueAddress: state.1, cycle: state.2
      )
      let control = uint32(Array(bytes[12..<16]))
      guard control & 1 == (state.2 ? 1 : 0) else { return }
      let type = UInt8((control >> 10) & 0x3F)
      if type == 6 {
        let target = uint64(Array(bytes[0..<8])) & ~UInt64(0xF)
        guard target != 0 else { return }
        let admitted = lock.withLock {
          guard commandReceiptIsCurrentLocked(receipt) else { return false }
          commandRingDequeueAddress = target
          if control & 2 != 0 { commandRingCycle.toggle() }
          return true
        }
        guard admitted else { return }
        continue
      }

      guard lock.withLock({ commandReceiptIsCurrentLocked(receipt) }) else { return }
      guard let result = executeCommand(
        type: type,
        parameter: uint64(Array(bytes[0..<8])),
        status: uint32(Array(bytes[8..<12])),
        control: control,
        memory: memory,
        receipt: receipt
      ) else { return }
      var event = [UInt8](repeating: 0, count: 16)
      put(state.1, at: 0, in: &event)
      put(UInt32(result.completionCode) << 24, at: 8, in: &event)
      put(
        UInt32(result.slotID) << 24 | UInt32(33) << 10,
        at: 12,
        in: &event
      )
      let admitted = lock.withLock {
        guard commandReceiptIsCurrentLocked(receipt) else { return false }
        commandRingDequeueAddress &+= 16
        return (try? writeEventLocked(event)) != nil
      }
      guard admitted else { return }
      updateInterruptLine()
    }
  }

  private func commandReceiptIsCurrentLocked(_ receipt: CommandReceipt) -> Bool {
    processingCommandRing == receipt.owner && guestMemoryGeneration == receipt.memoryGeneration
      && commandRingDequeueAddress == receipt.dequeueAddress
      && commandRingCycle == receipt.cycle && usbCommand & 1 != 0
  }

  private func processTransferRing(slotID: UInt8, dci: UInt8) {
    let executionKey = UInt16(slotID) << 8 | UInt16(dci)
    let executionID = UUID()
    guard lock.withLock({ () -> Bool in
      guard processingEndpoints[executionKey] == nil else { return false }
      processingEndpoints[executionKey] = executionID
      return true
    }) else { return }
    defer {
      lock.withLock {
        if processingEndpoints[executionKey] == executionID {
          processingEndpoints.removeValue(forKey: executionKey)
        }
      }
    }
    for _ in 0..<4_096 {
      let state = lock.withLock {
        () -> (
          memory: (any DoryVirtioGuestMemory)?,
          memoryGeneration: UUID,
          endpoint: Slot.Endpoint?,
          device: (any DoryPCUSBDevice)?
        ) in
        guard processingEndpoints[executionKey] == executionID,
          let slot = slots[slotID], let endpoint = slot.endpoints[dci] else {
          return (guestMemory, guestMemoryGeneration, nil, nil)
        }
        return (guestMemory, guestMemoryGeneration, endpoint, devices[Int(slot.rootPort) - 1])
      }
      guard let memory = state.memory, var endpoint = state.endpoint, let device = state.device,
        endpoint.state != .halted, endpoint.state != .error,
        endpoint.dequeueAddress != 0,
        let bytes = try? memory.read(at: endpoint.dequeueAddress, byteCount: 16), bytes.count == 16
      else { return }
      if endpoint.state == .stopped {
        let expectedEndpoint = endpoint
        endpoint.state = .running
        guard commitTransferResult(
          slotID: slotID,
          dci: dci,
          endpoint: endpoint,
          expectedEndpoint: expectedEndpoint,
          device: device,
          memory: memory,
          memoryGeneration: state.memoryGeneration,
          payloadWrites: [], event: nil
        )
        else { return }
      }
      let control = uint32(Array(bytes[12..<16]))
      guard control & 1 == (endpoint.cycle ? 1 : 0) else { return }
      let trbType = UInt8((control >> 10) & 0x3F)
      if trbType == 6 {
        let expectedEndpoint = endpoint
        let target = uint64(Array(bytes[0..<8])) & ~UInt64(0xF)
        guard target != 0 else { return }
        endpoint.dequeueAddress = target
        if control & 2 != 0 { endpoint.cycle.toggle() }
        guard commitTransferResult(
          slotID: slotID,
          dci: dci,
          endpoint: endpoint,
          expectedEndpoint: expectedEndpoint,
          device: device,
          memory: memory,
          memoryGeneration: state.memoryGeneration,
          payloadWrites: [], event: nil
        ) else { return }
        continue
      }
      if endpoint.type == .control {
        processControlTransfer(
          slotID: slotID,
          dci: dci,
          endpoint: endpoint,
          device: device,
          memory: memory,
          memoryGeneration: state.memoryGeneration,
          firstTRB: bytes
        )
        return
      }
      let dataTRBType: UInt8 = endpoint.type == .isochronous ? 5 : 1
      guard trbType == dataTRBType || trbType == 7 else {
        postTransferEvent(
          trbAddress: endpoint.dequeueAddress,
          completionCode: 5,
          residualBytes: 0,
          slotID: slotID,
          dci: dci, expectedEndpoint: endpoint, device: device,
          memoryGeneration: state.memoryGeneration
        )
        return
      }
      guard
        let descriptor = collectTransferDescriptor(
          endpoint: endpoint,
          memory: memory,
          firstTRB: bytes,
          dataTRBType: dataTRBType
        )
      else {
        postTransferEvent(
          trbAddress: endpoint.dequeueAddress,
          completionCode: 5,
          residualBytes: 0,
          slotID: slotID,
          dci: dci, expectedEndpoint: endpoint, device: device,
          memoryGeneration: state.memoryGeneration
        )
        return
      }
      if descriptor.segments.isEmpty {
        let expectedEndpoint = endpoint
        endpoint.dequeueAddress = descriptor.nextDequeueAddress
        endpoint.cycle = descriptor.nextCycle
        let event = descriptor.interruptOnCompletion ? transferEvent(
          trbAddress: descriptor.eventPointer,
          completionCode: 1, residualBytes: 0,
          slotID: slotID, dci: dci, eventData: descriptor.eventData != nil
        ) : nil
        guard commitTransferResult(
          slotID: slotID,
          dci: dci,
          endpoint: endpoint,
          expectedEndpoint: expectedEndpoint,
          device: device,
          memory: memory,
          memoryGeneration: state.memoryGeneration,
          payloadWrites: [], event: event
        )
        else { return }
        if event != nil { updateInterruptLine() }
        continue
      }
      let requestedBytes = descriptor.requestedBytes
      let payload: [UInt8]
      if endpoint.direction == .out {
        var gathered: [UInt8] = []
        gathered.reserveCapacity(requestedBytes)
        for segment in descriptor.segments {
          guard
            let read = try? memory.read(at: segment.bufferAddress, byteCount: segment.byteCount),
            read.count == segment.byteCount
          else { return }
          gathered += read
        }
        payload = gathered
      } else {
        payload = []
      }
      guard
        let transfer = try? DoryPCUSBTransfer(
          type: endpoint.type,
          direction: endpoint.direction,
          endpoint: endpoint.number,
          payload: payload,
          maximumResponseBytes: endpoint.direction == .in ? requestedBytes : 0
        )
      else { return }
      let expectedEndpoint = endpoint
      let result = device.perform(transfer)
      if result.status == .notReady { return }
      let response = Array(result.payload.prefix(requestedBytes))
      var writes: [(address: UInt64, bytes: [UInt8])] = []
      if endpoint.direction == .in, !response.isEmpty {
        var responseOffset = 0
        for segment in descriptor.segments where responseOffset < response.count {
          let count = min(segment.byteCount, response.count - responseOffset)
          writes.append(
            (
              segment.bufferAddress,
              Array(response[responseOffset..<(responseOffset + count)])
            )
          )
          responseOffset += count
        }
      }
      let halted = result.status == .stalled || result.status == .transactionError
      if halted {
        endpoint.state = .halted
      } else {
        endpoint.dequeueAddress = descriptor.nextDequeueAddress
        endpoint.cycle = descriptor.nextCycle
      }
      let shortResponse = endpoint.direction == .in && response.count < requestedBytes
      let shouldPostEvent = halted || descriptor.interruptOnCompletion
        || shortResponse && descriptor.interruptOnShortPacket
      let residual = endpoint.direction == .in ? requestedBytes - response.count : 0
      let transferred = endpoint.direction == .in ? response.count : (halted ? 0 : requestedBytes)
      let event = shouldPostEvent ? transferEvent(
        trbAddress: descriptor.eventPointer,
        completionCode: completionCode(status: result.status, shortResponse: shortResponse),
        residualBytes: descriptor.eventData == nil ? residual : transferred,
        slotID: slotID, dci: dci, eventData: descriptor.eventData != nil
      ) : nil
      guard commitTransferResult(
        slotID: slotID,
        dci: dci,
        endpoint: endpoint,
        expectedEndpoint: expectedEndpoint,
        device: device,
        memory: memory,
        memoryGeneration: state.memoryGeneration,
        payloadWrites: writes,
        event: event
      )
      else { return }
      if event != nil { updateInterruptLine() }
    }
  }

  private func wakeTransfers(port: Int, generation: UUID) {
    let targets: [(UInt8, UInt8)] = lock.withLock {
      guard deviceGenerations[port - 1] == generation else { return [] }
      return slots.compactMap { slotID, slot -> [(UInt8, UInt8)]? in
        guard slot.rootPort == UInt8(port) else { return nil }
        return slot.endpoints.keys.sorted().map { (slotID, $0) }
      }.flatMap { $0 }
    }
    for (slotID, dci) in targets { processTransferRing(slotID: slotID, dci: dci) }
  }

  private func processControlTransfer(
    slotID: UInt8,
    dci: UInt8,
    endpoint: Slot.Endpoint,
    device: any DoryPCUSBDevice,
    memory: any DoryVirtioGuestMemory,
    memoryGeneration: UUID,
    firstTRB: [UInt8]
  ) {
    let setupControl = uint32(Array(firstTRB[12..<16]))
    guard (setupControl >> 10) & 0x3F == 2, setupControl & (1 << 6) != 0,
      let setup = try? DoryPCUSBSetupPacket(bytes: Array(firstTRB[0..<8]))
    else {
      postTransferEvent(
        trbAddress: endpoint.dequeueAddress,
        completionCode: 5,
        residualBytes: 0,
        slotID: slotID,
        dci: dci, expectedEndpoint: endpoint, device: device,
        memoryGeneration: memoryGeneration
      )
      return
    }
    var nextAddress = endpoint.dequeueAddress + 16
    guard let next = try? memory.read(at: nextAddress, byteCount: 16), next.count == 16 else {
      return
    }
    var nextControl = uint32(Array(next[12..<16]))
    guard nextControl & 1 == (endpoint.cycle ? 1 : 0) else { return }
    var dataAddress: UInt64 = 0
    var requestedBytes = 0
    var payload: [UInt8] = []
    if (nextControl >> 10) & 0x3F == 3 {
      dataAddress = uint64(Array(next[0..<8]))
      requestedBytes = Int(uint32(Array(next[8..<12])) & 0x1_FFFF)
      let dataDirection: DoryPCUSBTransferDirection = nextControl & (1 << 16) != 0 ? .in : .out
      guard dataDirection == setup.direction else {
        postTransferEvent(
          trbAddress: nextAddress,
          completionCode: 5,
          residualBytes: requestedBytes,
          slotID: slotID,
          dci: dci, expectedEndpoint: endpoint, device: device,
          memoryGeneration: memoryGeneration
        )
        return
      }
      if dataDirection == .out {
        guard let bytes = try? memory.read(at: dataAddress, byteCount: requestedBytes),
          bytes.count == requestedBytes
        else { return }
        payload = bytes
      }
      nextAddress += 16
      guard let status = try? memory.read(at: nextAddress, byteCount: 16), status.count == 16
      else { return }
      nextControl = uint32(Array(status[12..<16]))
    }
    guard (nextControl >> 10) & 0x3F == 4,
      nextControl & 1 == (endpoint.cycle ? 1 : 0),
      let transfer = try? DoryPCUSBTransfer(
        type: .control,
        direction: setup.direction,
        endpoint: 0,
        setup: setup,
        payload: payload,
        maximumResponseBytes: setup.direction == .in ? requestedBytes : 0
      )
    else { return }
    let result = device.perform(transfer)
    if result.status == .notReady { return }
    let response = Array(result.payload.prefix(requestedBytes))
    let writes: [(address: UInt64, bytes: [UInt8])] = setup.direction == .in && !response.isEmpty
      ? [(dataAddress, response)] : []
    var updated = endpoint
    let halted = result.status == .stalled || result.status == .transactionError
    if halted {
      updated.state = .halted
    } else {
      updated.dequeueAddress = nextAddress + 16
    }
    let residual = setup.direction == .in ? requestedBytes - response.count : 0
    let event = halted || nextControl & (1 << 5) != 0 ? transferEvent(
      trbAddress: nextAddress,
      completionCode: completionCode(
        status: result.status, shortResponse: setup.direction == .in && response.count < requestedBytes),
      residualBytes: residual, slotID: slotID, dci: dci
    ) : nil
    guard commitTransferResult(
      slotID: slotID,
      dci: dci,
      endpoint: updated,
      expectedEndpoint: endpoint,
      device: device,
      memory: memory,
      memoryGeneration: memoryGeneration,
      payloadWrites: writes,
      event: event
    )
    else { return }
    if event != nil { updateInterruptLine() }
  }

  private func collectTransferDescriptor(
    endpoint: Slot.Endpoint,
    memory: any DoryVirtioGuestMemory,
    firstTRB: [UInt8],
    dataTRBType: UInt8
  ) -> TransferDescriptor? {
    var address = endpoint.dequeueAddress
    var cycle = endpoint.cycle
    var bytes = firstTRB
    var segments: [TransferSegment] = []
    var totalBytes = 0
    var eventData: UInt64?
    var eventDataControl: UInt32?
    for _ in 0..<4_096 {
      let control = uint32(Array(bytes[12..<16]))
      guard control & 1 == (cycle ? 1 : 0) else { return nil }
      let type = UInt8((control >> 10) & 0x3F)
      if type == 6 {
        let target = uint64(Array(bytes[0..<8])) & ~UInt64(0xF)
        guard target != 0, control & (1 << 4) != 0 else { return nil }
        address = target
        if control & 2 != 0 { cycle.toggle() }
        guard let linked = try? memory.read(at: address, byteCount: 16), linked.count == 16
        else { return nil }
        bytes = linked
        continue
      }
      if type == 7 {
        guard eventData == nil else { return nil }
        eventData = uint64(Array(bytes[0..<8]))
        eventDataControl = control
        address &+= 16
        return .init(
          segments: segments,
          eventData: eventData,
          eventDataControl: eventDataControl,
          nextDequeueAddress: address,
          nextCycle: cycle
        )
      }
      // An Isoch TRB is not a Normal TRB with different metadata. Never pass it to a bulk or
      // interrupt device, and never treat a Normal TRB as an isochronous frame.
      guard type == dataTRBType else { return nil }
      let byteCount = Int(uint32(Array(bytes[8..<12])) & 0x1_FFFF)
      guard totalBytes <= DoryPCUSBDeviceLimits.maximumTransferBytes - byteCount else { return nil }
      segments.append(
        .init(
          trbAddress: address,
          bufferAddress: uint64(Array(bytes[0..<8])),
          byteCount: byteCount,
          control: control
        )
      )
      totalBytes += byteCount
      address &+= 16
      guard control & (1 << 4) != 0 else {
        return .init(
          segments: segments,
          eventData: nil,
          eventDataControl: nil,
          nextDequeueAddress: address,
          nextCycle: cycle
        )
      }
      guard let next = try? memory.read(at: address, byteCount: 16), next.count == 16 else {
        return nil
      }
      bytes = next
    }
    return nil
  }

  private func completionCode(status: DoryPCUSBTransferStatus, shortResponse: Bool) -> UInt8 {
    switch status {
    case .success: shortResponse ? 13 : 1
    case .shortPacket: 13
    case .notReady: 1
    case .stalled: 6
    case .transactionError: 4
    case .disconnected: 22
    }
  }

  private func postTransferEvent(
    trbAddress: UInt64,
    completionCode: UInt8,
    residualBytes: Int,
    slotID: UInt8,
    dci: UInt8,
    expectedEndpoint: Slot.Endpoint,
    device: any DoryPCUSBDevice,
    memoryGeneration: UUID
  ) {
    let admitted = lock.withLock {
      guard guestMemoryGeneration == memoryGeneration,
        let slot = slots[slotID], slot.endpoints[dci] == expectedEndpoint,
        devices[Int(slot.rootPort) - 1] === device
      else { return false }
      try? writeEventLocked(transferEvent(
        trbAddress: trbAddress, completionCode: completionCode, residualBytes: residualBytes,
        slotID: slotID, dci: dci
      ))
      return true
    }
    if admitted { updateInterruptLine() }
  }

  private func transferEvent(
    trbAddress: UInt64,
    completionCode: UInt8,
    residualBytes: Int,
    slotID: UInt8,
    dci: UInt8,
    eventData: Bool = false
  ) -> [UInt8] {
    var event = [UInt8](repeating: 0, count: 16)
    put(trbAddress, at: 0, in: &event)
    put(
      UInt32(min(residualBytes, 0xFF_FFFF)) | UInt32(completionCode) << 24,
      at: 8,
      in: &event
    )
    put(
      UInt32(slotID) << 24 | UInt32(dci) << 16 | UInt32(32) << 10
        | (eventData ? UInt32(1 << 2) : 0),
      at: 12,
      in: &event
    )
    return event
  }

  private func executeCommand(
    type: UInt8,
    parameter: UInt64,
    status: UInt32,
    control: UInt32,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    switch type {
    case 9:
      return lock.withLock {
        guard commandReceiptIsCurrentLocked(receipt) else { return nil }
        let limit = UInt8(min(configuredSlots, UInt32(Self.maximumSlots)))
        guard limit > 0,
          let slot = (1...limit).first(where: { slots[$0] == nil })
        else { return (9, 0) }
        slots[slot] = .init()
        return (1, slot)
      }
    case 10:
      let slot = UInt8(truncatingIfNeeded: control >> 24)
      return lock.withLock {
        guard commandReceiptIsCurrentLocked(receipt) else { return nil }
        guard slots.removeValue(forKey: slot) != nil else { return (11, slot) }
        return (1, slot)
      }
    case 11:
      return addressDevice(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        blockSetAddressRequest: control & (1 << 9) != 0,
        memory: memory, receipt: receipt
      )
    case 12:
      if control & (1 << 9) != 0 {
        return deconfigureEndpoints(
          slotID: UInt8(truncatingIfNeeded: control >> 24),
          memory: memory, receipt: receipt
        )
      }
      return configureEndpoints(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        memory: memory, receipt: receipt
      )
    case 13:
      return evaluateContext(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        memory: memory, receipt: receipt
      )
    case 14:
      return resetEndpoint(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        memory: memory,
        receipt: receipt
      )
    case 15:
      return stopEndpoint(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        memory: memory,
        receipt: receipt
      )
    case 16:
      return setTransferRingDequeuePointer(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        streamID: UInt16(truncatingIfNeeded: status >> 16),
        parameter: parameter,
        memory: memory,
        receipt: receipt
      )
    case 17:
      return resetDevice(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        memory: memory, receipt: receipt
      )
    case 23:
      return (1, 0)
    default:
      return (5, UInt8(truncatingIfNeeded: control >> 24))
    }
  }

  private func addressDevice(
    slotID: UInt8,
    inputContextAddress: UInt64,
    blockSetAddressRequest: Bool,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let contextBase = admission.contextBaseAddress
    guard inputContextAddress != 0, contextBase != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 96), input.count == 96,
      let dcbaaEntry = try? memory.read(
        at: contextBase + UInt64(slotID) * 8,
        byteCount: 8
      ), dcbaaEntry.count == 8
    else { return (17, slotID) }

    let addContextFlags = uint32(Array(input[4..<8]))
    let slotContext0 = uint32(Array(input[32..<36]))
    let slotContext1 = uint32(Array(input[36..<40]))
    let rootPort = UInt8((slotContext1 >> 16) & 0xFF)
    let speed = UInt8((slotContext0 >> 20) & 0xF)
    let outputContextAddress = uint64(dcbaaEntry) & ~UInt64(0x3F)
    guard addContextFlags & 3 == 3, slotContext0 >> 27 >= 1,
      (1...Self.portCount).contains(Int(rootPort)), outputContextAddress != 0
    else { return (17, slotID) }
    let portReceipt = lock.withLock { () -> PortStatusReceipt? in
      guard slotCommandIsCurrentLocked(admission.receipt), deviceContextBaseAddress == contextBase,
        portGenerations[Int(rootPort) - 1] == admission.receipt.portGenerations[Int(rootPort) - 1],
        ports[Int(rootPort) - 1] & Self.portConnectStatus != 0,
        UInt8((ports[Int(rootPort) - 1] >> 10) & 0xF) == speed
      else { return nil }
      return .init(
        port: Int(rootPort), portGeneration: admission.receipt.portGenerations[Int(rootPort) - 1],
        memoryGeneration: receipt.memoryGeneration
      )
    }
    guard let portReceipt else {
      return lock.withLock {
        guard slotCommandIsCurrentLocked(admission.receipt),
          portGenerations[Int(rootPort) - 1] == admission.receipt.portGenerations[Int(rootPort) - 1]
        else { return nil }
        return (22, slotID)
      }
    }

    var output = [UInt8](repeating: 0, count: 64)
    output.replaceSubrange(0..<32, with: input[32..<64])
    output.replaceSubrange(32..<64, with: input[64..<96])
    let deviceAddress = blockSetAddressRequest ? UInt8(0) : slotID
    var outputSlot3 = uint32(Array(output[12..<16]))
    outputSlot3 = (outputSlot3 & 0x07FF_FF00) | UInt32(deviceAddress)
    outputSlot3 |= UInt32(blockSetAddressRequest ? 1 : 2) << 27
    put(outputSlot3, at: 12, in: &output)
    var endpoint0 = uint32(Array(output[32..<36]))
    endpoint0 = (endpoint0 & ~UInt32(0x7)) | 1
    put(endpoint0, at: 32, in: &output)
    let endpoint0Pointer = uint64(Array(output[40..<48]))
    let replacement = Slot(
        addressed: !blockSetAddressRequest,
        rootPort: rootPort,
        deviceAddress: deviceAddress,
        outputContextAddress: outputContextAddress,
        endpoints: [
          1: .init(
            type: .control,
            direction: .out,
            number: 0,
            dequeueAddress: endpoint0Pointer & ~UInt64(0xF),
            cycle: endpoint0Pointer & 1 != 0,
            state: .running
          )
        ]
    )
    guard commitSlotCommand(
      admission.receipt, memory: memory, targetPort: portReceipt, contextBase: contextBase,
      prepareWrites: { _ in [(outputContextAddress, output)] },
      mutate: { $0 = replacement }
    ) else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func configureEndpoints(
    slotID: UInt8,
    inputContextAddress: UInt64,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard slot.addressed else { return (19, slotID) }
    guard inputContextAddress != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 1_056), input.count == 1_056
    else { return (17, slotID) }
    let dropFlags = uint32(Array(input[0..<4]))
    let addFlags = uint32(Array(input[4..<8]))
    var addedEndpoints: [UInt8: Slot.Endpoint] = [:]
    var droppedEndpoints: [UInt8] = []
    var writes: [(address: UInt64, bytes: [UInt8])] = []
    for dci in UInt8(2)...31 {
      let flag = UInt32(1) << UInt32(dci)
      if dropFlags & flag != 0 { droppedEndpoints.append(dci) }
      guard addFlags & flag != 0 else { continue }
      let offset = 32 + Int(dci) * 32
      var context = Array(input[offset..<(offset + 32)])
      let context1 = uint32(Array(context[4..<8]))
      let endpointType = UInt8((context1 >> 3) & 0x7)
      let pointer = uint64(Array(context[8..<16]))
      guard let decoded = decodeEndpoint(type: endpointType, dci: dci),
        pointer & ~UInt64(0xF) != 0
      else { return (17, slotID) }
      var context0 = uint32(Array(context[0..<4]))
      context0 = (context0 & ~UInt32(0x7)) | 1
      put(context0, at: 0, in: &context)
      addedEndpoints[dci] = .init(
        type: decoded.type,
        direction: decoded.direction,
        number: dci / 2,
        dequeueAddress: pointer & ~UInt64(0xF),
        cycle: pointer & 1 != 0,
        state: .running
      )
      writes.append((slot.outputContextAddress + UInt64(dci) * 32, context))
    }
    guard commitSlotCommand(
      admission.receipt, memory: memory, prepareWrites: { _ in writes },
      mutate: { current in
        for dci in droppedEndpoints { current.endpoints.removeValue(forKey: dci) }
        for (dci, endpoint) in addedEndpoints { current.endpoints[dci] = endpoint }
      }
    ) else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func deconfigureEndpoints(
    slotID: UInt8,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard slot.addressed, var endpoint0 = slot.endpoints[1] else { return (19, slotID) }
    endpoint0.state = .stopped
    endpoint0.generation = UUID()
    var slotContext: [UInt8]
    var endpoint0Context: [UInt8]
    do {
      slotContext = try memory.read(at: slot.outputContextAddress, byteCount: 32)
      endpoint0Context = try memory.read(at: slot.outputContextAddress + 32, byteCount: 32)
      guard slotContext.count == 32, endpoint0Context.count == 32 else { return (17, slotID) }
      var entries = uint32(Array(slotContext[0..<4]))
      entries = (entries & 0x07FF_FFFF) | UInt32(1) << 27
      put(entries, at: 0, in: &slotContext)
      var state = uint32(Array(slotContext[12..<16]))
      state = (state & 0x07FF_FFFF) | UInt32(2) << 27
      put(state, at: 12, in: &slotContext)
    } catch {
      return (17, slotID)
    }
    guard commitSlotCommand(
      admission.receipt, memory: memory,
      prepareWrites: { _ in [
        (slot.outputContextAddress, slotContext),
        (slot.outputContextAddress + 32, endpointContextBytes(endpoint0, existing: endpoint0Context)),
        (slot.outputContextAddress + 64, [UInt8](repeating: 0, count: 960)),
      ] }, mutate: { $0.endpoints = [1: endpoint0] }
    ) else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func evaluateContext(
    slotID: UInt8,
    inputContextAddress: UInt64,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard inputContextAddress != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 1_056), input.count == 1_056,
      let output = try? memory.read(at: slot.outputContextAddress, byteCount: 1_024),
      output.count == 1_024
    else { return (17, slotID) }
    let dropFlags = uint32(Array(input[0..<4]))
    let addFlags = uint32(Array(input[4..<8]))
    guard dropFlags == 0, addFlags != 0 else { return (17, slotID) }
    var contexts: [(id: UInt8, bytes: [UInt8])] = []
    for contextID in 0...31 where addFlags & (UInt32(1) << UInt32(contextID)) != 0 {
      if contextID > 0, slot.endpoints[UInt8(contextID)] == nil { return (12, slotID) }
      let inputOffset = 32 + contextID * 32
      let outputOffset = contextID * 32
      var context = Array(input[inputOffset..<(inputOffset + 32)])
      if contextID == 0 {
        let oldState = uint32(Array(output[12..<16])) & 0xF800_0000
        var newState = uint32(Array(context[12..<16])) & 0x07FF_FFFF
        newState |= oldState
        put(newState, at: 12, in: &context)
      } else {
        let oldContext = Array(output[outputOffset..<(outputOffset + 32)])
        var state = uint32(Array(context[0..<4]))
        state = (state & ~UInt32(0x7)) | (uint32(Array(oldContext[0..<4])) & 0x7)
        put(state, at: 0, in: &context)
        context.replaceSubrange(8..<16, with: oldContext[8..<16])
      }
      contexts.append((UInt8(contextID), context))
    }
    guard commitSlotCommand(
      admission.receipt, memory: memory,
      prepareWrites: { current in
        var writes: [(address: UInt64, bytes: [UInt8])] = []
        for context in contexts {
          let bytes: [UInt8]
          if context.id == 0 {
            bytes = context.bytes
          } else {
            guard let endpoint = current.endpoints[context.id] else { return nil }
            bytes = endpointContextBytes(endpoint, existing: context.bytes)
          }
          writes.append((current.outputContextAddress + UInt64(context.id) * 32, bytes))
        }
        return writes
      }, mutate: { _ in }
    ) else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func resetEndpoint(
    slotID: UInt8,
    dci: UInt8,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard endpoint.state == .halted else { return (19, slotID) }
    let expectedEndpoint = endpoint
    endpoint.state = .stopped
    endpoint.generation = UUID()
    guard updateEndpointContext(
      admission.receipt, slot: slot, dci: dci, endpoint: endpoint,
      expectedEndpoint: expectedEndpoint, memory: memory
    )
    else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func stopEndpoint(
    slotID: UInt8,
    dci: UInt8,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard endpoint.state == .running || endpoint.state == .stopped else { return (19, slotID) }
    let expectedEndpoint = endpoint
    endpoint.state = .stopped
    endpoint.generation = UUID()
    guard updateEndpointContext(
      admission.receipt, slot: slot, dci: dci, endpoint: endpoint,
      expectedEndpoint: expectedEndpoint, memory: memory
    )
    else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func setTransferRingDequeuePointer(
    slotID: UInt8,
    dci: UInt8,
    streamID: UInt16,
    parameter: UInt64,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard streamID == 0, parameter & 0xE == 0, parameter & ~UInt64(0xF) != 0 else {
      return (17, slotID)
    }
    guard endpoint.state == .stopped || endpoint.state == .error else { return (19, slotID) }
    let expectedEndpoint = endpoint
    endpoint.dequeueAddress = parameter & ~UInt64(0xF)
    endpoint.cycle = parameter & 1 != 0
    endpoint.generation = UUID()
    guard updateEndpointContext(
      admission.receipt, slot: slot, dci: dci, endpoint: endpoint,
      expectedEndpoint: expectedEndpoint, memory: memory
    )
    else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func resetDevice(
    slotID: UInt8,
    memory: any DoryVirtioGuestMemory,
    receipt: CommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    guard let admission = captureSlotCommand(slotID: slotID, command: receipt) else {
      return (11, slotID)
    }
    let slot = admission.slot
    guard var endpoint0 = slot.endpoints[1] else { return (19, slotID) }
    endpoint0.state = .stopped
    endpoint0.generation = UUID()
    var slotContext: [UInt8]
    var endpoint0Context: [UInt8]
    do {
      slotContext = try memory.read(at: slot.outputContextAddress, byteCount: 32)
      endpoint0Context = try memory.read(at: slot.outputContextAddress + 32, byteCount: 32)
      guard slotContext.count == 32, endpoint0Context.count == 32 else { return (17, slotID) }
      var entries = uint32(Array(slotContext[0..<4]))
      entries = (entries & 0x07FF_FFFF) | UInt32(1) << 27
      put(entries, at: 0, in: &slotContext)
      var state = uint32(Array(slotContext[12..<16]))
      state = (state & 0x07FF_FF00) | UInt32(1) << 27
      put(state, at: 12, in: &slotContext)
    } catch {
      return (17, slotID)
    }
    guard commitSlotCommand(
      admission.receipt, memory: memory,
      prepareWrites: { _ in [
        (slot.outputContextAddress, slotContext),
        (slot.outputContextAddress + 32, endpointContextBytes(endpoint0, existing: endpoint0Context)),
        (slot.outputContextAddress + 64, [UInt8](repeating: 0, count: 960)),
      ] }, mutate: { current in
        current.addressed = false
        current.deviceAddress = 0
        current.endpoints = [1: endpoint0]
      }
    ) else { return rejectedSlotCommandResult(admission.receipt) }
    return (1, slotID)
  }

  private func captureSlotCommand(
    slotID: UInt8, command: CommandReceipt
  ) -> (slot: Slot, receipt: SlotCommandReceipt, contextBaseAddress: UInt64)? {
    lock.withLock {
      guard commandReceiptIsCurrentLocked(command), let slot = slots[slotID] else { return nil }
      return (slot, .init(
        command: command, slotID: slotID, slotGeneration: slot.generation,
        rootPort: slot.rootPort, portGenerations: portGenerations
      ), deviceContextBaseAddress)
    }
  }

  private func slotCommandIsCurrentLocked(_ receipt: SlotCommandReceipt) -> Bool {
    guard commandReceiptIsCurrentLocked(receipt.command),
      let slot = slots[receipt.slotID], slot.generation == receipt.slotGeneration
    else { return false }
    return receipt.rootPort == 0
      || portGenerations[Int(receipt.rootPort) - 1]
        == receipt.portGenerations[Int(receipt.rootPort) - 1]
  }

  private func rejectedSlotCommandResult(
    _ receipt: SlotCommandReceipt
  ) -> (completionCode: UInt8, slotID: UInt8)? {
    lock.withLock {
      guard slotCommandIsCurrentLocked(receipt) else { return nil }
      return (17, receipt.slotID)
    }
  }

  /// Context reads occur before this boundary. Admission, guest DMA and the corresponding
  /// slot mutation commit together; reset/unplug cannot replace ownership between them.
  private func commitSlotCommand(
    _ receipt: SlotCommandReceipt,
    memory: any DoryVirtioGuestMemory,
    targetPort: PortStatusReceipt? = nil,
    contextBase: UInt64? = nil,
    prepareWrites: (Slot) -> [(address: UInt64, bytes: [UInt8])]?,
    mutate: (inout Slot) -> Void
  ) -> Bool {
    lock.withLock {
      guard slotCommandIsCurrentLocked(receipt), var slot = slots[receipt.slotID] else {
        return false
      }
      if let targetPort {
        guard guestMemoryGeneration == targetPort.memoryGeneration,
          portGenerations[targetPort.port - 1] == targetPort.portGeneration
        else { return false }
      }
      if let contextBase, deviceContextBaseAddress != contextBase { return false }
      guard let writes = prepareWrites(slot) else { return false }
      do {
        for write in writes {
          try memory.validate(at: write.address, byteCount: write.bytes.count, deviceWillWrite: true)
        }
        for write in writes { try memory.write(at: write.address, bytes: write.bytes) }
        memory.synchronize()
      } catch { return false }
      mutate(&slot)
      slot.generation = UUID()
      slots[receipt.slotID] = slot
      return true
    }
  }

  /// The platform call runs without the controller lock. Its payload and endpoint writeback
  /// acquire ownership together, so unplug, reset, or a replacement memory mapping cannot
  /// publish a stale device's bytes before the ordinary endpoint comparison rejects it.
  private func commitTransferResult(
    slotID: UInt8,
    dci: UInt8,
    endpoint: Slot.Endpoint,
    expectedEndpoint: Slot.Endpoint,
    device: any DoryPCUSBDevice,
    memory: any DoryVirtioGuestMemory,
    memoryGeneration: UUID,
    payloadWrites: [(address: UInt64, bytes: [UInt8])],
    event: [UInt8]?
  ) -> Bool {
    lock.withLock {
      guard guestMemoryGeneration == memoryGeneration,
        var slot = slots[slotID], slot.endpoints[dci] == expectedEndpoint,
        devices[Int(slot.rootPort) - 1] === device
      else { return false }
      let contextAddress = slot.outputContextAddress + UInt64(dci) * 32
      do {
        let existing = try memory.read(at: contextAddress, byteCount: 32)
        guard existing.count == 32 else { return false }
        try memory.validate(at: contextAddress, byteCount: 32, deviceWillWrite: true)
        for write in payloadWrites {
          try memory.validate(at: write.address, byteCount: write.bytes.count, deviceWillWrite: true)
        }
        for write in payloadWrites { try memory.write(at: write.address, bytes: write.bytes) }
        try memory.write(at: contextAddress, bytes: endpointContextBytes(endpoint, existing: existing))
        memory.synchronize()
      } catch {
        return false
      }
      slot.endpoints[dci] = endpoint
      slots[slotID] = slot
      if let event { try? writeEventLocked(event) }
      return true
    }
  }

  private func updateEndpointContext(
    _ receipt: SlotCommandReceipt,
    slot: Slot,
    dci: UInt8,
    endpoint: Slot.Endpoint,
    expectedEndpoint: Slot.Endpoint,
    memory: any DoryVirtioGuestMemory
  ) -> Bool {
    let address = slot.outputContextAddress + UInt64(dci) * 32
    guard let existing = try? memory.read(at: address, byteCount: 32), existing.count == 32 else {
      return false
    }
    return lock.withLock {
      guard slotCommandIsCurrentLocked(receipt),
        var currentSlot = slots[receipt.slotID], currentSlot.endpoints[dci] == expectedEndpoint
      else { return false }
      do {
        try memory.validate(at: address, byteCount: 32, deviceWillWrite: true)
        try memory.write(at: address, bytes: endpointContextBytes(endpoint, existing: existing))
        memory.synchronize()
      } catch { return false }
      currentSlot.endpoints[dci] = endpoint
      currentSlot.generation = UUID()
      slots[receipt.slotID] = currentSlot
      return true
    }
  }

  private func writeEndpointContext(
    _ endpoint: Slot.Endpoint,
    at address: UInt64,
    memory: any DoryVirtioGuestMemory
  ) -> Bool {
    do {
      let existing = try memory.read(at: address, byteCount: 32)
      guard existing.count == 32 else { return false }
      let bytes = endpointContextBytes(endpoint, existing: existing)
      try memory.validate(at: address, byteCount: 32, deviceWillWrite: true)
      try memory.write(at: address, bytes: bytes)
      memory.synchronize()
      return true
    } catch {
      return false
    }
  }

  private func endpointContextBytes(_ endpoint: Slot.Endpoint, existing: [UInt8]?) -> [UInt8] {
    var bytes = existing ?? [UInt8](repeating: 0, count: 32)
    var state = uint32(Array(bytes[0..<4]))
    state = (state & ~UInt32(0x7)) | endpoint.state.rawValue
    put(state, at: 0, in: &bytes)
    put(endpoint.dequeueAddress | (endpoint.cycle ? 1 : 0), at: 8, in: &bytes)
    return bytes
  }

  private func decodeEndpoint(
    type: UInt8,
    dci: UInt8
  ) -> (type: DoryPCUSBTransferType, direction: DoryPCUSBTransferDirection)? {
    let decoded: (type: DoryPCUSBTransferType, direction: DoryPCUSBTransferDirection)? =
      switch type {
      case 1: (.isochronous, .out)
      case 2: (.bulk, .out)
      case 3: (.interrupt, .out)
      case 5: (.isochronous, .in)
      case 6: (.bulk, .in)
      case 7: (.interrupt, .in)
      default: nil
      }
    guard let decoded, (dci & 1 != 0) == (decoded.direction == .in) else { return nil }
    return decoded
  }

  /// Called with controller ownership, including transfer completion publication. A reset or
  /// memory replacement cannot swap the event ring between its reservation and DMA write.
  private func writeEventLocked(_ event: [UInt8]) throws {
        guard usbCommand & 1 != 0, let guestMemory else {
          throw DoryPCXHCIError.eventRingUnavailable
        }
        try configureEventRingLocked(memory: guestMemory)
        guard eventRingSegmentSize > 0 else { throw DoryPCXHCIError.eventRingUnavailable }
        var bytes = event
        if eventRingCycle { bytes[12] |= 1 } else { bytes[12] &= 0xFE }
        let address = eventRingEnqueueAddress
        try guestMemory.validate(at: address, byteCount: 16, deviceWillWrite: true)
        try guestMemory.write(at: address, bytes: bytes)
        guestMemory.synchronize()
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
