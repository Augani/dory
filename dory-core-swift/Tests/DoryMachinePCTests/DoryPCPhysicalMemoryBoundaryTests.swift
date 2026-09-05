import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPhysicalMemoryBoundaryTests {
  private func backing(mmap: Bool, base: UInt64 = 0, count: Int = 0x2000) throws
    -> any DoryX86PhysicalRAM
  {
    if mmap { return try DoryX86MmapMemory(baseAddress: base, byteCount: count) }
    return try DoryX86ByteArrayMemory(baseAddress: base, validatingByteCount: count)
  }

  @Test(arguments: [false, true])
  func crossDeviceBoundaryPreservesAccessKindBeforeAnyDeviceEffect(mmap: Bool) throws {
    let ram = try backing(mmap: mmap)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let device = BoundaryMMIO(baseAddress: 0x1000, byteCount: 0x10)
    try bus.attach(device)
    let address = device.baseAddress + device.byteCount - 1
    let read = DoryX86MemoryError.unmapped(address: address, byteCount: 2, access: .read)
    let write = DoryX86MemoryError.unmapped(address: address, byteCount: 2, access: .write)
    let fetch = DoryX86MemoryError.unmapped(
      address: address, byteCount: 2, access: .instructionFetch)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      #expect(throws: read) { try bus.read(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.readScalar(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.readRestartableScalar(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.validateRead(at: address, byteCount: 2) }
      #expect(throws: write) { try bus.write(at: address, bytes: [1, 2]) }
      #expect(throws: write) { try bus.writeScalar(at: address, value: 0x0201, byteCount: 2) }
      #expect(throws: write) { try bus.validateWrite(at: address, byteCount: 2) }
      #expect(throws: fetch) { try bus.codeGeneration(at: address, byteCount: 2) }
      #expect(throws: read) {
        try bus.validateDMA(at: address, byteCount: 2, deviceWillWrite: false)
      }
      #expect(throws: write) {
        try bus.validateDMA(at: address, byteCount: 2, deviceWillWrite: true)
      }
      #expect(device.accesses == 0)
      #expect(try ram.read(at: 0, byteCount: ram.byteCount) == Array(repeating: 0, count: ram.byteCount))
    }
  }

  @Test(arguments: [false, true])
  func executableMappingLargerThanIntDoesNotOverflowBoundedFetch(mmap: Bool) throws {
    let bus = try DoryPCPhysicalMemoryBus(ram: backing(mmap: mmap))
    let device = BoundaryMMIO(baseAddress: 0x8000, byteCount: UInt64(Int.max) + 1)
    try bus.attach(device)
    let lastAddress = device.baseAddress + device.byteCount - 1
    for sealed in [false, true] {
      if sealed { bus.seal() }
      #expect(try bus.instructionBytes(at: device.baseAddress, maximumCount: 15)
        == Array(repeating: 0x90, count: 15))
      #expect(try bus.instructionBytes(at: lastAddress, maximumCount: 15) == [0x90])
      #expect(try bus.instructionBytes(at: lastAddress, maximumCount: 0).isEmpty)
    }
    #expect(device.accesses == 4)
  }

  @Test(arguments: [false, true])
  func relocatedRAMMustFitItsCompletePhysicalAddressRange(mmap: Bool) throws {
    let ram = try backing(mmap: mmap)
    let high = UInt64.max - 0x0FFF
    #expect(throws: DoryPCPhysicalMemoryError.invalidRAMConfiguration(
      base: 0, byteCount: 0x2000, mmioHoleStart: 0x1000, above4GRAMStart: high)) {
      try DoryPCPhysicalMemoryBus(ram: ram, mmioHoleStart: 0x1000, above4GRAMStart: high)
    }
    // The adjacent non-overflowing configuration remains byte-exact at its last mapped byte.
    let bus = try DoryPCPhysicalMemoryBus(
      ram: ram, mmioHoleStart: 0x1000, above4GRAMStart: high - 1)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      try bus.writeScalar(at: UInt64.max - 1, value: 0x5A, byteCount: 1)
      #expect(try bus.readScalar(at: UInt64.max - 1, byteCount: 1) == 0x5A)
      #expect(try ram.readScalar(at: 0x1FFF, byteCount: 1) == 0x5A)
      #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 1)) {
        try bus.read(at: .max, byteCount: 1)
      }
    }
  }

  @Test(arguments: [false, true])
  func readValidationUsesExactLogicalBytesAndPreservesFaults(mmap: Bool) throws {
    let base: UInt64 = 0x123
    let ram = try backing(mmap: mmap, base: base, count: 4097)
    #expect(ram.baseAddress == base && ram.byteCount == 4097)
    #expect(try ram.read(at: base + 4095, byteCount: 2) == [0, 0])
    try ram.write(at: base + 4095, bytes: [0xA5, 0x5A])
    let generation = try ram.codeGeneration(at: base + 4095, byteCount: 2)
    try ram.validateRead(at: base, byteCount: ram.byteCount)
    try ram.validateRead(at: .max, byteCount: 0)
    for count in [Int.min, -1] {
      #expect(throws: DoryX86MemoryError.addressOverflow(address: base, byteCount: count)) {
        try ram.validateRead(at: base, byteCount: count)
      }
    }
    #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 1)) {
      try ram.validateRead(at: .max, byteCount: 1)
    }
    for address in [base - 1, base + 4097] {
      #expect(throws: DoryX86MemoryError.unmapped(address: address, byteCount: 1, access: .read)) {
        try ram.validateRead(at: address, byteCount: 1)
      }
    }
    #expect(throws: DoryX86MemoryError.unmapped(address: base, byteCount: 4098, access: .read)) {
      try ram.validateRead(at: base, byteCount: 4098)
    }
    #expect(try ram.codeGeneration(at: base + 4095, byteCount: 2) == generation)
    #expect(try ram.read(at: base + 4095, byteCount: 2) == [0xA5, 0x5A])
  }

  @Test(arguments: [false, true])
  func DMAReadPreflightDoesNotMaterializeOrReadThePayload(mmap: Bool) throws {
    let memory = BoundaryCountingRAM(try backing(mmap: mmap))
    let bus = try DoryPCPhysicalMemoryBus(ram: memory)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      try bus.validateDMA(at: 0, byteCount: memory.byteCount, deviceWillWrite: false)
      try bus.validateDMA(at: 0, byteCount: memory.byteCount, deviceWillWrite: true)
    }
    #expect(memory.readCalls == 0)
    #expect(memory.readValidations == 2)
    #expect(memory.writeValidations == 2)
  }

  @Test(arguments: [false, true])
  func MMIOReadPreflightUsesDeviceValidationWithoutReadingARegister(mmap: Bool) throws {
    let bus = try DoryPCPhysicalMemoryBus(ram: backing(mmap: mmap))
    let device = BoundaryMMIO(baseAddress: 0x4000, byteCount: 0x100)
    try bus.attach(device)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      try bus.validateRead(at: device.baseAddress + 4, byteCount: 4)
    }
    #expect(device.reads == 0)
    #expect(device.readValidations == 2)
    #expect(device.accesses == 2)
  }


  @Test func atomicCompareExchangeRoutesOnlyOrdinaryRAMAndHighRAM() throws {
    let ram = try DoryX86ByteArrayMemory(byteCount: 0x3000)
    let bus = try DoryPCPhysicalMemoryBus(
      ram: ram,
      mmioHoleStart: 0x1000,
      above4GRAMStart: 0x1_0000_0000
    )
    let device = BoundaryMMIO(baseAddress: 0x800, byteCount: 0x100)
    try bus.attach(device)
    bus.seal()

    try ram.writeScalar(at: 0x100, value: 0x1111_2222, byteCount: 4)
    #expect(try bus.compareExchangeScalar(
      at: 0x100, expected: 0x1111_2222, desired: 0x3333_4444, byteCount: 4) == 0x1111_2222)
    #expect(try ram.readScalar(at: 0x100, byteCount: 4) == 0x3333_4444)

    try ram.writeScalar(at: 0x1000, value: 0x55AA, byteCount: 2)
    #expect(try bus.compareExchangeScalar(
      at: 0x1_0000_0000, expected: 0x55AA, desired: 0xAA55, byteCount: 2) == 0x55AA)
    #expect(try ram.readScalar(at: 0x1000, byteCount: 2) == 0xAA55)

    #expect(try bus.compareExchangeScalar(
      at: device.baseAddress, expected: 0, desired: 1, byteCount: 4) == nil)
    #expect(device.accesses == 0)
  }

  @Test func lockedNativeCompareExchangeSharesGateAcrossTranslatedBusViews() throws {
    #if arch(arm64)
      let ram = try GateProbeRAM(
        backing: DoryX86MmapMemory(byteCount: 0x20_000),
        probedAddressRange: 0x9000..<0x9004
      )
      let codeLinear: UInt64 = 0x0040_0000
      let dataLinear: UInt64 = 0x0041_0000
      try installFourLevelMapping(linear: codeLinear, physicalPage: 0x8000, memory: ram.backing)
      try installFourLevelMapping(linear: dataLinear, physicalPage: 0x9000, memory: ram.backing)
      let code: [UInt8] = [0xF0, 0x0F, 0xB1, 0x17] // LOCK CMPXCHG dword ptr [RDI], EDX
      try ram.backing.write(at: 0x8000, bytes: code)
      try ram.backing.writeScalar(at: 0x9000, value: 0, byteCount: 4)

      let nativeBus = try DoryPCPhysicalMemoryBus(ram: ram)
      let interpreterBus = try DoryPCPhysicalMemoryBus(ram: ram)
      nativeBus.seal()
      interpreterBus.seal()
      let context = longModeContext()
      let nativeMemory = DoryX86TranslatedMemory(
        physicalMemory: nativeBus, pagingUnit: DoryX86PagingUnit(), context: context)
      let interpreterMemory = DoryX86TranslatedMemory(
        physicalMemory: interpreterBus, pagingUnit: DoryX86PagingUnit(), context: context)

      let nativeInitial = try machineState(rip: codeLinear, data: dataLinear, expected: 0, desired: 1)
      let interpreterInitial = try machineState(
        rip: codeLinear, data: dataLinear, expected: 1, desired: 2)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)

      ram.blockNextAtomicCompareExchange()
      let unguardedAtomicDone = DispatchSemaphore(value: 0)
      let unguardedAtomicResult = LockedBox<Result<UInt64?, Error>?>(nil)
      DispatchQueue.global().async {
        do {
          let observed = try ram.compareExchangeScalar(
            at: 0x9000, expected: 0, desired: 0, byteCount: 4)
          unguardedAtomicResult.set(.success(observed))
        } catch {
          unguardedAtomicResult.set(.failure(error))
        }
        unguardedAtomicDone.signal()
      }
      try #require(ram.waitForBlockedAtomicCompareExchange())
      #expect(try interpreterMemory.readScalar(at: dataLinear, byteCount: 4) == 0)
      #expect(ram.scalarReadsWhileAtomicBlocked == 1)
      ram.releaseBlockedAtomicCompareExchange()
      #expect(unguardedAtomicDone.wait(timeout: .now() + .seconds(2)) == .success)
      #expect(try #require(unguardedAtomicResult.value).get() == 0)

      let nativeDone = DispatchSemaphore(value: 0)
      let interpreterStarted = DispatchSemaphore(value: 0)
      let interpreterDone = DispatchSemaphore(value: 0)
      let nativeResult = LockedBox<Result<(DoryX86ArchitecturalState, DoryARM64BaselineExecution?), Error>?>(nil)
      let interpreterResult = LockedBox<(DoryX86ArchitecturalState, DoryX86InterpreterResult)?>(nil)

      ram.blockNextAtomicCompareExchange()
      DispatchQueue.global().async {
        var nativeState = nativeInitial
        do {
          let execution = try executor.execute(
            byteProvider: { try nativeMemory.instructionBytes(at: codeLinear, maximumCount: $0) },
            codeGenerationProvider: { try nativeMemory.codeGeneration(at: codeLinear, byteCount: $0) },
            at: codeLinear,
            mode: .long64,
            addressSpaceID: 1,
            maximumInstructions: 1,
            state: &nativeState,
            memory: nativeMemory
          )
          nativeResult.set(.success((nativeState, execution)))
        } catch {
          nativeResult.set(.failure(error))
        }
        nativeDone.signal()
      }
      try #require(ram.waitForBlockedAtomicCompareExchange())

      DispatchQueue.global().async {
        var interpreterState = interpreterInitial
        interpreterStarted.signal()
        let result = DoryX86Interpreter().step(
          state: &interpreterState, memory: interpreterMemory, mode: .long64)
        interpreterResult.set((interpreterState, result))
        interpreterDone.signal()
      }
      try #require(interpreterStarted.wait(timeout: .now() + .seconds(2)) == .success)
      #expect(interpreterDone.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
      #expect(ram.scalarReadsWhileAtomicBlocked == 0)

      ram.releaseBlockedAtomicCompareExchange()
      #expect(nativeDone.wait(timeout: .now() + .seconds(2)) == .success)
      #expect(interpreterDone.wait(timeout: .now() + .seconds(2)) == .success)
      let (nativeState, nativeExecution) = try #require(nativeResult.value).get()
      let (interpreterState, interpreterOutcome) = try #require(interpreterResult.value)
      #expect(nativeExecution?.block.requiresMemoryCallbacks == true)
      #expect(nativeExecution?.block.guestInstructionCount == 1)
      if case .retired = interpreterOutcome {} else {
        Issue.record("interpreter locked CMPXCHG did not retire after native gate release")
      }
      #expect(try ram.backing.readScalar(at: 0x9000, byteCount: 4) == 2)
      #expect(nativeState.rflags.contains(.zero))
      #expect(interpreterState.rflags.contains(.zero))
    #endif
  }

  @Test func defaultReadValidationPreservesCustomReadDenial() throws {
    let memory = BoundaryReadDeniedMemory()
    // A writable custom memory object must not acquire read permission through write validation.
    try memory.validateWrite(at: 0, byteCount: 8)
    #expect(throws: DoryX86MemoryError.unmapped(address: 0, byteCount: 8, access: .read)) {
      try memory.validateRead(at: 0, byteCount: 8)
    }
  }

  @Test(arguments: [false, true])
  func sealedBusReleasesItsOwnedBackingAndDevices(mmap: Bool) throws {
    weak var observedRAM: (any DoryX86PhysicalRAM)?
    weak var observedDevice: BoundaryMMIO?
    var retainedBus: DoryPCPhysicalMemoryBus?
    do {
      let ram = try backing(mmap: mmap)
      let device = BoundaryMMIO(baseAddress: 0x1000, byteCount: 0x100)
      let bus = try DoryPCPhysicalMemoryBus(ram: ram)
      try bus.attach(device)
      bus.seal()
      observedRAM = ram
      observedDevice = device
      retainedBus = bus
    }
    #expect(observedRAM != nil && observedDevice != nil)
    withExtendedLifetime(retainedBus) {}
    retainedBus = nil
    #expect(observedRAM == nil && observedDevice == nil)
  }


  private func installFourLevelMapping(
    linear: UInt64,
    physicalPage: UInt64,
    memory: any DoryX86PhysicalRAM
  ) throws {
    let pml4Index = (linear >> 39) & 0x1ff
    let pdptIndex = (linear >> 30) & 0x1ff
    let pdIndex = (linear >> 21) & 0x1ff
    let ptIndex = (linear >> 12) & 0x1ff
    try write64(memory, 0x1000 + pml4Index * 8, 0x2000 | 0x7)
    try write64(memory, 0x2000 + pdptIndex * 8, 0x3000 | 0x7)
    try write64(memory, 0x3000 + pdIndex * 8, 0x4000 | 0x7)
    try write64(memory, 0x4000 + ptIndex * 8, physicalPage | 0x7)
  }

  private func write64(_ memory: any DoryX86Memory, _ address: UInt64, _ value: UInt64) throws {
    try memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })
  }

  private func longModeContext() -> DoryX86PagingContext {
    .init(
      control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: 1 << 5, efer: (1 << 10) | (1 << 11)),
      rflags: .reset,
      currentPrivilegeLevel: 0,
      mode: .long64
    )
  }

  private func machineState(
    rip: UInt64,
    data: UInt64,
    expected: UInt64,
    desired: UInt64
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: expected, rdx: desired, rdi: data),
      rip: rip,
      rflags: [.reservedOne, .carry, .sign],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: 1 << 5, efer: (1 << 10) | (1 << 11))
    )
  }

}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    lock.withLock { storage }
  }

  func set(_ value: Value) {
    lock.withLock { storage = value }
  }
}

