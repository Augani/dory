import DoryDBTX86
import Foundation

public enum DoryPCMachineError: Error, Sendable, Equatable {
  case invalidMemorySize(Int)
  case alreadyLoaded
  case notLoaded
}

public enum DoryPCMachineStop: Sendable, Hashable {
  case halted(instructionCount: UInt64)
  case exception(DoryX86Exception, instructionCount: UInt64)
  case tripleFault(instructionCount: UInt64)
  case instructionBudget(UInt64)
}

public enum DoryPCExceptionPolicy: Sendable, Hashable {
  /// Debugger/conformance mode: expose the first precise CPU exception to the caller.
  case stop
  /// Product mode: enter the guest IDT, including architectural double/triple-fault escalation.
  case deliver
}

/// Phase-4 uniprocessor direct-kernel machine. It deliberately exposes only the PVH boot and
/// serial-console surface required to bring the interpreter to Linux; the Phase-5 PC devices are
/// added behind the same sealed buses rather than hidden in this loop.
public final class DoryPCDirectKernelMachine: @unchecked Sendable {
  public let memory: DoryX86ByteArrayMemory
  public let physicalMemory: DoryPCPhysicalMemoryBus
  public let ioBus: DoryPCPortIOBus
  public let serial: DoryPCUART16550
  public let localAPIC: DoryPCLocalAPIC
  public let ioAPIC: DoryPCIOAPIC
  public let legacyPIC: DoryPCPIC8259Pair
  public let legacyPIT: DoryPCPIT8254
  public let rtc: DoryPCRTC146818
  public let hpet: DoryPCHPET
  public let pciExpress: DoryPCPCIExpressECAM
  public let pagingUnit: DoryX86PagingUnit
  public let interpreter: DoryX86Interpreter
  public let bootLayout: DoryPCPVHBootLayout
  public let acpiLayout: DoryPCACPILayout
  public let memoryByteCount: Int

  private let lock = NSLock()
  private var loadedState: DoryX86ArchitecturalState?
  private var consumedPayload = false

