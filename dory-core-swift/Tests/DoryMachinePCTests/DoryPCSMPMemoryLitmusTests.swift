import DoryDBTX86
import DoryVirtio
import Foundation
import Testing

@testable import DoryMachinePC

/// Guest-code memory-order cells for internally admitted interpreter, baseline-JIT and mixed
/// owners. Repeated interpreter cells reset data only while owners are joined; native/mixed cells
/// use a fresh one-shot machine so unequal dispatch boundaries cannot contaminate a later trial.
/// These cells do not by themselves qualify public SMP.
@Suite(.serialized) struct DoryPCSMPMemoryLitmusTests {
  private let iterations = 2_000
  private let x: UInt32 = 0x3000
  private let y: UInt32 = 0x3004
  private let payload: UInt32 = 0x3008
  private let flag: UInt32 = 0x300C

  @Test func storeBufferingRecordsThePermittedOutcomeWithoutInventingValues() throws {
    let machine = try makeMachine(
      bsp: loop([
        store(x, 1),
        loadEAX(y),
      ]),
      ap: loop([
        store(y, 1),
        loadEAX(x),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    var outcomes: [UInt64: Int] = [:]

    for _ in 0..<iterations {
      try zero([x, y], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      let first = try register(.rax, processor: 0, in: machine)
      let second = try register(.rax, processor: 1, in: machine)
      #expect(first <= 1)
      #expect(second <= 1)
      outcomes[first << 1 | second, default: 0] += 1
    }

    #expect(outcomes.values.reduce(0, +) == iterations)
    #expect(overlap.maximumActive == 2)
  }

  @Test func loadBufferingForbidsBothLoadsReadingFutureStores() throws {
    let machine = try makeMachine(
      bsp: loop([
        loadEAX(y),
        store(x, 1),
      ]),
      ap: loop([
        loadEAX(x),
        store(y, 1),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([x, y], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      let first = try register(.rax, processor: 0, in: machine)
      let second = try register(.rax, processor: 1, in: machine)
      #expect(first <= 1)
      #expect(second <= 1)
      #expect(!(first == 1 && second == 1))
    }

    #expect(overlap.maximumActive == 2)
  }

  @Test func messagePassingNeverPublishesFlagBeforePayload() throws {
    let machine = try makeMachine(
      bsp: loop([
        store(payload, 1),
        store(flag, 1),
      ]),
      ap: loop([
        loadEAX(flag),
        loadEBX(payload),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([payload, flag], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      let observedFlag = try register(.rax, processor: 1, in: machine)
      let observedPayload = try register(.rbx, processor: 1, in: machine)
      #expect(observedFlag <= 1)
      #expect(observedPayload <= 1)
      if observedFlag == 1 { #expect(observedPayload == 1) }
    }

    #expect(overlap.maximumActive == 2)
  }

  @Test func twoNativeOwnersPreserveMessagePublicationOrder() throws {
    #if arch(arm64)
      for _ in 0..<128 {
        let machine = try makeMachine(
          bsp: oneShot([store(payload, 1), store(flag, 1)]),
          ap: oneShot([loadEAX(flag), loadEBX(payload)]),
          tier: .baselineJIT
        )
        let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
        let overlap = LitmusOverlapProbe()
        machine.observeWorkers { overlap.observe($0) }
        #expect(try machine.run(maximumInstructions: 16) == .instructionBudget(16))
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_0014)
        #expect(machine.state(forProcessor: 1)?.rip == 0x900B)
        let observedFlag = try register(.rax, processor: 1, in: machine)
        let observedPayload = try register(.rbx, processor: 1, in: machine)
        #expect(observedFlag <= 1 && observedPayload <= 1)
        if observedFlag == 1 { #expect(observedPayload == 1) }
        let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
        #expect(nativeAfter.count == 2)
        #expect(nativeAfter[0] > nativeBefore[0])
        #expect(nativeAfter[1] > nativeBefore[1])
        #expect(overlap.maximumActive == 2)
      }
    #endif
  }

  @Test(arguments: [0, 1])
  func mixedNativeAndInterpreterOwnersPreservePublicationOrder(
    interpreterProcessor: Int
  ) throws {
    #if arch(arm64)
      for _ in 0..<128 {
        let machine = try makeMachine(
          bsp: oneShot([store(payload, 1), store(flag, 1)]),
          ap: oneShot([loadEAX(flag), loadEBX(payload)]),
          tier: .baselineJIT,
          interpreterOnlyProcessor: interpreterProcessor
        )
        let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
        let overlap = LitmusOverlapProbe()
        machine.observeWorkers { overlap.observe($0) }
        #expect(try machine.run(maximumInstructions: 16) == .instructionBudget(16))
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_0014)
        #expect(machine.state(forProcessor: 1)?.rip == 0x900B)
        let observedFlag = try register(.rax, processor: 1, in: machine)
        let observedPayload = try register(.rbx, processor: 1, in: machine)
        #expect(observedFlag <= 1 && observedPayload <= 1)
        if observedFlag == 1 { #expect(observedPayload == 1) }
        let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
        #expect(nativeAfter.count == 2)
        #expect(nativeAfter[interpreterProcessor] == nativeBefore[interpreterProcessor])
        #expect(nativeAfter[1 - interpreterProcessor] > nativeBefore[1 - interpreterProcessor])
        #expect(machine.executionStatistics.interpreterInstructions > 0)
        #expect(overlap.maximumActive == 2)
      }
    #endif
  }

  @Test func twoNativeOwnersForbidLoadBufferingFromTheFuture() throws {
    #if arch(arm64)
      for _ in 0..<128 {
        let machine = try makeMachine(
          bsp: oneShot([loadEAX(y), store(x, 1)]),
          ap: oneShot([loadEAX(x), store(y, 1)]),
          tier: .baselineJIT
        )
        let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
        let overlap = LitmusOverlapProbe()
        machine.observeWorkers { overlap.observe($0) }
        #expect(try machine.run(maximumInstructions: 16) == .instructionBudget(16))
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_000F)
        #expect(machine.state(forProcessor: 1)?.rip == 0x900F)
        let first = try register(.rax, processor: 0, in: machine)
        let second = try register(.rax, processor: 1, in: machine)
        #expect(first <= 1 && second <= 1)
        #expect(!(first == 1 && second == 1))
        let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
        #expect(nativeAfter[0] > nativeBefore[0])
        #expect(nativeAfter[1] > nativeBefore[1])
        #expect(overlap.maximumActive == 2)
      }
    #endif
  }

  @Test(arguments: [0, 1])
  func mixedNativeAndInterpreterOwnersForbidLoadBufferingFromTheFuture(
    interpreterProcessor: Int
  ) throws {
    #if arch(arm64)
      for _ in 0..<128 {
        let machine = try makeMachine(
          bsp: oneShot([loadEAX(y), store(x, 1)]),
          ap: oneShot([loadEAX(x), store(y, 1)]),
          tier: .baselineJIT,
          interpreterOnlyProcessor: interpreterProcessor
        )
        let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
        let overlap = LitmusOverlapProbe()
        machine.observeWorkers { overlap.observe($0) }
        #expect(try machine.run(maximumInstructions: 16) == .instructionBudget(16))
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_000F)
        #expect(machine.state(forProcessor: 1)?.rip == 0x900F)
        let first = try register(.rax, processor: 0, in: machine)
        let second = try register(.rax, processor: 1, in: machine)
        #expect(first <= 1 && second <= 1)
        #expect(!(first == 1 && second == 1))
        let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
        #expect(nativeAfter[interpreterProcessor] == nativeBefore[interpreterProcessor])
        #expect(nativeAfter[1 - interpreterProcessor] > nativeBefore[1 - interpreterProcessor])
        #expect(machine.executionStatistics.interpreterInstructions > 0)
        #expect(overlap.maximumActive == 2)
      }
    #endif
  }

  @Test(arguments: [-1, 0, 1])
  func nativeAndMixedOwnersOrderOrdinaryStoresBeforeLockedExchangeAdd(
    interpreterProcessor: Int
  ) throws {
    #if arch(arm64)
      for _ in 0..<128 {
        let machine = try makeMachine(
          bsp: oneShot([store(payload, 1), store(flag, 1)]),
          ap: oneShot([moveEAX(0), lockedExchangeAddEAX(flag), loadEBX(payload)]),
          tier: .baselineJIT,
          interpreterOnlyProcessor: interpreterProcessor < 0 ? nil : interpreterProcessor
        )
        let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
        let overlap = LitmusOverlapProbe()
        machine.observeWorkers { overlap.observe($0) }
        #expect(try machine.run(maximumInstructions: 16) == .instructionBudget(16))
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_0014)
        #expect(machine.state(forProcessor: 1)?.rip == 0x9013)
        let observedFlag = try register(.rax, processor: 1, in: machine)
        let observedPayload = try register(.rbx, processor: 1, in: machine)
        #expect(observedFlag <= 1 && observedPayload <= 1)
        if observedFlag == 1 { #expect(observedPayload == 1) }
        let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
        if interpreterProcessor < 0 {
          #expect(nativeAfter[0] > nativeBefore[0])
          #expect(nativeAfter[1] > nativeBefore[1])
        } else {
          #expect(nativeAfter[interpreterProcessor] == nativeBefore[interpreterProcessor])
          #expect(nativeAfter[1 - interpreterProcessor] > nativeBefore[1 - interpreterProcessor])
          #expect(machine.executionStatistics.interpreterInstructions > 0)
        }
        #expect(overlap.maximumActive == 2)
      }
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT])
  func independentReadersCannotObserveOppositeWriteOrders(
    tier: DoryPCExecutionTier
  ) throws {
    let machine = try makeQuartetMachine(programs: [
      loop([store(x, 1), [0x90]]),
      loop([store(y, 1), [0x90]]),
      loop([loadEAX(x), loadEBX(y)]),
      loop([loadEAX(y), loadEBX(x)]),
    ], tier: tier)
    let overlap = LitmusOverlapProbe(requiredConcurrentOwners: 4)
    machine.observeWorkers { overlap.observe($0) }
    let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor

    for _ in 0..<iterations {
      try zero([x, y], in: machine)
      #expect(try machine.run(maximumInstructions: 12) == .instructionBudget(12))
      let firstX = try register(.rax, processor: 2, in: machine)
      let firstY = try register(.rbx, processor: 2, in: machine)
      let secondY = try register(.rax, processor: 3, in: machine)
      let secondX = try register(.rbx, processor: 3, in: machine)
      #expect(firstX <= 1 && firstY <= 1 && secondX <= 1 && secondY <= 1)
      #expect(!(firstX == 1 && firstY == 0 && secondY == 1 && secondX == 0))
    }

    #expect(overlap.maximumActive == 4)
    if tier == .baselineJIT {
      let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
      #expect(nativeAfter.count == 4)
      for processor in 0..<4 {
        #expect(nativeAfter[processor] > nativeBefore[processor])
      }
    }
  }

  @Test(arguments: [0, 1, 2, 3])
  func mixedQuartetCannotObserveOppositeWriteOrders(
    interpreterProcessor: Int
  ) throws {
    let machine = try makeQuartetMachine(programs: [
      loop([store(x, 1), [0x90]]),
      loop([store(y, 1), [0x90]]),
      loop([loadEAX(x), loadEBX(y)]),
      loop([loadEAX(y), loadEBX(x)]),
    ], tier: .baselineJIT, interpreterOnlyProcessor: interpreterProcessor)
    let overlap = LitmusOverlapProbe(requiredConcurrentOwners: 4)
    machine.observeWorkers { overlap.observe($0) }
    let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor

    for _ in 0..<512 {
      try zero([x, y], in: machine)
      #expect(try machine.run(maximumInstructions: 12) == .instructionBudget(12))
      let firstX = try register(.rax, processor: 2, in: machine)
      let firstY = try register(.rbx, processor: 2, in: machine)
      let secondY = try register(.rax, processor: 3, in: machine)
      let secondX = try register(.rbx, processor: 3, in: machine)
      #expect(firstX <= 1 && firstY <= 1 && secondX <= 1 && secondY <= 1)
      #expect(!(firstX == 1 && firstY == 0 && secondY == 1 && secondX == 0))
    }

    let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
    #expect(nativeAfter.count == 4)
    for processor in 0..<4 {
      if processor == interpreterProcessor {
        #expect(nativeAfter[processor] == nativeBefore[processor])
      } else {
        #expect(nativeAfter[processor] > nativeBefore[processor])
      }
    }
    #expect(machine.executionStatistics.interpreterInstructions > 0)
    #expect(overlap.maximumActive == 4)
  }

  @Test(arguments: [UInt64(1), 2, 3, 4, 5, 7, 129])
  func quartetPreservesExactSharedInstructionBudget(budget: UInt64) throws {
    let spin = loop([[0x90]])
    let machine = try makeQuartetMachine(programs: [spin, spin, spin, spin])
    #expect(
      try machine.run(maximumInstructions: budget) == .instructionBudget(budget)
    )
  }

  @Test func fullFenceForbidsTheStoreBufferingZeroZeroOutcome() throws {
    let machine = try makeMachine(
      bsp: loop([
        store(x, 1),
        [0x0F, 0xAE, 0xF0],  // mfence
        loadEAX(y),
      ]),
      ap: loop([
        store(y, 1),
        [0x0F, 0xAE, 0xF0],  // mfence
        loadEAX(x),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([x, y], in: machine)
      #expect(try machine.run(maximumInstructions: 8) == .instructionBudget(8))
      let first = try register(.rax, processor: 0, in: machine)
      let second = try register(.rax, processor: 1, in: machine)
      #expect(!(first == 0 && second == 0))
    }

    #expect(overlap.maximumActive == 2)
  }

  @Test func storeFencePublishesOlderStoresBeforeYoungerStores() throws {
    let machine = try makeMachine(
      bsp: loop([
        store(payload, 1),
        [0x0F, 0xAE, 0xF8],  // sfence
        store(flag, 1),
      ]),
      ap: loop([
        loadEAX(flag),
        loadEBX(payload),
        [0x90],  // keep both owners on the same four-instruction loop boundary
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    let synchronizationsBefore = machine.physicalMemories.map {
      $0.diagnostics.synchronizationHelperCalls
    }

    for _ in 0..<iterations {
      try zero([payload, flag], in: machine)
      #expect(try machine.run(maximumInstructions: 8) == .instructionBudget(8))
      let observedFlag = try register(.rax, processor: 1, in: machine)
      let observedPayload = try register(.rbx, processor: 1, in: machine)
      #expect(observedFlag <= 1)
      #expect(observedPayload <= 1)
      if observedFlag == 1 { #expect(observedPayload == 1) }
    }

    let synchronizationsAfter = machine.physicalMemories.map {
      $0.diagnostics.synchronizationHelperCalls
    }
    #expect(
      synchronizationsAfter
        == [synchronizationsBefore[0] + UInt64(iterations), synchronizationsBefore[1]])
    #expect(overlap.maximumActive == 2)
  }

  @Test func loadFenceOrdersPublicationReadsAtTheProductionMemoryBoundary() throws {
    let machine = try makeMachine(
      bsp: loop([
        store(payload, 1),
        store(flag, 1),
        [0x90],  // keep both owners on the same four-instruction loop boundary
      ]),
      ap: loop([
        loadEAX(flag),
        [0x0F, 0xAE, 0xE8],  // lfence
        loadEBX(payload),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    let synchronizationsBefore = machine.physicalMemories.map {
      $0.diagnostics.synchronizationHelperCalls
    }

    for _ in 0..<iterations {
      try zero([payload, flag], in: machine)
      #expect(try machine.run(maximumInstructions: 8) == .instructionBudget(8))
      let observedFlag = try register(.rax, processor: 1, in: machine)
      let observedPayload = try register(.rbx, processor: 1, in: machine)
      #expect(observedFlag <= 1)
      #expect(observedPayload <= 1)
      if observedFlag == 1 { #expect(observedPayload == 1) }
    }

    let synchronizationsAfter = machine.physicalMemories.map {
      $0.diagnostics.synchronizationHelperCalls
    }
    #expect(
      synchronizationsAfter
        == [synchronizationsBefore[0], synchronizationsBefore[1] + UInt64(iterations)])
    #expect(overlap.maximumActive == 2)
  }

  @Test(arguments: [UInt32(0x3000), UInt32(0x3FFF)])
  func implicitLockedExchangeHasOneTotalOrder(address: UInt32) throws {
    let machine = try makeMachine(
      bsp: loop([
        moveEAX(1),
        exchangeEAX(address),
      ]),
      ap: loop([
        moveEAX(2),
        exchangeEAX(address),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([address], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      let final = try machine.memory.readScalar(at: UInt64(address), byteCount: 4)
      let first = try register(.rax, processor: 0, in: machine)
      let second = try register(.rax, processor: 1, in: machine)
      #expect(
        (final == 1 && first == 2 && second == 0)
          || (final == 2 && first == 0 && second == 1)
      )
    }

    #expect(overlap.maximumActive == 2)
  }

  @Test func lockedExchangeAddCannotLoseConcurrentUpdates() throws {
    let machine = try makeMachine(
      bsp: loop([
        moveEAX(1),
        lockedExchangeAddEAX(x),
      ]),
      ap: loop([
        moveEAX(1),
        lockedExchangeAddEAX(x),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    try zero([x], in: machine)
    let budget: UInt64 = 24_000

    #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
    #expect(
      try machine.memory.readScalar(at: UInt64(x), byteCount: 4)
        == budget / 3
    )
    #expect(overlap.maximumActive == 2)
  }

  @Test(arguments: [UInt32(0x3000), UInt32(0x3FFF)])
  func lockedAddCannotLoseAlignedOrSplitPageUpdates(address: UInt32) throws {
    let machine = try makeMachine(
      bsp: loop([lockedAdd(address, 1)]),
      ap: loop([lockedAdd(address, 1)])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    try zero([address], in: machine)
    let budget: UInt64 = 8_000

    #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
    #expect(try machine.memory.readScalar(at: UInt64(address), byteCount: 4) == budget / 2)
    #expect(overlap.maximumActive == 2)
  }

  @Test(arguments: [UInt32(0x3001), UInt32(0x3FFF)], [-1, 0, 1])
  func ordinaryUnalignedAndSplitPageRAMStaysWithinTheTwoWrittenValues(
    address: UInt32, interpreterProcessor: Int
  ) throws {
    let firstValue: UInt32 = 0xA1B2_C3D4
    let secondValue: UInt32 = 0x1020_3040
    let machine = try makeMachine(
      bsp: loop([store(address, firstValue), loadEAX(address)]),
      ap: loop([store(address, secondValue), loadEAX(address)]),
      tier: .baselineJIT,
      interpreterOnlyProcessor: interpreterProcessor < 0 ? nil : interpreterProcessor
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    let nativeBefore = machine.qualificationBaselineNativeEntriesByProcessor
    try machine.memory.write(at: UInt64(address - 1), bytes: [0x5A])
    try machine.memory.write(at: UInt64(address + 4), bytes: [0xA5])

    for _ in 0..<512 {
      try zero([address], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      for value in [
        try register(.rax, processor: 0, in: machine),
        try register(.rax, processor: 1, in: machine),
        try machine.memory.readScalar(at: UInt64(address), byteCount: 4),
      ] {
        for shift in stride(from: 0, to: 32, by: 8) {
          let byte = UInt8(truncatingIfNeeded: value >> shift)
          let firstByte = UInt8(truncatingIfNeeded: firstValue >> shift)
          let secondByte = UInt8(truncatingIfNeeded: secondValue >> shift)
          #expect(byte == 0 || byte == firstByte || byte == secondByte)
        }
      }
      #expect(try machine.memory.read(at: UInt64(address - 1), byteCount: 1) == [0x5A])
      #expect(try machine.memory.read(at: UInt64(address + 4), byteCount: 1) == [0xA5])
    }

    let nativeAfter = machine.qualificationBaselineNativeEntriesByProcessor
    for processor in 0..<2 {
      if processor == interpreterProcessor {
        #expect(nativeAfter[processor] == nativeBefore[processor])
      } else {
        #expect(nativeAfter[processor] > nativeBefore[processor])
      }
    }
    #expect(overlap.maximumActive == 2)
  }

  @Test func configuredVirtioEntropyDMAInvalidatesTranslatedGuestCode() throws {
    let bar: UInt64 = 0xD000_1000
    let entropy = try DoryPCVirtioEntropyPCIDevice(
      address: .init(bus: 0, device: 3, function: 0),
      initialBARAddress: bar,
      source: ConstantEntropySource(byte: 0x22)
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [entropy],
      executionTier: .baselineJIT
    )
    // mov eax,0x11111111; jmp back to mov. The device overwrites only the immediate.
    try machine.load(
      kernel: makeELF(code: [0xB8, 0x11, 0x11, 0x11, 0x11, 0xEB, 0xF9]),
      commandLine: "x"
    )
    #expect(try machine.run(maximumInstructions: 2_000) == .instructionBudget(2_000))
    #expect(try register(.rax, processor: 0, in: machine) == 0x1111_1111)
    let nativeBeforeDMA = machine.qualificationBaselineNativeEntriesByProcessor[0]
    #expect(nativeBeforeDMA > 0)

    try entropy.writeConfiguration(offset: 4, bytes: [2, 0])
    try machine.physicalMemory.write(at: bar + 0x08, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x0C, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x14, bytes: [0x0F])
    try machine.physicalMemory.write(at: bar + 0x18, bytes: [8, 0])
    try machine.physicalMemory.write(at: bar + 0x20, bytes: littleEndian64(0x18_000))
    try machine.physicalMemory.write(at: bar + 0x28, bytes: littleEndian64(0x19_000))
    try machine.physicalMemory.write(at: bar + 0x30, bytes: littleEndian64(0x1A_000))
    try machine.physicalMemory.write(at: bar + 0x1C, bytes: [1, 0])
    try machine.physicalMemory.write(
      at: 0x18_000,
      bytes: littleEndian64(0x10_0001) + littleEndian(UInt32(4)) + [2, 0, 0, 0]
    )
    try machine.physicalMemory.write(at: 0x19_000, bytes: [0, 0, 1, 0, 0, 0])
    try machine.physicalMemory.write(at: bar + 0x100, bytes: [0, 0])

    #expect(try machine.physicalMemory.read(at: 0x10_0001, byteCount: 4)
      == [0x22, 0x22, 0x22, 0x22])
    #expect(try machine.physicalMemory.read(at: 0x1A_002, byteCount: 2) == [1, 0])
    #expect(try machine.run(maximumInstructions: 2_000) == .instructionBudget(2_000))
    #expect(try register(.rax, processor: 0, in: machine) == 0x2222_2222)
    #expect(machine.qualificationBaselineNativeEntriesByProcessor[0] > nativeBeforeDMA)
  }

  @Test func configuredVirtioEntropyDMAFailsClosedForTrackedPageTableWrites() throws {
    let bar: UInt64 = 0xD000_1000
    let entropy = try DoryPCVirtioEntropyPCIDevice(
      address: .init(bus: 0, device: 3, function: 0),
      initialBARAddress: bar,
      source: ConstantEntropySource(byte: 0x22)
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [entropy],
      executionTier: .baselineJIT
    )
    // A control-thread kick is not owned by the vCPU. It must reject a tracked PTE target
    // without a partial DMA write or completion; only the sole dispatch owner can publish inline.
    try machine.load(
      kernel: makeELF(code: protectedPagingSetup() + [
        0xA1, 0x00, 0x00, 0x40, 0x00,  // mov eax,[0x400000]
        0xEB, 0xF9,  // jmp back to the read
      ]),
      commandLine: "x"
    )
    try installLegacyPageTables(in: machine)
    try machine.memory.writeScalar(at: 0x3000, value: 0x1111, byteCount: 4)
    try machine.memory.writeScalar(at: 0x4000, value: 0x2222, byteCount: 4)
    #expect(try machine.run(maximumInstructions: 2_000) == .instructionBudget(2_000))
    #expect(try register(.rax, processor: 0, in: machine) == 0x1111)
    #expect(machine.physicalMemory.isTrackedPageTablePage(containing: 0x82_000))
    let before = machine.pagingUnits[0].diagnostics

    try entropy.writeConfiguration(offset: 4, bytes: [2, 0])
    try machine.physicalMemory.write(at: bar + 0x08, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x0C, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x14, bytes: [0x0F])
    try machine.physicalMemory.write(at: bar + 0x18, bytes: [8, 0])
    try machine.physicalMemory.write(at: bar + 0x20, bytes: littleEndian64(0x18_000))
    try machine.physicalMemory.write(at: bar + 0x28, bytes: littleEndian64(0x19_000))
    try machine.physicalMemory.write(at: bar + 0x30, bytes: littleEndian64(0x1A_000))
    try machine.physicalMemory.write(at: bar + 0x1C, bytes: [1, 0])
    try machine.physicalMemory.write(
      at: 0x18_000,
      bytes: littleEndian64(0x82_000) + littleEndian(UInt32(4)) + [2, 0, 0, 0]
    )
    try machine.physicalMemory.write(at: 0x19_000, bytes: [0, 0, 1, 0, 0, 0])
    try machine.physicalMemory.write(at: bar + 0x100, bytes: [0, 0])

    let pte = try machine.physicalMemory.read(at: 0x82_000, byteCount: 4)
    let usedIndex = try machine.physicalMemory.read(at: 0x1A_002, byteCount: 2)
    #expect(pte == [0x23, 0x30, 0x00, 0x00])
    #expect(usedIndex == [0, 0])
    #expect(entropy.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try machine.run(maximumInstructions: 2_000) == .instructionBudget(2_000))
    #expect(try register(.rax, processor: 0, in: machine) == 0x1111)
    #expect(machine.pagingUnits[0].diagnostics.globalInvalidations == before.globalInvalidations)
  }

  @Test func soleVCPUConfiguredVirtioDMAInvalidatesItsTrackedPageTable() throws {
    let bar: UInt64 = 0xD000_1000
    let entropy = try DoryPCVirtioEntropyPCIDevice(
      address: .init(bus: 0, device: 3, function: 0),
      initialBARAddress: bar,
      source: FixedEntropySource(bytes: littleEndian(UInt32(0x4003)))
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [entropy],
      executionTier: .baselineJIT,
      instrumentationEnabled: true
    )
    try machine.load(
      kernel: makeELF(code: protectedPagingSetup() + [
        0xA1, 0x00, 0x00, 0x40, 0x00,  // fill the original 0x400000 translation
        0xC7, 0x05, 0x00, 0x11, 0x00, 0xD0, 0, 0, 0, 0,  // kick the entropy queue
        0xA1, 0x00, 0x00, 0x40, 0x00,  // must use the DMA-installed translation
        0xEB, 0xFE,
      ]),
      commandLine: "x"
    )
    try installLegacyPageTables(in: machine)
    // The guest's MMIO doorbell must be mapped through its own page tables. The device
    // rewrites the separately tracked 0x400000 PTE, not the doorbell's translation.
    try machine.memory.writeScalar(at: 0x80000 + (832 * 4), value: 0x83003, byteCount: 4)
    try machine.memory.writeScalar(at: 0x83000 + 4, value: bar | 3, byteCount: 4)
    try machine.memory.writeScalar(at: 0x3000, value: 0x1111, byteCount: 4)
    try machine.memory.writeScalar(at: 0x4000, value: 0x2222, byteCount: 4)

    try entropy.writeConfiguration(offset: 4, bytes: [2, 0])
    try machine.physicalMemory.write(at: bar + 0x08, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x0C, bytes: littleEndian(UInt32(1)))
    try machine.physicalMemory.write(at: bar + 0x14, bytes: [0x0F])
    try machine.physicalMemory.write(at: bar + 0x18, bytes: [8, 0])
    try machine.physicalMemory.write(at: bar + 0x20, bytes: littleEndian64(0x18_000))
    try machine.physicalMemory.write(at: bar + 0x28, bytes: littleEndian64(0x19_000))
    try machine.physicalMemory.write(at: bar + 0x30, bytes: littleEndian64(0x1A_000))
    try machine.physicalMemory.write(at: bar + 0x1C, bytes: [1, 0])
    try machine.physicalMemory.write(
      at: 0x18_000,
      bytes: littleEndian64(0x82_000) + littleEndian(UInt32(4)) + [2, 0, 0, 0]
    )
    try machine.physicalMemory.write(at: 0x19_000, bytes: [0, 0, 1, 0, 0, 0])

    #expect(try machine.run(maximumInstructions: 2_000) == .instructionBudget(2_000))
    #expect(try register(.rax, processor: 0, in: machine) == 0x2222)
    let pte = try machine.physicalMemory.read(at: 0x82_000, byteCount: 4)
    // The subsequent guest read sets the hardware-defined accessed bit in the new PTE.
    #expect(pte == littleEndian(UInt32(0x4023)))
    #expect(machine.physicalMemory.isTrackedPageTablePage(containing: 0x82_000))
    #expect(try machine.physicalMemory.read(at: 0x1A_002, byteCount: 2) == [1, 0])
    #expect(!entropy.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(machine.pagingUnits[0].diagnostics.globalInvalidations > 0)
    let invalidation = machine.translationInvalidationDiagnostics
    #expect(invalidation.generation > 0)
    #expect(invalidation.requiredGenerations == invalidation.acknowledgedGenerations)
  }

  @Test func lockedCompareExchangeAllowsExactlyOneWinner() throws {
    let machine = try makeMachine(
      bsp: loop([
        moveEAX(0),
        moveEBX(1),
        lockedCompareExchangeEBX(x),
      ]),
      ap: loop([
        moveEAX(0),
        moveEBX(2),
        lockedCompareExchangeEBX(x),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([x], in: machine)
      let result = try machine.run(maximumInstructions: 8)
      try #require(result == .instructionBudget(8), "unexpected run result: \(result)")
      let final = try machine.memory.readScalar(at: UInt64(x), byteCount: 4)
      let firstWon = try #require(machine.state(forProcessor: 0)).rflags.contains(.zero)
      let secondWon = try #require(machine.state(forProcessor: 1)).rflags.contains(.zero)
      #expect(final == 1 || final == 2)
      #expect(firstWon != secondWon)
      #expect(firstWon == (final == 1))
      #expect(secondWon == (final == 2))
    }

    #expect(overlap.maximumActive == 2)
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT])
  func guestPageTableRewriteInvalidatesAnActiveRemoteTLB(
    tier: DoryPCExecutionTier
  ) throws {
    let setup = protectedPagingSetup()
    let machine = try makeMachine(
      bsp: setup + [
        // Wait until the AP has filled and hit its old 0x400000 translation.
        0x83, 0x3D, 0x00, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5000],1
        0x75, 0xF7,  // jne back
        // Remap 0x400000 from physical 0x3000 to 0x4000. The tracked page-table write
        // publishes a conservative global flush before this owner can continue.
        0xC7, 0x05, 0x00, 0x20, 0x08, 0x00, 0x03, 0x40, 0x00, 0x00,
        0xC7, 0x05, 0x04, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        // Do not halt until the AP has observed and published the replacement page.
        0x81, 0x3D, 0x14, 0x50, 0x00, 0x00, 0x22, 0x22, 0x00, 0x00,
        0x75, 0xF4,  // jne back
        // Publish the exact invalidation only after the AP proves the global page-table flush
        // completed. Multiple same-batch invalidations are conservatively promoted to global.
        0x0F, 0x01, 0x3D, 0x00, 0x00, 0x40, 0x00,  // invlpg [0x400000]
        0x66, 0xBA, 0x04, 0x06,  // mov dx,PM1_CONTROL
        0x66, 0xB8, 0x00, 0x34,  // mov ax,S5|SLP_EN
        0x66, 0xEF,  // out dx,ax
      ],
      ap: setup + [
        0xA1, 0x00, 0x00, 0x40, 0x00,  // mov eax,[0x400000] (fill)
        0xA1, 0x00, 0x00, 0x40, 0x00,  // mov eax,[0x400000] (hit)
        0xA3, 0x10, 0x50, 0x00, 0x00,  // mov [0x5010],eax
        0xC7, 0x05, 0x00, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x83, 0x3D, 0x04, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5004],1
        0x75, 0xF7,  // jne back
        0x8B, 0x1D, 0x00, 0x00, 0x40, 0x00,  // mov ebx,[0x400000]
        0x89, 0x1D, 0x14, 0x50, 0x00, 0x00,  // mov [0x5014],ebx
        0xF4,
      ],
      tier: tier
    )
    let nativeEntriesBefore = machine.qualificationBaselineNativeEntriesByProcessor
    try installLegacyPageTables(in: machine)
    try machine.memory.writeScalar(at: 0x3000, value: 0x1111, byteCount: 4)
    try machine.memory.writeScalar(at: 0x4000, value: 0x2222, byteCount: 4)
    try zero([0x5000, 0x5004, 0x5010, 0x5014], in: machine)
    let before = machine.pagingUnits.map(\.diagnostics)
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    let stop = try machine.run(maximumInstructions: 100_000)
    guard case .poweredOff(let retired) = stop else {
      let bspRIP = machine.state(forProcessor: 0)?.rip
      let apRIP = machine.state(forProcessor: 1)?.rip
      let oldValue = try machine.memory.readScalar(at: 0x5010, byteCount: 4)
      let newValue = try machine.memory.readScalar(at: 0x5014, byteCount: 4)
      let message = "expected guest poweroff after the remote translation changed: \(stop); "
        + "BSP RIP=\(String(describing: bspRIP)), AP RIP=\(String(describing: apRIP)), "
        + "old=\(oldValue), new=\(newValue)"
      Issue.record(Comment(rawValue: message))
      return
    }

    #expect(retired > 0)
    #expect(try machine.memory.readScalar(at: 0x5010, byteCount: 4) == 0x1111)
    #expect(try machine.memory.readScalar(at: 0x5014, byteCount: 4) == 0x2222)
    #expect(overlap.maximumActive == 2)
    let translationAcknowledgements = overlap.translationAcknowledgements
    for processor in 0..<2 {
      let after = machine.pagingUnits[processor].diagnostics
      #expect(
        after.globalInvalidations > before[processor].globalInvalidations,
        "processor \(processor) did not acknowledge the global page-table invalidation"
      )
      #expect(
        after.linearInvalidations > before[processor].linearInvalidations,
        "processor \(processor) did not acknowledge the targeted linear invalidation; worker acknowledgements: \(translationAcknowledgements)"
      )
    }
    #expect(machine.pagingUnits[1].diagnostics.recentTLBHits > 0)
    if tier == .baselineJIT {
      let nativeEntriesAfter = machine.qualificationBaselineNativeEntriesByProcessor
      #expect(nativeEntriesAfter[0] > nativeEntriesBefore[0])
      #expect(nativeEntriesAfter[1] > nativeEntriesBefore[1])
    }
    let invalidation = machine.translationInvalidationDiagnostics
    #expect(invalidation.generation >= 2)
    #expect(invalidation.requiredGenerations == invalidation.acknowledgedGenerations)
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT])
  func deviceDMAPageTableRewriteInvalidatesAnActiveRemoteTLB(tier: DoryPCExecutionTier) throws {
    let setup = protectedPagingSetup()
    let machine = try makeMachine(
      bsp: setup + [
        // Keep the BSP guest-active until the AP observes the DMA-installed translation.
        0x81, 0x3D, 0x14, 0x50, 0x00, 0x00, 0x22, 0x22, 0x00, 0x00,
        0x75, 0xF4,  // jne back
        0x66, 0xBA, 0x04, 0x06,  // mov dx,PM1_CONTROL
        0x66, 0xB8, 0x00, 0x34,  // mov ax,S5|SLP_EN
        0x66, 0xEF,  // out dx,ax
      ],
      ap: setup + [
        0xA1, 0x00, 0x00, 0x40, 0x00,  // mov eax,[0x400000] (fill)
        0xA1, 0x00, 0x00, 0x40, 0x00,  // mov eax,[0x400000] (hit)
        0xA3, 0x10, 0x50, 0x00, 0x00,  // mov [0x5010],eax
        0xC7, 0x05, 0x00, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x83, 0x3D, 0x04, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5004],1
        0x75, 0xF7,  // jne back
        0x8B, 0x1D, 0x00, 0x00, 0x40, 0x00,  // mov ebx,[0x400000]
        0x89, 0x1D, 0x14, 0x50, 0x00, 0x00,  // mov [0x5014],ebx
        0xF4,
      ],
      tier: tier
    )
    let nativeEntriesBefore = machine.qualificationBaselineNativeEntriesByProcessor
    try installLegacyPageTables(in: machine)
    try machine.memory.writeScalar(at: 0x3000, value: 0x1111, byteCount: 4)
    try machine.memory.writeScalar(at: 0x4000, value: 0x2222, byteCount: 4)
    try zero([0x5000, 0x5004, 0x5010, 0x5014], in: machine)
    let before = machine.pagingUnits.map(\.diagnostics)
    let dmaValidationsBefore = machine.physicalMemory.diagnostics.dmaValidationCalls
    let dma: any DoryVirtioGuestMemory = machine.qualificationDMAMemory
    let dmaStarted = DispatchSemaphore(value: 0)
    let dmaFinished = DispatchSemaphore(value: 0)
    let dmaResult = LitmusBox<Result<UInt64, Error>?>(nil)
    let dmaThread = Thread {
      dmaStarted.signal()
      defer { dmaFinished.signal() }
      do {
        let deadline = Date(timeIntervalSinceNow: 5)
        var readAttempts: UInt64 = 0
        while true {
          readAttempts += 1
          if try dma.read(at: 0x5000, byteCount: 4) == [1, 0, 0, 0] { break }
          guard Date() < deadline else { throw LitmusDMAError.guestReadyTimeout }
          Thread.sleep(forTimeInterval: 0.0001)
        }
        // The AP's walk has now registered physical page 0x82000 as a page-table page.
        guard machine.physicalMemory.isTrackedPageTablePage(containing: 0x82000) else {
          throw LitmusDMAError.pageTableNotTracked
        }
        try dma.validate(at: 0x82000, byteCount: 4, deviceWillWrite: true)
        try dma.write(at: 0x82000, bytes: [0x03, 0x40, 0x00, 0x00])
        dma.synchronize()
        try dma.validate(at: 0x5004, byteCount: 4, deviceWillWrite: true)
        try dma.write(at: 0x5004, bytes: [1, 0, 0, 0])
        dma.synchronize()
        dmaResult.set(.success(readAttempts))
      } catch {
        dmaResult.set(.failure(error))
      }
    }
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    dmaThread.start()
    dmaStarted.wait()

    let result = try machine.run(maximumInstructions: 1_000_000)
    #expect(dmaFinished.wait(timeout: .now() + .seconds(6)) == .success)
    let readAttempts = try #require(dmaResult.value).get()
    guard case .poweredOff(let retired) = result else {
      Issue.record("expected guest poweroff after DMA changed the remote translation")
      return
    }

    #expect(retired > 0)
    #expect(try machine.memory.readScalar(at: 0x5010, byteCount: 4) == 0x1111)
    #expect(try machine.memory.readScalar(at: 0x5014, byteCount: 4) == 0x2222)
    // The device adapter checks both explicit descriptor preflight and the actual writes;
    // a backend must not be able to bypass MMIO admission by omitting preflight.
    #expect(
      machine.physicalMemory.diagnostics.dmaValidationCalls
        == dmaValidationsBefore + readAttempts + 4
    )
    #expect(overlap.maximumActive == 2)
    let translationAcknowledgements = overlap.translationAcknowledgements
    for processor in 0..<2 {
      #expect(
        translationAcknowledgements.contains(where: { $0.processor == processor }),
        "external DMA invalidation was not acknowledged by vCPU owner \(processor)"
      )
    }
    for processor in 0..<2 {
      let after = machine.pagingUnits[processor].diagnostics
      #expect(
        after.globalInvalidations > before[processor].globalInvalidations,
        "processor \(processor) did not acknowledge the DMA page-table invalidation; worker acknowledgements: \(translationAcknowledgements)"
      )
    }
    #expect(machine.pagingUnits[1].diagnostics.recentTLBHits > 0)
    let invalidation = machine.translationInvalidationDiagnostics
    #expect(invalidation.generation >= 1)
    #expect(invalidation.requiredGenerations == invalidation.acknowledgedGenerations)
    if tier == .baselineJIT {
      let nativeEntriesAfter = machine.qualificationBaselineNativeEntriesByProcessor
      #expect(nativeEntriesAfter[0] > nativeEntriesBefore[0])
      #expect(nativeEntriesAfter[1] > nativeEntriesBefore[1])
    }
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT])
  func guestCPUMutationRevokesRemoteInstructionFetch(tier: DoryPCExecutionTier) throws {
    let mutableCode: UInt64 = 0xA000
    let machine = try makeMachine(
      bsp: [
        // Wait until the AP has executed the old bytes and left the mutable function.
        0x83, 0x3D, 0x00, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5000],1
        0x75, 0xF7,  // jne back
        // Replace the immediate in `mov eax,0x1111` through the normal guest CPU write path.
        0xC7, 0x05, 0x01, 0xA0, 0x00, 0x00, 0x22, 0x22, 0x00, 0x00,
        0x0F, 0xAE, 0xF0,  // mfence
        0xC7, 0x05, 0x04, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        // Wait until the AP has serialized and executed the replacement bytes.
        0x81, 0x3D, 0x14, 0x50, 0x00, 0x00, 0x22, 0x22, 0x00, 0x00,
        0x75, 0xF4,  // jne back
        0x66, 0xBA, 0x04, 0x06,  // mov dx,PM1_CONTROL
        0x66, 0xB8, 0x00, 0x34,  // mov ax,S5|SLP_EN
        0x66, 0xEF,  // out dx,ax
      ],
      ap: [
        0xB8, 0x00, 0xA0, 0x00, 0x00,  // mov eax,0xA000
        0xFF, 0xD0,  // call eax
        0xA3, 0x10, 0x50, 0x00, 0x00,  // mov [0x5010],eax
        0xC7, 0x05, 0x00, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x83, 0x3D, 0x04, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5004],1
        0x75, 0xF7,  // jne back
        0x31, 0xC0,  // xor eax,eax
        0x0F, 0xA2,  // cpuid (cross-modifying-code serialization)
        0xB8, 0x00, 0xA0, 0x00, 0x00,  // mov eax,0xA000
        0xFF, 0xD0,  // call eax
        0xA3, 0x14, 0x50, 0x00, 0x00,  // mov [0x5014],eax
        0xF4,
      ],
      tier: tier
    )
    let nativeEntriesBefore = machine.qualificationBaselineNativeEntriesByProcessor
    try machine.memory.write(
      at: mutableCode,
      bytes: [0xB8, 0x11, 0x11, 0x00, 0x00, 0xC3]  // mov eax,0x1111; ret
    )
    try zero([0x5000, 0x5004, 0x5010, 0x5014], in: machine)
    let generationBefore = try #require(
      try machine.memory.codeGeneration(at: mutableCode, byteCount: 6)
    )
    let codeProtection = try #require(
      machine.memory as? any DoryX86TranslatedCodeProtectionMemory
    )
    #expect(try codeProtection.protectTranslatedCode(at: mutableCode, byteCount: 6))
    #expect(codeProtection.protectedTranslatedCodePageCount > 0)
    let protectionBefore = codeProtection.translatedCodeProtectionGeneration
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    guard case .poweredOff(let retired) = try machine.run(maximumInstructions: 100_000) else {
      Issue.record("expected guest poweroff after the remote instruction fetch changed")
      return
    }

    #expect(retired > 0)
    #expect(try machine.memory.readScalar(at: 0x5010, byteCount: 4) == 0x1111)
    #expect(try machine.memory.readScalar(at: 0x5014, byteCount: 4) == 0x2222)
    #expect(
      try machine.memory.codeGeneration(at: mutableCode, byteCount: 6) != generationBefore
    )
    #expect(codeProtection.translatedCodeProtectionGeneration > protectionBefore)
    if tier == .interpreter {
      #expect(codeProtection.protectedTranslatedCodePageCount == 0)
    }
    #expect(overlap.maximumActive == 2)
    if tier == .baselineJIT {
      let nativeEntriesAfter = machine.qualificationBaselineNativeEntriesByProcessor
      #expect(nativeEntriesAfter[0] > nativeEntriesBefore[0])
      #expect(nativeEntriesAfter[1] > nativeEntriesBefore[1])
    }
  }

  @Test(arguments: [DoryPCExecutionTier.interpreter, .baselineJIT])
  func deviceDMAMutationRevokesRemoteInstructionFetch(tier: DoryPCExecutionTier) throws {
    let mutableCode: UInt64 = 0xA000
    let machine = try makeMachine(
      bsp: [
        // The BSP remains guest-active while the AP and device backend complete the protocol.
        0x81, 0x3D, 0x14, 0x50, 0x00, 0x00, 0x22, 0x22, 0x00, 0x00,
        0x75, 0xF4,  // jne back
        0x66, 0xBA, 0x04, 0x06,  // mov dx,PM1_CONTROL
        0x66, 0xB8, 0x00, 0x34,  // mov ax,S5|SLP_EN
        0x66, 0xEF,  // out dx,ax
      ],
      ap: [
        0xB8, 0x00, 0xA0, 0x00, 0x00,  // mov eax,0xA000
        0xFF, 0xD0,  // call eax
        0xA3, 0x10, 0x50, 0x00, 0x00,  // mov [0x5010],eax
        0xC7, 0x05, 0x00, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x83, 0x3D, 0x04, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5004],1
        0x75, 0xF7,  // jne back
        0x31, 0xC0,  // xor eax,eax
        0x0F, 0xA2,  // cpuid (cross-modifying-code serialization)
        0xB8, 0x00, 0xA0, 0x00, 0x00,  // mov eax,0xA000
        0xFF, 0xD0,  // call eax
        0xA3, 0x14, 0x50, 0x00, 0x00,  // mov [0x5014],eax
        0xF4,
      ],
      tier: tier
    )
    let nativeEntriesBefore = machine.qualificationBaselineNativeEntriesByProcessor
    try machine.memory.write(
      at: mutableCode,
      bytes: [0xB8, 0x11, 0x11, 0x00, 0x00, 0xC3]  // mov eax,0x1111; ret
    )
    try zero([0x5000, 0x5004, 0x5010, 0x5014], in: machine)
    let generationBefore = try #require(
      try machine.physicalMemory.codeGeneration(at: mutableCode, byteCount: 6)
    )
    #expect(try machine.physicalMemory.protectTranslatedCode(at: mutableCode, byteCount: 6))
    let protectionBefore = machine.physicalMemory.translatedCodeProtectionGeneration
    let dmaValidationsBefore = machine.physicalMemory.diagnostics.dmaValidationCalls
    let dma: any DoryVirtioGuestMemory = machine.qualificationDMAMemory
    let dmaStarted = DispatchSemaphore(value: 0)
    let dmaFinished = DispatchSemaphore(value: 0)
    let dmaResult = LitmusBox<Result<UInt64, Error>?>(nil)
    let dmaThread = Thread {
      dmaStarted.signal()
      defer { dmaFinished.signal() }
      do {
        let deadline = Date(timeIntervalSinceNow: 5)
        var readAttempts: UInt64 = 0
        while true {
          readAttempts += 1
          if try dma.read(at: 0x5000, byteCount: 4) == [1, 0, 0, 0] { break }
          guard Date() < deadline else { throw LitmusDMAError.guestReadyTimeout }
          Thread.sleep(forTimeInterval: 0.0001)
        }
        try dma.validate(at: mutableCode + 1, byteCount: 4, deviceWillWrite: true)
        try dma.write(at: mutableCode + 1, bytes: [0x22, 0x22, 0x00, 0x00])
        dma.synchronize()
        try dma.validate(at: 0x5004, byteCount: 4, deviceWillWrite: true)
        try dma.write(at: 0x5004, bytes: [1, 0, 0, 0])
        dma.synchronize()
        dmaResult.set(.success(readAttempts))
      } catch {
        dmaResult.set(.failure(error))
      }
    }
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }
    dmaThread.start()
    dmaStarted.wait()

    let result = try machine.run(maximumInstructions: 1_000_000)
    #expect(dmaFinished.wait(timeout: .now() + .seconds(6)) == .success)
    let readAttempts = try #require(dmaResult.value).get()
    guard case .poweredOff(let retired) = result else {
      Issue.record("expected guest poweroff after DMA changed the remote instruction fetch")
      return
    }

    #expect(retired > 0)
    #expect(try machine.memory.readScalar(at: 0x5010, byteCount: 4) == 0x1111)
    #expect(try machine.memory.readScalar(at: 0x5014, byteCount: 4) == 0x2222)
    #expect(
      try machine.physicalMemory.codeGeneration(at: mutableCode, byteCount: 6)
        != generationBefore
    )
    #expect(machine.physicalMemory.translatedCodeProtectionGeneration > protectionBefore)
    if tier == .interpreter {
      #expect(machine.physicalMemory.protectedTranslatedCodePageCount == 0)
    }
    // Each of the two writes is checked both at explicit descriptor preflight and again at
    // the actual DMA write, so a backend cannot bypass admission by skipping preflight.
    #expect(
      machine.physicalMemory.diagnostics.dmaValidationCalls
        == dmaValidationsBefore + readAttempts + 4
    )
    #expect(overlap.maximumActive == 2)
    if tier == .baselineJIT {
      let nativeEntriesAfter = machine.qualificationBaselineNativeEntriesByProcessor
      #expect(nativeEntriesAfter[0] > nativeEntriesBefore[0])
      #expect(nativeEntriesAfter[1] > nativeEntriesBefore[1])
    }
  }

  private enum Register { case rax, rbx }

  private func register(
    _ register: Register,
    processor: Int,
    in machine: DoryPCDirectKernelMachine
  ) throws -> UInt64 {
    let state = try #require(machine.state(forProcessor: processor))
    switch register {
    case .rax: return state.registers.rax & 0xFFFF_FFFF
    case .rbx: return state.registers.rbx & 0xFFFF_FFFF
    }
  }

  private func zero(_ addresses: [UInt32], in machine: DoryPCDirectKernelMachine) throws {
    for address in addresses {
      try machine.memory.writeScalar(at: UInt64(address), value: 0, byteCount: 4)
    }
  }

  private func store(_ address: UInt32, _ value: UInt32) -> [UInt8] {
    [0xC7, 0x05] + littleEndian(address) + littleEndian(value)
  }

  private func loadEAX(_ address: UInt32) -> [UInt8] {
    [0xA1] + littleEndian(address)
  }

  private func loadEBX(_ address: UInt32) -> [UInt8] {
    [0x8B, 0x1D] + littleEndian(address)
  }

  private func moveEAX(_ value: UInt32) -> [UInt8] {
    [0xB8] + littleEndian(value)
  }

  private func moveEBX(_ value: UInt32) -> [UInt8] {
    [0xBB] + littleEndian(value)
  }

  private func exchangeEAX(_ address: UInt32) -> [UInt8] {
    [0x87, 0x05] + littleEndian(address)
  }

  private func lockedExchangeAddEAX(_ address: UInt32) -> [UInt8] {
    [0xF0, 0x0F, 0xC1, 0x05] + littleEndian(address)
  }

  private func lockedAdd(_ address: UInt32, _ value: UInt8) -> [UInt8] {
    [0xF0, 0x83, 0x05] + littleEndian(address) + [value]
  }

  private func lockedCompareExchangeEBX(_ address: UInt32) -> [UInt8] {
    [0xF0, 0x0F, 0xB1, 0x1D] + littleEndian(address)
  }

  private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }

  private func littleEndian64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func loop(_ instructions: [[UInt8]]) -> [UInt8] {
    let body = instructions.flatMap { $0 }
    precondition(body.count + 2 <= 128)
    return body + [0xEB, UInt8(bitPattern: Int8(-(body.count + 2)))]
  }

  private func oneShot(_ instructions: [[UInt8]]) -> [UInt8] {
    // A terminal self-branch preserves each observation after its first execution. Native and
    // interpreter owners can retire different slices without mixing two litmus iterations.
    let body = instructions.flatMap { $0 }
    precondition(body.count + 2 <= 128)
    return body + [0xEB, 0xFE]
  }

  private func protectedPagingSetup() -> [UInt8] {
    [
      0xB8, 0x00, 0x00, 0x08, 0x00,  // mov eax,0x80000
      0x0F, 0x22, 0xD8,  // mov cr3,eax
      0x0F, 0x20, 0xC0,  // mov eax,cr0
      0x0D, 0x00, 0x00, 0x00, 0x80,  // or eax,CR0.PG
      0x0F, 0x22, 0xC0,  // mov cr0,eax
    ]
  }

  private func installLegacyPageTables(in machine: DoryPCDirectKernelMachine) throws {
    var directory = [UInt8](repeating: 0, count: 4_096)
    directory.replaceSubrange(0..<4, with: littleEndian(0x0008_1003))
    directory.replaceSubrange(4..<8, with: littleEndian(0x0008_2003))
    try machine.memory.write(at: 0x80000, bytes: directory)

    var identity = [UInt8](repeating: 0, count: 4_096)
    for page in 0..<512 {
      let entry = UInt32(page * 4_096) | 3
      identity.replaceSubrange((page * 4)..<(page * 4 + 4), with: littleEndian(entry))
    }
    try machine.memory.write(at: 0x81000, bytes: identity)

    var alias = [UInt8](repeating: 0, count: 4_096)
    alias.replaceSubrange(0..<4, with: littleEndian(0x0000_3003))
    try machine.memory.write(at: 0x82000, bytes: alias)
  }

  /// Starts the AP in the same flat protected32 mode as the PVH BSP, then installs the two litmus
  /// loops and enables the requested otherwise-private concurrent-owner policy.
  private func makeMachine(
    bsp: [UInt8], ap: [UInt8], tier: DoryPCExecutionTier = .interpreter,
    interpreterOnlyProcessor: Int? = nil
  ) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      executionTier: tier,
      clockSource: .hostMonotonic { 0 },
      instrumentationEnabled: true
    )
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    try machine.memory.write(at: 0x6006, bytes: [0x17, 0, 0, 0x62, 0, 0])
    try machine.memory.write(
      at: 0x6200,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )
    try machine.memory.write(
      at: 0x8000,
      bytes: [
        0x66, 0x0F, 0x01, 0x16, 6, 0x60,  // lgdt [0x6006]
        0x66, 0x0F, 0x20, 0xC0,  // mov eax,cr0
        0x66, 0x83, 0xC8, 1,  // or eax,1
        0x66, 0x0F, 0x22, 0xC0,  // mov cr0,eax
        0x66, 0xEA, 0, 0x8F, 0, 0, 8, 0,  // jmp 8:0x8F00
      ]
    )
    try machine.memory.write(
      at: 0x8F00,
      bytes: [
        0x66, 0xB8, 0x10, 0,  // mov ax,0x10
        0x8E, 0xD8,  // mov ds,ax
        0xE9, 0xF5, 0, 0, 0,  // jmp 0x9000
      ]
    )
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: 6 << 8 | 8
    )
    for step in 0..<32 {
      if machine.state(forProcessor: 1)?.rip == 0x9000 { break }
      try #require(
        try machine.run(maximumInstructions: 1) == .instructionBudget(1),
        "AP protected-mode setup step \(step)"
      )
    }
    try #require(machine.state(forProcessor: 1)?.rip == 0x9000)
    try #require(machine.state(forProcessor: 1)?.cs.base == 0)
    try #require(machine.state(forProcessor: 1)?.cs.limit == .max)
    try machine.memory.write(at: 0x10_0000, bytes: bsp)
    try machine.memory.write(at: 0x9000, bytes: ap)
    if let interpreterOnlyProcessor {
      try machine.enableQualifiedMixedBaselineJITPairExecution(
        interpreterProcessor: interpreterOnlyProcessor
      )
    } else if tier == .baselineJIT {
      try machine.enableQualifiedBaselineJITPairExecution()
    } else {
      try machine.enableQualifiedInterpreterPairExecution()
    }
    return machine
  }

  private func makeQuartetMachine(
    programs: [[UInt8]], tier: DoryPCExecutionTier = .interpreter,
    interpreterOnlyProcessor: Int? = nil
  ) throws -> DoryPCDirectKernelMachine {
    precondition(programs.count == 4)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 4,
      executionTier: tier,
      clockSource: .hostMonotonic { 0 },
      instrumentationEnabled: true
    )
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    try machine.memory.write(at: 0x6006, bytes: [0x17, 0, 0, 0x62, 0, 0])
    try machine.memory.write(
      at: 0x6200,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )
    let destinations: [UInt32] = [0, 0xB000, 0xC000, 0xD000]
    for processor in 1..<4 {
      let bootstrap = UInt32(0x8000 + (processor - 1) * 0x1000)
      let protectedEntry = bootstrap + 0xF00
      let destination = destinations[processor]
      try machine.memory.write(
        at: UInt64(bootstrap),
        bytes: [
          0x66, 0x0F, 0x01, 0x16, 6, 0x60,  // lgdt [0x6006]
          0x66, 0x0F, 0x20, 0xC0,  // mov eax,cr0
          0x66, 0x83, 0xC8, 1,  // or eax,1
          0x66, 0x0F, 0x22, 0xC0,  // mov cr0,eax
          0x66, 0xEA,
        ] + littleEndian(protectedEntry) + [8, 0]
      )
      let displacement = destination - (protectedEntry + 11)
      try machine.memory.write(
        at: UInt64(protectedEntry),
        bytes: [0x66, 0xB8, 0x10, 0, 0x8E, 0xD8, 0xE9]
          + littleEndian(displacement)
      )
      try machine.memory.write(at: UInt64(destination), bytes: [0xEB, 0xFE])
      try machine.multiprocessorController.handleInterruptCommand(
        sourceAPICID: 0,
        high: UInt32(processor) << 24,
        low: 6 << 8 | (8 + UInt32(processor - 1))
      )
      for _ in 0..<256 {
        if machine.state(forProcessor: processor)?.rip == UInt64(destination) { break }
        try #require(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      }
      try #require(machine.state(forProcessor: processor)?.rip == UInt64(destination))
      try #require(machine.state(forProcessor: processor)?.cs.base == 0)
    }
    try machine.memory.write(at: 0x10_0000, bytes: programs[0])
    for processor in 1..<4 {
      try machine.memory.write(at: UInt64(destinations[processor]), bytes: programs[processor])
    }
    if tier == .baselineJIT {
      if let interpreterOnlyProcessor {
        try machine.enableQualifiedMixedBaselineJITQuartetExecution(
          interpreterProcessor: interpreterOnlyProcessor
        )
      } else {
        try machine.enableQualifiedBaselineJITQuartetExecution()
      }
    } else {
      precondition(interpreterOnlyProcessor == nil)
      try machine.enableQualifiedInterpreterQuartetExecution()
    }
    return machine
  }

  private func makeELF(code: [UInt8]) -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + code.count)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt16(64), to: &data, at: 52)
    write(UInt32(5), to: &data, at: 0x44)
    write(UInt64(0x10_0000), to: &data, at: 0x50)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeHeader(
      to: &data,
      at: 0x40,
      type: 1,
      fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000,
      size: UInt64(code.count)
    )
    writeHeader(
      to: &data,
      at: 0x78,
      type: 4,
      fileOffset: 0x180,
      physicalAddress: 0,
      size: 20
    )
    write(UInt32(4), to: &data, at: 0x180)
    write(UInt32(4), to: &data, at: 0x184)
    write(UInt32(0x12), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(UInt32(0x10_0000), to: &data, at: 0x190)
    data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
    return data
  }

  private func writeHeader(
    to data: inout Data,
    at offset: Int,
    type: UInt32,
    fileOffset: UInt64,
    physicalAddress: UInt64,
    size: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 24)
    write(size, to: &data, at: offset + 32)
    write(size, to: &data, at: offset + 40)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}

