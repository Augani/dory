import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2A, IRET REAL-ADDRESS-MODE p. 3-491 and exceptions p. 3-497:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// Vol. 1 §6.2.3: SS.B controls implicit stack addresses, independently of 67H.
// https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf
// Ordinary real-mode CS reloads are covered here; nonstandard cached CS limits,
// virtual-8086 mode, NMI unblocking and task returns remain separate work.
@Suite struct DoryX86RealIRETTests {
  @Test func decodedOperandWidthAndStackAddressSizeAreIndependentOfAddressOverride() throws {
    for operand32 in [false, true] {
      for stack32 in [false, true] {
        for addressOverride in [false, true] {
          let width = operand32 ? 4 : 2
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x40000)
          var state = try state(stack32: stack32)
          let code = instruction(operand32: operand32, addressOverride: addressOverride)
          try memory.write(at: 0x100, bytes: code)
          let stack = stack32 ? UInt64(0x18000) : 0x8000
          try memory.write(at: 0x10000 + stack,
            bytes: frame([0x5678, 0xBEEF_1234, 3], width: width))
          state.ss.limit = UInt32(stack + UInt64(3 * width) - 1)
          let before = state
          let contents = memory.snapshot()
          let decoded = try DoryX86Decoder().decode(code, at: 0x100, mode: .real16)
          #expect(decoded.operation == .interruptReturn)
          #expect(decoded.prefixes.operandSizeOverride == operand32)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
            == .retired(decoded))
          #expect(state.rip == 0x5678)
          #expect(state.cs == .init(selector: 0x1234, attributes: 0x009B,
            limit: 0xFFFF, base: 0x12340))
          #expect(state.ss == before.ss)
          let expectedStack = stack32 ? stack + UInt64(3 * width)
            : (before.registers.rsp & ~UInt64(0xFFFF)) | (stack + UInt64(3 * width))
          #expect(state.registers.rsp == expectedStack)
          #expect(state.rflags.rawValue == 3)
          #expect(memory.snapshot() == contents)
        }
      }
    }
  }

  @Test func flagsUseRealModeMasksAndIgnoreReservedBitsInThePoppedImage() throws {
    let images: [UInt64] = [0, 0xFFFF_FFFF] + (0..<32).map { UInt64(1) << $0 }
    for width in [2, 4] {
      for old: UInt64 in [2, 0x1A0002, 0x3F7FD7] {
        for image in images {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x20000)
          var state = try state()
          state.rflags = .init(rawValue: old)
          try memory.write(at: 0x18000, bytes: frame([0x4321, 0x2345, image], width: width))
          try DoryX86InterruptDelivery().interruptReturn(state: &state,
            physicalMemory: memory, mode: .real16, operandSizeOverride: width == 4)
          let expected = width == 4 ? (image & 0x257FD5) | (old & 0x1A0000) | 2
            : (image & 0x7FD5) | (old & ~UInt64(0xFFFF)) | 2
          #expect(state.rflags.rawValue == expected)
          #expect(try state.rflags.validated() == state.rflags)
          #expect(state.rip == 0x4321 && state.cs.selector == 0x2345)
        }
      }
    }
  }

  @Test func shortOrWrappingFramesRaiseSSBeforeReadsThroughBothEntryPoints() throws {
    for width in [2, 4] {
      for stack32 in [false, true] {
        for crossesPointerBoundary in [false, true] {
          let backing = try DoryX86ByteArrayMemory(byteCount: 0x40000)
          let code = instruction(operand32: width == 4)
          try backing.write(at: 0x100, bytes: code)
          var state = try state(stack32: stack32)
          if crossesPointerBoundary {
            state.registers.rsp = stack32 ? 0xFFFF_FFFC : 0xABCD_FFFC
            // The pointer-width bound still applies if a cached limit is wider.
            state.ss.limit = .max
          } else {
            let stack = stack32 ? 0x18000 : 0x8000
            state.ss.limit = UInt32(stack + 3 * width - 2)
          }
          let before = state
          let memory = RealIRETReadTrackingMemory(backing: backing)
          let fault = DoryX86Exception(kind: .stackSegment, vector: 12,
            errorCode: 0, instructionPointer: 0x100)
          #expect(throws: fault) {
            try DoryX86InterruptDelivery().interruptReturn(state: &state,
              physicalMemory: memory, mode: .real16, operandSizeOverride: width == 4)
          }
          #expect(state == before)
          #expect(memory.stackReads.isEmpty)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
            == .exception(fault))
          #expect(state == before)
          #expect(memory.stackReads.isEmpty)
        }
      }
    }
  }

  @Test func anExactlyFittingFrameMayWrapTheFinalStackPointerAfterTheLastPop() throws {
    for width in [2, 4] {
      for stack32 in [false, true] {
        var state = try state(stack32: stack32)
        let mask: UInt64 = stack32 ? 0xFFFF_FFFF : 0xFFFF
        let stack = mask - UInt64(3 * width) + 1
        state.registers.rsp = 0xCAFE_0000_0000 | stack
        state.ss.limit = UInt32(mask)
        let memory = try DoryX86ByteArrayMemory(baseAddress: state.ss.base + stack,
          bytes: frame([0xFFFF, 0, 2], width: width))
        let before = state
        try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: memory,
          mode: .real16, operandSizeOverride: width == 4)
        #expect(state.rip == 0xFFFF && state.cs.selector == 0)
        #expect(state.registers.rsp == (stack32 ? 0 : before.registers.rsp & ~UInt64(0xFFFF)))
        #expect(state.ss == before.ss)
      }
    }
  }

  @Test func iretdRejectsOutOfRangeEIPWithoutTruncationOrPartialState() throws {
    for target: UInt64 in [0x10000, 0x1234_5678, 0xFFFF_FFFF] {
      let backing = try DoryX86ByteArrayMemory(byteCount: 0x20000)
      try backing.write(at: 0x100, bytes: [0x66, 0xCF])
      try backing.write(at: 0x18000, bytes: frame([target, 0x2345, 0xFFFF_FFFF], width: 4))
      var state = try state()
      state.rflags = [.reservedOne, .direction, .overflow, .virtualInterrupt]
      let before = state
      let contents = backing.snapshot()
      let fault = DoryX86Exception(kind: .generalProtection, vector: 13,
        errorCode: 0, instructionPointer: 0x100)
      #expect(throws: fault) {
        try DoryX86InterruptDelivery().interruptReturn(state: &state,
          physicalMemory: backing, mode: .real16, operandSizeOverride: true)
      }
      #expect(state == before)
      #expect(DoryX86Interpreter().step(state: &state, memory: backing, mode: .real16)
        == .exception(fault))
      #expect(state == before)
      #expect(backing.snapshot() == contents)
      // The word form consumes only IP, so it can return to the low word.
      try backing.write(at: 0x18000, bytes: frame([target, 0x2345, 2], width: 2))
      try DoryX86InterruptDelivery().interruptReturn(state: &state,
        physicalMemory: backing, mode: .real16)
      #expect(state.rip == target & 0xFFFF)
    }
  }

  @Test func aLateBackingReadFailureDoesNotPublishEarlierPoppedSlots() throws {
    // This tests the software memory API's failure propagation, not hardware
    // paging in real mode: an unmapped backing read uses the existing #PF path.
    for width in [2, 4] {
      let backing = try DoryX86ByteArrayMemory(byteCount: 0x20000)
      try backing.write(at: 0x100, bytes: instruction(operand32: width == 4))
      try backing.write(at: 0x18000, bytes: frame([0x4321, 0x2345, 3], width: width))
      let denied = UInt64(0x18000 + 3 * width - 1)
      let memory = RealIRETReadTrackingMemory(backing: backing, deniedAddress: denied)
      var state = try state()
      let before = state
      let contents = backing.snapshot()
      let error = DoryX86MemoryError.unmapped(address: denied, byteCount: 1, access: .read)
      #expect(throws: error) {
        try DoryX86InterruptDelivery().interruptReturn(state: &state,
          physicalMemory: memory, mode: .real16, operandSizeOverride: width == 4)
      }
      #expect(state == before)
      #expect(memory.stackReads.count == 3)
      memory.clearReads()
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
        == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0,
          instructionPointer: 0x100, linearAddress: denied)))
      var expected = before
      expected.control.cr2 = denied
      #expect(state == expected)
      #expect(memory.stackReads.count == 3)
      #expect(backing.snapshot() == contents)
    }
  }

  @Test func ordinaryRealModeInterruptEntryStillRoundTripsThroughDecodedIRET16() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x20000)
    try memory.write(at: 0x40, bytes: [0, 2, 0, 0])
    try memory.write(at: 0x200, bytes: [0xCF])
    var state = try state()
    state.idtr = .init(limit: 0x3FF)
    state.rflags = [.reservedOne, .carry, .interruptEnable, .trap, .identification]
    let before = state
    try DoryX86InterruptDelivery().deliver(vector: 0x10, source: .software,
      state: &state, physicalMemory: memory, mode: .real16)
    let decoded = try DoryX86Decoder().decode([0xCF], at: 0x200, mode: .real16)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
      == .retired(decoded))
    #expect(state.rip == before.rip && state.cs == before.cs)
    #expect(state.registers == before.registers && state.rflags == before.rflags)
    #expect(state.ss == before.ss)
  }

  private func state(stack32: Bool = false) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0x1234, rsp: stack32 ? 0xCAFE_0001_8000 : 0xCAFE_8000),
      rip: 0x100, cs: .init(selector: 0, attributes: 0x009B, limit: 0xFFFF),
      ss: .init(selector: 0x1000, attributes: stack32 ? 0x4093 : 0x0093,
        limit: 0x2FFFF, base: 0x10000), control: .init(cr2: 0x1234))
  }

  private func instruction(operand32: Bool, addressOverride: Bool = false) -> [UInt8] {
    (operand32 ? [UInt8(0x66)] : []) + (addressOverride ? [UInt8(0x67)] : []) + [0xCF]
  }

  private func frame(_ values: [UInt64], width: Int) -> [UInt8] {
    values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }
}

private final class RealIRETReadTrackingMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let deniedAddress: UInt64?
  private(set) var stackReads: [UInt64] = []
  init(backing: DoryX86ByteArrayMemory, deniedAddress: UInt64? = nil) {
    self.backing = backing
    self.deniedAddress = deniedAddress
  }
  func clearReads() { stackReads = [] }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address >= 0x10000 { stackReads.append(address) }
    if let deniedAddress, address <= deniedAddress, deniedAddress - address < UInt64(byteCount) {
      throw DoryX86MemoryError.unmapped(address: deniedAddress, byteCount: 1, access: .read)
    }
    return try backing.read(at: address, byteCount: byteCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws { try backing.write(at: address, bytes: bytes) }
}