  public init(
    memoryBytes: Int,
    bootLayout: DoryPCPVHBootLayout = .init(),
    acpiLayout: DoryPCACPILayout = .init(),
    initialRTCDate: Date = Date(),
    pciFunctions: [any DoryPCPCIFunction] = [],
    interpreter: DoryX86Interpreter = .init()
  ) throws {
    guard memoryBytes >= 1024 * 1024 else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
    memory = DoryX86ByteArrayMemory(byteCount: memoryBytes)
    physicalMemory = DoryPCPhysicalMemoryBus(ram: memory)
    memoryByteCount = memoryBytes
    ioBus = DoryPCPortIOBus()
    localAPIC = DoryPCLocalAPIC(apicID: 0)
    ioAPIC = DoryPCIOAPIC()
    try ioAPIC.attach(localAPIC)
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
    for function in pciFunctions { try pciExpress.attach(function) }
    pciExpress.seal()
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: false))
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: true))
    try ioBus.attach(legacyPIT)
    try ioBus.attach(rtc)
    try ioBus.attach(serial)
    ioBus.seal()
    try physicalMemory.attach(
      DoryPCLocalAPICMMIO(apic: localAPIC) { [ioAPIC] vector in
        try ioAPIC.endOfInterrupt(vector: vector, destinationAPICID: 0)
      })
    try physicalMemory.attach(DoryPCIOAPICMMIO(ioAPIC: ioAPIC))
    try physicalMemory.attach(hpet)
    try physicalMemory.attach(pciExpress)
    physicalMemory.seal()
    pagingUnit = DoryX86PagingUnit()
    self.interpreter = interpreter
    self.bootLayout = bootLayout
    self.acpiLayout = acpiLayout
  }

  public func load(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = "console=ttyS0 earlyprintk=serial,ttyS0,115200"
  ) throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let kernelImage = try DoryPCPVHKernelImage(data: kernel)
      let acpi = try DoryPCACPIBuilder.build(layout: acpiLayout)
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
      } catch {
        // The machine cannot safely retry a partially loaded kernel with another payload.
        throw error
      }
      loadedState = try bootImage.initialState(entryPoint: kernelImage.physicalEntryPoint)
    }
  }

  public var state: DoryX86ArchitecturalState? { lock.withLock { loadedState } }

  public func run(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    guard maximumInstructions > 0 else { return .instructionBudget(0) }
    return try lock.withLock {
      guard var state = loadedState else { throw DoryPCMachineError.notLoaded }
      for completed in 0..<maximumInstructions {
        localAPIC.advanceTimer(by: 1)
        legacyPIT.advance(by: 1)
        rtc.advance(by: 1)
        hpet.advance(by: 1)
        let interruptsEnabled = state.rflags.contains(.interruptEnable)
        let vector =
          localAPIC.acknowledge(
            interruptsEnabled: interruptsEnabled,
            externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
          ) ?? legacyPIC.acknowledge(interruptsEnabled: interruptsEnabled)
        if let vector {
          do {
            try DoryX86InterruptDelivery().deliver(
              vector: vector,
              source: .externalMaskable,
              state: &state,
              physicalMemory: physicalMemory,
              pagingUnit: pagingUnit,
              mode: executionMode(state)
            )
          } catch {
            loadedState = state
            return .tripleFault(instructionCount: completed)
          }
        }
        let result = interpreter.step(
          state: &state,
          memory: physicalMemory,
          mode: executionMode(state),
          pagingUnit: pagingUnit,
          ioBus: ioBus
        )
        loadedState = state
        switch result {
        case .retired, .yielded:
          continue
        case .halted:
          let apic = localAPIC.snapshot()
          if state.rflags.contains(.interruptEnable) {
            if apic.softwareEnabled, !apic.timer.masked, apic.timer.currentCount > 0 {
              localAPIC.advanceTimer(by: UInt64(apic.timer.currentCount))
              continue
            }
            let pit = legacyPIT.snapshot()
            let picAcceptsTimer = legacyPIC.snapshot().masterMask & 1 == 0
            let ioAPICAcceptsTimer =
              ((try? ioAPIC.route(for: 2)).map { !$0.masked } ?? false)
              && apic.softwareEnabled
            if pit.armed, pit.current > 0, picAcceptsTimer || ioAPICAcceptsTimer {
              legacyPIT.advance(by: UInt64(pit.current))
              continue
            }
            let pic = legacyPIC.snapshot()
            let picAcceptsRTC = pic.masterMask & (1 << 2) == 0 && pic.slaveMask & 1 == 0
            let ioAPICAcceptsRTC =
              ((try? ioAPIC.route(for: 8)).map { !$0.masked } ?? false)
              && apic.softwareEnabled
            if let rtcTicks = rtc.ticksUntilNextInterrupt(), rtcTicks > 0,
              picAcceptsRTC || ioAPICAcceptsRTC
            {
              rtc.advance(by: rtcTicks)
              continue
            }
            if let hpetTicks = hpet.ticksUntilNextInterrupt(), hpetTicks > 0 {
              hpet.advance(by: hpetTicks)
              continue
            }
          }
          return .halted(instructionCount: completed + 1)
        case .exception(let exception):
          guard exceptionPolicy == .deliver else {
            return .exception(exception, instructionCount: completed)
          }
          do {
            try DoryX86InterruptDelivery().deliverException(
              exception,
              state: &state,
              physicalMemory: physicalMemory,
              pagingUnit: pagingUnit,
              mode: executionMode(state)
            )
          } catch {
            loadedState = state
            return .tripleFault(instructionCount: completed)
          }
        }
      }
      return .instructionBudget(maximumInstructions)
    }
  }

  private func executionMode(_ state: DoryX86ArchitecturalState) -> DoryX86ExecutionMode {
    guard state.control.cr0 & 1 != 0 else { return .real16 }
    if state.control.efer & (1 << 10) != 0, state.cs.attributes & 0x2000 != 0 {
      return .long64
    }
    return .protected32
  }
}
