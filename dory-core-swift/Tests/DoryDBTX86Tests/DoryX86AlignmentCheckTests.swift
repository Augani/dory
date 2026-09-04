import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A Event 17 and Table 7-7: #AC is a fault with
// error code zero, enabled by CR0.AM + RFLAGS.AC at CPL 3 (including VM86).
// Segment and paging faults for the access take priority.
// https://cdrdv2.intel.com/v1/dl/getContent/671190
@Suite struct DoryX86AlignmentCheckTests {
  @Test func admissionRequiresAllControlBitsAndEffectiveCPLThree() throws {
    var state = try userState()
    #expect(DoryX86AlignmentPolicy.isEnabled(state: state))
    state.control.cr0 &= ~(UInt64(1) << 18)
    #expect(!DoryX86AlignmentPolicy.isEnabled(state: state))
    state.control.cr0 |= UInt64(1) << 18
    state.rflags.remove(.alignmentCheck)
    #expect(!DoryX86AlignmentPolicy.isEnabled(state: state))
    state.rflags.insert(.alignmentCheck)
    state.cs.selector = 0
    #expect(!DoryX86AlignmentPolicy.isEnabled(state: state))

    var virtual = try userState(mode: .protected16)
    virtual.cs.selector = 0
    virtual.rflags.insert(.virtual8086)
    #expect(DoryX86AlignmentPolicy.isEnabled(state: virtual))
    virtual.control.cr0 &= ~UInt64(1)
    #expect(!DoryX86AlignmentPolicy.isEnabled(state: virtual))
  }

