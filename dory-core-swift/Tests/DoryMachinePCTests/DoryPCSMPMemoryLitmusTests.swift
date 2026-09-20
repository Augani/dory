import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

/// Guest-code memory-order cells for the first internally admitted interpreter pair. Every test
/// loops each vCPU back to the same instruction boundary, resets data only while both owners are
/// joined, and proves at least one real two-owner overlap. These cells remain necessary but are not
/// sufficient for public SMP promotion or any native-tier pair.
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

  @Test func implicitLockedExchangeHasOneTotalOrder() throws {
    let machine = try makeMachine(
      bsp: loop([
        moveEAX(1),
        exchangeEAX(x),
      ]),
      ap: loop([
        moveEAX(2),
        exchangeEAX(x),
      ])
    )
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    for _ in 0..<iterations {
      try zero([x], in: machine)
      #expect(try machine.run(maximumInstructions: 6) == .instructionBudget(6))
      let final = try machine.memory.readScalar(at: UInt64(x), byteCount: 4)
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

  @Test func guestPageTableRewriteInvalidatesAnActiveRemoteTLB() throws {
    let setup = protectedPagingSetup()
    let machine = try makeMachine(
      bsp: setup + [
        // Wait until the AP has filled and hit its old 0x400000 translation.
        0x83, 0x3D, 0x00, 0x50, 0x00, 0x00, 0x01,  // cmp dword [0x5000],1
        0x75, 0xF7,  // jne back
        // Remap 0x400000 from physical 0x3000 to 0x4000. The tracked page-table write
        // publishes a conservative global flush before this owner can continue.
        0xC7, 0x05, 0x00, 0x20, 0x08, 0x00, 0x03, 0x40, 0x00, 0x00,
        // The architectural invalidation then publishes the exact linear page to both owners.
        0x0F, 0x01, 0x3D, 0x00, 0x00, 0x40, 0x00,  // invlpg [0x400000]
        0xC7, 0x05, 0x04, 0x50, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        // Do not halt until the AP has observed and published the replacement page.
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
      ]
    )
    try installLegacyPageTables(in: machine)
    try machine.memory.writeScalar(at: 0x3000, value: 0x1111, byteCount: 4)
    try machine.memory.writeScalar(at: 0x4000, value: 0x2222, byteCount: 4)
    try zero([0x5000, 0x5004, 0x5010, 0x5014], in: machine)
    let before = machine.pagingUnits.map(\.diagnostics)
    let overlap = LitmusOverlapProbe()
    machine.observeWorkers { overlap.observe($0) }

    guard case .poweredOff(let retired) = try machine.run(maximumInstructions: 100_000) else {
      Issue.record("expected guest poweroff after the remote translation changed")
      return
    }

    #expect(retired > 0)
    #expect(try machine.memory.readScalar(at: 0x5010, byteCount: 4) == 0x1111)
    #expect(try machine.memory.readScalar(at: 0x5014, byteCount: 4) == 0x2222)
    #expect(overlap.maximumActive == 2)
    for processor in 0..<2 {
      let after = machine.pagingUnits[processor].diagnostics
      #expect(after.globalInvalidations > before[processor].globalInvalidations)
      #expect(after.linearInvalidations > before[processor].linearInvalidations)
    }
    #expect(machine.pagingUnits[1].diagnostics.recentTLBHits > 0)
    let invalidation = machine.translationInvalidationDiagnostics
    #expect(invalidation.generation >= 2)
    #expect(invalidation.requiredGenerations == invalidation.acknowledgedGenerations)
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

  private func lockedCompareExchangeEBX(_ address: UInt32) -> [UInt8] {
    [0xF0, 0x0F, 0xB1, 0x1D] + littleEndian(address)
  }

  private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }

  private func loop(_ instructions: [[UInt8]]) -> [UInt8] {
    let body = instructions.flatMap { $0 }
    precondition(body.count + 2 <= 128)
    return body + [0xEB, UInt8(bitPattern: Int8(-(body.count + 2)))]
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
  /// loops and enables the otherwise-private interpreter-pair policy.
  private func makeMachine(bsp: [UInt8], ap: [UInt8]) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
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
    try machine.enableQualifiedInterpreterPairExecution()
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
  private var entries = 0
  private var active = 0
  private var highWatermark = 0

  var maximumActive: Int { condition.withLock { highWatermark } }

  func observe(_ event: DoryPCDirectKernelMachine.WorkerEvent) {
    condition.lock()
    defer { condition.unlock() }
    switch event {
    case .executing(_, concurrent: true):
      entries += 1
      active += 1
      highWatermark = max(highWatermark, active)
      if entries == 2 { condition.broadcast() }
      let deadline = Date(timeIntervalSinceNow: 5)
      while entries < 2 {
        if !condition.wait(until: deadline) { break }
      }
    case .executed(_, concurrent: true):
      active -= 1
    default:
      break
    }
  }
}
