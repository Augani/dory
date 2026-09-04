import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A IRET/IRETD/IRETQ, pp. 3-490--498.
// IA-32e dispatch follows EFER.LMA. The instruction's effective operand size
// selects 16/32/64-bit frame slots independently of the target code mode.
@Suite struct DoryX86IA32eIRETCompletionTests {
  @Test func longModeUsesExactSixteenThirtyTwoAndSixtyFourBitFrames() throws {
    let forms: [([UInt8], DoryX86OperandWidth, UInt64, UInt64)] = [
      ([0x66, 0xCF], .word, 0x3456, 0x4321),
      ([0xCF], .doubleword, 0x7654_3210, 0x8765_4321),
      ([0x48, 0xCF], .quadword, 0xFFFF_8000_0000_1234, 0xFFFF_8000_0000_8000),
    ]
    for (instruction, width, target, restoredStack) in forms {
      let memory = try fixtureMemory(
        instruction: instruction,
        width: width,
        frame: [target, 8, DoryX86RFLAGS.reservedOne.rawValue, restoredStack, 0],
        descriptors: [8: codeDescriptor(dpl: 0, long: true)]
      )
      var state = try ia32eState(mode: .long64)
      let decoded = try DoryX86Decoder().decode(instruction, at: 0x1000, mode: .long64)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded)
      )
      #expect(state.rip == target)
      #expect(state.registers.rsp == restoredStack)
      #expect(state.cs.selector == 8)
      #expect(state.ss == .init(selector: 0))
    }
  }

  @Test func compatibilityOriginUsesIA32eRulesAndCanReturnToLongMode() throws {
    for (mode, instruction, width, target):
      (
        DoryX86ExecutionMode, [UInt8], DoryX86OperandWidth, UInt64
      ) in [
        (.protected16, [0xCF], .word, 0x3456),
        (.protected32, [0xCF], .doubleword, 0x7654_3210),
      ]
    {
      let memory = try fixtureMemory(
        instruction: instruction,
        width: width,
        frame: [target, 8, DoryX86RFLAGS.reservedOne.rawValue],
        descriptors: [8: codeDescriptor(dpl: 0, long: true)]
      )
      var state = try ia32eState(mode: mode)
      let decoded = try DoryX86Decoder().decode(instruction, at: 0x1000, mode: mode)

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          == .retired(decoded)
      )
      #expect(state.rip == target)
      #expect(state.cs.attributes & 0x2000 != 0)
      #expect(state.registers.rsp == 0x2000 + UInt64(3 * width.byteCount))
    }
  }

  @Test func longModeCanReturnToCompatibilityCodeAndLoadsTheRealStackDescriptor() throws {
    let instruction: [UInt8] = [0x48, 0xCF]
    let memory = try fixtureMemory(
      instruction: instruction,
      width: .quadword,
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [
        0x18: codeDescriptor(dpl: 3, long: false, default32: true),
        0x20: dataDescriptor(dpl: 3),
      ]
    )
    var state = try ia32eState(mode: .long64)
    let decoded = try DoryX86Decoder().decode(instruction, at: 0x1000, mode: .long64)

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded)
    )
    #expect(state.rip == 0x1234)
    #expect(state.registers.rsp == 0x3000)
    #expect(state.cs == .init(selector: 0x1B, attributes: 0xC0FB, limit: .max, base: 0))
    #expect(state.ss == .init(selector: 0x23, attributes: 0xC0F3, limit: .max, base: 0))
  }

  @Test func codeModeAndPrivilegeRulesRaiseExactSelectorGP() throws {
    let invalidDescriptors: [UInt64] = [
      codeDescriptor(dpl: 3, long: true, default32: true),
      codeDescriptor(dpl: 0, long: false, default32: true),
    ]
    for descriptor in invalidDescriptors {
      let memory = try fixtureMemory(
        instruction: [0x48, 0xCF],
        width: .quadword,
        frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
        descriptors: [0x18: descriptor, 0x20: dataDescriptor(dpl: 3)]
      )
      var state = try ia32eState(mode: .long64)
      let before = state

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == fault(.generalProtection, vector: 13, errorCode: 0x18)
      )
      #expect(state == before)
    }

    let conforming = try fixtureMemory(
      instruction: [0x48, 0xCF],
      width: .quadword,
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [
        0x18: codeDescriptor(dpl: 0, long: true, conforming: true),
        0x20: dataDescriptor(dpl: 3),
      ]
    )
    var state = try ia32eState(mode: .long64)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: conforming, mode: .long64)
        == .retired(try DoryX86Decoder().decode([0x48, 0xCF], at: 0x1000, mode: .long64))
    )
    #expect(state.cs.selector == 0x1B)
  }

  @Test func absentCodeAndCompatibilityLimitUseArchitecturalFaultCodes() throws {
    do {
      let memory = try fixtureMemory(
        instruction: [0x48, 0xCF],
        width: .quadword,
        frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
        descriptors: [
          0x18: codeDescriptor(dpl: 3, long: true, present: false),
          0x20: dataDescriptor(dpl: 3),
        ]
      )
      var state = try ia32eState(mode: .long64)
      let before = state
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == fault(.segmentNotPresent, vector: 11, errorCode: 0x18)
      )
      #expect(state == before)
    }

    do {
      let memory = try fixtureMemory(
        instruction: [0x48, 0xCF],
        width: .quadword,
        frame: [0x1000, 0x1B, 2, 0x3000, 0x23],
        descriptors: [
          0x18: codeDescriptor(dpl: 3, long: false, default32: true, limit: 0x0FFF),
          0x20: dataDescriptor(dpl: 3),
        ]
      )
      var state = try ia32eState(mode: .long64)
      let before = state
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == fault(.generalProtection, vector: 13, errorCode: 0)
      )
      #expect(state == before)
    }
  }

  @Test func descriptorAddressOverflowAndNoncanonicalRangesFaultBeforeMemoryAccess() throws {
    for base: UInt64 in [0x0000_7FFF_FFFF_FFF8, UInt64.max - 4] {
      let memory = try fixtureMemory(
        instruction: [0x48, 0xCF],
        width: .quadword,
        frame: [0x1234, 8, 2, 0x3000, 0],
        descriptors: [:]
      )
      var state = try ia32eState(mode: .long64)
      state.gdtr = .init(limit: 0x0F, base: base)
      let before = state

      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == fault(.generalProtection, vector: 13, errorCode: 8)
      )
      #expect(state == before)
    }
  }

  @Test func descriptorPageFaultPublishesOnlyNMIUnblockAndCR2() throws {
    let backing = try fixtureMemory(
      instruction: [0x48, 0xCF],
      width: .quadword,
      frame: [0x1234, 8, 2, 0x3000, 0],
      descriptors: [:]
    )
    let memory = DescriptorFaultMemory(backing: backing, faultAddress: 0x5008)
    var state = try ia32eState(mode: .long64)
    state.nmiBlocked = true
    state.control.cr2 = 0xDEAD
    var expected = state
    expected.nmiBlocked = false
    expected.control.cr2 = 0x5008

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 5,
            instructionPointer: 0x1000,
            linearAddress: 0x5008
          ))
    )
    #expect(state == expected)
  }

  @Test func nestedTaskFaultsBeforeReadingTheReturnFrame() throws {
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x48, 0xCF] + .init(repeating: 0, count: 16)
    )
    var state = try ia32eState(mode: .long64)
    state.rflags.insert(.nestedTask)
    state.nmiBlocked = true
    var expected = state
    expected.nmiBlocked = false

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == fault(.generalProtection, vector: 13, errorCode: 0)
    )
    #expect(state == expected)
  }

  private func ia32eState(mode: DoryX86ExecutionMode) throws -> DoryX86ArchitecturalState {
    let long = mode == .long64
    let default32 = mode != .protected16
    return try .init(
      registers: .init(rsp: 0x2000),
      rip: 0x1000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(
        selector: 8,
        attributes: long ? 0xA09B : (default32 ? 0xC09B : 0x809B),
        limit: .max
      ),
      ss: .init(selector: 16, attributes: default32 ? 0xC093 : 0x8093, limit: .max),
      gdtr: .init(limit: 0x2F, base: 0x5000),
      control: .init(cr0: 0x8000_0011, cr4: 1 << 5, efer: 1 << 10)
    )
  }

  private func fixtureMemory(
    instruction: [UInt8],
    width: DoryX86OperandWidth,
    frame: [UInt64],
    descriptors: [UInt16: UInt64]
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x8000)
    try memory.write(at: 0x1000, bytes: instruction)
    for (index, value) in frame.enumerated() {
      try write(
        memory,
        at: 0x2000 + UInt64(index * width.byteCount),
        value: value,
        byteCount: width.byteCount
      )
    }
    for (offset, descriptor) in descriptors {
      try write(memory, at: 0x5000 + UInt64(offset), value: descriptor, byteCount: 8)
    }
    return memory
  }

  private func codeDescriptor(
    dpl: UInt8,
    long: Bool,
    default32: Bool = false,
    conforming: Bool = false,
    present: Bool = true,
    limit: UInt32 = .max
  ) -> UInt64 {
    descriptor(
      access: UInt8(0x1B | (conforming ? 4 : 0) | Int(dpl & 3) << 5 | (present ? 0x80 : 0)),
      long: long,
      default32: default32,
      limit: limit
    )
  }

  private func dataDescriptor(dpl: UInt8, present: Bool = true) -> UInt64 {
    descriptor(
      access: UInt8(0x13 | Int(dpl & 3) << 5 | (present ? 0x80 : 0)),
      long: false,
      default32: true,
      limit: .max
    )
  }

  private func descriptor(
    access: UInt8,
    long: Bool,
    default32: Bool,
    limit: UInt32
  ) -> UInt64 {
    let granular = limit > 0xFFFFF
    let encodedLimit = granular ? limit >> 12 : limit
    var flags: UInt64 = granular ? 8 : 0
    if long { flags |= 2 }
    if default32 { flags |= 4 }
    return UInt64(encodedLimit & 0xFFFF)
      | UInt64(access) << 40
      | UInt64((encodedLimit >> 16) & 0x0F) << 48
      | flags << 52
  }

  private func write(
    _ memory: DoryX86ByteArrayMemory,
    at address: UInt64,
    value: UInt64,
    byteCount: Int
  ) throws {
    try memory.write(
      at: address,
      bytes: (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    )
  }

  private func fault(
    _ kind: DoryX86Exception.Kind,
    vector: UInt8,
    errorCode: UInt32
  ) -> DoryX86InterpreterResult {
    .exception(
      .init(
        kind: kind,
        vector: vector,
        errorCode: errorCode,
        instructionPointer: 0x1000
      ))
  }
}

private final class DescriptorFaultMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let faultAddress: UInt64

  init(backing: DoryX86ByteArrayMemory, faultAddress: UInt64) {
    self.backing = backing
    self.faultAddress = faultAddress
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address == faultAddress {
      throw DoryX86MemoryError.pageFault(address: faultAddress, errorCode: 5)
    }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    if address == faultAddress {
      throw DoryX86MemoryError.pageFault(address: faultAddress, errorCode: 5)
    }
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() { backing.synchronize() }
}
