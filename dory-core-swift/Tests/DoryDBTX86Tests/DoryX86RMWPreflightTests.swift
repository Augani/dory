import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2A ALU/XCHG and Vol. 2B XADD/BT-family operation
// descriptions specify memory destinations as read-modify-write operands. A
// write-access fault is detected before the data read and before flags or
// registers change. Register-indexed BT-family memory forms apply the signed
// bit offset to the memory address before checking the accessed element.
// https://cdrdv2.intel.com/v1/dl/getContent/671110
@Suite struct DoryX86RMWPreflightTests {
  @Test func deniedWritesPrecedeReadsAndEffectsForCoreRMWFamilies() throws {
    let cases: [[UInt8]] = [
      [0x83, 0x03, 0x01],  // ADD dword ptr [RBX],1
      [0xFF, 0x03],  // INC dword ptr [RBX]
      [0x87, 0x03],  // XCHG dword ptr [RBX],EAX
      [0x0F, 0xC1, 0x03],  // XADD dword ptr [RBX],EAX
    ]
    for bytes in cases {
      let memory = try RMWTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install(littleEndian32(5), at: 0x8000)
      memory.writeFault = .pageFault(address: 0x8000, errorCode: 7)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rax = 3
      state.rflags = [.reservedOne, .carry, .direction]
      let before = state
      let snapshot = memory.snapshot()

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == pageFault(address: 0x8000, errorCode: 7))
      var expected = before
      expected.control.cr2 = 0x8000
      #expect(state == expected)
      #expect(memory.snapshot() == snapshot)
      #expect(memory.validatedWriteAddresses == [0x8000])
      #expect(memory.dataReadAddresses.isEmpty)
      #expect(memory.dataWriteAddresses.isEmpty)
    }
  }

  @Test func coreRMWFamiliesRetainSuccessfulRegisterMemoryAndFlagEffects() throws {
    let cases: [(bytes: [UInt8], expectedMemory: UInt32, expectedRAX: UInt64)] = [
      ([0x83, 0x03, 0x01], 6, 3),  // ADD
      ([0xFF, 0x03], 6, 3),  // INC
      ([0x87, 0x03], 3, 5),  // XCHG
      ([0x0F, 0xC1, 0x03], 8, 5),  // XADD
    ]
    for item in cases {
      let memory = try RMWTrackingMemory()
      memory.install(item.bytes, at: 0x1000)
      memory.install(littleEndian32(5), at: 0x8000)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rax = 3
      let decoded = try DoryX86Decoder().decode(item.bytes, at: 0x1000, mode: .protected32)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == .retired(decoded))
      #expect(state.rip == UInt64(0x1000 + item.bytes.count))
      #expect(state.registers.rax == item.expectedRAX)
      #expect(memory.storedUInt32(at: 0x8000) == item.expectedMemory)
      #expect(memory.validatedWriteAddresses == [0x8000])
      #expect(memory.dataReadAddresses == [0x8000])
      #expect(memory.dataWriteAddresses == [0x8000])
    }
  }

  @Test func adjustedBitWriteFaultPrecedesBackingReadAndCarryChange() throws {
    for opcode: UInt8 in [0xAB, 0xB3, 0xBB] {  // BTS/BTR/BTC
      let memory = try RMWTrackingMemory()
      memory.install([0x0F, opcode, 0x0B], at: 0x1000)
      memory.install(littleEndian32(1), at: 0x8004)
      memory.writeFault = .pageFault(address: 0x8004, errorCode: 7)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rcx = 32
      state.rflags = [.reservedOne, .carry, .overflow]
      let before = state
      let snapshot = memory.snapshot()

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == pageFault(address: 0x8004, errorCode: 7))
      var expected = before
      expected.control.cr2 = 0x8004
      #expect(state == expected)
      #expect(memory.snapshot() == snapshot)
      #expect(memory.validatedWriteAddresses == [0x8004])
      #expect(memory.dataReadAddresses.isEmpty)
      #expect(memory.dataWriteAddresses.isEmpty)
    }
  }

  @Test func adjustedBitElementReceivesSegmentAndCanonicalValidation() throws {
    let segmentedMemory = try RMWTrackingMemory()
    segmentedMemory.install([0x0F, 0xAB, 0x0B], at: 0x1000)  // BTS [RBX],ECX
    var segmented = try protectedState()
    segmented.registers.rbx = 0x8000
    segmented.registers.rcx = 32
    segmented.ds.limit = 0x8003
    let segmentedBefore = segmented
    #expect(
      DoryX86Interpreter().step(
        state: &segmented, memory: segmentedMemory, mode: .protected32)
        == protectionFault)
    #expect(segmented == segmentedBefore)
    #expect(segmentedMemory.validatedWriteAddresses.isEmpty)
    #expect(segmentedMemory.dataReadAddresses.isEmpty)

    let canonicalMemory = try RMWTrackingMemory()
    canonicalMemory.install([0x48, 0x0F, 0xAB, 0x0B], at: 0x1000)  // BTS [RBX],RCX
    var canonical = try longState()
    canonical.registers.rbx = 0x0000_7fff_ffff_fff8
    canonical.registers.rcx = 64
    let canonicalBefore = canonical
    #expect(
      DoryX86Interpreter().step(
        state: &canonical, memory: canonicalMemory, mode: .long64)
        == protectionFault)
    #expect(canonical == canonicalBefore)
    #expect(canonicalMemory.validatedWriteAddresses.isEmpty)
    #expect(canonicalMemory.dataReadAddresses.isEmpty)
  }

  @Test func longModeCoreRMWRejectsNoncanonicalDestinationBeforeMemory() throws {
    let memory = try RMWTrackingMemory()
    memory.install([0x48, 0x83, 0x03, 0x01], at: 0x1000)  // ADD qword ptr [RBX],1
    var state = try longState()
    state.registers.rbx = 0x0000_8000_0000_0000
    let before = state

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == protectionFault)
    #expect(state == before)
    #expect(memory.validatedWriteAddresses.isEmpty)
    #expect(memory.dataReadAddresses.isEmpty)
    #expect(memory.dataWriteAddresses.isEmpty)
  }

  @Test func bitOperationsUseAdjustedPositiveAndNegativeElements() throws {
    let cases: [(opcode: UInt8, initial: UInt32, expected: UInt32, carry: Bool)] = [
      (0xA3, 1, 1, true),  // BT
      (0xAB, 0, 1, false),  // BTS
      (0xB3, 1, 0, true),  // BTR
      (0xBB, 1, 0, true),  // BTC
    ]
    for item in cases {
      let memory = try RMWTrackingMemory()
      memory.install([0x0F, item.opcode, 0x0B], at: 0x1000)
      memory.install(littleEndian32(item.initial), at: 0x8004)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rcx = 32
      let decoded = try DoryX86Decoder().decode(
        [0x0F, item.opcode, 0x0B], at: 0x1000, mode: .protected32)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == .retired(decoded))
      #expect(state.rflags.contains(.carry) == item.carry)
      #expect(memory.storedUInt32(at: 0x8004) == item.expected)
      #expect(memory.dataReadAddresses == [0x8004])
      #expect(memory.validatedWriteAddresses == (item.opcode == 0xA3 ? [] : [0x8004]))
      #expect(memory.dataWriteAddresses == (item.opcode == 0xA3 ? [] : [0x8004]))
    }

    let negativeMemory = try RMWTrackingMemory()
    negativeMemory.install([0x0F, 0xA3, 0x0B], at: 0x1000)  // BT [RBX],ECX
    negativeMemory.install(littleEndian32(0x8000_0000), at: 0x8000)
    negativeMemory.resetObservations()
    var negative = try protectedState()
    negative.registers.rbx = 0x8004
    negative.registers.rcx = UInt64(UInt32.max)  // signed index -1
    #expect(
      DoryX86Interpreter().step(
        state: &negative, memory: negativeMemory, mode: .protected32
      ).isRetired)
    #expect(negative.rflags.contains(.carry))
    #expect(negativeMemory.dataReadAddresses == [0x8000])
  }

  private var protectionFault: DoryX86InterpreterResult {
    .exception(
      .init(
        kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: 0x1000))
  }

  private func pageFault(address: UInt64, errorCode: UInt32) -> DoryX86InterpreterResult {
    .exception(
      .init(
        kind: .pageFault, vector: 14, errorCode: errorCode,
        instructionPointer: 0x1000, linearAddress: address))
  }

  private func protectedState() throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000,
      rflags: [.reservedOne, .direction],
      cs: .init(selector: 0x08, attributes: 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      es: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      control: .init(cr0: 1)
    )
  }

  private func longState() throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000,
      rflags: [.reservedOne, .direction],
      cs: .init(selector: 0x08, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      es: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      control: .init(cr0: 1, efer: (1 << 8) | (1 << 10))
    )
  }

  private func littleEndian32(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }
}

