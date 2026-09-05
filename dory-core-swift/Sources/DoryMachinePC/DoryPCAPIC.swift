import DoryPlatformC
import Foundation

public enum DoryPCAPICError: Error, Sendable, Equatable {
  case invalidVector(UInt8)
  case invalidPin(Int)
  case duplicateLocalAPICID(UInt32)
  case sealed
}

public enum DoryPCLocalAPICTimerMode: String, Codable, Sendable, Hashable {
  case oneShot
  case periodic
}

public struct DoryPCLocalAPICTimerState: Codable, Sendable, Hashable {
  public var vector: UInt8
  public var masked: Bool
  public var mode: DoryPCLocalAPICTimerMode
  public var initialCount: UInt32
  public var currentCount: UInt32

  public init(
    vector: UInt8 = 0x20,
    masked: Bool = true,
    mode: DoryPCLocalAPICTimerMode = .oneShot,
    initialCount: UInt32 = 0,
    currentCount: UInt32 = 0
  ) {
    self.vector = vector
    self.masked = masked
    self.mode = mode
    self.initialCount = initialCount
    self.currentCount = currentCount
  }
}

public struct DoryPCLocalAPICSnapshot: Codable, Sendable, Hashable {
  public let apicID: UInt32
  public let softwareEnabled: Bool
  public let spuriousVector: UInt8
  public let taskPriority: UInt8
  public let interruptRequest: Set<UInt8>
  public let inService: Set<UInt8>
  public let levelTriggered: Set<UInt8>
  public let timer: DoryPCLocalAPICTimerState
}

/// Deterministic xAPIC priority and timer core. Register transports are deliberately separate so
/// xAPIC MMIO and x2APIC MSRs share exactly the same interrupt state machine.
public final class DoryPCLocalAPIC: @unchecked Sendable {
  public let apicID: UInt32

  private let lock = NSLock()
  private let hasPendingRequest: UnsafeMutablePointer<UInt8>
  private var softwareEnabled = false
  private var spuriousVector: UInt8 = 0xFF
  private var taskPriority: UInt8 = 0
  private var logicalDestination: UInt8 = 0
  private var destinationFormat: UInt32 = 0xFFFF_FFFF
  private var interruptRequest: Set<UInt8> = []
  private var inService: Set<UInt8> = []
  private var levelTriggered: Set<UInt8> = []
  private var timer = DoryPCLocalAPICTimerState()
  private var timerDivideValue: UInt64 = 2
  private var timerBaseClockRemainder: UInt64 = 0

  public init(apicID: UInt32) {
    self.apicID = apicID
    hasPendingRequest = .allocate(capacity: 1)
    hasPendingRequest.initialize(to: 0)
  }

  deinit {
    hasPendingRequest.deinitialize(count: 1)
    hasPendingRequest.deallocate()
  }

  public func configureSpuriousVector(_ vector: UInt8, softwareEnabled: Bool) throws {
    // Unlike deliverable interrupt vectors, Intel permits the architectural reset/virtual-wire
    // value 0x0f in the SVR. EDK II intentionally enables virtual-wire mode with SVR=0x10f.
    lock.withLock {
      spuriousVector = vector
      self.softwareEnabled = softwareEnabled
    }
  }

  public func setTaskPriority(_ value: UInt8) {
    lock.withLock { taskPriority = value }
  }

  var logicalDestinationRegister: UInt32 {
    get { lock.withLock { UInt32(logicalDestination) << 24 } }
    set { lock.withLock { logicalDestination = UInt8(truncatingIfNeeded: newValue >> 24) } }
  }

  var destinationFormatRegister: UInt32 {
    get { lock.withLock { destinationFormat } }
    set { lock.withLock { destinationFormat = newValue | 0x0FFF_FFFF } }
  }

  /// xAPIC logical addressing uses the LDR mask, not the physical APIC ID.
  /// Intel SDM Vol. 3A 10.6.2.2 defines flat, cluster, and all-ones broadcast matching.
  func matchesLogicalDestination(_ destination: UInt8) -> Bool {
    lock.withLock {
      if destination == 0xFF { return true }
      switch destinationFormat >> 28 {
      case 0xF:
        return destination & logicalDestination != 0
      case 0:
        return destination & 0xF0 == logicalDestination & 0xF0
          && destination & logicalDestination & 0x0F != 0
      default:
        return false
      }
    }
  }

