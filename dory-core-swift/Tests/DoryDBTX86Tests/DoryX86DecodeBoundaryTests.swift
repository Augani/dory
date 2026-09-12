import Testing

@testable import DoryDBTX86

// A07.1: Decode boundary tests for address wrapping, redundant prefix groups,
// and FS/GS base handling. These complement the existing 15-byte limit,
// cross-page fetch, and code segment limit tests in DoryX86InstructionLengthTests.
@Suite struct DoryX86DecodeBoundaryTests {
  // 0x67 address-size override in 64-bit mode wraps effective addresses to
  // 32 bits. Intel SDM Vol. 2A, Table 2-3: the address size is 32 bits when
  // the 67H prefix is used in 64-bit mode.
  @Test func addressSizeOverrideIsRecordedInLongMode() throws {
    // 67 8B 00: MOV eax, [rax] with 32-bit address size in 64-bit mode.
    let bytes: [UInt8] = [0x67, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 3)
    #expect(instruction.prefixes.addressSizeOverride == true)
    if case .move(let destination, .memory(let operand)) = instruction.operation {
      #expect(destination == .register(.rax, width: .doubleword))
      #expect(operand.base == .rax)
    } else {
      Issue.record("expected move from memory, got \(instruction.operation)")
    }
  }

  // Redundant prefix groups: multiple identical prefixes are architecturally
  // legal (within the 15-byte limit) and should not change the decoded
  // instruction's operation.
  @Test func redundantPrefixGroupsDoNotChangeDecodedOperation() throws {
    let single: [UInt8] = [0x66, 0x0F, 0xAF, 0xC1]  // IMUL ax, cx (66 prefix)
    let doubled: [UInt8] = [0x66, 0x66, 0x0F, 0xAF, 0xC1]  // Two 66 prefixes
    let instruction1 = try DoryX86Decoder().decode(single, at: 0x1000, mode: .long64)
    let instruction2 = try DoryX86Decoder().decode(doubled, at: 0x1000, mode: .long64)
    #expect(instruction1.operation == instruction2.operation)
    #expect(instruction2.length == 5)
  }

  // Multiple different prefix groups combined in one instruction.
  @Test func combinedPrefixGroupsAreAccepted() throws {
    // 67 66 8B 00: address-size + operand-size override + MOV ax, [eax]
    let bytes: [UInt8] = [0x67, 0x66, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 4)
    #expect(instruction.prefixes.addressSizeOverride == true)
    #expect(instruction.prefixes.operandSizeOverride == true)
    if case .move(let destination, .memory(let operand)) = instruction.operation {
      #expect(destination == .register(.rax, width: .word))
      #expect(operand.base == .rax)
    } else {
      Issue.record("expected move from memory, got \(instruction.operation)")
    }
  }

  // FS/GS segment override prefixes (0x64, 0x65) combine with memory operands.
  @Test func fsSegmentOverridePrefixIsRecorded() throws {
    // 64 8B 00: FS: MOV eax, [rax]
    let bytes: [UInt8] = [0x64, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.prefixes.segmentOverride == 0x64)
    #expect(instruction.length == 3)
  }

  @Test func gsSegmentOverridePrefixIsRecorded() throws {
    // 65 8B 00: GS: MOV eax, [rax]
    let bytes: [UInt8] = [0x65, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.prefixes.segmentOverride == 0x65)
    #expect(instruction.length == 3)
  }

  // REX.W with 0x67 address-size override: REX.W selects 64-bit operand size
  // while 0x67 selects 32-bit address size. Both should be honored.
  @Test func rexWWithAddressSizeOverrideSelects64BitOperandAnd32BitAddress() throws {
    // 67 48 8B 00: MOV rax, [eax] (64-bit operand, 32-bit address).
    // REX must follow legacy prefixes to remain effective.
    let bytes: [UInt8] = [0x67, 0x48, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 4)
    #expect(instruction.prefixes.rex?.w == true)
    #expect(instruction.prefixes.addressSizeOverride == true)
    if case .move(let destination, .memory(let operand)) = instruction.operation {
      #expect(destination == .register(.rax, width: .quadword))
      #expect(operand.base == .rax)
    } else {
      Issue.record("expected move from memory, got \(instruction.operation)")
    }
  }

