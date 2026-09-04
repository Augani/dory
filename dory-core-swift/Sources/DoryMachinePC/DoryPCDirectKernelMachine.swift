import Dispatch
import DoryDBTX86
import DoryPlatformC
import Foundation

public enum DoryPCMachineError: Error, Sendable, Equatable {
  case invalidMemorySize(Int)
  case invalidProcessorCount(Int)
  case invalidTSCFrequency(UInt64)
  case alreadyLoaded
  case notLoaded
  case invalidBootRange
  case bootArtifactOutsideRAM
  case overlappingBootArtifacts
}

public enum DoryPCExecutionTier: String, Codable, Sendable, Hashable {
  case interpreter
  case baselineJIT
  case optimizingJIT
}

/// Selects the source of guest machine time without changing the DoryPC-v1 clock frequencies.
/// Deterministic time is reserved for conformance, replay, and unit tests. Product UEFI machines
/// use host-monotonic time so a slow translated CPU cannot also make firmware timers run slowly.
public struct DoryPCClockSource: Sendable {
  fileprivate let monotonicNanoseconds: (@Sendable () -> UInt64)?
  fileprivate let discontinuityGeneration: @Sendable () -> UInt32

  public static let deterministic = Self(
    monotonicNanoseconds: nil,
    discontinuityGeneration: { 0 }
  )
  public static let hostMonotonic = Self(
    monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds },
    discontinuityGeneration: { dory_sigcont_generation() }
  )

  /// Injectable host-monotonic source for clock conformance tests. Values that move backwards are
  /// ignored; production uses `hostMonotonic`.
  public static func hostMonotonic(
    _ monotonicNanoseconds: @escaping @Sendable () -> UInt64,
    discontinuityGeneration: @escaping @Sendable () -> UInt32 = { 0 }
  ) -> Self {
    Self(
      monotonicNanoseconds: monotonicNanoseconds,
      discontinuityGeneration: discontinuityGeneration
    )
  }

  private init(
    monotonicNanoseconds: (@Sendable () -> UInt64)?,
    discontinuityGeneration: @escaping @Sendable () -> UInt32
  ) {
    self.monotonicNanoseconds = monotonicNanoseconds
    self.discontinuityGeneration = discontinuityGeneration
  }

  /// Installs the process-wide SIGCONT generation marker used to exclude explicit VM suspension
  /// from host-monotonic guest time. DoryPC runners host exactly one VM per process.
  public static func installProcessResumeTracking() -> Bool {
    dory_install_sigcont_generation_tracker() == 0
  }
}

public struct DoryPCExecutionStatistics: Codable, Sendable, Hashable {
  public let interpreterInstructions: UInt64
  public let baselineJITInstructions: UInt64
  public let baselineJITBlocks: UInt64
  public let optimizingJITInstructions: UInt64
  public let optimizingJITBlocks: UInt64

  public init(
    interpreterInstructions: UInt64,
    baselineJITInstructions: UInt64,
    baselineJITBlocks: UInt64,
    optimizingJITInstructions: UInt64,
    optimizingJITBlocks: UInt64
  ) {
    self.interpreterInstructions = interpreterInstructions
    self.baselineJITInstructions = baselineJITInstructions
    self.baselineJITBlocks = baselineJITBlocks
    self.optimizingJITInstructions = optimizingJITInstructions
    self.optimizingJITBlocks = optimizingJITBlocks
  }
}

public struct DoryPCJITCacheStatistics: Sendable, Hashable {
  public let recentLookupHits: UInt64
  public let dictionaryLookupHits: UInt64
  public let lookupMisses: UInt64
  public let memoryGenerationHits: UInt64
  public let byteValidationHits: UInt64
  public let sharedCodeHits: UInt64
  public let compiledBlocks: UInt64
  public let declinedCompilations: UInt64
  public let negativeCacheHits: UInt64
  public let negativeCacheMisses: UInt64
  public let negativeGenerationMismatches: UInt64
  public let negativeEntryCount: UInt64
  public let negativeCacheHotSites: [DoryPCJITNegativeCacheHotSite]
  public let codeCacheWraps: UInt64
  public let nativeTraceAttempts: UInt64
  public let nativeTraceReplays: UInt64
  public let codeGenerationChecks: UInt64
  public let codeGenerationMismatches: UInt64
  public let chainedExecutionCalls: UInt64
  public let chainedRequestedInstructions: UInt64
  public let chainedRetiredInstructions: UInt64

  fileprivate init(_ source: DoryARM64BaselineExecutorDiagnostics) {
    recentLookupHits = source.recentLookupHits
    dictionaryLookupHits = source.dictionaryLookupHits
    lookupMisses = source.lookupMisses
    memoryGenerationHits = source.memoryGenerationHits
    byteValidationHits = source.byteValidationHits
    sharedCodeHits = source.sharedCodeHits
    compiledBlocks = source.compiledBlocks
    declinedCompilations = source.declinedCompilations
    negativeCacheHits = source.negativeCacheHits
    negativeCacheMisses = source.negativeCacheMisses
    negativeGenerationMismatches = source.negativeGenerationMismatches
    negativeEntryCount = source.negativeEntryCount
    negativeCacheHotSites = source.negativeCacheHotSites.map(DoryPCJITNegativeCacheHotSite.init)
    codeCacheWraps = source.codeCacheWraps
    nativeTraceAttempts = source.nativeTraceAttempts
    nativeTraceReplays = source.nativeTraceReplays
    codeGenerationChecks = source.codeGenerationChecks
    codeGenerationMismatches = source.codeGenerationMismatches
    chainedExecutionCalls = source.chainedExecutionCalls
    chainedRequestedInstructions = source.chainedRequestedInstructions
    chainedRetiredInstructions = source.chainedRetiredInstructions
  }
}