private final class BoundaryMMIO: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64
  let allowsInstructionFetch = true
  private let lock = NSLock()
  private var counts = (all: 0, reads: 0, readValidations: 0)
  var accesses: Int { lock.withLock { counts.all } }
  var reads: Int { lock.withLock { counts.reads } }
  var readValidations: Int { lock.withLock { counts.readValidations } }
  init(baseAddress: UInt64, byteCount: UInt64) {
    self.baseAddress = baseAddress
    self.byteCount = byteCount
  }
  private func record() { lock.withLock { counts.all += 1 } }
  private func recordRead() { lock.withLock { counts.all += 1; counts.reads += 1 } }
  private func recordReadValidation() {
    lock.withLock { counts.all += 1; counts.readValidations += 1 }
  }
  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    recordRead()
    return Array(repeating: 0x90, count: byteCount)
  }
  func validateRead(offset: UInt64, byteCount: Int) throws { recordReadValidation() }
  func readRestartableScalar(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func codeGeneration(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func write(offset: UInt64, bytes: [UInt8]) throws { record() }
  func validateWrite(offset: UInt64, byteCount: Int) throws { record() }
}

private final class BoundaryCountingRAM: DoryX86PhysicalRAM, @unchecked Sendable {
  let backing: any DoryX86PhysicalRAM
  var baseAddress: UInt64 { backing.baseAddress }
  var byteCount: Int { backing.byteCount }
  private let lock = NSLock()
  private var counts = (reads: 0, readValidations: 0, writeValidations: 0)
  var readCalls: Int { lock.withLock { counts.reads } }
  var readValidations: Int { lock.withLock { counts.readValidations } }
  var writeValidations: Int { lock.withLock { counts.writeValidations } }
  init(_ backing: any DoryX86PhysicalRAM) { self.backing = backing }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    lock.withLock { counts.reads += 1 }
    return try backing.read(at: address, byteCount: byteCount)
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    lock.withLock { counts.readValidations += 1 }
    try backing.validateRead(at: address, byteCount: byteCount)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    lock.withLock { counts.writeValidations += 1 }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws { try backing.write(at: address, bytes: bytes) }
  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.readRestartableScalar(at: address, byteCount: byteCount)
  }
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.codeGeneration(at: address, byteCount: byteCount)
  }
  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    backing.bulkCopyRAMSpan(at: address, maximumByteCount: maximumByteCount)
  }
  func copyForwardNonoverlapping(
    from sourceAddress: UInt64, to destinationAddress: UInt64, maximumByteCount: Int
  ) throws -> Int? {
    try backing.copyForwardNonoverlapping(
      from: sourceAddress, to: destinationAddress, maximumByteCount: maximumByteCount)
  }
}