  @Test func legacyPrefixAfterREXDiscardsItsWidthAndRegisterExtensions() throws {
    let decoder = DoryX86Decoder()
    for prefix: UInt8 in [0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65, 0x66, 0x67] {
      let instruction = try decoder.decode([0x4F, prefix, 0x8B, 0xC1], at: 0x1000, mode: .long64)
      #expect(instruction.prefixes.rex == nil)
      #expect(instruction.operation == .move(
        destination: .register(.rax, width: prefix == 0x66 ? .word : .doubleword),
        source: .register(.rcx, width: prefix == 0x66 ? .word : .doubleword)))
    }
  }

  @Test func discardedREXRestoresHighByteRegistersAndLaterREXCanReplaceIt() throws {
    let decoder = DoryX86Decoder()
    let highByte = try decoder.decode([0x40, 0x66, 0x88, 0xE0], at: 0x1000, mode: .long64)
    #expect(highByte.operation == .move(
      destination: .register(.rax, width: .byte), source: .highByteRegister(.rax)))
    let replacement = try decoder.decode([0x4F, 0x67, 0x48, 0x8B, 0xC1], at: 0x1000, mode: .long64)
    #expect(replacement.operation == .move(
      destination: .register(.rax, width: .quadword), source: .register(.rcx, width: .quadword)))
  }

  // LOCK prefix (0xF0) on a memory instruction.
  @Test func lockPrefixIsRecordedOnMemoryInstruction() throws {
    // F0 01 00: LOCK ADD [rax], eax
    let bytes: [UInt8] = [0xF0, 0x01, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.prefixes.lock == true)
    #expect(instruction.length == 3)
  }

  // REP/REPNE prefixes (0xF3, 0xF2) on string instructions.
  @Test func repPrefixIsRecordedOnStringInstruction() throws {
    // F3 A4: REP MOVSB
    let bytes: [UInt8] = [0xF3, 0xA4]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.prefixes.repeatPrefix == 0xF3)
    #expect(instruction.length == 2)
  }

  @Test func repnePrefixIsRecordedOnStringInstruction() throws {
    // F2 A6: REPNE CMPSB
    let bytes: [UInt8] = [0xF2, 0xA6]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.prefixes.repeatPrefix == 0xF2)
    #expect(instruction.length == 2)
  }

  // SIB with no base register (base=101, index!=100): [index*scale + disp32]
  @Test func sibWithoutBaseUsesDisplacement32() throws {
    // 8B 04 0D 78 56 34 12: MOV eax, [ecx*1 + 0x12345678]
    let bytes: [UInt8] = [0x8B, 0x04, 0x0D, 0x78, 0x56, 0x34, 0x12]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 7)
    if case .move(.register(.rax, width: .doubleword), .memory(let operand)) = instruction.operation {
      #expect(operand.index == .rcx)
      #expect(operand.scale == 1)
      #expect(operand.displacement == 0x12345678)
    } else {
      Issue.record("expected move from SIB memory, got \(instruction.operation)")
    }
  }

  // SIB with no index (index=100): [base + disp] with no scaled index.
  @Test func sibWithoutIndexUsesBaseOnly() throws {
    // 8B 04 20: MOV eax, [rax] (SIB with index=100 (none), base=000 (rax))
    let bytes: [UInt8] = [0x8B, 0x04, 0x20]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 3)
    if case .move(.register(.rax, width: .doubleword), .memory(let operand)) = instruction.operation {
      #expect(operand.base == .rax)
      #expect(operand.index == nil)
    } else {
      Issue.record("expected move from SIB memory, got \(instruction.operation)")
    }
  }

  // REX.B extends the base register in a ModRM/SIB memory operand.
  @Test func rexBExtendsBaseRegisterInMemoryOperand() throws {
    // 41 8B 00: MOV eax, [r8] (REX.B extends base from rax to r8)
    let bytes: [UInt8] = [0x41, 0x8B, 0x00]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 3)
    if case .move(.register(.rax, width: .doubleword), .memory(let operand)) = instruction.operation {
      #expect(operand.base == .r8)
    } else {
      Issue.record("expected move from r8, got \(instruction.operation)")
    }
  }

  // REX.X extends the index register in a SIB memory operand.
  @Test func rexXExtendsIndexRegisterInSIBOperand() throws {
    // 42 8B 04 08: MOV eax, [rax + r9*1] (REX.X extends index from rcx to r9)
    // SIB: 04 = scale=0, index=000(rcx→r9 with REX.X), base=000(rax)
    let bytes: [UInt8] = [0x42, 0x8B, 0x04, 0x08]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 4)
    if case .move(.register(.rax, width: .doubleword), .memory(let operand)) = instruction.operation {
      #expect(operand.index == .r9)
      #expect(operand.base == .rax)
    } else {
      Issue.record("expected move with r9 index, got \(instruction.operation)")
    }
  }

  // 16-bit addressing in real mode uses different ModRM encoding.
  @Test func realModeUses16BitImmediate() throws {
    // B8 00 01: MOV ax, 0x0100 (immediate to ax in real mode)
    let bytes: [UInt8] = [0xB8, 0x00, 0x01]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .real16)
    #expect(instruction.length == 3)
    let expected: DoryX86InstructionOperation = .move(
      destination: .register(.rax, width: .word),
      source: .immediate(0x0100, width: .word))
    #expect(instruction.operation == expected)
  }

  // An instruction with maximum legal prefix count (14 prefixes + 1 opcode).
  @Test func fourteenPrefixesPlusOpcodeIsExactly15Bytes() throws {
    let bytes = Array(repeating: UInt8(0x67), count: 14) + [0x90]
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(instruction.length == 15)
  }

  // An instruction with 15 prefixes + 1 opcode exceeds the 15-byte limit.
  @Test func fifteenPrefixesPlusOpcodeExceedsLimit() throws {
    let bytes = Array(repeating: UInt8(0x67), count: 15) + [0x90]
    #expect(throws: DoryX86DecodeError.instructionTooLong(address: 0x1000)) {
      _ = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    }
  }
}