public struct DoryPCJITNegativeCacheHotSite: Sendable, Hashable {
  public let guestRIP: UInt64
  public let executionMode: DoryX86ExecutionMode
  public let instructionBudget: Int
  public let addressSpaceID: UInt64
  public let privilegeLevel: UInt8
  public let pagingEnabled: Bool
  public let guestByteCount: Int
  public let instructionBytes: [UInt8]
  public let declineReason: DoryARM64CompilationDeclineReason
  public let hitCount: UInt64

  fileprivate init(_ source: DoryARM64NegativeCacheHotSite) {
    guestRIP = source.guestRIP
    executionMode = source.executionMode
    instructionBudget = source.instructionBudget
    addressSpaceID = source.addressSpaceID
    privilegeLevel = source.privilegeLevel
    pagingEnabled = source.pagingEnabled
    guestByteCount = source.guestByteCount
    instructionBytes = source.instructionBytes
    declineReason = source.declineReason
    hitCount = source.hitCount
  }
}

public struct DoryPCProcessorExecutionSnapshot: Sendable, Hashable {
  public let index: Int
  public let lifecycle: DoryPCProcessorLifecycle
  public let isHalted: Bool
  public let state: DoryX86ArchitecturalState?

  public init(
    index: Int,
    lifecycle: DoryPCProcessorLifecycle,
    isHalted: Bool,
    state: DoryX86ArchitecturalState?
  ) {
    self.index = index
    self.lifecycle = lifecycle
    self.isHalted = isHalted
    self.state = state
  }
}

public struct DoryPCTripleFaultExceptionEvidence: Sendable, Hashable {
  public let exception: DoryX86Exception
  public let processor: Int
  public let executionMode: DoryX86ExecutionMode
  public let state: DoryX86ArchitecturalState
  public let instructionBytes: [UInt8]

  public init(
    exception: DoryX86Exception,
    processor: Int,
    executionMode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    instructionBytes: [UInt8]
  ) {
    self.exception = exception
    self.processor = processor
    self.executionMode = executionMode
    self.state = state
    self.instructionBytes = instructionBytes
  }
}

public enum DoryPCTripleFaultSource: Sendable, Hashable {
  case exception(DoryPCTripleFaultExceptionEvidence)
  case interrupt(vector: UInt8, source: DoryX86InterruptSource, processor: Int)
}

public enum DoryPCMachineStop: Sendable, Hashable {
  case halted(instructionCount: UInt64)
  case exception(DoryX86Exception, instructionCount: UInt64)
  case tripleFault(source: DoryPCTripleFaultSource, instructionCount: UInt64)
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
  private final class ProcessorState: @unchecked Sendable {
    var value: DoryX86ArchitecturalState

    init(_ value: DoryX86ArchitecturalState) {
      self.value = value
    }
  }

  public let memory: any DoryX86PhysicalRAM
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
  public let systemControlPort: DoryPCSystemControlPortB
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
  public let firmwareConfiguration: DoryPCFirmwareConfiguration
  public let platformMMIODevices: [any DoryPCMMIODevice]
  public let memoryByteCount: Int
  public let processorCount: Int
  public let executionTier: DoryPCExecutionTier

  private let lock = NSLock()
  // `run` intentionally owns `lock` for a deterministic execution quantum. Observability must not
  // contend for that lock: a lifecycle telemetry request is served on another queue while the VM
  // is executing and would otherwise wait until the full quantum retired (or deadlock its socket
  // deadline). Publish an immutable snapshot after every quantum under a dedicated short lock.
  private let executionStatisticsLock = NSLock()
  private var loadedStates: [ProcessorState?]
  private var haltedProcessors: [Bool]
  private var processorLifecycles: [DoryPCProcessorLifecycle]
  private var pendingNMIs: Set<Int> = []
  private var roundRobinCursor = 0
  private var consumedPayload = false
  private let baselineJIT: DoryARM64BaselineExecutor?
  private let optimizingJIT: DoryARM64BaselineExecutor?
  private let optimizingJITWarmupDispatches: UInt8
  private struct JITHotnessEntry {
    var tag: UInt64 = 0
    var dispatchCount: UInt8 = 0
  }
  // A bounded direct-mapped table keeps full-system cold-start accounting independent of the
  // number of distinct firmware, kernel, and initramfs RIPs. A collision merely delays promotion;
  // it cannot affect architectural behavior or cache correctness.
  private var jitHotness = [JITHotnessEntry](repeating: .init(), count: 1 << 16)
  private let translatedMemories: [DoryX86TranslatedMemory]
  private var interpreterInstructionCount: UInt64 = 0
  private var baselineJITInstructionCount: UInt64 = 0
  private var baselineJITBlockCount: UInt64 = 0
  private var optimizingJITInstructionCount: UInt64 = 0
  private var optimizingJITBlockCount: UInt64 = 0
  private var publishedExecutionStatistics = DoryPCExecutionStatistics(
    interpreterInstructions: 0,
    baselineJITInstructions: 0,
    baselineJITBlocks: 0,
    optimizingJITInstructions: 0,
    optimizingJITBlocks: 0
  )
  private var pitClockRemainder: UInt64 = 0
  private var rtcClockRemainder: UInt64 = 0
  private var localAPICClockRemainder: UInt64 = 0
  private var pmTimerClockRemainder: UInt64 = 0
  private var tscClockRemainder: UInt64 = 0
  private let clockSource: DoryPCClockSource
  private var lastHostClockNanoseconds: UInt64?
  private var hostClockNanosecondRemainder: UInt64 = 0
  private var hostClockDiscontinuityGeneration: UInt32?

  // HPET exposes a 100 ns period, so one deterministic machine-clock tick is 100 ns. Keeping the
  // execution tiers on this shared timebase preserves the selected CPU's TSC rate
  // while the PIT, RTC, and ACPI PM timer receive their independent oscillator rates.
  private static let machineClockFrequencyHz: UInt64 = 10_000_000
  private static let localAPICClockFrequencyHz: UInt64 = 1_000_000_000
  private static let pitFrequencyHz: UInt64 = 1_193_182