private final class GateProbeRAM: DoryX86PhysicalRAM, DoryX86AtomicScalarMemory, @unchecked Sendable {
  let backing: any DoryX86PhysicalRAM & DoryX86AtomicScalarMemory
  var baseAddress: UInt64 { backing.baseAddress }
  var byteCount: Int { backing.byteCount }
  private let lock = NSLock()
  private let probedAddressRange: Range<UInt64>
  private var shouldBlockAtomic = false
  private var blockedAtomic = false
  private var scalarReadsDuringBlock = 0
  private var entered = DispatchSemaphore(value: 0)
  private var release = DispatchSemaphore(value: 0)

  var scalarReadsWhileAtomicBlocked: Int { lock.withLock { scalarReadsDuringBlock } }

  init(
    backing: any DoryX86PhysicalRAM & DoryX86AtomicScalarMemory,
    probedAddressRange: Range<UInt64>
  ) {
    self.backing = backing
    self.probedAddressRange = probedAddressRange
  }

  func blockNextAtomicCompareExchange() {
    lock.withLock {
      shouldBlockAtomic = true
      blockedAtomic = false
      scalarReadsDuringBlock = 0
      entered = DispatchSemaphore(value: 0)
      release = DispatchSemaphore(value: 0)
    }
  }

  func waitForBlockedAtomicCompareExchange() -> Bool {
    entered.wait(timeout: .now() + .seconds(2)) == .success
  }