  /// Dory's serialized xAPIC model uses the APR class for lowest-priority routing: the
  /// task, pending-request, and in-service priority classes choose the recipient, with APIC ID
  /// used only as this emulator's deterministic tie-breaker. This is virtual routing policy, not
  /// an attempt to model physical APIC-bus focus/arbitration side effects.
  func arbitrationPriority() -> UInt8 {
    lock.withLock {
      let tpr = taskPriority
      let irr = interruptRequest.max() ?? 0
      let isr = inService.max() ?? 0
      if tpr & 0xF0 >= irr & 0xF0, tpr & 0xF0 > isr & 0xF0 {
        return tpr
      }
      return max(max(tpr & 0xF0, isr & 0xF0), irr & 0xF0)
    }
  }

  public func inject(vector: UInt8, levelTriggered: Bool = false) throws {
    try validate(vector)
    lock.withLock { injectLocked(vector: vector, levelTriggered: levelTriggered) }
  }

  /// Selects and acknowledges the highest deliverable vector. Acknowledgement atomically moves
  /// the vector from IRR to ISR; callers then perform architectural IDT delivery.
  public func acknowledge(
    interruptsEnabled: Bool,
    externalPriority: UInt8 = 0
  ) -> UInt8? {
    guard interruptsEnabled, dory_atomic_u8_load_acquire(hasPendingRequest) != 0 else {
      return nil
    }
    return lock.withLock {
      guard softwareEnabled else { return nil }
      let processorPriority = processorPriorityLocked(externalPriority: externalPriority)
      guard
        let vector =
          interruptRequest
          .filter({ $0 & 0xF0 > processorPriority })
          .max()
      else { return nil }
      interruptRequest.remove(vector)
      dory_atomic_u8_store_release(hasPendingRequest, interruptRequest.isEmpty ? 0 : 1)
      inService.insert(vector)
      return vector
    }
  }

  /// Reports whether a future interrupt at `vector` could be acknowledged without mutating IRR.
  /// Halted-vCPU clock advancement uses this to ignore timer deadlines that cannot wake a CPU.
  public func canAccept(
    vector: UInt8,
    interruptsEnabled: Bool,
    externalPriority: UInt8 = 0
  ) -> Bool {
    lock.withLock {
      softwareEnabled && interruptsEnabled && vector >= 0x10
        && vector & 0xF0 > processorPriorityLocked(externalPriority: externalPriority)
    }
  }

  /// Completes the highest-priority in-service interrupt and returns its vector for IOAPIC remote
  /// IRR processing. Edge-triggered vectors require no controller follow-up.
  public func endOfInterrupt() -> UInt8? {
    lock.withLock {
      guard let vector = inService.max() else { return nil }
      inService.remove(vector)
      if !interruptRequest.contains(vector) { levelTriggered.remove(vector) }
      return vector
    }
  }

  public func configureTimer(
    vector: UInt8,
    masked: Bool,
    mode: DoryPCLocalAPICTimerMode,
    initialCount: UInt32
  ) throws {
    try validate(vector)
    lock.withLock {
      timer = .init(
        vector: vector,
        masked: masked,
        mode: mode,
        initialCount: initialCount,
        currentCount: initialCount
      )
    }
  }

  /// LVT mask/vector writes preserve the countdown; changing timer mode disarms it
  /// (Intel SDM, Vol. 3A, 10.5.4). Only an initial-count write rearms the timer.
  public func configureTimerControl(
    vector: UInt8,
    masked: Bool,
    mode: DoryPCLocalAPICTimerMode
  ) throws {
    try validate(vector)
    lock.withLock {
      if timer.mode != mode {
        timer.currentCount = 0
        timerBaseClockRemainder = 0
      }
      timer.vector = vector
      timer.masked = masked
      timer.mode = mode
    }
  }

  /// Updates the architectural xAPIC timer divisor without reloading the current count.
  public func configureTimerDivideValue(_ divideValue: UInt32) {
    precondition([1, 2, 4, 8, 16, 32, 64, 128].contains(divideValue))
    lock.withLock {
      timerDivideValue = UInt64(divideValue)
      timerBaseClockRemainder = 0
    }
  }

  /// Advances the timer from its undivided bus clock while retaining partial divider periods.
  public func advanceTimer(byBaseClockTicks ticks: UInt64) {
    guard ticks > 0 else { return }
    lock.withLock {
      let wholeTicks = ticks / timerDivideValue
      let fractionalTicks = timerBaseClockRemainder + ticks % timerDivideValue
      timerBaseClockRemainder = fractionalTicks % timerDivideValue
      advanceTimerLocked(by: wholeTicks + fractionalTicks / timerDivideValue)
    }
  }

