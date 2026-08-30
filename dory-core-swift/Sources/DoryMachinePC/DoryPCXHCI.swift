import DoryVirtio
import Foundation

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
    struct Endpoint {
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
    }

    var addressed = false
    var rootPort: UInt8 = 0
    var deviceAddress: UInt8 = 0
    var outputContextAddress: UInt64 = 0
    var endpoints: [UInt8: Endpoint] = [:]
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
  private var guestMemory: (any DoryVirtioGuestMemory)?
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
  private var devices: [Int: any DoryPCUSBDevice] = [:]
  private var slots: [UInt8: Slot] = [:]

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

  public func connect(port: Int, device: any DoryPCUSBDevice) throws {
    try lock.withLock {
      let index = try portIndex(port)
      guard devices[index] == nil else { throw DoryPCXHCIError.portAlreadyConnected(port) }
      devices[index] = device
    }
    do {
      try connect(port: port, speed: device.speed)
    } catch {
      _ = lock.withLock { devices.removeValue(forKey: port - 1) }
      throw error
    }
  }

  public func disconnect(port: Int) throws {
    let result = try lock.withLock {
      let index = try portIndex(port)
      let device = devices.removeValue(forKey: index)
      let old = ports[index]
      var value = old & Self.portChangeMask
      value |= Self.portPower | Self.portConnectChange
      if old & Self.portEnabled != 0 { value |= Self.portEnableChange }
      ports[index] = value
      return (old & Self.portConnectStatus != 0, device)
    }
    result.1?.cancelAll()
    if result.0 { postPortStatusChange(port: port) }
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
      lock.withLock {
        let value = uint64(bytes)
        commandRingControl = value & ~UInt64(0x30)
        commandRingDequeueAddress = value & ~UInt64(0x3F)
        commandRingCycle = value & 1 != 0
      }
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
    let result = try lock.withLock {
      let index = try portIndex(port)
      var current = ports[index]
      current &= ~(value & Self.portChangeMask)
      guard value & Self.portReset != 0 else {
        ports[index] = current
        return (false, nil as (any DoryPCUSBDevice)?)
      }
      if current & Self.portConnectStatus != 0 {
        current |= Self.portEnabled | Self.portResetChange
      }
      current &= ~Self.portReset
      ports[index] = current
      return (true, devices[index])
    }
    result.1?.reset()
    if result.0 { postPortStatusChange(port: port) }
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
      return Array(devices.values)
    }
    for device in connectedDevices { device.cancelAll() }
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

  private func processCommandRing() {
    for _ in 0..<4_096 {
      let state = lock.withLock {
        (guestMemory, commandRingDequeueAddress, commandRingCycle, usbCommand & 1 != 0)
      }
      guard state.3, let memory = state.0, state.1 != 0,
        let bytes = try? memory.read(at: state.1, byteCount: 16), bytes.count == 16
      else { return }
      let control = uint32(Array(bytes[12..<16]))
      guard control & 1 == (state.2 ? 1 : 0) else { return }
      let type = UInt8((control >> 10) & 0x3F)
      if type == 6 {
        let target = uint64(Array(bytes[0..<8])) & ~UInt64(0xF)
        guard target != 0 else { return }
        lock.withLock {
          commandRingDequeueAddress = target
          if control & 2 != 0 { commandRingCycle.toggle() }
        }
        continue
      }

      let result = executeCommand(
        type: type,
        parameter: uint64(Array(bytes[0..<8])),
        status: uint32(Array(bytes[8..<12])),
        control: control,
        memory: memory
      )
      var event = [UInt8](repeating: 0, count: 16)
      put(state.1, at: 0, in: &event)
      put(UInt32(result.completionCode) << 24, at: 8, in: &event)
      put(
        UInt32(result.slotID) << 24 | UInt32(33) << 10,
        at: 12,
        in: &event
      )
      lock.withLock { commandRingDequeueAddress &+= 16 }
      guard (try? postEvent(event)) != nil else { return }
    }
  }

  private func processTransferRing(slotID: UInt8, dci: UInt8) {
    for _ in 0..<4_096 {
      let state = lock.withLock {
        () -> (
          memory: (any DoryVirtioGuestMemory)?,
          endpoint: Slot.Endpoint?,
          device: (any DoryPCUSBDevice)?
        ) in
        guard let slot = slots[slotID], let endpoint = slot.endpoints[dci] else {
          return (guestMemory, nil, nil)
        }
        return (guestMemory, endpoint, devices[Int(slot.rootPort) - 1])
      }
      guard let memory = state.memory, var endpoint = state.endpoint, let device = state.device,
        endpoint.state != .halted, endpoint.state != .error,
        endpoint.dequeueAddress != 0,
        let bytes = try? memory.read(at: endpoint.dequeueAddress, byteCount: 16), bytes.count == 16
      else { return }
      if endpoint.state == .stopped {
        endpoint.state = .running
        guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: endpoint, memory: memory)
        else { return }
      }
      let control = uint32(Array(bytes[12..<16]))
      guard control & 1 == (endpoint.cycle ? 1 : 0) else { return }
      let trbType = UInt8((control >> 10) & 0x3F)
      if trbType == 6 {
        let target = uint64(Array(bytes[0..<8])) & ~UInt64(0xF)
        guard target != 0 else { return }
        endpoint.dequeueAddress = target
        if control & 2 != 0 { endpoint.cycle.toggle() }
        lock.withLock { slots[slotID]?.endpoints[dci] = endpoint }
        continue
      }
      if endpoint.type == .control {
        processControlTransfer(
          slotID: slotID,
          dci: dci,
          endpoint: endpoint,
          device: device,
          memory: memory,
          firstTRB: bytes
        )
        return
      }
      guard trbType == 1 || trbType == 5 else {
        postTransferEvent(
          trbAddress: endpoint.dequeueAddress,
          completionCode: 5,
          residualBytes: 0,
          slotID: slotID,
          dci: dci
        )
        return
      }
      let bufferAddress = uint64(Array(bytes[0..<8]))
      let requestedBytes = Int(uint32(Array(bytes[8..<12])) & 0x1_FFFF)
      let oldDequeue = endpoint.dequeueAddress
      let payload: [UInt8]
      if endpoint.direction == .out {
        guard let read = try? memory.read(at: bufferAddress, byteCount: requestedBytes),
          read.count == requestedBytes
        else { return }
        payload = read
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
      let result = device.perform(transfer)
      if result.status == .notReady { return }
      let response = Array(result.payload.prefix(requestedBytes))
      if endpoint.direction == .in, !response.isEmpty {
        do {
          try memory.validate(at: bufferAddress, byteCount: response.count, deviceWillWrite: true)
          try memory.write(at: bufferAddress, bytes: response)
          memory.synchronize()
        } catch {
          return
        }
      }
      let halted = result.status == .stalled || result.status == .transactionError
      if halted {
        endpoint.state = .halted
      } else {
        endpoint.dequeueAddress &+= 16
      }
      guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: endpoint, memory: memory)
      else { return }
      guard halted || control & (1 << 5) != 0 else { continue }
      let residual = endpoint.direction == .in ? requestedBytes - response.count : 0
      let completion = completionCode(
        status: result.status,
        shortResponse: endpoint.direction == .in && response.count < requestedBytes
      )
      postTransferEvent(
        trbAddress: oldDequeue,
        completionCode: completion,
        residualBytes: residual,
        slotID: slotID,
        dci: dci
      )
    }
  }

  private func processControlTransfer(
    slotID: UInt8,
    dci: UInt8,
    endpoint: Slot.Endpoint,
    device: any DoryPCUSBDevice,
    memory: any DoryVirtioGuestMemory,
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
        dci: dci
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
          dci: dci
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
    if setup.direction == .in, !response.isEmpty {
      do {
        try memory.validate(at: dataAddress, byteCount: response.count, deviceWillWrite: true)
        try memory.write(at: dataAddress, bytes: response)
        memory.synchronize()
      } catch {
        return
      }
    }
    var updated = endpoint
    let halted = result.status == .stalled || result.status == .transactionError
    if halted {
      updated.state = .halted
    } else {
      updated.dequeueAddress = nextAddress + 16
    }
    guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: updated, memory: memory)
    else { return }
    guard halted || nextControl & (1 << 5) != 0 else { return }
    let residual = setup.direction == .in ? requestedBytes - response.count : 0
    postTransferEvent(
      trbAddress: nextAddress,
      completionCode: completionCode(
        status: result.status,
        shortResponse: setup.direction == .in && response.count < requestedBytes
      ),
      residualBytes: residual,
      slotID: slotID,
      dci: dci
    )
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
    dci: UInt8
  ) {
    var event = [UInt8](repeating: 0, count: 16)
    put(trbAddress, at: 0, in: &event)
    put(
      UInt32(min(residualBytes, 0xFF_FFFF)) | UInt32(completionCode) << 24,
      at: 8,
      in: &event
    )
    put(
      UInt32(slotID) << 24 | UInt32(dci) << 16 | UInt32(32) << 10,
      at: 12,
      in: &event
    )
    _ = try? postEvent(event)
  }

  private func executeCommand(
    type: UInt8,
    parameter: UInt64,
    status: UInt32,
    control: UInt32,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    switch type {
    case 9:
      return lock.withLock {
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
        guard slots.removeValue(forKey: slot) != nil else { return (11, slot) }
        return (1, slot)
      }
    case 11:
      return addressDevice(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        blockSetAddressRequest: control & (1 << 9) != 0,
        memory: memory
      )
    case 12:
      if control & (1 << 9) != 0 {
        return deconfigureEndpoints(
          slotID: UInt8(truncatingIfNeeded: control >> 24),
          memory: memory
        )
      }
      return configureEndpoints(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        memory: memory
      )
    case 13:
      return evaluateContext(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        inputContextAddress: parameter & ~UInt64(0xF),
        memory: memory
      )
    case 14:
      return resetEndpoint(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        memory: memory
      )
    case 15:
      return stopEndpoint(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        memory: memory
      )
    case 16:
      return setTransferRingDequeuePointer(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        dci: UInt8(truncatingIfNeeded: control >> 16),
        streamID: UInt16(truncatingIfNeeded: status >> 16),
        parameter: parameter,
        memory: memory
      )
    case 17:
      return resetDevice(
        slotID: UInt8(truncatingIfNeeded: control >> 24),
        memory: memory
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
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    let controller = lock.withLock { (slots[slotID], deviceContextBaseAddress) }
    guard controller.0 != nil else { return (11, slotID) }
    guard inputContextAddress != 0, controller.1 != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 96), input.count == 96,
      let dcbaaEntry = try? memory.read(
        at: controller.1 + UInt64(slotID) * 8,
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
    let port = lock.withLock { ports[Int(rootPort) - 1] }
    guard port & Self.portConnectStatus != 0, UInt8((port >> 10) & 0xF) == speed else {
      return (22, slotID)
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
    do {
      try memory.validate(at: outputContextAddress, byteCount: output.count, deviceWillWrite: true)
      try memory.write(at: outputContextAddress, bytes: output)
      memory.synchronize()
    } catch {
      return (17, slotID)
    }
    lock.withLock {
      let endpoint0Pointer = uint64(Array(output[40..<48]))
      slots[slotID] = .init(
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
    }
    return (1, slotID)
  }

  private func configureEndpoints(
    slotID: UInt8,
    inputContextAddress: UInt64,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard let slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard slot.addressed else { return (19, slotID) }
    guard inputContextAddress != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 1_056), input.count == 1_056
    else { return (17, slotID) }
    let dropFlags = uint32(Array(input[0..<4]))
    let addFlags = uint32(Array(input[4..<8]))
    var endpoints = slot.endpoints
    var writes: [(address: UInt64, bytes: [UInt8])] = []
    for dci in UInt8(2)...31 {
      let flag = UInt32(1) << UInt32(dci)
      if dropFlags & flag != 0 { endpoints.removeValue(forKey: dci) }
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
      endpoints[dci] = .init(
        type: decoded.type,
        direction: decoded.direction,
        number: dci / 2,
        dequeueAddress: pointer & ~UInt64(0xF),
        cycle: pointer & 1 != 0,
        state: .running
      )
      writes.append((slot.outputContextAddress + UInt64(dci) * 32, context))
    }
    do {
      for write in writes {
        try memory.validate(at: write.address, byteCount: 32, deviceWillWrite: true)
      }
      for write in writes { try memory.write(at: write.address, bytes: write.bytes) }
      memory.synchronize()
    } catch {
      return (17, slotID)
    }
    lock.withLock { slots[slotID]?.endpoints = endpoints }
    return (1, slotID)
  }

  private func deconfigureEndpoints(
    slotID: UInt8,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard var slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard slot.addressed, var endpoint0 = slot.endpoints[1] else { return (19, slotID) }
    endpoint0.state = .stopped
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
      try memory.validate(at: slot.outputContextAddress, byteCount: 1_024, deviceWillWrite: true)
      try memory.write(at: slot.outputContextAddress, bytes: slotContext)
      try memory.write(
        at: slot.outputContextAddress + 32,
        bytes: endpointContextBytes(endpoint0, existing: endpoint0Context)
      )
      try memory.write(
        at: slot.outputContextAddress + 64,
        bytes: [UInt8](repeating: 0, count: 960)
      )
      memory.synchronize()
    } catch {
      return (17, slotID)
    }
    slot.endpoints = [1: endpoint0]
    lock.withLock { slots[slotID] = slot }
    return (1, slotID)
  }

  private func evaluateContext(
    slotID: UInt8,
    inputContextAddress: UInt64,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard let slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard inputContextAddress != 0,
      let input = try? memory.read(at: inputContextAddress, byteCount: 1_056), input.count == 1_056,
      let output = try? memory.read(at: slot.outputContextAddress, byteCount: 1_024),
      output.count == 1_024
    else { return (17, slotID) }
    let dropFlags = uint32(Array(input[0..<4]))
    let addFlags = uint32(Array(input[4..<8]))
    guard dropFlags == 0, addFlags != 0 else { return (17, slotID) }
    var writes: [(UInt64, [UInt8])] = []
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
      writes.append((slot.outputContextAddress + UInt64(outputOffset), context))
    }
    do {
      for write in writes {
        try memory.validate(at: write.0, byteCount: 32, deviceWillWrite: true)
      }
      for write in writes { try memory.write(at: write.0, bytes: write.1) }
      memory.synchronize()
    } catch {
      return (17, slotID)
    }
    return (1, slotID)
  }

  private func resetEndpoint(
    slotID: UInt8,
    dci: UInt8,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard let slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard endpoint.state == .halted else { return (19, slotID) }
    endpoint.state = .stopped
    guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: endpoint, memory: memory)
    else { return (17, slotID) }
    return (1, slotID)
  }

  private func stopEndpoint(
    slotID: UInt8,
    dci: UInt8,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard let slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard endpoint.state == .running || endpoint.state == .stopped else { return (19, slotID) }
    endpoint.state = .stopped
    guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: endpoint, memory: memory)
    else { return (17, slotID) }
    return (1, slotID)
  }

  private func setTransferRingDequeuePointer(
    slotID: UInt8,
    dci: UInt8,
    streamID: UInt16,
    parameter: UInt64,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard let slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard var endpoint = slot.endpoints[dci] else { return (12, slotID) }
    guard streamID == 0, parameter & 0xE == 0, parameter & ~UInt64(0xF) != 0 else {
      return (17, slotID)
    }
    guard endpoint.state == .stopped || endpoint.state == .error else { return (19, slotID) }
    endpoint.dequeueAddress = parameter & ~UInt64(0xF)
    endpoint.cycle = parameter & 1 != 0
    guard updateEndpointContext(slotID: slotID, dci: dci, endpoint: endpoint, memory: memory)
    else { return (17, slotID) }
    return (1, slotID)
  }

  private func resetDevice(
    slotID: UInt8,
    memory: any DoryVirtioGuestMemory
  ) -> (completionCode: UInt8, slotID: UInt8) {
    guard var slot = lock.withLock({ slots[slotID] }) else { return (11, slotID) }
    guard var endpoint0 = slot.endpoints[1] else { return (19, slotID) }
    endpoint0.state = .stopped
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
      try memory.validate(at: slot.outputContextAddress, byteCount: 1_024, deviceWillWrite: true)
      try memory.write(at: slot.outputContextAddress, bytes: slotContext)
      try memory.write(
        at: slot.outputContextAddress + 32,
        bytes: endpointContextBytes(endpoint0, existing: endpoint0Context)
      )
      try memory.write(
        at: slot.outputContextAddress + 64,
        bytes: [UInt8](repeating: 0, count: 960)
      )
      memory.synchronize()
    } catch {
      return (17, slotID)
    }
    slot.addressed = false
    slot.deviceAddress = 0
    slot.endpoints = [1: endpoint0]
    lock.withLock { slots[slotID] = slot }
    return (1, slotID)
  }

  private func updateEndpointContext(
    slotID: UInt8,
    dci: UInt8,
    endpoint: Slot.Endpoint,
    memory: any DoryVirtioGuestMemory
  ) -> Bool {
    guard let slot = lock.withLock({ slots[slotID] }) else { return false }
    let address = slot.outputContextAddress + UInt64(dci) * 32
    do {
      let existing = try memory.read(at: address, byteCount: 32)
      guard existing.count == 32 else { return false }
      let bytes = endpointContextBytes(endpoint, existing: existing)
      try memory.validate(at: address, byteCount: 32, deviceWillWrite: true)
      try memory.write(at: address, bytes: bytes)
      memory.synchronize()
    } catch {
      return false
    }
    lock.withLock { slots[slotID]?.endpoints[dci] = endpoint }
    return true
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