  func releaseBlockedAtomicCompareExchange() { release.signal() }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    let upper = address.addingReportingOverflow(UInt64(byteCount))
    lock.withLock {
      if blockedAtomic, !upper.overflow, address < probedAddressRange.upperBound,
        probedAddressRange.lowerBound < upper.partialValue
      {
        scalarReadsDuringBlock += 1
      }
    }
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.readRestartableScalar(at: address, byteCount: byteCount)
  }

  func compareExchangeScalar(
    at address: UInt64, expected: UInt64, desired: UInt64, byteCount: Int
  ) throws -> UInt64? {
    let shouldBlock = lock.withLock { () -> Bool in
      guard shouldBlockAtomic else { return false }
      shouldBlockAtomic = false
      blockedAtomic = true
      return true
    }
    if shouldBlock {
      entered.signal()
      _ = release.wait(timeout: .now() + .seconds(2))
      lock.withLock { blockedAtomic = false }
    }
    return try backing.compareExchangeScalar(
      at: address, expected: expected, desired: desired, byteCount: byteCount)
  }

  func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.codeGeneration(at: address, byteCount: byteCount)
  }

  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    backing.bulkCopyRAMSpan(at: address, maximumByteCount: maximumByteCount)
  }

  func copyForwardNonoverlapping(
    from sourceAddress: UInt64, to destinationAddress: UInt64, maximumByteCount: Int
  ) throws -> Int? {
    try backing.copyForwardNonoverlapping(
      from: sourceAddress, to: destinationAddress, maximumByteCount: maximumByteCount)
  }
}

private final class BoundaryReadDeniedMemory: DoryX86Memory, @unchecked Sendable {
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: maximumCount, access: .instructionFetch)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {}
  func validateWrite(at address: UInt64, byteCount: Int) throws {}
}