  /// Undivided bus-clock ticks remaining before the current one-shot or periodic expiry.
  public func baseClockTicksUntilTimerExpiration() -> UInt64? {
    lock.withLock {
      guard timer.currentCount > 0 else { return nil }
      return UInt64(timer.currentCount) * timerDivideValue - timerBaseClockRemainder
    }
  }

  /// Advances the already-divided APIC timer clock. Multiple expirations coalesce in the IRR bit,
  /// matching the APIC's bounded pending representation.
  public func advanceTimer(by ticks: UInt64) {
    guard ticks > 0 else { return }
    lock.withLock { advanceTimerLocked(by: ticks) }
  }

  private func advanceTimerLocked(by ticks: UInt64) {
    guard ticks > 0, timer.currentCount > 0 else { return }
    let current = UInt64(timer.currentCount)
    guard ticks >= current else {
      timer.currentCount -= UInt32(ticks)
      return
    }

    if !timer.masked {
      injectLocked(vector: timer.vector, levelTriggered: false)
    }
    switch timer.mode {
    case .oneShot:
      timer.currentCount = 0
    case .periodic:
      guard timer.initialCount > 0 else {
        timer.currentCount = 0
        return
      }
      let period = UInt64(timer.initialCount)
      let ticksAfterFirstExpiry = ticks - current
      let phase = ticksAfterFirstExpiry % period
      timer.currentCount = phase == 0 ? timer.initialCount : UInt32(period - phase)
    }
  }

  public func snapshot() -> DoryPCLocalAPICSnapshot {
    lock.withLock {
      .init(
        apicID: apicID,
        softwareEnabled: softwareEnabled,
        spuriousVector: spuriousVector,
        taskPriority: taskPriority,
        interruptRequest: interruptRequest,
        inService: inService,
        levelTriggered: levelTriggered,
        timer: timer
      )
    }
  }

  private func injectLocked(vector: UInt8, levelTriggered: Bool) {
    interruptRequest.insert(vector)
    dory_atomic_u8_store_release(hasPendingRequest, 1)
    if levelTriggered { self.levelTriggered.insert(vector) }
  }

  private func processorPriorityLocked(externalPriority: UInt8) -> UInt8 {
    max(
      max(taskPriority & 0xF0, externalPriority & 0xF0),
      inService.max().map { $0 & 0xF0 } ?? 0
    )
  }

  private func validate(_ vector: UInt8) throws {
    guard vector >= 0x10 else { throw DoryPCAPICError.invalidVector(vector) }
  }
}

func doryPCLowestPriorityTarget(in targets: [DoryPCLocalAPIC]) -> DoryPCLocalAPIC? {
  targets.map { (apic: $0, priority: $0.arbitrationPriority()) }
    .min { left, right in
      if left.priority != right.priority { return left.priority < right.priority }
      return left.apic.apicID < right.apic.apicID
    }?.apic
}

public enum DoryPCIOAPICDeliveryMode: UInt8, Codable, Sendable, Hashable {
  case fixed = 0
  case lowestPriority = 1
  case smi = 2
  case reserved3 = 3
  case nmi = 4
  case initDelivery = 5
  case reserved6 = 6
  case extINT = 7

  var isDeliverableThroughIRQLine: Bool {
    switch self {
    case .fixed, .lowestPriority: true
    case .smi, .reserved3, .nmi, .initDelivery, .reserved6, .extINT: false
    }
  }
}

public enum DoryPCIOAPICDestinationMode: String, Codable, Sendable, Hashable {
  case physical
  case logical
}

public struct DoryPCIOAPICRoute: Codable, Sendable, Hashable {
  public var vector: UInt8
  public var destinationAPICID: UInt32
  public var deliveryMode: DoryPCIOAPICDeliveryMode
  public var destinationMode: DoryPCIOAPICDestinationMode
  public var masked: Bool
  public var levelTriggered: Bool
  public var activeLow: Bool

  public init(
    vector: UInt8 = 0x20,
    destinationAPICID: UInt32 = 0,
    deliveryMode: DoryPCIOAPICDeliveryMode = .fixed,
    destinationMode: DoryPCIOAPICDestinationMode = .physical,
    masked: Bool = true,
    levelTriggered: Bool = false,
    activeLow: Bool = false
  ) {
    self.vector = vector
    self.destinationAPICID = destinationAPICID
    self.deliveryMode = deliveryMode
    self.destinationMode = destinationMode
    self.masked = masked
    self.levelTriggered = levelTriggered
    self.activeLow = activeLow
  }