private final class LitmusOverlapProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private let requiredConcurrentOwners: Int
  private var entries = 0
  private var active = 0
  private var highWatermark = 0
  private var invalidationAcknowledgements: [(processor: Int, generation: UInt64)] = []

  init(requiredConcurrentOwners: Int = 2) {
    self.requiredConcurrentOwners = requiredConcurrentOwners
  }

  var maximumActive: Int { condition.withLock { highWatermark } }
  var translationAcknowledgements: [(processor: Int, generation: UInt64)] {
    condition.withLock { invalidationAcknowledgements }
  }

  func observe(_ event: DoryPCDirectKernelMachine.WorkerEvent) {
    condition.lock()
    defer { condition.unlock() }
    switch event {
    case .executing(_, concurrent: true):
      entries += 1
      active += 1
      highWatermark = max(highWatermark, active)
      if entries == requiredConcurrentOwners { condition.broadcast() }
      let deadline = Date(timeIntervalSinceNow: 5)
      while entries < requiredConcurrentOwners {
        if !condition.wait(until: deadline) { break }
      }
    case .executed(_, concurrent: true):
      active -= 1
    case .acknowledgedTranslationInvalidation(let processor, let generation):
      invalidationAcknowledgements.append((processor, generation))
    default:
      break
    }
  }
}

private enum LitmusDMAError: Error {
  case guestReadyTimeout
  case pageTableNotTracked
}

private struct ConstantEntropySource: DoryVirtioEntropySource, Sendable {
  let byte: UInt8

  func randomBytes(byteCount: Int) throws -> [UInt8] {
    [UInt8](repeating: byte, count: byteCount)
  }
}

private struct FixedEntropySource: DoryVirtioEntropySource, Sendable {
  let bytes: [UInt8]

  func randomBytes(byteCount: Int) throws -> [UInt8] {
    Array(bytes.prefix(byteCount))
  }
}

private final class LitmusBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value { lock.withLock { storage } }

  func set(_ value: Value) {
    lock.withLock { storage = value }
  }
}