  @Test func ordinaryScalarReadsAndWritesFaultBeforeEffects() throws {
    for (bytes, write): ([UInt8], Bool) in [
      ([0x8B, 0x03], false), // MOV EAX,[RBX]
      ([0x89, 0x03], true),  // MOV [RBX],EAX
      ([0x48, 0x8B, 0x03], false), // MOV RAX,[RBX]
    ] {
      let memory = try AlignmentTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install([UInt8](repeating: 0x5A, count: 16), at: 0x8000)
      var state = try userState(mode: bytes.first == 0x48 ? .long64 : .protected32)
      state.registers.rbx = 0x8001
      let before = state
      let snapshot = memory.snapshot()
      #expect(DoryX86Interpreter().step(
        state: &state, memory: memory,
        mode: bytes.first == 0x48 ? .long64 : .protected32) == alignmentFault)
      #expect(state == before)
      #expect(memory.snapshot() == snapshot)
      #expect(memory.validatedReads == (write ? 0 : 1))
      #expect(memory.validatedWrites == (write ? 1 : 0))
      #expect(memory.dataReads == 0 && memory.dataWrites == 0)
    }
  }

  @Test func pageAndSegmentFaultsPrecedeAlignmentCheck() throws {
    let memory = try AlignmentTrackingMemory()
    memory.install([0x8B, 0x03], at: 0x1000) // MOV EAX,[RBX]
    memory.readFault = .pageFault(address: 0x8001, errorCode: 5)
    var paged = try userState()
    paged.registers.rbx = 0x8001
    let before = paged
    #expect(DoryX86Interpreter().step(state: &paged, memory: memory, mode: .protected32)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 5,
        instructionPointer: 0x1000, linearAddress: 0x8001)))
    var expected = before
    expected.control.cr2 = 0x8001
    #expect(paged == expected)
    #expect(memory.validatedReads == 1 && memory.dataReads == 0)

    memory.readFault = nil
    memory.resetObservations()
    var segmented = try userState()
    segmented.registers.rbx = 0x8001
    segmented.ds.limit = 0x100
    let segmentedBefore = segmented
    #expect(DoryX86Interpreter().step(state: &segmented, memory: memory, mode: .protected32)
      == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: 0x1000)))
    #expect(segmented == segmentedBefore)
    #expect(memory.validatedReads == 0 && memory.dataReads == 0)
  }

  @Test func byteAlignedAndDisabledAccessesRetainOrdinaryBehavior() throws {
    for variant in 0..<5 {
      let memory = try AlignmentTrackingMemory()
      let bytes: [UInt8] = variant == 0 ? [0x8A, 0x03] : [0x8B, 0x03]
      memory.install(bytes, at: 0x1000)
      memory.install([0x78, 0x56, 0x34, 0x12, 0xAB], at: 0x8001)
      var state = try userState()
      state.registers.rbx = 0x8001
      switch variant {
      case 1: state.control.cr0 &= ~(UInt64(1) << 18)
      case 2: state.rflags.remove(.alignmentCheck)
      case 3: state.cs.selector = 0
      case 4: state.registers.rbx = 0x8004
      default: break
      }
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .protected32)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
        == .retired(decoded))
      #expect(state.rip == UInt64(0x1000 + bytes.count))
      #expect(memory.dataReads == 1)
    }
  }

  @Test func stackAndStringOperandsUseTheirElementAlignment() throws {
    for (bytes, mode, configure):
      ([UInt8], DoryX86ExecutionMode, (inout DoryX86ArchitecturalState) -> Void) in [
      ([0x50], .protected32, { $0.registers.rsp = 0x8005 }), // PUSH EAX -> 8001
      ([0x58], .protected32, { $0.registers.rsp = 0x8001 }), // POP EAX
      ([0xCF], .protected32, { $0.registers.rsp = 0x8001 }), // IRETD
      ([0xAB], .protected32, { $0.registers.rdi = 0x9001 }), // STOSD
      ([0x48, 0xA5], .long64, { $0.registers.rsi = 0x8001; $0.registers.rdi = 0x9000 }),
    ] {
      let memory = try AlignmentTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install([UInt8](repeating: 0x11, count: 16), at: 0x8000)
      memory.install([UInt8](repeating: 0x22, count: 16), at: 0x9000)
      var state = try userState(mode: mode)
      configure(&state)
      let before = state
      let snapshot = memory.snapshot()
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        == alignmentFault)
      #expect(state == before && memory.snapshot() == snapshot)
      #expect(memory.dataReads == 0 && memory.dataWrites == 0)
    }
  }

  @Test func scalarSIMDX87BitStringAndCompareExchangePairFaultPrecisely() throws {
    let cases: [([UInt8], UInt64)] = [
      ([0xF3, 0x0F, 0x10, 0x03], 0x8001), // MOVSS XMM0,[RBX]
      ([0xDD, 0x03], 0x8001),             // FLD m64 [RBX]
      ([0x0F, 0xA3, 0x0B], 0x8001),       // BT dword [RBX],ECX
      ([0x0F, 0xC7, 0x0B], 0x8001),       // CMPXCHG8B [RBX]
      ([0x0F, 0x01, 0x03], 0x8001),       // SGDT [RBX]
      ([0x0F, 0x00, 0x0B], 0x8002),       // STR [RBX], task-register contents align to 4
      ([0xFF, 0x2B], 0x8001),             // JMP far ptr48 [RBX]
    ]
    for (bytes, address) in cases {
      let memory = try AlignmentTrackingMemory()
      memory.install(bytes, at: 0x1000)
      memory.install([UInt8](repeating: 0, count: 32), at: 0x8000)
      var state = try userState()
      state.registers.rbx = address
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
        == alignmentFault)
      #expect(state == before)
      #expect(memory.dataReads == 0 && memory.dataWrites == 0)
    }
  }

  @Test func writePermissionFaultPrecedesAlignmentCheckForRMW() throws {
    let memory = try AlignmentTrackingMemory()
    memory.install([0x83, 0x03, 0x01], at: 0x1000) // ADD dword [RBX],1
    memory.writeFault = .pageFault(address: 0x8001, errorCode: 7)
    var state = try userState()
    state.registers.rbx = 0x8001
    let before = state
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 7,
        instructionPointer: 0x1000, linearAddress: 0x8001)))
    var expected = before
    expected.control.cr2 = 0x8001
    #expect(state == expected)
    #expect(memory.validatedWrites == 1)
    #expect(memory.validatedReads == 0 && memory.dataReads == 0 && memory.dataWrites == 0)
  }

  @Test func translatedPreflightNeverReadsTheDataMappingAndSpansPagesPrecisely() throws {
    for secondPagePresent in [true, false] {
      let physical = try AlignmentTrackingMemory()
      // One legacy page directory maps code at 1000 and the two data pages at
      // 8000/9000. The FLD m64 operand begins three bytes before the boundary.
      physical.install(littleEndian32(0x2027), at: 0x1000)
      physical.install(littleEndian32(0x3027), at: 0x2004)
      physical.install(littleEndian32(0x4027), at: 0x2020)
      if secondPagePresent { physical.install(littleEndian32(0x5027), at: 0x2024) }
      physical.install([0xDD, 0x03], at: 0x3000)
      physical.install([UInt8](repeating: 0, count: 3), at: 0x4FFD)
      if secondPagePresent { physical.install([UInt8](repeating: 0, count: 5), at: 0x5000) }
      physical.resetObservations()
      var state = try userState()
      state.control.cr0 |= 1 << 31
      state.control.cr3 = 0x1000
      state.registers.rbx = 0x8FFD
      let before = state
      let result = DoryX86Interpreter().step(
        state: &state,
        memory: physical,
        mode: .protected32,
        pagingUnit: DoryX86PagingUnit()
      )
      if secondPagePresent {
        #expect(result == alignmentFault)
        #expect(state == before)
        #expect(physical.validatedReadAddresses.contains(0x4FFD))
        #expect(physical.validatedReadAddresses.contains(0x5000))
      } else {
        #expect(result == .exception(.init(kind: .pageFault, vector: 14, errorCode: 4,
          instructionPointer: 0x1000, linearAddress: 0x9000)))
        var expected = before
        expected.control.cr2 = 0x9000
        #expect(state == expected)
      }
      // Page-table walks and instruction fetches may read physical memory; the
      // translated data mappings themselves must only receive permission probes.
      #expect(!physical.dataReadAddresses.contains(0x4FFD))
      #expect(!physical.dataReadAddresses.contains(0x5000))
      #expect(physical.dataWrites == 0)
    }
  }

  @Test func nativeExecutorsDeclineBeforeFetchOrEffectsWhenAlignmentCheckingIsActive() throws {
    #if arch(arm64)
      for optimization: DoryARM64JITOptimization in [.baseline, .optimizing] {
        let memory = try AlignmentTrackingMemory()
        memory.install([0x48, 0xFF, 0x07], at: 0x1000) // INC qword [RDI]
        memory.install([UInt8](repeating: 0, count: 16), at: 0x8000)
        var state = try userState(mode: .long64)
        state.registers.rdi = 0x8001
        let before = state
        let snapshot = memory.snapshot()
        var fetches = 0
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16_384, optimization: optimization)
        #expect(try executor.executeSummary(
          byteProvider: { _ in fetches += 1; return [0x48, 0xFF, 0x07] },
          at: 0x1000, mode: .long64, addressSpaceID: 1,
          maximumInstructions: 1, state: &state, memory: memory) == nil)
        #expect(fetches == 0 && state == before && memory.snapshot() == snapshot)
        #expect(try executor.executeChainedSummary(
          byteProvider: { _, _ in fetches += 1; return [0x48, 0xFF, 0x07] },
          at: 0x1000, mode: .long64, addressSpaceID: 1,
          maximumInstructions: 1, state: &state, memory: memory) == nil)
        #expect(fetches == 0 && state == before && memory.snapshot() == snapshot)
      }
    #endif
  }

  private var alignmentFault: DoryX86InterpreterResult {
    .exception(.init(kind: .alignmentCheck, vector: 17, errorCode: 0,
      instructionPointer: 0x1000))
  }

  private func userState(
    mode: DoryX86ExecutionMode = .protected32
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: 0x1234_5678, rcx: 1, rsp: 0x9000),
      rip: 0x1000,
      rflags: [.reservedOne, .alignmentCheck],
      cs: .init(selector: 3, attributes: mode == .long64 ? 0xA0FB : 0xC0FB, limit: .max),
      ds: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      es: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      ss: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      control: .init(cr0: 0x4_0011, cr4: 1 << 9)
    )
  }

  private func littleEndian32(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }
}

private final class AlignmentTrackingMemory: DoryX86Memory, @unchecked Sendable {
  private let backing: DoryX86ByteArrayMemory
  var readFault: DoryX86MemoryError?
  var writeFault: DoryX86MemoryError?
  private(set) var validatedReads = 0
  private(set) var validatedWrites = 0
  private(set) var dataReads = 0
  private(set) var dataWrites = 0
  private(set) var validatedReadAddresses: [UInt64] = []
  private(set) var dataReadAddresses: [UInt64] = []

  init() throws {
    backing = try DoryX86ByteArrayMemory(byteCount: 0x10_000)
  }

  func install(_ bytes: [UInt8], at address: UInt64) {
    try! backing.write(at: address, bytes: bytes)
  }

  func snapshot() -> [UInt8] { backing.snapshot() }

  func resetObservations() {
    validatedReads = 0
    validatedWrites = 0
    dataReads = 0
    dataWrites = 0
    validatedReadAddresses = []
    dataReadAddresses = []
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReads += 1
    dataReadAddresses.append(address)
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    validatedReads += 1
    validatedReadAddresses.append(address)
    if let readFault { throw readFault }
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataWrites += 1
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    validatedWrites += 1
    if let writeFault { throw writeFault }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }
}
