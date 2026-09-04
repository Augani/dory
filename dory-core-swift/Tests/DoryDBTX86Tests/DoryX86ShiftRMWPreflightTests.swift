import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2B SAL/SAR/SHL/SHR, RCL/RCR/ROL/ROR, SHLD, and SHRD:
// memory destinations are writable read-modify-write operands. Their memory
// exceptions precede operand reads and architectural flag/register effects,
// including when the masked count is zero.
// https://cdrdv2.intel.com/v1/dl/getContent/671110
@Suite struct DoryX86ShiftRMWPreflightTests {
  @Test func deniedWritesPrecedeReadsAndEffectsForScalarAndDoubleShifts() throws {
    let cases: [(bytes: [UInt8], count: UInt64)] = [
      ([0xD1, 0x23], 1),  // SHL dword ptr [RBX],1
      ([0xD1, 0x0B], 1),  // ROR dword ptr [RBX],1
      ([0xD3, 0x23], 32),  // SHL dword ptr [RBX],CL; masked count zero
      ([0x0F, 0xA5, 0x13], 4),  // SHLD dword ptr [RBX],EDX,CL
      ([0x0F, 0xAD, 0x13], 4),  // SHRD dword ptr [RBX],EDX,CL
      ([0x0F, 0xA4, 0x13, 0], 7),  // SHLD dword ptr [RBX],EDX,0
    ]
    for item in cases {
      let memory = try ShiftRMWTrackingMemory()
      memory.install(item.bytes, at: 0x1000)
      memory.install(littleEndian32(0x1234_5678), at: 0x8000)
      memory.writeFault = .pageFault(address: 0x8000, errorCode: 7)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rcx = item.count
      state.registers.rdx = 0x9abc_defa
      state.rflags = [.reservedOne, .carry, .zero, .overflow, .direction]
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

  @Test func segmentAndCanonicalSpansPrecedeBackingReads() throws {
    for bytes: [UInt8] in [[0xD1, 0x23], [0x0F, 0xA4, 0x13, 1]] {
      let segmentedMemory = try ShiftRMWTrackingMemory()
      segmentedMemory.install(bytes, at: 0x1000)
      var segmented = try protectedState()
      segmented.registers.rbx = 0x8002
      segmented.registers.rdx = 0x9abc_defa
      segmented.ds.limit = 0x8004
      let before = segmented

      #expect(
        DoryX86Interpreter().step(
          state: &segmented, memory: segmentedMemory, mode: .protected32)
          == protectionFault)
      #expect(segmented == before)
      #expect(segmentedMemory.validatedWriteAddresses.isEmpty)
      #expect(segmentedMemory.dataReadAddresses.isEmpty)
      #expect(segmentedMemory.dataWriteAddresses.isEmpty)

      let canonicalMemory = try ShiftRMWTrackingMemory()
      let longBytes = [UInt8(0x48)] + bytes
      canonicalMemory.install(longBytes, at: 0x1000)
      var canonical = try longState()
      canonical.registers.rbx = 0x0000_7fff_ffff_fffe
      canonical.registers.rdx = 0x9abc_defa
      let canonicalBefore = canonical

      #expect(
        DoryX86Interpreter().step(
          state: &canonical, memory: canonicalMemory, mode: .long64)
          == protectionFault)
      #expect(canonical == canonicalBefore)
      #expect(canonicalMemory.validatedWriteAddresses.isEmpty)
      #expect(canonicalMemory.dataReadAddresses.isEmpty)
      #expect(canonicalMemory.dataWriteAddresses.isEmpty)
    }
  }

