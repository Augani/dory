import Dispatch
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86InterpreterTests {
  private let interpreter = DoryX86Interpreter()

  @Test func executesIntegerControlFlowWithoutHostAssumptions() throws {
    // mov rax,5; mov rcx,3; add rax,rcx; mov rdx,8; cmp rax,rdx;
    // jne +10; mov rbx,42; hlt
    let program: [UInt8] = [
      0x48, 0xB8, 5, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0xB9, 3, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0x01, 0xC8,
      0x48, 0xBA, 8, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0x39, 0xD0,
      0x75, 10,
      0x48, 0xBB, 42, 0, 0, 0, 0, 0, 0, 0,
      0xF4,
    ]
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: program + .init(repeating: 0, count: 64))
    var state = try DoryX86ArchitecturalState(rip: 0x1000)
    var result: DoryX86InterpreterResult = .exception(
      .init(kind: .invalidOpcode, vector: 6, instructionPointer: 0))
    for _ in 0..<8 {
      result = interpreter.step(state: &state, memory: memory, mode: .long64)
      if case .halted = result { break }
    }
    guard case .halted = result else {
      Issue.record("program did not halt: \(result)")
      return
    }
    #expect(state.registers.rax == 8)
    #expect(state.registers.rbx == 42)
    #expect(state.rflags.contains(.zero))
  }

  @Test func callAndReturnPreserveTheArchitecturalStack() throws {
    // call +1; hlt; mov rax,9; ret
    let program: [UInt8] = [
      0xE8, 1, 0, 0, 0,
      0xF4,
      0x48, 0xB8, 9, 0, 0, 0, 0, 0, 0, 0,
      0xC3,
    ]
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x2000, bytes: program + .init(repeating: 0, count: 0x100))
    var registers = DoryX86GeneralRegisters()
    registers.rsp = 0x2100
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x2000)
    for _ in 0..<4 { _ = interpreter.step(state: &state, memory: memory, mode: .long64) }
    #expect(state.registers.rax == 9)
    #expect(state.registers.rsp == 0x2100)
    #expect(state.rip == 0x2006)
  }

  @Test func cpuidCannotAdvertiseUnimplementedAVX() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x3000, bytes: [0x0F, 0xA2] + .init(repeating: 0, count: 16))
    let registers = DoryX86GeneralRegisters(rax: 1)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x3000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rcx & (1 << 28) == 0)
  }

  @Test func memoryFaultIsPreciseAndLeavesInstructionRestartable() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x4000, bytes: [0x48, 0x8B, 0x00] + .init(repeating: 0, count: 16))
    let registers = DoryX86GeneralRegisters(rax: 0xDEAD_0000)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x4000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 0,
            instructionPointer: 0x4000,
            linearAddress: 0xDEAD_0000
          )))
    #expect(state.rip == 0x4000)
    #expect(state.control.cr2 == 0xDEAD_0000)
  }

  @Test func faultingStackWriteDoesNotLeakTheSpeculativeStackPointer() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x4800,
      bytes: [0x50] + .init(repeating: 0, count: 16)
    )
    let registers = DoryX86GeneralRegisters(rax: 7, rsp: 0x5000)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x4800)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 2,
            instructionPointer: 0x4800,
            linearAddress: 0x4FF8
          )))
    #expect(state.rip == 0x4800)
    #expect(state.registers.rsp == 0x5000)
    #expect(state.registers.rax == 7)
    #expect(state.control.cr2 == 0x4FF8)
  }

  @Test func executesControlMSRAndTimestampInstructionsAtRingZero() throws {
    // mov cr3,rbx; mov rcx,cr3; rdtscp
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x5000,
      bytes: [0x0F, 0x22, 0xDB, 0x0F, 0x20, 0xD9, 0x0F, 0x01, 0xF9]
        + .init(repeating: 0, count: 16)
    )
    let registers = DoryX86GeneralRegisters(rbx: 0x9000)
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x5000,
      cs: .init(selector: 0, attributes: 0xA09B, limit: .max),
      tsc: 0x1122_3344_5566_7788,
      tscAux: 0xAABB_CCDD
    )
    let paging = DoryX86PagingUnit()
    _ = interpreter.step(state: &state, memory: memory, mode: .long64, pagingUnit: paging)
    #expect(state.control.cr3 == 0x9000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64, pagingUnit: paging)
    #expect(state.registers.rcx == 0x9000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64, pagingUnit: paging)
    #expect(state.registers.rax == 0x5566_7788)
    #expect(state.registers.rdx == 0x1122_3344)
    #expect(state.registers.rcx == 0xAABB_CCDD)
  }

  @Test func readsAndWritesOnlyTheDefinedMSRSurface() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x6000,
      bytes: [0x0F, 0x30, 0x0F, 0x32, 0x0F, 0x32] + .init(repeating: 0, count: 16)
    )
    let registers = DoryX86GeneralRegisters(
      rax: 0x1234_5678,
      rcx: 0xC000_0103
    )
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x6000,
      cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
    )
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.tscAux == 0x1234_5678)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0x1234_5678)
    state.registers.rcx = 0xDEAD_BEEF
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: 0x6004
          )))
    #expect(state.rip == 0x6004)
  }

  @Test func syscallAndSysretPerformArchitecturalRegisterTransitions() throws {
    let syscallMemory = DoryX86ByteArrayMemory(
      baseAddress: 0x7000,
      bytes: [0x0F, 0x05] + .init(repeating: 0, count: 16)
    )
    let msrs = DoryX86ModelSpecificRegisterState(
      star: UInt64(0x0013_0008) << 32,
      longStar: 0xffff_8000_0000_1000,
      syscallFlagMask: DoryX86RFLAGS.interruptEnable.rawValue
    )
    var control = DoryX86ControlState()
    control.efer = 1
    var state = try DoryX86ArchitecturalState(
      rip: 0x7000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0x23, attributes: 0xA0FB, limit: .max),
      control: control,
      modelSpecific: msrs
    )
    _ = interpreter.step(state: &state, memory: syscallMemory, mode: .long64)
    #expect(state.rip == 0xffff_8000_0000_1000)
    #expect(state.registers.rcx == 0x7002)
    #expect(state.registers.r11 & DoryX86RFLAGS.interruptEnable.rawValue != 0)
    #expect(!state.rflags.contains(.interruptEnable))
    #expect(state.cs.selector == 8)

    let sysretMemory = DoryX86ByteArrayMemory(
      baseAddress: state.rip,
      bytes: [0x0F, 0x07] + .init(repeating: 0, count: 16)
    )
    state.registers.rcx = 0x7002
    state.registers.r11 =
      DoryX86RFLAGS.reservedOne.rawValue | DoryX86RFLAGS.interruptEnable.rawValue
    _ = interpreter.step(state: &state, memory: sysretMemory, mode: .long64)
    #expect(state.rip == 0x7002)
    #expect(state.cs.selector & 3 == 3)
    #expect(state.rflags.contains(.interruptEnable))
  }

  @Test func executesByteLanesCarryArithmeticAndRotates() throws {
    // mov ah,7f; mov spl,77; stc; adc al,0; rol ah,1
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x9000,
      bytes: [
        0xB4, 0x7F,
        0x40, 0xB4, 0x77,
        0xF9,
        0x14, 0x00,
        0xD0, 0xC4,
      ] + .init(repeating: 0, count: 32)
    )
    let registers = DoryX86GeneralRegisters(rax: 0x12FF, rsp: 0x1234)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x9000)
    for _ in 0..<5 { _ = interpreter.step(state: &state, memory: memory, mode: .long64) }
    #expect(state.registers.rax & 0xFFFF == 0xFE00)
    #expect(state.registers.rsp == 0x1277)
    #expect(!state.rflags.contains(.carry))
    #expect(state.rflags.contains(.overflow))
  }

  @Test func executesUnaryAndImmediateGroupsWithArchitecturalFlags() throws {
    // mov al,7f; inc al; sbb al,1; neg al; sar al,1
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x9200,
      bytes: [
        0xB0, 0x7F,
        0xFE, 0xC0,
        0x1C, 0x01,
        0xF6, 0xD8,
        0xD0, 0xF8,
      ] + .init(repeating: 0, count: 32)
    )
    var state = try DoryX86ArchitecturalState(rip: 0x9200)
    for _ in 0..<5 { _ = interpreter.step(state: &state, memory: memory, mode: .long64) }
    #expect(state.registers.rax & 0xFF == 0xC0)
    #expect(state.rflags.contains(.sign))
    #expect(!state.rflags.contains(.zero))
  }

  @Test func indirectCallUsesTheLongModeStackWidth() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0xA000,
      bytes: [0xFF, 0xD0] + .init(repeating: 0, count: 0x200)
    )
    let registers = DoryX86GeneralRegisters(rax: 0xA010, rsp: 0xA100)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0xA000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.rip == 0xA010)
    #expect(state.registers.rsp == 0xA0F8)
    let returnAddress = try memory.read(at: 0xA0F8, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    #expect(returnAddress == 0xA002)
  }

  @Test func executesExtensionMultiplyAndConditionalMoves() throws {
    // mov al,80; movsx rax,al; imul rax,rax,-2; cmp rax,100; sete bl; cmove rcx,rdx
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0xB000,
      bytes: [
        0xB0, 0x80,
        0x48, 0x0F, 0xBE, 0xC0,
        0x48, 0x6B, 0xC0, 0xFE,
        0x48, 0x81, 0xF8, 0x00, 0x01, 0x00, 0x00,
        0x0F, 0x94, 0xC3,
        0x48, 0x0F, 0x44, 0xCA,
      ] + .init(repeating: 0, count: 32)
    )
    let registers = DoryX86GeneralRegisters(rcx: 1, rdx: 0xCAFE)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0xB000)
    for _ in 0..<6 { _ = interpreter.step(state: &state, memory: memory, mode: .long64) }
    #expect(state.registers.rax == 0x100)
    #expect(state.registers.rbx & 0xFF == 1)
    #expect(state.registers.rcx == 0xCAFE)
    #expect(state.rflags.contains(.zero))
  }

  @Test func multiplyAndDivideUseTheArchitecturalAccumulatorPairs() throws {
    let byteMemory = DoryX86ByteArrayMemory(
      baseAddress: 0xB100,
      bytes: [0xF6, 0xF3, 0xF6, 0xE3] + .init(repeating: 0, count: 16)
    )
    let byteRegisters = DoryX86GeneralRegisters(rax: 0x100, rbx: 2)
    var byteState = try DoryX86ArchitecturalState(
      registers: byteRegisters,
      rip: 0xB100
    )
    _ = interpreter.step(state: &byteState, memory: byteMemory, mode: .long64)
    #expect(byteState.registers.rax & 0xFFFF == 0x80)
    _ = interpreter.step(state: &byteState, memory: byteMemory, mode: .long64)
    #expect(byteState.registers.rax & 0xFFFF == 0x100)
    #expect(byteState.rflags.contains(.carry))
    #expect(byteState.rflags.contains(.overflow))

    let signedMemory = DoryX86ByteArrayMemory(
      baseAddress: 0xB200,
      bytes: [0x48, 0xF7, 0xFB] + .init(repeating: 0, count: 16)
    )
    let signedRegisters = DoryX86GeneralRegisters(
      rax: UInt64(bitPattern: -10),
      rdx: .max,
      rbx: 3
    )
    var signedState = try DoryX86ArchitecturalState(
      registers: signedRegisters,
      rip: 0xB200
    )
    _ = interpreter.step(state: &signedState, memory: signedMemory, mode: .long64)
    #expect(Int64(bitPattern: signedState.registers.rax) == -3)
    #expect(Int64(bitPattern: signedState.registers.rdx) == -1)
  }

  @Test func divideErrorIsPreciseAndNeverTrapsTheHostRuntime() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0xB300,
      bytes: [0xF6, 0xF3] + .init(repeating: 0, count: 16)
    )
    let registers = DoryX86GeneralRegisters(rax: 0x100, rbx: 0)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0xB300)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .divideError,
            vector: 0,
            instructionPointer: 0xB300
          )))
    #expect(state.rip == 0xB300)
    #expect(state.registers == registers)
  }

  @Test func executesAtomicExchangeCompareExchangeAndBitOperations() throws {
    let program: [UInt8] = [
      0x48, 0x87, 0x0E,  // xchg [rsi],rcx
      0xF0, 0x48, 0x0F, 0xC1, 0x0E,  // lock xadd [rsi],rcx
      0xF0, 0x48, 0x0F, 0xAB, 0x0E,  // lock bts [rsi],rcx
      0x48, 0x0F, 0xA3, 0x0E,  // bt [rsi],rcx
    ]
    var bytes = program + [UInt8](repeating: 0, count: 0x200)
    let dataOffset = 0x100
    bytes.replaceSubrange(dataOffset..<(dataOffset + 8), with: littleEndian(5))
    let memory = DoryX86ByteArrayMemory(baseAddress: 0xB000, bytes: bytes)
    let registers = DoryX86GeneralRegisters(rcx: 3, rsi: 0xB000 + UInt64(dataOffset))
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0xB000)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(readQuadword(memory, at: registers.rsi) == 3)
    #expect(state.registers.rcx == 5)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(readQuadword(memory, at: registers.rsi) == 8)
    #expect(state.registers.rcx == 3)

    state.registers.rcx = 65
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(readQuadword(memory, at: registers.rsi + 8) == 2)
    #expect(!state.rflags.contains(.carry))
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.rflags.contains(.carry))
  }

  @Test func compareExchangePairsCommitOrRestoreArchitecturalAccumulators() throws {
    let program: [UInt8] = [
      0xF0, 0x48, 0x0F, 0xB1, 0x0E,  // lock cmpxchg [rsi],rcx
      0xF0, 0x48, 0x0F, 0xC7, 0x0F,  // lock cmpxchg16b [rdi]
      0xF0, 0x0F, 0xC7, 0x0E,  // lock cmpxchg8b [rsi]
    ]
    var bytes = program + [UInt8](repeating: 0, count: 0x240)
    bytes.replaceSubrange(0x100..<0x108, with: littleEndian(9))
    bytes.replaceSubrange(0x120..<0x128, with: littleEndian(0x1111))
    bytes.replaceSubrange(0x128..<0x130, with: littleEndian(0x2222))
    bytes.replaceSubrange(0x140..<0x148, with: littleEndian(0x3344_5566_7788_99AA))
    let memory = DoryX86ByteArrayMemory(baseAddress: 0xC000, bytes: bytes)
    let registers = DoryX86GeneralRegisters(
      rax: 9,
      rcx: 12,
      rdx: 0x2222,
      rbx: 0xAAAA,
      rsi: 0xC100,
      rdi: 0xC120
    )
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0xC000)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(readQuadword(memory, at: 0xC100) == 12)
    #expect(state.rflags.contains(.zero))

    state.registers.rax = 0x1111
    state.registers.rbx = 0xAAAA
    state.registers.rcx = 0xBBBB
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(readQuadword(memory, at: 0xC120) == 0xAAAA)
    #expect(readQuadword(memory, at: 0xC128) == 0xBBBB)
    #expect(state.rflags.contains(.zero))

    state.registers.rsi = 0xC140
    state.registers.rax = 1
    state.registers.rdx = 2
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0x7788_99AA)
    #expect(state.registers.rdx == 0x3344_5566)
    #expect(!state.rflags.contains(.zero))
  }

  @Test func lockedUpdatesSerializeAcrossVirtualCPUs() throws {
    let iterations = 500
    var bytes = [0xF0, 0x48, 0x01, 0x06] + [UInt8](repeating: 0, count: 0x100)
    bytes.replaceSubrange(0x80..<0x88, with: littleEndian(0))
    let memory = DoryX86ByteArrayMemory(baseAddress: 0xD000, bytes: bytes)

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      var state = try! DoryX86ArchitecturalState(
        registers: .init(rax: 1, rsi: 0xD080),
        rip: 0xD000
      )
      _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    }
    #expect(readQuadword(memory, at: 0xD080) == UInt64(iterations))
  }

  @Test func repeatStringsHonorCountDirectionAndStopConditions() throws {
    let program: [UInt8] = [
      0xF3, 0xA4,  // rep movsb
      0xF2, 0xAE,  // repne scasb
      0xFD,  // std
      0xF3, 0x66, 0xAB,  // rep stosw
    ]
    var bytes = program + [UInt8](repeating: 0, count: 0x200)
    bytes.replaceSubrange(0x80..<0x84, with: [1, 2, 3, 4])
    bytes.replaceSubrange(0xA0..<0xA4, with: [1, 2, 3, 4])
    let memory = DoryX86ByteArrayMemory(baseAddress: 0xE000, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 4, rsi: 0xE080, rdi: 0xE0A0),
      rip: 0xE000
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(try memory.read(at: 0xE0A0, byteCount: 4) == [1, 2, 3, 4])
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == 0xE084)
    #expect(state.registers.rdi == 0xE0A4)

    state.registers.rax = 3
    state.registers.rcx = 4
    state.registers.rdi = 0xE0A0
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rdi == 0xE0A3)
    #expect(state.rflags.contains(.zero))

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    state.registers.rax = 0xBEEF
    state.registers.rcx = 3
    state.registers.rdi = 0xE0C4
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(try memory.read(at: 0xE0C0, byteCount: 6) == [0xEF, 0xBE, 0xEF, 0xBE, 0xEF, 0xBE])
    #expect(state.registers.rdi == 0xE0BE)
    #expect(state.registers.rcx == 0)
  }

  @Test func repeatStringFaultCommitsOnlyCompletedIterations() throws {
    var bytes = [0xF3, 0xA4] + [UInt8](repeating: 0, count: 0x3E)
    bytes[0x10] = 0x5A
    bytes[0x11] = 0xA5
    let memory = DoryX86ByteArrayMemory(baseAddress: 0xF000, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: 0xF010, rdi: 0xF03F),
      rip: 0xF000
    )

    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 2,
            instructionPointer: 0xF000,
            linearAddress: 0xF040,
            commitsPartialProgress: true
          )))
    #expect(state.rip == 0xF000)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == 0xF011)
    #expect(state.registers.rdi == 0xF040)
    #expect(try memory.read(at: 0xF03F, byteCount: 1) == [0x5A])
  }

  @Test func longRepeatStringsYieldAtAnInterruptibleBoundary() throws {
    let count: UInt64 = 4_097
    var bytes = [0xF3, 0xA4] + [UInt8](repeating: 0, count: 0x3FFE)
    for index in 0..<Int(count) { bytes[0x100 + index] = UInt8(truncatingIfNeeded: index) }
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x10_000, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: count, rsi: 0x10_100, rdi: 0x12_000),
      rip: 0x10_000
    )

    let first = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .yielded = first else {
      Issue.record("long REP MOVSB did not yield: \(first)")
      return
    }
    #expect(state.rip == 0x10_000)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == 0x11_100)
    #expect(state.registers.rdi == 0x13_000)

    let second = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = second else {
      Issue.record("final REP MOVSB iteration did not retire: \(second)")
      return
    }
    #expect(state.registers.rcx == 0)
    #expect(state.rip == 0x10_002)
    #expect(try memory.read(at: 0x12_000, byteCount: Int(count)) == Array(bytes[0x100..<0x1101]))
  }

  @Test func realModeFetchAndDataAccessUseSegmentBases() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes.replaceSubrange(0x110..<0x113, with: [0x8B, 0x42, 0xFE])
    bytes.replaceSubrange(0x23E..<0x240, with: [0xEF, 0xBE])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    let registers = DoryX86GeneralRegisters(rbp: 0x30, rsi: 0x10)
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x10,
      cs: .init(selector: 0x10, attributes: 0x93, limit: 0xffff, base: 0x100),
      ss: .init(selector: 0x20, attributes: 0x93, limit: 0xffff, base: 0x200)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.registers.rax == 0xBEEF)
    #expect(state.rip == 0x13)
  }

  @Test func descriptorTablesRoundTripAcrossRealModeLayouts() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes.replaceSubrange(0x100..<0x106, with: [0x0F, 0x01, 0x10, 0x0F, 0x01, 0x01])
    bytes.replaceSubrange(0x180..<0x186, with: [0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x89])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rbx: 0x100, rsi: 0x80, rdi: 0x90),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x93, limit: 0xffff, base: 0)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.gdtr == .init(limit: 0x1234, base: 0xAB_CDEF))
    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(try memory.read(at: 0x190, byteCount: 6) == [0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x00])
  }

  @Test func segmentLoadsAndFarJumpsTransitionExecutionModes() throws {
    var realBytes = [UInt8](repeating: 0, count: 0x200)
    realBytes.replaceSubrange(
      0x100..<0x10A,
      with: [0xB8, 0x34, 0x12, 0x8E, 0xD8, 0xEA, 0x00, 0x02, 0x78, 0x56]
    )
    let realMemory = DoryX86ByteArrayMemory(bytes: realBytes)
    var realState = try DoryX86ArchitecturalState(
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x93, limit: 0xffff, base: 0)
    )
    _ = interpreter.step(state: &realState, memory: realMemory, mode: .real16)
    _ = interpreter.step(state: &realState, memory: realMemory, mode: .real16)
    #expect(realState.ds.selector == 0x1234)
    #expect(realState.ds.base == 0x1_2340)
    _ = interpreter.step(state: &realState, memory: realMemory, mode: .real16)
    #expect(realState.cs.selector == 0x5678)
    #expect(realState.cs.base == 0x5_6780)
    #expect(realState.rip == 0x200)

    var protectedBytes = [UInt8](repeating: 0, count: 0x300)
    protectedBytes.replaceSubrange(
      0x100..<0x107,
      with: [0xEA, 0x78, 0x56, 0x34, 0x12, 0x08, 0x00]
    )
    protectedBytes.replaceSubrange(
      0x208..<0x210,
      with: [0xFF, 0xFF, 0, 0, 0, 0x9A, 0xCF, 0]
    )
    let protectedMemory = DoryX86ByteArrayMemory(bytes: protectedBytes)
    var protectedState = try DoryX86ArchitecturalState(
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x9A, limit: 0xffff, base: 0),
      gdtr: .init(limit: 0x0F, base: 0x200)
    )
    _ = interpreter.step(
      state: &protectedState, memory: protectedMemory, mode: .protected32)
    #expect(protectedState.cs.selector == 8)
    #expect(protectedState.cs.attributes == 0xC09A)
    #expect(protectedState.cs.limit == .max)
    #expect(protectedState.rip == 0x1234_5678)
  }

  @Test func machineStatusTransitionsPreserveProtectedMode() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x11_000,
      bytes: [0x0F, 0x01, 0xF0, 0x0F, 0x01, 0xE3, 0x0F, 0x06]
        + [UInt8](repeating: 0, count: 16)
    )
    var control = DoryX86ControlState()
    control.cr0 = 0x19
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0, rbx: 0),
      rip: 0x11_000,
      cs: .init(selector: 0, attributes: 0x9A, limit: .max),
      control: control
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.control.cr0 & 1 == 1)
    #expect(state.control.cr0 & 0xE == 0)
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.registers.rbx & 0xffff == 0x11)
    state.control.cr0 |= 1 << 3
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.control.cr0 & (1 << 3) == 0)
  }

  @Test func systemSegmentLoadsValidateDescriptorsAndMarkTasksBusy() throws {
    var bytes = [UInt8](repeating: 0, count: 0x500)
    bytes.replaceSubrange(0x100..<0x106, with: [0x0F, 0x00, 0xD0, 0x0F, 0x00, 0xDB])
    bytes.replaceSubrange(0x208..<0x210, with: [0xFF, 0, 0, 0x30, 0, 0x82, 0, 0])
    bytes.replaceSubrange(0x210..<0x218, with: [0x67, 0, 0, 0x40, 0, 0x89, 0, 0])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 8, rbx: 16),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x9A, limit: .max),
      gdtr: .init(limit: 0x17, base: 0x200)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.ldtr.selector == 8)
    #expect(state.ldtr.base == 0x3000)
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.tr.selector == 16)
    #expect(state.tr.base == 0x4000)
    #expect(try memory.read(at: 0x215, byteCount: 1) == [0x8B])
  }

  @Test func realModeFarCallAndReturnUseSegmentedStackFrames() throws {
    var bytes = [UInt8](repeating: 0, count: 0x500)
    bytes.replaceSubrange(0x100..<0x105, with: [0x9A, 0x20, 0, 0x20, 0])
    bytes.replaceSubrange(0x220..<0x221, with: [0xCB])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0x80),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x93, limit: 0xffff, base: 0),
      ss: .init(selector: 0x30, attributes: 0x93, limit: 0xffff, base: 0x300)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.cs.selector == 0x20)
    #expect(state.rip == 0x20)
    #expect(state.registers.rsp & 0xffff == 0x7C)
    #expect(try memory.read(at: 0x37C, byteCount: 4) == [0x05, 0x01, 0, 0])
    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.cs.selector == 0)
    #expect(state.rip == 0x105)
    #expect(state.registers.rsp & 0xffff == 0x80)
  }

  @Test func protectedSegmentsRejectCrossLimitAndReadOnlyWrites() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes.replaceSubrange(0x100..<0x106, with: [0x66, 0x8B, 0x07, 0x66, 0x89, 0x07])
    bytes.replaceSubrange(0x20E..<0x210, with: [0x34, 0x12])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdi: 0x0E),
      rip: 0x100,
      cs: .init(selector: 8, attributes: 0xC09A, limit: .max),
      ds: .init(selector: 16, attributes: 0x4091, limit: 0x0F, base: 0x200)
    )
    state.control.cr0 |= 1

    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.registers.rax & 0xffff == 0x1234)
    let writeResult = interpreter.step(state: &state, memory: memory, mode: .protected32)
    guard case .exception(let exception) = writeResult else {
      Issue.record("read-only segment write did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(state.rip == 0x103)

    state.registers.rdi = 0x0F
    state.rip = 0x100
    let limitResult = interpreter.step(state: &state, memory: memory, mode: .protected32)
    guard case .exception(let exception) = limitResult else {
      Issue.record("cross-limit word read did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
  }

  private func readQuadword(_ memory: DoryX86ByteArrayMemory, at address: UInt64) -> UInt64 {
    try! memory.read(at: address, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