  private enum CodingKeys: String, CodingKey {
    case vector
    case destinationAPICID
    case deliveryMode
    case destinationMode
    case masked
    case levelTriggered
    case activeLow
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    vector = try container.decode(UInt8.self, forKey: .vector)
    destinationAPICID = try container.decode(UInt32.self, forKey: .destinationAPICID)
    deliveryMode =
      try container.decodeIfPresent(DoryPCIOAPICDeliveryMode.self, forKey: .deliveryMode) ?? .fixed
    destinationMode =
      try container.decodeIfPresent(DoryPCIOAPICDestinationMode.self, forKey: .destinationMode)
      ?? .physical
    masked = try container.decode(Bool.self, forKey: .masked)
    levelTriggered = try container.decode(Bool.self, forKey: .levelTriggered)
    activeLow = try container.decode(Bool.self, forKey: .activeLow)
  }
}

public struct DoryPCIOAPICPinSnapshot: Codable, Sendable, Hashable {
  public let pin: Int
  public let route: DoryPCIOAPICRoute
  public let asserted: Bool
  public let remoteIRR: Bool
}

/// DoryPC-v1 IOAPIC routing core with edge detection and level-triggered remote-IRR behavior.
public final class DoryPCIOAPIC: @unchecked Sendable {
  private struct PinState {
    var route = DoryPCIOAPICRoute(vector: 0)
    var asserted = false
    var remoteIRR = false
    var deliveredAPICIDs: Set<UInt32> = []
  }

  public let pinCount: Int
  private let lock = NSLock()
  private var pins: [PinState]
  private var localAPICs: [UInt32: DoryPCLocalAPIC] = [:]
  private var isSealed = false

  public init(pinCount: Int = 24) {
    precondition(pinCount > 0)
    self.pinCount = pinCount
    pins = .init(repeating: .init(), count: pinCount)
  }

  public func attach(_ localAPIC: DoryPCLocalAPIC) throws {
    try lock.withLock {
      guard !isSealed else { throw DoryPCAPICError.sealed }
      guard localAPICs[localAPIC.apicID] == nil else {
        throw DoryPCAPICError.duplicateLocalAPICID(localAPIC.apicID)
      }
      localAPICs[localAPIC.apicID] = localAPIC
    }
  }

  public func seal() { lock.withLock { isSealed = true } }

  public func configure(pin: Int, route: DoryPCIOAPICRoute) throws {
    guard route.masked || route.vector >= 0x10 else {
      throw DoryPCAPICError.invalidVector(route.vector)
    }
    try storeRedirectionEntry(pin: pin, route: route)
  }

  func configureMMIORedirectionEntry(pin: Int, route: DoryPCIOAPICRoute) throws {
    // Guest MMIO writes store the architectural redirection entry even when the vector field is in
    // the reserved 0...15 range; such an entry is not deliverable until software programs a valid
    // vector. Dory does not yet expose local-APIC ESR illegal-vector reporting.
    try storeRedirectionEntry(pin: pin, route: route)
  }

  private func storeRedirectionEntry(pin: Int, route: DoryPCIOAPICRoute) throws {
    guard pins.indices.contains(pin) else { throw DoryPCAPICError.invalidPin(pin) }
    let deliveries: [(DoryPCLocalAPIC, UInt8, Bool)] = lock.withLock {
      pins[pin].route = route
      guard route.levelTriggered, route.vector >= 0x10, !route.masked, pins[pin].asserted,
        !pins[pin].remoteIRR
      else { return [] }
      return deliverLocked(pin: pin, route: route, levelTriggered: true)
    }
    for delivery in deliveries {
      try delivery.0.inject(vector: delivery.1, levelTriggered: delivery.2)
    }
  }

  /// Sets the device's logical assertion state. Polarity is a guest-visible electrical property;
  /// device cores use this logical API and therefore never duplicate active-low conversion.
  public func setAsserted(_ asserted: Bool, pin: Int) throws {
    guard pins.indices.contains(pin) else { throw DoryPCAPICError.invalidPin(pin) }
    let deliveries: [(DoryPCLocalAPIC, UInt8, Bool)] = lock.withLock {
      let previous = pins[pin].asserted
      pins[pin].asserted = asserted
      let route = pins[pin].route
      guard route.vector >= 0x10, !route.masked else { return [] }
      if route.levelTriggered {
        guard asserted, !pins[pin].remoteIRR else { return [] }
        return deliverLocked(pin: pin, route: route, levelTriggered: true)
      }
      guard asserted, !previous else { return [] }
      return deliverLocked(pin: pin, route: route, levelTriggered: false)
    }
    for delivery in deliveries {
      try delivery.0.inject(vector: delivery.1, levelTriggered: delivery.2)
    }
  }