  public init(
    memoryBytes: Int,
    processorCount: Int = 1,
    bootLayout: DoryPCPVHBootLayout = .init(),
    acpiLayout: DoryPCACPILayout = .init(),
    smbiosLayout: DoryPCSMBIOSLayout = .init(),
    smbiosIdentity: DoryPCSMBIOSIdentity = .init(),
    initialRTCDate: Date = Date(),
    firmwareConfigurationFlags: DoryPCFirmwareConfiguration.Flags = [],
    pciFunctions: [any DoryPCPCIFunction] = [],
    platformMMIODevices: [any DoryPCMMIODevice] = [],
    interpreter: DoryX86Interpreter = .init(),
    executionTier: DoryPCExecutionTier = .interpreter,
    baselineJITMaximumCodeBytes: Int = DoryARM64BaselineExecutor.defaultMaximumCodeBytes,
    optimizingJITWarmupDispatches: UInt8 = 8,
    clockSource: DoryPCClockSource = .deterministic
  ) throws {
    guard memoryBytes >= 1024 * 1024,
      memoryBytes % (1024 * 1024) == 0,
      UInt64(memoryBytes) <= DoryPCV1ABI.maximumMemoryBytes
    else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
    guard (1...255).contains(processorCount) else {
      throw DoryPCMachineError.invalidProcessorCount(processorCount)
    }
    guard (32...52).contains(interpreter.profile.physicalAddressBits) else {
      throw DoryX86StateError.invalidPhysicalAddressBits(interpreter.profile.physicalAddressBits)
    }
    guard interpreter.profile.virtualTSCFrequencyHz > 0 else {
      throw DoryPCMachineError.invalidTSCFrequency(interpreter.profile.virtualTSCFrequencyHz)
    }
    self.processorCount = processorCount
    self.executionTier = executionTier
    self.optimizingJITWarmupDispatches = optimizingJITWarmupDispatches
    self.clockSource = clockSource
    baselineJIT =
      switch executionTier {
      case .interpreter:
        nil
      case .baselineJIT:
        try DoryARM64BaselineExecutor(
          maximumCodeBytes: baselineJITMaximumCodeBytes,
          decoder: interpreter.decoder,
          cpuProfileIdentifier: interpreter.profile.identifier,
          physicalAddressBits: interpreter.profile.physicalAddressBits,
          optimization: .baseline
        )
      case .optimizingJIT:
        try DoryARM64BaselineExecutor(
          maximumCodeBytes: max(4_096, baselineJITMaximumCodeBytes / 4),
          decoder: interpreter.decoder,
          cpuProfileIdentifier: interpreter.profile.identifier,
          physicalAddressBits: interpreter.profile.physicalAddressBits,
          optimization: .baseline
        )
      }
    optimizingJIT =
      switch executionTier {
      case .interpreter, .baselineJIT:
        nil
      case .optimizingJIT:
        try DoryARM64BaselineExecutor(
          maximumCodeBytes: max(4_096, baselineJITMaximumCodeBytes * 3 / 4),
          decoder: interpreter.decoder,
          cpuProfileIdentifier: interpreter.profile.identifier,
          physicalAddressBits: interpreter.profile.physicalAddressBits,
          optimization: .optimizing
        )
      }
    firmwareConfiguration = DoryPCFirmwareConfiguration(
      totalRAMBytes: UInt64(memoryBytes),
      processorCount: processorCount,
      flags: firmwareConfigurationFlags,
      acpiRSDPAddress: acpiLayout.rsdp,
      smbiosEntryAddress: smbiosLayout.entryPoint
    )
    self.platformMMIODevices = [firmwareConfiguration] + platformMMIODevices
    // Physical machines need a recoverable host allocation boundary at every size.
    // Swift Array allocation traps on exhaustion; byte-array RAM remains a conformance fixture.
    let sharedMemory: any DoryX86PhysicalRAM = try DoryX86MmapMemory(
      validatingByteCount: memoryBytes
    )
    memory = sharedMemory
    physicalMemories = try (0..<processorCount).map {
      _ in try DoryPCPhysicalMemoryBus(ram: sharedMemory)
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
    systemControlPort = DoryPCSystemControlPortB(pit: legacyPIT)
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
      if asserted, case .legacyIRQ(let irq) = route { try? legacyPIC.raise(irq: irq) }
      try? ioAPIC.setAsserted(asserted, pin: Self.ioAPICPin(forHPETRoute: route))
    }
    pciExpress = DoryPCPCIExpressECAM()
    pciBARWindow = DoryPCPCIBARWindow()
    powerController = DoryPCPowerController()
    let intxRouter = DoryPCPCIINTxRouter(ioAPIC: ioAPIC)
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
      if let intxFunction = function as? any DoryPCPCIINTxControllable {
        let source = ObjectIdentifier(intxFunction)
        intxFunction.connectINTxSink { [intxRouter] line, asserted in
          intxRouter.setAsserted(asserted, line: Int(line), source: source)
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
    try ioBus.attach(systemControlPort)
    try ioBus.attach(rtc)
    try ioBus.attach(serial)
    try ioBus.attach(DoryPCACPIPMEventPort(controller: powerController))
    try ioBus.attach(DoryPCACPIPMControlPort(controller: powerController))
    try ioBus.attach(DoryPCACPMPMTimerPort(controller: powerController))
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
      for device in self.platformMMIODevices { try bus.attach(device) }
      bus.seal()
    }
    pagingUnits = (0..<processorCount).map { _ in
      DoryX86PagingUnit(physicalAddressBits: interpreter.profile.physicalAddressBits)
    }
    pagingUnit = pagingUnits[0]
    translatedMemories = zip(physicalMemories, pagingUnits).map { physicalMemory, pagingUnit in
      DoryX86TranslatedMemory(
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        context: .init(state: .reset(), mode: .real16)
      )
    }
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
    loadedStates = [ProcessorState?](repeating: nil, count: processorCount)
    haltedProcessors = [Bool](repeating: false, count: processorCount)
    processorLifecycles = (0..<processorCount).map {
      $0 == 0 ? .running : .waitingForStartup
    }
  }

  public func load(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = "console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1"
  ) throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let kernelImage = try DoryPCPVHKernelImage(data: kernel)
      let acpi = try DoryPCACPIBuilder.build(
        layout: acpiLayout,
        processorCount: UInt8(processorCount)
      )
      let memoryMap = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryByteCount))
      let bootImage = try DoryPCPVHBootBuilder.build(
        commandLine: commandLine,
        initrd: initrd,
        memoryMap: memoryMap,
        layout: bootLayout,
        rsdpPhysicalAddress: acpiLayout.rsdp
      )
      let initialState = try bootImage.initialState(entryPoint: kernelImage.physicalEntryPoint)
      try initialState.control.validateLegacyPAEPDPTEs(
        physicalAddressBits: interpreter.profile.physicalAddressBits
      )
      try validateDirectBoot(
        kernel: kernelImage, boot: bootImage, acpi: acpi, memoryMap: memoryMap
      )
      // All static layout and memory-authority rejection happens before any write or
      // consumption. An unexpected failure during installation remains non-retryable.
      consumedPayload = true
      try kernelImage.load(into: physicalMemory)
      try bootImage.install(into: physicalMemory)
      try acpi.install(into: physicalMemory)
      try smbios.install(into: physicalMemory)
      loadedStates[0] = ProcessorState(initialState)
      for index in 1..<processorCount {
        loadedStates[index] = ProcessorState(applicationProcessorResetState())
      }
      haltedProcessors = [Bool](repeating: false, count: processorCount)
    }
  }

  private func validateDirectBoot(
    kernel: DoryPCPVHKernelImage,
    boot: DoryPCPVHBootImage,
    acpi: DoryPCACPITables,
    memoryMap: [DoryPCMemoryMapEntry]
  ) throws {
    func range(_ address: UInt64, _ count: UInt64) throws -> Range<UInt64> {
      let (end, overflow) = address.addingReportingOverflow(count)
      guard count > 0, count <= UInt64(Int.max), !overflow else {
        throw DoryPCMachineError.invalidBootRange
      }
      return address..<end
    }
    let ram = try memoryMap.filter { $0.kind == .ram }.map { try range($0.address, $0.size) }
    let kernelRanges = try kernel.segments.filter { $0.memorySize > 0 }.map {
      try range($0.physicalAddress, $0.memorySize)
    }
    // Segment writes include BSS. No part may cross a reserved hole or depend on
    // the packed backing offsets used internally for RAM above four GiB.
    guard kernelRanges.allSatisfy({ segment in
      ram.contains { $0.lowerBound <= segment.lowerBound && segment.upperBound <= $0.upperBound }
    }) else { throw DoryPCMachineError.bootArtifactOutsideRAM }

    let artifacts: [(UInt64, [UInt8])] = [
      (boot.layout.startInfo, boot.startInfo), (boot.layout.commandLine, boot.commandLine),
      (boot.layout.modules, boot.modules), (boot.layout.memoryMap, boot.memoryMap),
      (boot.layout.initrd, boot.initrd),
      (acpi.layout.rsdp, acpi.rsdp), (acpi.layout.xsdt, acpi.xsdt),
      (acpi.layout.madt, acpi.madt), (acpi.layout.hpet, acpi.hpet),
      (acpi.layout.mcfg, acpi.mcfg), (acpi.layout.fadt, acpi.fadt),
      (acpi.layout.facs, acpi.facs), (acpi.layout.dsdt, acpi.dsdt),
      (smbios.layout.entryPoint, smbios.entryPoint),
      (smbios.layout.structureTable, smbios.structureTable),
    ]
    let artifactRanges = try artifacts.filter { !$0.1.isEmpty }.map {
      try range($0.0, UInt64($0.1.count))
    }
    // Preserve the legacy first page and the explicitly supplied initial stack.
    let ranges = (kernelRanges + artifactRanges + [0..<0x1000, 0x7000..<0x8000])
      .sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCMachineError.overlappingBootArtifacts
    }
    for item in kernelRanges + artifactRanges {
      // RAM-only validation rejects writable MMIO overlays as well as ROM, holes
      // and unmapped addresses; preflight cannot trigger a device write.
      try physicalMemory.validateDMA(
        at: item.lowerBound, byteCount: Int(item.count), deviceWillWrite: true
      )
    }
    try kernel.validate(into: physicalMemory)
    try boot.validate(into: physicalMemory)
  }

  /// Installs firmware discovery tables and enters the architectural x86 reset state. Firmware
  /// code must already be attached as an instruction-fetchable platform MMIO device.
  public func loadUEFI() throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let initialState = DoryX86ArchitecturalState.reset()
      try initialState.control.validateLegacyPAEPDPTEs(
        physicalAddressBits: interpreter.profile.physicalAddressBits
      )
      let acpi = try DoryPCACPIBuilder.build(
        layout: acpiLayout,
        processorCount: UInt8(processorCount)
      )
      _ = try physicalMemory.instructionBytes(
        at: DoryPCV1ABI.uefiResetAddress,
        maximumCount: 1
      )
      consumedPayload = true
      do {
        try acpi.install(into: memory)
        try smbios.install(into: memory)
      } catch {
        throw error
      }
      loadedStates[0] = ProcessorState(initialState)
      for index in 1..<processorCount {
        loadedStates[index] = ProcessorState(applicationProcessorResetState())
      }
      haltedProcessors = [Bool](repeating: false, count: processorCount)
    }
  }

  public var state: DoryX86ArchitecturalState? { state(forProcessor: 0) }

  public var executionStatistics: DoryPCExecutionStatistics {
    executionStatisticsLock.withLock { publishedExecutionStatistics }
  }

  public var baselineJITDiagnostics: DoryPCJITCacheStatistics? {
    baselineJIT.map { .init($0.diagnostics) }
  }

  public var optimizingJITDiagnostics: DoryPCJITCacheStatistics? {
    optimizingJIT.map { .init($0.diagnostics) }
  }

  public func state(forProcessor index: Int) -> DoryX86ArchitecturalState? {
    lock.withLock { loadedStates.indices.contains(index) ? loadedStates[index]?.value : nil }
  }

  public var processorExecutionSnapshots: [DoryPCProcessorExecutionSnapshot] {
    lock.withLock {
      loadedStates.indices.map { index in
        .init(
          index: index,
          lifecycle: processorLifecycles[index],
          isHalted: haltedProcessors[index],
          state: loadedStates[index]?.value
        )
      }
    }
  }

  /// Reads instruction bytes through the processor's current linear-address translation. This is
  /// intended for precise diagnostics: callers must not treat `CS.base + RIP` as a physical
  /// address once paging is active.
  public func instructionBytes(
    forProcessor index: Int = 0,
    maximumCount: Int = 16
  ) throws -> [UInt8]? {
    guard maximumCount > 0 else { return [] }
    return try lock.withLock {
      guard loadedStates.indices.contains(index), let state = loadedStates[index]?.value else {
        return nil
      }
      let translatedMemory = translatedMemories[index]
      translatedMemory.updateContext(.init(state: state, mode: executionMode(state)))
      return try translatedMemory.instructionBytes(
        at: state.cs.base &+ state.rip,
        maximumCount: maximumCount
      )
    }
  }

  /// Reads diagnostic data through the processor's current linear-address translation.
  public func memoryBytes(
    forProcessor index: Int = 0,
    atLinearAddress address: UInt64,
    maximumCount: Int
  ) throws -> [UInt8]? {
    guard maximumCount > 0 else { return [] }
    return try lock.withLock {
      guard loadedStates.indices.contains(index), let state = loadedStates[index]?.value else {
        return nil
      }
      let translatedMemory = translatedMemories[index]
      translatedMemory.updateContext(.init(state: state, mode: executionMode(state)))
      return try translatedMemory.read(at: address, byteCount: maximumCount)
    }
  }

  public func run(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    guard maximumInstructions > 0 else { return .instructionBudget(0) }
    return try lock.withLock {
      guard loadedStates[0] != nil else { throw DoryPCMachineError.notLoaded }
      // Validate installed latches before consuming device events, advancing clocks, or
      // entering either execution tier. Guest RAM is not a substitute for latched state.
      for processorState in loadedStates {
        try processorState?.value.control.validateLegacyPAEPDPTEs(
          physicalAddressBits: interpreter.profile.physicalAddressBits
        )
      }
      defer { publishExecutionStatistics() }
      var completed: UInt64 = 0
      while completed < maximumInstructions {
        if let stop = powerStop(instructionCount: completed) { return stop }
        applyProcessorEvents()
        if clockSource.monotonicNanoseconds != nil {
          synchronizeHostClock()
        } else {
          // Deterministic conformance time advances with retired work and remains identical across
          // interpreter and JIT tiers. Product UEFI execution never uses this policy.
          advanceClocks(by: 1)
        }
        if let stop = deliverPendingInterrupts(instructionCount: completed) { return stop }
        guard let processor = nextRunnableProcessor() else {
          if waitForNextInterrupt() { continue }
          return .halted(instructionCount: completed)
        }
        guard let processorState = loadedStates[processor] else { continue }
        let remaining = maximumInstructions - completed
        let jitInstructionBudget =
          baselineJIT == nil ? nil : baselineInstructionBudget(maximumInstructions: remaining)
        let execution = try execute(
          processor: processor,
          state: &processorState.value,
          maximumInstructions: remaining,
          jitInstructionBudget: jitInstructionBudget
        )
        completed += execution.instructionCount
        switch execution.jitTier {
        case .baseline:
          baselineJITInstructionCount &+= execution.instructionCount
          baselineJITBlockCount &+= execution.jitBlockCount
        case .optimizing:
          optimizingJITInstructionCount &+= execution.instructionCount
          optimizingJITBlockCount &+= execution.jitBlockCount
        case .interpreterFallback, nil:
          interpreterInstructionCount &+= execution.instructionCount
        }
        if clockSource.monotonicNanoseconds != nil {
          synchronizeHostClock()
        } else {
          if execution.instructionCount > 1 {
            advanceClocks(by: execution.instructionCount - 1)
          }
          // Deterministic TSC progression is an explicit test/replay policy, not product time.
          advanceTSCs(byMachineTicks: execution.instructionCount)
        }
        if let stop = powerStop(instructionCount: completed) { return stop }
        switch execution.result {
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
          let faultMode = executionMode(processorState.value)
          translatedMemories[processor].updateContext(
            .init(state: processorState.value, mode: faultMode)
          )
          let faultLinearInstructionPointer =
            faultMode == .long64
            ? exception.instructionPointer
            : processorState.value.cs.base &+ exception.instructionPointer
          let faultBytes =
            (try? translatedMemories[processor].instructionBytes(
              at: faultLinearInstructionPointer,
              maximumCount: 15
            )) ?? []
          let evidence = DoryPCTripleFaultExceptionEvidence(
            exception: exception,
            processor: processor,
            executionMode: faultMode,
            state: processorState.value,
            instructionBytes: faultBytes
          )
          do {
            try DoryX86InterruptDelivery().deliverException(
              exception,
              state: &processorState.value,
              physicalMemory: physicalMemories[processor],
              pagingUnit: pagingUnits[processor],
              mode: executionMode(processorState.value)
            )
          } catch {
            return .tripleFault(
              source: .exception(evidence),
              instructionCount: completed - 1
            )
          }
        }
      }
      return .instructionBudget(maximumInstructions)
    }
  }

  private func publishExecutionStatistics() {
    let snapshot = DoryPCExecutionStatistics(
      interpreterInstructions: interpreterInstructionCount,
      baselineJITInstructions: baselineJITInstructionCount,
      baselineJITBlocks: baselineJITBlockCount,
      optimizingJITInstructions: optimizingJITInstructionCount,
      optimizingJITBlocks: optimizingJITBlockCount
    )
    executionStatisticsLock.withLock { publishedExecutionStatistics = snapshot }
  }

  private enum ProcessorResult {
    case retired
    case yielded
    case halted
    case exception(DoryX86Exception)
  }

  private struct ProcessorExecution {
    let result: ProcessorResult
    let instructionCount: UInt64
    let jitTier: DoryARM64CompilationTier?
    let jitBlockCount: UInt64
  }

  private func execute(
    processor: Int,
    state: inout DoryX86ArchitecturalState,
    maximumInstructions: UInt64,
    jitInstructionBudget: Int?
  ) throws -> ProcessorExecution {
    let mode = executionMode(state)
    if let jit = selectedJIT(for: state, mode: mode),
      mode == .long64 || (mode == .protected32 && state.cs.base == 0),
      !state.rflags.contains(.trap)
    {
      let budget = jitInstructionBudget ?? 1
      let translatedMemory = translatedMemories[processor]
      translatedMemory.updateContext(.init(state: state, mode: mode))
      let guestRIP = state.rip
      if let execution = try jit.executeChainedSummary(
        byteProvider: { address, maximumCount in
          // A speculative block fetch can cross an unmapped guest page even when the current
          // instruction itself is valid. Preserve the architectural path by declining JIT
          // execution and letting the interpreter perform its precise instruction fetch/fault.
          (try? translatedMemory.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
        },
        codeGenerationProvider: { address, byteCount in
          try translatedMemory.codeGeneration(at: address, byteCount: byteCount)
        },
        at: guestRIP,
        mode: mode,
        addressSpaceID: state.control.cr3,
        maximumInstructions: budget,
        state: &state,
        memory: translatedMemory
      ) {
        let count = UInt64(execution.guestInstructionCount)
        switch execution.exitCode {
        case .dispatch:
          return .init(
            result: .retired,
            instructionCount: count,
            jitTier: execution.tier,
            jitBlockCount: UInt64(execution.residentBlockCount)
          )
        case .halt:
          return .init(
            result: .halted,
            instructionCount: count,
            jitTier: execution.tier,
            jitBlockCount: UInt64(execution.residentBlockCount)
          )
        case .interpreter, .system, .portIO:
          break
        }
      }
    }

    let result = interpreters[processor].step(
      state: &state,
      memory: physicalMemories[processor],
      mode: mode,
      pagingUnit: pagingUnits[processor],
      translatedMemory: translatedMemories[processor],
      ioBus: ioBus
    )
    let machineResult: ProcessorResult =
      switch result {
      case .retired: .retired
      case .yielded: .yielded
      case .halted: .halted
      case .exception(let exception): .exception(exception)
      }
    return .init(result: machineResult, instructionCount: 1, jitTier: nil, jitBlockCount: 0)
  }

  private func selectedJIT(
    for state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> DoryARM64BaselineExecutor? {
    guard executionTier == .optimizingJIT, let optimizingJIT else { return baselineJIT }
    guard optimizingJITWarmupDispatches > 0 else { return optimizingJIT }

    var tag = state.rip
    tag ^= state.control.cr3 &* 0x9e37_79b9_7f4a_7c15
    tag ^= UInt64(state.cs.selector & 3) << 57
    tag ^= state.control.cr0 & (1 << 31) != 0 ? 1 << 56 : 0
    switch mode {
    case .real16: tag ^= 0x11
    case .protected16: tag ^= 0x22
    case .protected32: tag ^= 0x33
    case .long64: tag ^= 0x44
    }
    tag ^= tag >> 33
    tag &*= 0xff51_afd7_ed55_8ccd
    tag ^= tag >> 33
    // Reserve zero as the empty tag while retaining deterministic treatment of the one hash that
    // naturally maps there.
    if tag == 0 { tag = 1 }
    let index = Int(tag & UInt64(jitHotness.count - 1))
    if jitHotness[index].tag != tag {
      jitHotness[index] = .init(tag: tag, dispatchCount: 1)
      return baselineJIT
    }
    if jitHotness[index].dispatchCount < optimizingJITWarmupDispatches {
      jitHotness[index].dispatchCount &+= 1
    }
    return jitHotness[index].dispatchCount >= optimizingJITWarmupDispatches
      ? optimizingJIT : baselineJIT
  }

  private func baselineInstructionBudget(maximumInstructions: UInt64) -> Int {
    // SMP fairness keeps a 64-instruction quantum while multiple processors can run. Once every
    // other processor has parked, a larger bounded quantum avoids needless Swift round trips.
    // Interrupt deadlines below still shorten either batch whenever observable work is due sooner.
    let runnableProcessorCount = loadedStates.indices.lazy.filter {
      self.loadedStates[$0] != nil && !self.haltedProcessors[$0]
        && self.processorLifecycles[$0] == .running
    }.prefix(2).count
    let fairnessLimit: UInt64 = runnableProcessorCount == 1 ? 4_096 : 64
    var budget = Int(min(maximumInstructions, fairnessLimit))
    if let deadline = ticksUntilNextAcceptedInterrupt() {
      budget = min(budget, Int(min(deadline, UInt64(Int.max))))
    }
    return max(1, budget)
  }

  private func advanceClocks(by ticks: UInt64) {
    guard ticks > 0 else { return }
    let localAPICTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: Self.localAPICClockFrequencyHz,
      remainder: &localAPICClockRemainder
    )
    for apic in localAPICs { apic.advanceTimer(byBaseClockTicks: localAPICTicks) }
    let pitTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: Self.pitFrequencyHz,
      remainder: &pitClockRemainder
    )
    let rtcTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: DoryPCRTC146818.oscillatorFrequency,
      remainder: &rtcClockRemainder
    )
    legacyPIT.advance(by: pitTicks)
    rtc.advance(by: rtcTicks)
    hpet.advance(by: ticks)
    let pmTimerTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: DoryPCPowerController.pmTimerFrequencyHz,
      remainder: &pmTimerClockRemainder
    )
    powerController.advancePMTimer(by: pmTimerTicks)
  }

  private func advanceTSCs(byMachineTicks ticks: UInt64) {
    guard ticks > 0 else { return }
    let tscTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: interpreter.profile.virtualTSCFrequencyHz,
      remainder: &tscClockRemainder
    )
    for index in loadedStates.indices {
      loadedStates[index]?.value.tsc &+= tscTicks
    }
  }

  /// Samples elapsed host time and advances one coherent 10 MHz machine epoch. The remainder is
  /// retained so repeated sub-100 ns samples cannot lose time. Guest-visible state stores only
  /// virtual ticks; the host uptime sample is disposable launch-local authority.
  private func synchronizeHostClock() {
    guard let sample = clockSource.monotonicNanoseconds else { return }
    let now = sample()
    let discontinuity = clockSource.discontinuityGeneration()
    guard hostClockDiscontinuityGeneration == discontinuity else {
      hostClockDiscontinuityGeneration = discontinuity
      lastHostClockNanoseconds = now
      hostClockNanosecondRemainder = 0
      return
    }
    guard let previous = lastHostClockNanoseconds else {
      lastHostClockNanoseconds = now
      return
    }
    guard now >= previous else { return }
    lastHostClockNanoseconds = now
    let elapsed = now - previous
    let wholeTicks = elapsed / 100
    let fractionalNanoseconds = hostClockNanosecondRemainder + elapsed % 100
    let ticks = wholeTicks &+ fractionalNanoseconds / 100
    hostClockNanosecondRemainder = fractionalNanoseconds % 100
    guard ticks > 0 else { return }
    advanceClocks(by: ticks)
    advanceTSCs(byMachineTicks: ticks)
  }

  private func scaledDeviceTicks(
    machineTicks: UInt64,
    frequencyHz: UInt64,
    remainder: inout UInt64
  ) -> UInt64 {
    let wholeSeconds = machineTicks / Self.machineClockFrequencyHz
    let fractionalMachineTicks = machineTicks % Self.machineClockFrequencyHz
    // Split both factors before multiplying: the fractional product is below 10^14
    // even for an arbitrary UInt64 TSC rate. Only the delivered counter may wrap.
    let wholeRate = frequencyHz / Self.machineClockFrequencyHz
    let fractionalRate = frequencyHz % Self.machineClockFrequencyHz
    let fractional = remainder + fractionalMachineTicks * fractionalRate
    remainder = fractional % Self.machineClockFrequencyHz
    return machineTicks &* wholeRate &+ wholeSeconds &* fractionalRate
      &+ fractional / Self.machineClockFrequencyHz
  }

  private func machineTicks(
    untilDeviceTicks deviceTicks: UInt64,
    frequencyHz: UInt64,
    remainder: UInt64
  ) -> UInt64 {
    guard deviceTicks > 0 else { return 0 }
    let numerator = deviceTicks &* Self.machineClockFrequencyHz
    guard numerator > remainder else { return 1 }
    let remaining = numerator - remainder
    return (remaining &+ frequencyHz - 1) / frequencyHz
  }

  private func ticksUntilNextAcceptedInterrupt() -> UInt64? {
    var deadlines: [UInt64] = []
    for (index, apic) in localAPICs.enumerated() {
      guard let state = loadedStates[index]?.value else { continue }
      let timer = apic.snapshot().timer
      if !timer.masked, timer.currentCount > 0,
        apic.canAccept(
          vector: timer.vector,
          interruptsEnabled: state.rflags.contains(.interruptEnable),
          externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
        )
      {
        if let baseClockTicks = apic.baseClockTicksUntilTimerExpiration() {
          deadlines.append(
            machineTicks(
              untilDeviceTicks: baseClockTicks,
              frequencyHz: Self.localAPICClockFrequencyHz,
              remainder: localAPICClockRemainder
            )
          )
        }
      }
    }
    if let bsp = loadedStates[0]?.value {
      let interruptsEnabled = bsp.rflags.contains(.interruptEnable)
      let pit = legacyPIT.snapshot()
      let picAcceptsTimer = legacyPIC.canAccept(irq: 0, interruptsEnabled: interruptsEnabled)
      let ioAPICAcceptsTimer = ioAPICCanAccept(pin: 2)
      if pit.armed, pit.current > 0, picAcceptsTimer || ioAPICAcceptsTimer {
        deadlines.append(
          machineTicks(
            untilDeviceTicks: UInt64(pit.current),
            frequencyHz: Self.pitFrequencyHz,
            remainder: pitClockRemainder
          )
        )
      }
      if let ticks = rtc.ticksUntilNextInterrupt(), ticks > 0,
        legacyPIC.canAccept(irq: 8, interruptsEnabled: interruptsEnabled)
          || ioAPICCanAccept(pin: 8)
      {
        deadlines.append(
          machineTicks(
            untilDeviceTicks: ticks,
            frequencyHz: DoryPCRTC146818.oscillatorFrequency,
            remainder: rtcClockRemainder
          )
        )
      }
      for deadline in hpet.interruptDeadlines() {
        let picAccepts: Bool
        if case .legacyIRQ(let irq) = deadline.route {
          picAccepts = legacyPIC.canAccept(irq: irq, interruptsEnabled: interruptsEnabled)
        } else {
          picAccepts = false
        }
        if picAccepts || ioAPICCanAccept(pin: Self.ioAPICPin(forHPETRoute: deadline.route)) {
          deadlines.append(deadline.ticks)
        }
      }
    }
    return deadlines.min()
  }

  private static func ioAPICPin(forHPETRoute route: DoryPCHPETInterruptRoute) -> Int {
    switch route {
    // Match the PIT source and the IRQ0 -> GSI2 override in DoryPC-v1's MADT.
    case .legacyIRQ(0): 2
    case .legacyIRQ(let irq): Int(irq)
    case .ioAPICPin(let pin): pin
    }
  }

  private func ioAPICCanAccept(pin: Int) -> Bool {
    guard let route = try? ioAPIC.route(for: pin), !route.masked,
      let index = processorIndex(route.destinationAPICID),
      let state = loadedStates[index]?.value
    else { return false }
    return localAPICs[index].canAccept(
      vector: route.vector,
      interruptsEnabled: state.rflags.contains(.interruptEnable),
      externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
    )
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
        let coherentTSC = loadedStates[0]?.value.tsc ?? loadedStates[index]?.value.tsc ?? 0
        processorLifecycles[index] = .waitingForStartup
        var state = applicationProcessorResetState()
        state.tsc = coherentTSC
        loadedStates[index] = ProcessorState(state)
        haltedProcessors[index] = true
        pendingNMIs.remove(index)
      case .startup(let apicID, let vector):
        guard let index = processorIndex(apicID) else { continue }
        processorLifecycles[index] = .running
        var state = applicationProcessorResetState()
        state.tsc = loadedStates[0]?.value.tsc ?? loadedStates[index]?.value.tsc ?? 0
        state.rip = 0
        state.cs = .init(
          selector: UInt16(vector) << 8,
          attributes: 0x009B,
          limit: 0xFFFF,
          base: UInt64(vector) << 12
        )
        loadedStates[index] = ProcessorState(state)
        haltedProcessors[index] = false
      case .nonMaskableInterrupt(let apicID):
        if let index = processorIndex(apicID) { pendingNMIs.insert(index) }
      }
    }
  }

  private func deliverPendingInterrupts(instructionCount: UInt64) -> DoryPCMachineStop? {
    for index in loadedStates.indices {
      guard let processorState = loadedStates[index],
        processorLifecycles[index] == .running
      else { continue }
      let source: DoryX86InterruptSource
      let vector: UInt8?
      if pendingNMIs.remove(index) != nil {
        source = .nonMaskable
        vector = 2
      } else {
        source = .externalMaskable
        let enabled = processorState.value.rflags.contains(.interruptEnable)
        vector =
          localAPICs[index].acknowledge(
            interruptsEnabled: enabled,
            externalPriority: UInt8(truncatingIfNeeded: processorState.value.control.cr8) << 4
          ) ?? (index == 0 ? legacyPIC.acknowledge(interruptsEnabled: enabled) : nil)
      }
      guard let vector else { continue }
      do {
        try DoryX86InterruptDelivery().deliver(
          vector: vector,
          source: source,
          state: &processorState.value,
          physicalMemory: physicalMemories[index],
          pagingUnit: pagingUnits[index],
          mode: executionMode(processorState.value)
        )
        haltedProcessors[index] = false
      } catch {
        return .tripleFault(
          source: .interrupt(vector: vector, source: source, processor: index),
          instructionCount: instructionCount
        )
      }
    }
    return nil
  }

  private func nextRunnableProcessor() -> Int? {
    for displacement in 0..<processorCount {
      let index = (roundRobinCursor + displacement) % processorCount
      guard loadedStates[index] != nil, !haltedProcessors[index],
        processorLifecycles[index] == .running
      else { continue }
      roundRobinCursor = (index + 1) % processorCount
      return index
    }
    return nil
  }

  private func waitForNextInterrupt() -> Bool {
    guard let ticks = ticksUntilNextAcceptedInterrupt() else { return false }
    if clockSource.monotonicNanoseconds != nil {
      // Keep cancellation and lifecycle supervision responsive while a guest is halted. The next
      // run-loop pass samples real elapsed time and delivers the interrupt once its deadline is
      // reached; production time is never synthesized from translator throughput.
      let nanoseconds = min(ticks, 10_000) * 100
      if nanoseconds > 0 {
        Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
      }
      synchronizeHostClock()
      return true
    }
    advanceClocks(by: ticks)
    advanceTSCs(byMachineTicks: ticks)
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
    return state.cs.attributes & 0x4000 == 0 ? .protected16 : .protected32
  }
}

private final class DoryPCPCIINTxRouter: @unchecked Sendable {
  private let ioAPIC: DoryPCIOAPIC
  private let lock = NSLock()
  private var sourcesByLine: [Int: Set<ObjectIdentifier>] = [:]

  init(ioAPIC: DoryPCIOAPIC) {
    self.ioAPIC = ioAPIC
  }

  func setAsserted(_ asserted: Bool, line: Int, source: ObjectIdentifier) {
    guard (0..<ioAPIC.pinCount).contains(line) else { return }
    let transition: Bool? = lock.withLock {
      let wasAsserted = !(sourcesByLine[line] ?? []).isEmpty
      if asserted {
        sourcesByLine[line, default: []].insert(source)
      } else {
        sourcesByLine[line]?.remove(source)
        if sourcesByLine[line]?.isEmpty == true { sourcesByLine[line] = nil }
      }
      let isAsserted = !(sourcesByLine[line] ?? []).isEmpty
      return wasAsserted == isAsserted ? nil : isAsserted
    }
    if let transition { try? ioAPIC.setAsserted(transition, pin: line) }
  }
}