private final class RMWTrackingMemory: DoryX86Memory, @unchecked Sendable {
  private let backing: DoryX86ByteArrayMemory
  var writeFault: DoryX86MemoryError?
  private(set) var validatedWriteAddresses: [UInt64] = []
  private(set) var dataReadAddresses: [UInt64] = []
  private(set) var dataWriteAddresses: [UInt64] = []

  init() throws {
    backing = try DoryX86ByteArrayMemory(byteCount: 0x10_000)
  }

  func install(_ bytes: [UInt8], at address: UInt64) {
    try! backing.write(at: address, bytes: bytes)
  }

  func storedUInt32(at address: UInt64) -> UInt32 {
    let bytes = try! backing.read(at: address, byteCount: 4)
    return bytes.enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << UInt32($1.offset * 8)
    }
  }

  func snapshot() -> [UInt8] { backing.snapshot() }

  func resetObservations() {
    validatedWriteAddresses = []
    dataReadAddresses = []
    dataWriteAddresses = []
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReadAddresses.append(address)
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataWriteAddresses.append(address)
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    validatedWriteAddresses.append(address)
    if let writeFault { throw writeFault }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() {}
}

extension DoryX86InterpreterResult {
  fileprivate var isRetired: Bool {
    if case .retired = self { return true }
    return false
  }
}