  /// Clears remote IRR for every matching level route and immediately re-pends any line that is
  /// still asserted, preventing lost level interrupts.
  public func endOfInterrupt(vector: UInt8, destinationAPICID: UInt32) throws {
    let deliveries: [(DoryPCLocalAPIC, UInt8)] = lock.withLock {
      var result: [(DoryPCLocalAPIC, UInt8)] = []
      for index in pins.indices {
        let route = pins[index].route
        guard route.levelTriggered, pins[index].remoteIRR, route.vector == vector,
          pins[index].deliveredAPICIDs.contains(destinationAPICID)
        else { continue }
        pins[index].remoteIRR = false
        pins[index].deliveredAPICIDs.removeAll(keepingCapacity: true)
        if pins[index].asserted, !route.masked {
          result.append(
            contentsOf: deliverLocked(pin: index, route: route, levelTriggered: true).map {
              ($0.0, $0.1)
            })
        }
      }
      return result
    }
    for delivery in deliveries {
      try delivery.0.inject(vector: delivery.1, levelTriggered: true)
    }
  }

  private func deliverLocked(
    pin: Int,
    route: DoryPCIOAPICRoute,
    levelTriggered: Bool
  ) -> [(DoryPCLocalAPIC, UInt8, Bool)] {
    guard route.deliveryMode.isDeliverableThroughIRQLine else { return [] }
    let targets = resolvedTargetsLocked(route: route)
    let selected: [DoryPCLocalAPIC]
    switch route.deliveryMode {
    case .fixed:
      selected = targets
    case .lowestPriority:
      selected = doryPCLowestPriorityTarget(in: targets).map { [$0] } ?? []
    case .smi, .reserved3, .nmi, .initDelivery, .reserved6, .extINT:
      selected = []
    }
    guard !selected.isEmpty else { return [] }
    if levelTriggered {
      pins[pin].remoteIRR = true
      pins[pin].deliveredAPICIDs = Set(selected.map(\.apicID))
    }
    return selected.map { ($0, route.vector, levelTriggered) }
  }

  private func resolvedTargetsLocked(route: DoryPCIOAPICRoute) -> [DoryPCLocalAPIC] {
    let destination = UInt8(truncatingIfNeeded: route.destinationAPICID)
    switch route.destinationMode {
    case .physical:
      if destination == 0xFF { return localAPICs.values.sorted { $0.apicID < $1.apicID } }
      return localAPICs[UInt32(destination)].map { [$0] } ?? []
    case .logical:
      return localAPICs.values.filter { $0.matchesLogicalDestination(destination) }
        .sorted { $0.apicID < $1.apicID }
    }
  }

  func canDeliver(
    pin: Int,
    canAccept: (DoryPCLocalAPIC, UInt8) -> Bool
  ) throws -> Bool {
    try lock.withLock {
      guard pins.indices.contains(pin) else { throw DoryPCAPICError.invalidPin(pin) }
      let route = pins[pin].route
      guard route.vector >= 0x10, !route.masked, route.deliveryMode.isDeliverableThroughIRQLine,
        !(route.levelTriggered && pins[pin].remoteIRR)
      else { return false }
      let targets = resolvedTargetsLocked(route: route)
      switch route.deliveryMode {
      case .fixed:
        return targets.contains { canAccept($0, route.vector) }
      case .lowestPriority:
        guard let target = doryPCLowestPriorityTarget(in: targets) else { return false }
        return canAccept(target, route.vector)
      case .smi, .reserved3, .nmi, .initDelivery, .reserved6, .extINT:
        return false
      }
    }
  }

  public func route(for pin: Int) throws -> DoryPCIOAPICRoute {
    guard pins.indices.contains(pin) else { throw DoryPCAPICError.invalidPin(pin) }
    return lock.withLock { pins[pin].route }
  }

  public func snapshot() -> [DoryPCIOAPICPinSnapshot] {
    lock.withLock {
      pins.indices.map { snapshotLocked(for: $0) }
    }
  }

  func snapshot(for pin: Int) throws -> DoryPCIOAPICPinSnapshot {
    guard pins.indices.contains(pin) else { throw DoryPCAPICError.invalidPin(pin) }
    return lock.withLock { snapshotLocked(for: pin) }
  }

  private func snapshotLocked(for pin: Int) -> DoryPCIOAPICPinSnapshot {
    .init(
      pin: pin,
      route: pins[pin].route,
      asserted: pins[pin].asserted,
      remoteIRR: pins[pin].remoteIRR
    )
  }

}