  @Test func pagingWriteFaultPrecedesAlignmentCheckAndBackingRead() throws {
    for bytes: [UInt8] in [[0xD1, 0x23], [0x0F, 0xA4, 0x13, 1]] {
      let memory = try ShiftRMWTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install(littleEndian32(0x1234_5678), at: 0x8001)
      memory.writeFault = .pageFault(address: 0x8001, errorCode: 7)
      memory.resetObservations()
      var state = try alignmentState()
      state.registers.rbx = 0x8001
      state.registers.rdx = 0x9abc_defa
      let before = state

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == pageFault(address: 0x8001, errorCode: 7))
      var expected = before
      expected.control.cr2 = 0x8001
      #expect(state == expected)
      #expect(memory.validatedWriteAddresses == [0x8001])
      #expect(memory.dataReadAddresses.isEmpty)
      #expect(memory.dataWriteAddresses.isEmpty)
    }
  }

  @Test func alignmentCheckPrecedesBackingReadAndEffectsAfterWritableAdmission() throws {
    for bytes: [UInt8] in [[0xD1, 0x23], [0x0F, 0xAC, 0x13, 1]] {
      let memory = try ShiftRMWTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install(littleEndian32(0x1234_5678), at: 0x8001)
      memory.resetObservations()
      var state = try alignmentState()
      state.registers.rbx = 0x8001
      state.registers.rdx = 0x9abc_defa
      let before = state

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == alignmentFault)
      #expect(state == before)
      #expect(memory.validatedWriteAddresses == [0x8001])
      #expect(memory.dataReadAddresses.isEmpty)
      #expect(memory.dataWriteAddresses.isEmpty)
    }
  }

  @Test func scalarShiftAndRotateRetainSuccessfulEffects() throws {
    let cases: [(bytes: [UInt8], initial: UInt32, expected: UInt32, carry: Bool)] = [
      ([0xD1, 0x23], 5, 10, false),  // SHL dword ptr [RBX],1
      ([0xD1, 0x0B], 1, 0x8000_0000, true),  // ROR dword ptr [RBX],1
    ]
    for item in cases {
      let memory = try ShiftRMWTrackingMemory()
      memory.install(item.bytes, at: 0x1000)
      memory.install(littleEndian32(item.initial), at: 0x8000)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      let decoded = try DoryX86Decoder().decode(
        item.bytes, at: 0x1000, mode: .protected32)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == .retired(decoded))
      #expect(memory.storedUInt32(at: 0x8000) == item.expected)
      #expect(state.rflags.contains(.carry) == item.carry)
      #expect(memory.validatedWriteAddresses == [0x8000])
      #expect(memory.dataReadAddresses == [0x8000])
      #expect(memory.dataWriteAddresses == [0x8000])
    }
  }

  @Test func doubleShiftsRetainSuccessfulEffects() throws {
    let cases: [(bytes: [UInt8], expected: UInt32)] = [
      ([0x0F, 0xA4, 0x13, 4], 0x2345_6789),  // SHLD [RBX],EDX,4
      ([0x0F, 0xAC, 0x13, 4], 0xA123_4567),  // SHRD [RBX],EDX,4
    ]
    for item in cases {
      let memory = try ShiftRMWTrackingMemory()
      memory.install(item.bytes, at: 0x1000)
      memory.install(littleEndian32(0x1234_5678), at: 0x8000)
      memory.resetObservations()
      var state = try protectedState()
      state.registers.rbx = 0x8000
      state.registers.rdx = 0x9abc_defa
      let decoded = try DoryX86Decoder().decode(
        item.bytes, at: 0x1000, mode: .protected32)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          == .retired(decoded))
      #expect(memory.storedUInt32(at: 0x8000) == item.expected)
      #expect(memory.validatedWriteAddresses == [0x8000])
      #expect(memory.dataReadAddresses == [0x8000])
      #expect(memory.dataWriteAddresses == [0x8000])
    }
  }

  private var protectionFault: DoryX86InterpreterResult {
    .exception(
      .init(
        kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: 0x1000))
  }

  private var alignmentFault: DoryX86InterpreterResult {
    .exception(
      .init(
        kind: .alignmentCheck, vector: 17, errorCode: 0,
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
      rflags: [.reservedOne, .carry, .zero, .overflow, .direction],
      cs: .init(selector: 0x08, attributes: 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      es: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      control: .init(cr0: 1)
    )
  }

  private func alignmentState() throws -> DoryX86ArchitecturalState {
    var state = try protectedState()
    state.cs.selector = 3
    state.rflags.insert(.alignmentCheck)
    state.control.cr0 |= 1 << 18
    return state
  }

  private func longState() throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000,
      rflags: [.reservedOne, .carry, .zero, .overflow, .direction],
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

private final class ShiftRMWTrackingMemory: DoryX86Memory, @unchecked Sendable {
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
