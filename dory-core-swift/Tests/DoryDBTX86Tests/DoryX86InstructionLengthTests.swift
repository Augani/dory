import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 3A, Table 7-2 and Event 13: code-fetch faults precede
// overlength decode faults; an instruction exceeding 15 bytes raises #GP(0).
// https://cdrdv2-public.intel.com/868137/325462-089-sdm-vol-1-2abcd-3abcd-4.pdf
@Suite struct DoryX86InstructionLengthTests {
  @Test func decoderDistinguishesMissingBytesWithinTheLimitFromByteSixteen() throws {
    for mode in modes {
      #expect(throws: DoryX86DecodeError.truncated(address: 0x1000)) {
        try DoryX86Decoder().decode(Array(repeating: 0x67, count: 14), at: 0x1000, mode: mode)
      }
      for bytes in overlengthPrefixes {
        #expect(bytes.count == 15)
        for tail: [UInt8] in [[], [0x90], [0xFF, 0xFF, 0xFF, 0xFF]] {
          #expect(throws: DoryX86DecodeError.instructionTooLong(address: 0x1000)) {
            try DoryX86Decoder().decode(bytes + tail, at: 0x1000, mode: mode)
          }
        }
      }
    }
  }

  @Test func overlengthInstructionsRaiseGeneralProtectionWithoutFetchingByteSixteenOrCommitting() throws {
    for mode in modes {
      for bytes in overlengthPrefixes {
        let physical = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
        let observed = FetchObservedMemory(physical)
        var state = try state(mode: mode, rip: 0x1000)
        let before = state
        #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: mode)
          == generalProtection(rip: 0x1000))
        #expect(state == before)
        #expect(physical.snapshot() == bytes)
        #expect(observed.fetches.map(\.count).max() == 15)
        #expect(observed.fetches.allSatisfy { $0.address + UInt64($0.count) <= 0x100F })
        #expect(observed.dataReads == 0 && observed.dataWrites == 0)
      }
    }
  }

  @Test func exactlyFifteenByteInstructionsRetireWithoutFetchingTheNextInstruction() throws {
    let bytes = Array(repeating: UInt8(0x67), count: 14) + [0x90]
    for mode in modes {
      let physical = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      let observed = FetchObservedMemory(physical)
      var state = try state(mode: mode, rip: 0x1000, codeLimit: 0x100E)
      var expected = state
      expected.rip = 0x100F
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
      #expect(instruction.length == 15)
      #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: mode)
        == .retired(instruction))
      #expect(state == expected)
      #expect(observed.fetches.map(\.count).max() == 15)
      #expect(observed.fetches.allSatisfy { $0.address + UInt64($0.count) <= 0x100F })
    }
  }

  @Test func missingInstructionBytesThroughByteFifteenKeepPrecisePageFaultPriority() throws {
    for privilege: UInt16 in [0, 3] {
      for presentCount in 0..<15 {
        let rip = UInt64(0x2000 - presentCount)
        let physical = try pagedMemory()
        try physical.write(at: rip, bytes: Array(repeating: 0x67, count: presentCount))
        var state = try pagedState(rip: rip, privilege: privilege)
        let observed = observedPagedMemory(physical, state: state)
        var expected = state
        expected.control.cr2 = 0x2000
        #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: .long64)
          == .exception(.init(kind: .pageFault, vector: 14,
            errorCode: privilege == 3 ? 0x14 : 0x10,
            instructionPointer: rip, linearAddress: 0x2000)))
        #expect(state == expected)
        #expect(observed.fetches.allSatisfy { $0.address + UInt64($0.count) <= rip + 15 })
        #expect(observed.dataReads == 0 && observed.dataWrites == 0)
      }
    }
    // Even when byte 14's opcode implies that the whole immediate cannot fit,
    // a fault fetching byte 15 must win over the eventual length violation.
    let physical = try pagedMemory()
    try physical.write(at: 0x1FF2, bytes: Array(repeating: 0x67, count: 13) + [0xB8])
    var state = try pagedState(rip: 0x1FF2, privilege: 3)
    let observed = observedPagedMemory(physical, state: state)
    #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: .long64)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0x14,
        instructionPointer: 0x1FF2, linearAddress: 0x2000)))
    #expect(state.rip == 0x1FF2 && state.control.cr2 == 0x2000)
  }

  @Test func anUnmappedByteSixteenDoesNotOverrideOverlengthOrValidFifteenByteInstructions() throws {
    for completesInstruction in [false, true] {
      let bytes = Array(repeating: UInt8(0x67), count: 14)
        + [completesInstruction ? 0x90 : 0x67]
      let physical = try pagedMemory()
      try physical.write(at: 0x1FF1, bytes: bytes)
      var state = try pagedState(rip: 0x1FF1, privilege: 3)
      let observed = observedPagedMemory(physical, state: state)
      var expected = state
      let result = DoryX86Interpreter().step(state: &state, memory: observed, mode: .long64)
      if completesInstruction {
        let instruction = try DoryX86Decoder().decode(bytes, at: 0x1FF1, mode: .long64)
        #expect(result == .retired(instruction))
        expected.rip = 0x2000
      } else {
        #expect(result == generalProtection(rip: 0x1FF1))
      }
      #expect(state == expected)
      #expect(observed.fetches.map(\.count).max() == 15)
      #expect(observed.fetches.allSatisfy { $0.address + UInt64($0.count) <= 0x2000 })
    }
  }

  @Test func codeSegmentLimitStopsIncompleteFetchBeforeTheLengthLimit() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      for presentCount in [1, 7, 14] {
        let physical = try DoryX86ByteArrayMemory(baseAddress: 0x1000,
          bytes: Array(repeating: 0x67, count: 15) + [0x90])
        let observed = FetchObservedMemory(physical)
        var state = try state(mode: mode, rip: 0x1000,
          codeLimit: UInt32(0x1000 + presentCount - 1))
        let before = state
        #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: mode)
          == generalProtection(rip: 0x1000))
        #expect(state == before)
        #expect(observed.fetches.map(\.count).max() == presentCount)
        #expect(observed.fetches.allSatisfy {
          $0.address + UInt64($0.count) <= 0x1000 + UInt64(presentCount)
        })
      }
    }
  }

  @Test func completeInvalidEncodingsDoNotFetchIrrelevantLaterBytes() throws {
    for bytes: [UInt8] in [[0x0F, 0x0B], [0xF0, 0x90], [0x0F, 0x0C]] {
      let physical = try pagedMemory()
      try physical.write(at: 0x1FFE, bytes: bytes)
      var state = try pagedState(rip: 0x1FFE, privilege: 3)
      let observed = observedPagedMemory(physical, state: state)
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: observed, mode: .long64)
        == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1FFE)))
      #expect(state == before)
      #expect(observed.fetches.map(\.count) == [1, 2])
      #expect(observed.dataReads == 0 && observed.dataWrites == 0)
    }
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private var overlengthPrefixes: [[UInt8]] {
    [
      Array(repeating: 0x67, count: 15),
      Array(repeating: 0x67, count: 14) + [0x0F], // Second opcode byte.
      Array(repeating: 0x67, count: 14) + [0xFF], // ModRM byte.
      Array(repeating: 0x67, count: 13) + [0x8B, 0x84], // SIB or displacement.
      Array(repeating: 0x67, count: 13) + [0xB8, 0x78], // Immediate byte.
      Array(repeating: 0x67, count: 13) + [0xC6, 0x03], // Store immediate.
    ]
  }

  private func state(mode: DoryX86ExecutionMode, rip: UInt64, codeLimit: UInt32 = .max) throws
    -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0xA5, rbx: 0x1100), rip: rip,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(selector: 0, attributes: mode == .protected32 ? 0xC09B : 0x009B, limit: codeLimit),
      control: .init(cr0: mode == .real16 ? 0 : 1, cr2: 0x1234))
  }

  private func pagedMemory() throws -> DoryX86ByteArrayMemory {
    let physical = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [
      (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007), (0xC008, 0x1007),
    ] { try physical.writeScalar(at: address, value: value, byteCount: 8) }
    return physical
  }

  private func pagedState(rip: UInt64, privilege: UInt16) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0xA5), rip: rip,
      cs: .init(selector: privilege, attributes: privilege == 3 ? 0xA0FB : 0xA09B, limit: .max),
      control: .init(cr0: 0x8001_0011, cr2: 0x1234, cr3: 0x9000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }

  private func observedPagedMemory(_ physical: DoryX86ByteArrayMemory,
    state: DoryX86ArchitecturalState) -> FetchObservedMemory {
    FetchObservedMemory(DoryX86TranslatedMemory(physicalMemory: physical,
      pagingUnit: .init(), context: .init(state: state, mode: .long64)))
  }

  private func generalProtection(rip: UInt64) -> DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: rip))
  }
}

// Each test owns this observer and executes one vCPU synchronously.
private final class FetchObservedMemory: DoryX86Memory, @unchecked Sendable {
  struct Fetch { let address: UInt64; let count: Int }
  let memory: any DoryX86Memory
  var fetches: [Fetch] = []
  var dataReads = 0
  var dataWrites = 0

  init(_ memory: any DoryX86Memory) { self.memory = memory }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    fetches.append(.init(address: address, count: maximumCount))
    return try memory.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataReads += 1
    return try memory.read(at: address, byteCount: byteCount)
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    try memory.validateRead(at: address, byteCount: byteCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataWrites += 1
    try memory.write(at: address, bytes: bytes)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try memory.validateWrite(at: address, byteCount: byteCount)
  }
  func synchronize() { memory.synchronize() }
}
