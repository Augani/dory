import DoryDBTX86
import Foundation

public enum DoryPCMachineError: Error, Sendable, Equatable {
  case invalidMemorySize(Int)
  case invalidProcessorCount(Int)
  case alreadyLoaded
  case notLoaded
}

public enum DoryPCMachineStop: Sendable, Hashable {
  case halted(instructionCount: UInt64)
  case exception(DoryX86Exception, instructionCount: UInt64)
  case tripleFault(instructionCount: UInt64)
  case poweredOff(instructionCount: UInt64)
  case reset(instructionCount: UInt64)
  case instructionBudget(UInt64)
}

public enum DoryPCExceptionPolicy: Sendable, Hashable {
  /// Debugger/conformance mode: expose the first precise CPU exception to the caller.
  case stop
  /// Product mode: enter the guest IDT, including architectural double/triple-fault escalation.
  case deliver
}

/// Deterministic direct-kernel DoryPC machine shared by interpreter and translated execution tiers.
public final class DoryPCDirectKernelMachine: @unchecked Sendable {
  public let memory: DoryX86ByteArrayMemory
  public let physicalMemory: DoryPCPhysicalMemoryBus
  public let physicalMemories: [DoryPCPhysicalMemoryBus]
  public let ioBus: DoryPCPortIOBus
  public let serial: DoryPCUART16550
  public let localAPIC: DoryPCLocalAPIC
  public let localAPICs: [DoryPCLocalAPIC]
  public let multiprocessorController: DoryPCMultiprocessorController
  public let ioAPIC: DoryPCIOAPIC
  public let legacyPIC: DoryPCPIC8259Pair
  public let legacyPIT: DoryPCPIT8254
  public let rtc: DoryPCRTC146818
  public let hpet: DoryPCHPET
  public let pciExpress: DoryPCPCIExpressECAM
  public let pciBARWindow: DoryPCPCIBARWindow
  public let powerController: DoryPCPowerController
  public let pagingUnit: DoryX86PagingUnit
  public let pagingUnits: [DoryX86PagingUnit]
  public let interpreter: DoryX86Interpreter
  public let interpreters: [DoryX86Interpreter]
  public let bootLayout: DoryPCPVHBootLayout
  public let acpiLayout: DoryPCACPILayout
  public let smbios: DoryPCSMBIOSTables
  public let memoryByteCount: Int
  public let processorCount: Int

  private let lock = NSLock()
  private var loadedStates: [DoryX86ArchitecturalState?]
  private var haltedProcessors: [Bool]
  private var pendingNMIs: Set<Int> = []
  private var roundRobinCursor = 0
  private var consumedPayload = false

  public init(
    memoryBytes: Int,
    processorCount: Int = 1,
    bootLayout: DoryPCPVHBootLayout = .init(),
    acpiLayout: DoryPCACPILayout = .init(),
    smbiosLayout: DoryPCSMBIOSLayout = .init(),
    smbiosIdentity: DoryPCSMBIOSIdentity = .init(),
    initialRTCDate: Date = Date(),
    pciFunctions: [any DoryPCPCIFunction] = [],
    interpreter: DoryX86Interpreter = .init()
  ) throws {
    guard memoryBytes >= 1024 * 1024 else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
    guard (1...255).contains(processorCount) else {
      throw DoryPCMachineError.invalidProcessorCount(processorCount)
    }
    self.processorCount = processorCount
    let sharedMemory = DoryX86ByteArrayMemory(byteCount: memoryBytes)
    memory = sharedMemory
    physicalMemories = (0..<processorCount).map {
      _ in DoryPCPhysicalMemoryBus(ram: sharedMemory)
    }
    physicalMemory = physicalMemories[0]
    memoryByteCount = memoryBytes
    ioBus = DoryPCPortIOBus()
    localAPICs = (0..<processorCount).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    localAPIC = localAPICs[0]
    multiprocessorController = try .init(localAPICs: localAPICs)
    ioAPIC = DoryPCIOAPIC()
    for apic in localAPICs { try ioAPIC.attach(apic) }
    ioAPIC.seal()
    legacyPIC = DoryPCPIC8259Pair()
    legacyPIT = DoryPCPIT8254 { [legacyPIC, ioAPIC] in
      try? legacyPIC.raise(irq: 0)
      try? ioAPIC.setAsserted(true, pin: 2)
      try? ioAPIC.setAsserted(false, pin: 2)
    }
    serial = DoryPCUART16550()
    serial.connectInterruptSink { [legacyPIC, ioAPIC] asserted in
      if asserted { try? legacyPIC.raise(irq: 4) }
      try? ioAPIC.setAsserted(asserted, pin: 4)
    }
    rtc = DoryPCRTC146818(initialDate: initialRTCDate)
    rtc.connectInterruptSink { [legacyPIC, ioAPIC] asserted in
      if asserted { try? legacyPIC.raise(irq: 8) }
      try? ioAPIC.setAsserted(asserted, pin: 8)
    }
    hpet = DoryPCHPET { [legacyPIC, ioAPIC] _, route, asserted in
      if asserted, route < 16 { try? legacyPIC.raise(irq: UInt8(route)) }
      try? ioAPIC.setAsserted(asserted, pin: route)
    }
    pciExpress = DoryPCPCIExpressECAM()
    pciBARWindow = DoryPCPCIBARWindow()
    powerController = DoryPCPowerController()
    for function in pciFunctions {
      try pciExpress.attach(function)
      if let barDevice = function as? any DoryPCPCIBARMemoryDevice {
        try pciBARWindow.attach(barDevice)
      }
      if let msiFunction = function as? any DoryPCPCIMSIControllable {
        msiFunction.connectMSISink { [localAPICs] address, data in
          guard let message = DoryPCPCIMSIMessage.decode(address: address, data: data),
            let target = localAPICs.first(where: { $0.apicID == message.destinationAPICID })
          else { return false }
          do {
            try target.inject(vector: message.vector)
            return true
          } catch {
            return false
          }
        }
      }
      if let memoryConsumer = function as? any DoryPCVirtioGuestMemoryConsumer {
        memoryConsumer.connectGuestMemory(physicalMemory)
      }
    }
    pciExpress.seal()
    pciBARWindow.seal()
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: false))
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: true))
    try ioBus.attach(legacyPIT)
    try ioBus.attach(rtc)
    try ioBus.attach(serial)
    try ioBus.attach(DoryPCACPIPMControlPort(controller: powerController))
    try ioBus.attach(DoryPCResetControlPort(controller: powerController))
    ioBus.seal()
    for (index, bus) in physicalMemories.enumerated() {
      let apic = localAPICs[index]
      try bus.attach(
        DoryPCLocalAPICMMIO(
          apic: apic,
          onEndOfInterrupt: { [ioAPIC] vector in
            try ioAPIC.endOfInterrupt(vector: vector, destinationAPICID: apic.apicID)
          },
          onInterruptCommand: { [multiprocessorController] high, low in
            try multiprocessorController.handleInterruptCommand(
              sourceAPICID: apic.apicID,
              high: high,
              low: low
            )
          }
        ))
      try bus.attach(DoryPCIOAPICMMIO(ioAPIC: ioAPIC))
      try bus.attach(hpet)
      try bus.attach(pciExpress)
      try bus.attach(pciBARWindow)
      bus.seal()
    }
    pagingUnits = (0..<processorCount).map { _ in DoryX86PagingUnit() }
    pagingUnit = pagingUnits[0]
    interpreters = (0..<processorCount).map {
      DoryX86Interpreter(
        profile: interpreter.profile,
        decoder: interpreter.decoder,
        processorID: UInt32($0),
        logicalProcessorCount: UInt16(processorCount)
      )
    }
    self.interpreter = interpreters[0]
    self.bootLayout = bootLayout
    self.acpiLayout = acpiLayout
    smbios = try DoryPCSMBIOSBuilder.build(
      layout: smbiosLayout,
      identity: smbiosIdentity,
      processorCount: processorCount,
      memoryBytes: memoryBytes,
      cpuProfile: interpreter.profile
    )
    loadedStates = [DoryX86ArchitecturalState?](repeating: nil, count: processorCount)
    haltedProcessors = [Bool](repeating: false, count: processorCount)
  }

  public func load(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = "console=ttyS0 earlyprintk=serial,ttyS0,115200"
  ) throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let kernelImage = try DoryPCPVHKernelImage(data: kernel)
      let acpi = try DoryPCACPIBuilder.build(
        layout: acpiLayout,
        processorCount: UInt8(processorCount)
      )
      let bootImage = try DoryPCPVHBootBuilder.build(
        commandLine: commandLine,
        initrd: initrd,
        memoryMap: DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryByteCount)),
        layout: bootLayout,
        rsdpPhysicalAddress: acpiLayout.rsdp
      )
      consumedPayload = true
      try kernelImage.load(into: memory)
      do {
        try bootImage.install(into: memory)
        try acpi.install(into: memory)
        try smbios.install(into: memory)
      } catch {
        // The machine cannot safely retry a partially loaded kernel with another payload.
        throw error
      }
      loadedStates[0] = try bootImage.initialState(entryPoint: kernelImage.physicalEntryPoint)
      for index in 1..<processorCount { loadedStates[index] = applicationProcessorResetState() }
      haltedProcessors = [Bool](repeating: false, count: processorCount)
    }
  }

  public var state: DoryX86ArchitecturalState? { state(forProcessor: 0) }

  public func state(forProcessor index: Int) -> DoryX86ArchitecturalState? {
    lock.withLock { loadedStates.indices.contains(index) ? loadedStates[index] : nil }
  }

  public func run(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    guard maximumInstructions > 0 else { return .instructionBudget(0) }
    return try lock.withLock {
      guard loadedStates[0] != nil else { throw DoryPCMachineError.notLoaded }
      var completed: UInt64 = 0
      while completed < maximumInstructions {
        if let stop = powerStop(instructionCount: completed) { return stop }
        applyProcessorEvents()
        for apic in localAPICs { apic.advanceTimer(by: 1) }
        legacyPIT.advance(by: 1)
        rtc.advance(by: 1)
        hpet.advance(by: 1)
        if let stop = deliverPendingInterrupts(instructionCount: completed) { return stop }
        guard let processor = nextRunnableProcessor() else {
          if advanceToNextInterrupt() { continue }
          return .halted(instructionCount: completed)
        }
        guard var state = loadedStates[processor] else { continue }
        let result = interpreters[processor].step(
          state: &state,
          memory: physicalMemories[processor],
          mode: executionMode(state),
          pagingUnit: pagingUnits[processor],
          ioBus: ioBus
        )
        completed += 1
        loadedStates[processor] = state
        if let stop = powerStop(instructionCount: completed) { return stop }
        switch result {
        case .retired, .yielded:
          haltedProcessors[processor] = false
          continue
        case .halted:
          haltedProcessors[processor] = true
          continue
        case .exception(let exception):
          guard exceptionPolicy == .deliver else {
            return .exception(exception, instructionCount: completed - 1)
          }
          do {
            try DoryX86InterruptDelivery().deliverException(
              exception,
              state: &state,
              physicalMemory: physicalMemories[processor],
              pagingUnit: pagingUnits[processor],
              mode: executionMode(state)
            )
            loadedStates[processor] = state
          } catch {
            loadedStates[processor] = state
            return .tripleFault(instructionCount: completed - 1)
          }
        }
      }
      return .instructionBudget(maximumInstructions)
    }
  }

  private func powerStop(instructionCount: UInt64) -> DoryPCMachineStop? {
    switch powerController.consumeRequestedAction() {
    case .powerOff: return .poweredOff(instructionCount: instructionCount)
    case .reset: return .reset(instructionCount: instructionCount)
    case nil: return nil
    }
  }

  private func applyProcessorEvents() {
    for event in multiprocessorController.drainEvents() {
      switch event {
      case .initialize(let apicID):
        guard let index = processorIndex(apicID) else { continue }
        loadedStates[index] = applicationProcessorResetState()
        haltedProcessors[index] = true
        pendingNMIs.remove(index)
      case .startup(let apicID, let vector):
        guard let index = processorIndex(apicID) else { continue }
        var state = applicationProcessorResetState()
        state.rip = 0
        state.cs = .init(
          selector: UInt16(vector) << 8,
          attributes: 0x0093,
          limit: 0xFFFF,
          base: UInt64(vector) << 12
        )
        loadedStates[index] = state
        haltedProcessors[index] = false
      case .nonMaskableInterrupt(let apicID):
        if let index = processorIndex(apicID) { pendingNMIs.insert(index) }
      }
    }
  }

  private func deliverPendingInterrupts(instructionCount: UInt64) -> DoryPCMachineStop? {
    for index in loadedStates.indices {
      guard var state = loadedStates[index],
        multiprocessorController.snapshot().lifecycles[localAPICs[index].apicID] == .running
      else { continue }
      let source: DoryX86InterruptSource
      let vector: UInt8?
      if pendingNMIs.remove(index) != nil {
        source = .nonMaskable
        vector = 2
      } else {
        source = .externalMaskable
        let enabled = state.rflags.contains(.interruptEnable)
        vector =
          localAPICs[index].acknowledge(
            interruptsEnabled: enabled,
            externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
          ) ?? (index == 0 ? legacyPIC.acknowledge(interruptsEnabled: enabled) : nil)
      }
      guard let vector else { continue }
      do {
        try DoryX86InterruptDelivery().deliver(
          vector: vector,
          source: source,
          state: &state,
          physicalMemory: physicalMemories[index],
          pagingUnit: pagingUnits[index],
          mode: executionMode(state)
        )
        loadedStates[index] = state
        haltedProcessors[index] = false
      } catch {
        loadedStates[index] = state
        return .tripleFault(instructionCount: instructionCount)
      }
    }
    return nil
  }

  private func nextRunnableProcessor() -> Int? {
    let lifecycles = multiprocessorController.snapshot().lifecycles
    for displacement in 0..<processorCount {
      let index = (roundRobinCursor + displacement) % processorCount
      guard loadedStates[index] != nil, !haltedProcessors[index],
        lifecycles[localAPICs[index].apicID] == .running
      else { continue }
      roundRobinCursor = (index + 1) % processorCount
      return index
    }
    return nil
  }

  private func advanceToNextInterrupt() -> Bool {
    var deadlines: [UInt64] = []
    for (index, apic) in localAPICs.enumerated() {
      guard let state = loadedStates[index], state.rflags.contains(.interruptEnable) else {
        continue
      }
      let timer = apic.snapshot().timer
      if !timer.masked, timer.currentCount > 0 { deadlines.append(UInt64(timer.currentCount)) }
    }
    let bspAcceptsInterrupts = loadedStates[0]?.rflags.contains(.interruptEnable) == true
    if bspAcceptsInterrupts {
      let pit = legacyPIT.snapshot()
      let picAcceptsTimer = legacyPIC.snapshot().masterMask & 1 == 0
      let ioAPICAcceptsTimer = (try? ioAPIC.route(for: 2)).map { !$0.masked } ?? false
      if pit.armed, pit.current > 0, picAcceptsTimer || ioAPICAcceptsTimer {
        deadlines.append(UInt64(pit.current))
      }
      if let ticks = rtc.ticksUntilNextInterrupt(), ticks > 0 { deadlines.append(ticks) }
      if let ticks = hpet.ticksUntilNextInterrupt(), ticks > 0 { deadlines.append(ticks) }
    }
    guard let ticks = deadlines.min() else { return false }
    for apic in localAPICs { apic.advanceTimer(by: ticks) }
    legacyPIT.advance(by: ticks)
    rtc.advance(by: ticks)
    hpet.advance(by: ticks)
    return true
  }

  private func applicationProcessorResetState() -> DoryX86ArchitecturalState {
    var state = DoryX86ArchitecturalState.reset()
    state.modelSpecific.apicBase &= ~(1 << 8)
    return state
  }

  private func processorIndex(_ apicID: UInt32) -> Int? {
    localAPICs.firstIndex(where: { $0.apicID == apicID })
  }

  private func executionMode(_ state: DoryX86ArchitecturalState) -> DoryX86ExecutionMode {
    guard state.control.cr0 & 1 != 0 else { return .real16 }
    if state.control.efer & (1 << 10) != 0, state.cs.attributes & 0x2000 != 0 {
      return .long64
    }
    return .protected32
  }
}
