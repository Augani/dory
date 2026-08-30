import Dispatch
import Foundation
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

  @Test func returnWithImmediateReleasesCallerArguments() throws {
    let base: UInt64 = 0x2200
    let memory = DoryX86ByteArrayMemory(
      baseAddress: base,
      bytes: [0xC2, 0x10, 0x00] + .init(repeating: 0, count: 0xFD)
    )
    try memory.write(
      at: base + 0x80,
      bytes: [0x20, 0x22, 0, 0, 0, 0, 0, 0]
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: base + 0x80),
      rip: base
    )

    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("RET imm16 unexpectedly faulted: \(result)")
      return
    }
    #expect(state.rip == base + 0x20)
    #expect(state.registers.rsp == base + 0x98)
  }

  @Test func executesDebugAndExtendedControlRegisterMaintenance() throws {
    let profile = DoryX86CPUProfile(
      identifier: "test.xsave",
      features: [.xsave, .osxsave],
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000
    )
    let interpreter = DoryX86Interpreter(profile: profile)
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x2400,
      bytes: [
        0x0F, 0x23, 0xC0,  // mov dr0, rax
        0x0F, 0x21, 0xC3,  // mov rbx, dr0
        0x0F, 0x01, 0xD1,  // xsetbv
        0x0F, 0x01, 0xD0,  // xgetbv
        0x0F, 0x09,  // wbinvd
      ] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 3),
      rip: 0x2400,
      control: .init(cr4: 1 << 18)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.debug.dr0 == 3)
    #expect(state.registers.rbx == 3)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.control.xcr0 == 3)
    state.registers.rax = 0
    state.registers.rdx = 0
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 3)
    #expect(state.registers.rdx == 0)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("WBINVD unexpectedly faulted: \(result)")
      return
    }
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

  @Test func writingCR0NormalizesTheFixedExtensionTypeBit() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x5800,
      bytes: [0x0F, 0x22, 0xC0] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x23),
      rip: 0x5800,
      cs: .init(selector: 0, attributes: 0x009B, limit: .max)
    )
    let result = interpreter.step(state: &state, memory: memory, mode: .real16)
    guard case .retired = result else {
      Issue.record("MOV CR0 unexpectedly faulted: \(result)")
      return
    }
    #expect(state.control.cr0 == 0x33)
  }

  @Test func firmwareFarJumpLoadsAFlatProtectedModeCodeDescriptor() throws {
    let base: UInt64 = 0xFFFF_FE80
    var bytes = [UInt8](repeating: 0, count: 0x80)
    bytes.replaceSubrange(
      7..<15,
      with: [0x66, 0xEA, 0x8F, 0xFE, 0xFF, 0xFF, 0x10, 0x00]
    )
    bytes.replaceSubrange(
      0x40..<0x48,
      with: [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9B, 0xCF, 0x00]
    )
    let memory = DoryX86ByteArrayMemory(baseAddress: base, bytes: bytes)
    let decoded = try DoryX86Decoder().decode(
      Array(bytes[7..<22]),
      at: 0xFE87,
      mode: .protected16
    )
    #expect(decoded.operation == .farJump(offset: 0xFFFF_FE8F, selector: 0x10))
    var state = try DoryX86ArchitecturalState(
      rip: 0xFE87,
      cs: .init(selector: 0xF000, attributes: 0x009B, limit: 0xFFFF, base: 0xFFFF_0000),
      gdtr: .init(limit: 0x3F, base: 0xFFFF_FEB0),
      control: .init(cr0: 0x6000_0033)
    )
    let result = interpreter.step(state: &state, memory: memory, mode: .protected16)
    guard case .retired = result else {
      Issue.record("firmware far jump unexpectedly faulted: \(result)")
      return
    }
    #expect(state.cs.selector == 0x10)
    #expect(state.cs.base == 0)
    #expect(state.cs.attributes == 0xC09B)
    #expect(state.rip == 0xFFFF_FE8F)
  }

  @Test func compatibilityModeFarJumpPreservesFirmwareLongModeEntryPoint() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes.replaceSubrange(
      0x100..<0x107,
      with: [0xEA, 0xF8, 0xF6, 0xFF, 0xFF, 0x38, 0x00]
    )
    bytes.replaceSubrange(
      0x238..<0x240,
      with: [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9B, 0xAF, 0x00]
    )
    let memory = DoryX86ByteArrayMemory(baseAddress: 0, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      rip: 0x100,
      cs: .init(selector: 0x10, attributes: 0xC09B, limit: .max),
      gdtr: .init(limit: 0x3F, base: 0x200),
      control: .init(cr0: 0x8000_0033, cr4: 0x620, efer: 0xD00)
    )
    let result = interpreter.step(state: &state, memory: memory, mode: .protected32)
    guard case .retired = result else {
      Issue.record("long-mode far jump unexpectedly faulted: \(result)")
      return
    }
    #expect(state.cs.selector == 0x38)
    #expect(state.cs.attributes == 0xA09B)
    #expect(state.rip == 0xFFFF_F6F8)
  }

  @Test func firmwareCanEnableMachineCheckAndOperatingSystemSIMDSupport() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x5900,
      bytes: [0x0F, 0x22, 0xE0] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x640),
      rip: 0x5900,
      cs: .init(selector: 0x10, attributes: 0xC09B, limit: .max)
    )
    let result = interpreter.step(state: &state, memory: memory, mode: .protected32)
    guard case .retired = result else {
      Issue.record("MOV CR4 unexpectedly faulted: \(result)")
      return
    }
    #expect(state.control.cr4 == 0x640)
  }

  @Test func firmwareInitializesX87AndSIMDControlState() throws {
    var bytes = [UInt8](repeating: 0, count: 0x50)
    bytes.replaceSubrange(
      0..<16,
      with: [
        0x9B,
        0xDB, 0xE3,
        0xD9, 0x2D, 0x17, 0x00, 0x00, 0x00,
        0x0F, 0xAE, 0x15, 0x12, 0x00, 0x00, 0x00,
        0x0F, 0xAE, 0x1D, 0x10, 0x00, 0x00, 0x00,
        0xF3, 0x0F, 0x7F, 0x35, 0x19, 0x00, 0x00, 0x00,
      ]
    )
    bytes.replaceSubrange(0x20..<0x22, with: [0x7F, 0x02])
    bytes.replaceSubrange(0x22..<0x26, with: [0x80, 0x1F, 0x00, 0x00])
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.x87ControlWord = 0
    floatingPoint.x87StatusWord = 0xFFFF
    floatingPoint.x87TagWord = 0
    floatingPoint.mxcsr = 0
    floatingPoint.ymm[6] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    for _ in 0..<6 {
      let result = interpreter.step(state: &state, memory: memory, mode: .long64)
      guard case .retired = result else {
        Issue.record("floating-point initialization unexpectedly faulted: \(result)")
        return
      }
    }

    #expect(state.floatingPoint.x87ControlWord == 0x027F)
    #expect(state.floatingPoint.x87StatusWord == 0)
    #expect(state.floatingPoint.x87TagWord == 0xFFFF)
    #expect(state.floatingPoint.mxcsr == 0x1F80)
    #expect(try memory.read(at: 0x1027, byteCount: 4) == [0x80, 0x1F, 0, 0])
    #expect(try memory.read(at: 0x1038, byteCount: 16) == Array(0..<16))
  }

  @Test func movdquLoadsLowVectorAndPreservesUpperVector() throws {
    var bytes = [UInt8](repeating: 0, count: 0x30)
    bytes.replaceSubrange(0..<8, with: [0xF3, 0x0F, 0x6F, 0x35, 0x08, 0, 0, 0])
    bytes.replaceSubrange(0x10..<0x20, with: Array(0x80..<0x90))
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[6] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("MOVDQU load unexpectedly faulted: \(result)")
      return
    }
    #expect(state.floatingPoint.ymm[6].bytes == Array(0x80..<0x90) + Array(16..<32))
  }

  @Test func movdqaLoadsStoresAndEnforcesSixteenByteAlignment() throws {
    var bytes = [UInt8](repeating: 0, count: 0x50)
    bytes.replaceSubrange(0..<8, with: [0x66, 0x0F, 0x6F, 0x35, 0x18, 0, 0, 0])
    bytes.replaceSubrange(8..<16, with: [0x66, 0x0F, 0x7F, 0x35, 0x20, 0, 0, 0])
    bytes.replaceSubrange(0x20..<0x30, with: Array(0x40..<0x50))
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[6] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64),
      case .retired = interpreter.step(state: &state, memory: memory, mode: .long64)
    else {
      Issue.record("MOVDQA load/store unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[6].bytes == Array(0x40..<0x50) + Array(16..<32))
    #expect(try memory.read(at: 0x1030, byteCount: 16) == Array(0x40..<0x50))

    var misalignedBytes = [UInt8](repeating: 0, count: 0x30)
    misalignedBytes.replaceSubrange(
      0..<8,
      with: [0x66, 0x0F, 0x6F, 0x35, 0x09, 0, 0, 0]
    )
    let misalignedMemory = DoryX86ByteArrayMemory(baseAddress: 0x2000, bytes: misalignedBytes)
    var misalignedState = try DoryX86ArchitecturalState(
      rip: 0x2000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max)
    )
    #expect(
      interpreter.step(state: &misalignedState, memory: misalignedMemory, mode: .long64)
        == .exception(
          .init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x2000)
        )
    )
    #expect(misalignedState.rip == 0x2000)
  }

  @Test func fxsaveAndFXRSTORRoundTripArchitecturalFloatingPointState() throws {
    var bytes = [UInt8](repeating: 0, count: 0x400)
    bytes.replaceSubrange(0..<7, with: [0x0F, 0xAE, 0x05, 0xF9, 0, 0, 0])
    bytes.replaceSubrange(7..<14, with: [0x0F, 0xAE, 0x0D, 0xF2, 0, 0, 0])
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.x87ControlWord = 0x027F
    floatingPoint.x87StatusWord = 0x3800
    floatingPoint.x87TagWord = 0xFFFC
    floatingPoint.x87[0] = try .init(bytes: Array(0x20..<0x2A), expectedByteCount: 10)
    floatingPoint.ymm[15] = try .init(bytes: Array(0x40..<0x60), expectedByteCount: 32)
    floatingPoint.mxcsr = 0x1FA0
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("FXSAVE unexpectedly faulted")
      return
    }
    #expect(try memory.read(at: 0x1100, byteCount: 2) == [0x7F, 0x02])
    #expect(try memory.read(at: 0x1104, byteCount: 1) == [1])
    #expect(try memory.read(at: 0x1290, byteCount: 16) == Array(0x40..<0x50))

    state.floatingPoint = try .init()
    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("FXRSTOR unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.x87ControlWord == 0x027F)
    #expect(state.floatingPoint.x87StatusWord == 0x3800)
    #expect(state.floatingPoint.x87TagWord == 0xFFFC)
    #expect(state.floatingPoint.x87[0].bytes == Array(0x20..<0x2A))
    #expect(
      state.floatingPoint.ymm[15].bytes == Array(0x40..<0x50) + Array(repeating: 0, count: 16))
    #expect(state.floatingPoint.mxcsr == 0x1FA0)
  }

  @Test func baselineSSEMovesAndBitwiseOperationsPreserveLegacyUpperLanes() throws {
    var bytes = [UInt8](repeating: 0, count: 0x80)
    bytes.replaceSubrange(0..<4, with: [0xF3, 0x0F, 0x10, 0xC1])
    bytes.replaceSubrange(4..<12, with: [0xF3, 0x0F, 0x10, 0x05, 0x34, 0, 0, 0])
    bytes.replaceSubrange(12..<16, with: [0x66, 0x0F, 0xEF, 0xC1])
    bytes.replaceSubrange(16..<21, with: [0x66, 0x48, 0x0F, 0x6E, 0xC2])
    bytes.replaceSubrange(21..<26, with: [0x66, 0x48, 0x0F, 0x7E, 0xC1])
    bytes.replaceSubrange(0x40..<0x44, with: [0xF0, 0xF1, 0xF2, 0xF3])
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[0] = try .init(
      bytes: .init(repeating: 0xAA, count: 32), expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    let integer: UInt64 = 0x8877_6655_4433_2211
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdx: integer),
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("register MOVSS unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[0].bytes == Array(0..<4) + Array(repeating: 0xAA, count: 28))

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("memory MOVSS unexpectedly faulted")
      return
    }
    #expect(
      state.floatingPoint.ymm[0].bytes
        == [0xF0, 0xF1, 0xF2, 0xF3] + Array(repeating: 0, count: 12)
        + Array(repeating: 0xAA, count: 16)
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("PXOR unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[0].bytes[4..<16] == Array(4..<16)[...])
    #expect(state.floatingPoint.ymm[0].bytes[16..<32] == Array(repeating: 0xAA, count: 16)[...])

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64),
      case .retired = interpreter.step(state: &state, memory: memory, mode: .long64)
    else {
      Issue.record("MOVQ integer transfer unexpectedly faulted")
      return
    }
    #expect(state.registers.rcx == integer)
    #expect(state.floatingPoint.ymm[0].bytes[8..<16] == Array(repeating: 0, count: 8)[...])
    #expect(state.floatingPoint.ymm[0].bytes[16..<32] == Array(repeating: 0xAA, count: 16)[...])
  }

  @Test func fxsaveRequiresSixteenByteAlignment() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x0F, 0xAE, 0x05, 0xFA, 0, 0, 0] + .init(repeating: 0, count: 0x200)
    )
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max)
    )

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)
        )
    )
  }

  @Test func sseFloatingArithmeticHandlesPackedAndScalarLanes() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0xF3, 0x0F, 0x58, 0xC1, 0x66, 0x0F, 0x5E, 0xC1]
        + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    var lhs = [UInt8](repeating: 0xAA, count: 32)
    var rhs = [UInt8](repeating: 0, count: 32)
    lhs.replaceSubrange(0..<4, with: littleEndian(UInt64(Float(1.5).bitPattern)).prefix(4))
    rhs.replaceSubrange(0..<4, with: littleEndian(UInt64(Float(2.25).bitPattern)).prefix(4))
    floatingPoint.ymm[0] = try .init(bytes: lhs, expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: rhs, expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("ADDSS unexpectedly faulted")
      return
    }
    let scalarBits = UInt32(
      try memoryInteger(bytes: Array(state.floatingPoint.ymm[0].bytes.prefix(4))))
    #expect(Float(bitPattern: scalarBits) == 3.75)
    #expect(state.floatingPoint.ymm[0].bytes[4..<32] == Array(repeating: 0xAA, count: 28)[...])

    var packedLHS = [UInt8](repeating: 0xAA, count: 32)
    var packedRHS = [UInt8](repeating: 0, count: 32)
    packedLHS.replaceSubrange(0..<8, with: littleEndian(Double(9).bitPattern))
    packedLHS.replaceSubrange(8..<16, with: littleEndian(Double(-8).bitPattern))
    packedRHS.replaceSubrange(0..<8, with: littleEndian(Double(3).bitPattern))
    packedRHS.replaceSubrange(8..<16, with: littleEndian(Double(2).bitPattern))
    state.floatingPoint.ymm[0] = try .init(bytes: packedLHS, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: packedRHS, expectedByteCount: 32)

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("DIVPD unexpectedly faulted")
      return
    }
    #expect(
      Double(bitPattern: try memoryInteger(bytes: Array(state.floatingPoint.ymm[0].bytes[0..<8])))
        == 3)
    #expect(
      Double(bitPattern: try memoryInteger(bytes: Array(state.floatingPoint.ymm[0].bytes[8..<16])))
        == -4)
    #expect(state.floatingPoint.ymm[0].bytes[16..<32] == Array(repeating: 0xAA, count: 16)[...])
  }

  @Test func sse2PackedIntegerArithmeticAndComparisonsOperatePerLane() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [
        0x66, 0x0F, 0xFC, 0xC1,
        0x66, 0x0F, 0xF9, 0xC1,
        0x66, 0x0F, 0x66, 0xC1,
      ] + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[0] = try .init(
      bytes: [0xFF, 1] + .init(repeating: 0, count: 14) + .init(repeating: 0xAA, count: 16),
      expectedByteCount: 32
    )
    floatingPoint.ymm[1] = try .init(
      bytes: [1, 2] + .init(repeating: 0, count: 30), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max),
      floatingPoint: floatingPoint
    )

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("PADDB unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[0].bytes.prefix(2) == [0, 3][...])
    #expect(state.floatingPoint.ymm[0].bytes[16..<32] == Array(repeating: 0xAA, count: 16)[...])

    var words = [UInt8](repeating: 0, count: 32)
    words.replaceSubrange(0..<2, with: [0, 0x80])
    var wordSource = [UInt8](repeating: 0, count: 32)
    wordSource.replaceSubrange(0..<2, with: [1, 0])
    state.floatingPoint.ymm[0] = try .init(bytes: words, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: wordSource, expectedByteCount: 32)
    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("PSUBW unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[0].bytes.prefix(2) == [0xFF, 0x7F][...])

    var doublewords = [UInt8](repeating: 0, count: 32)
    doublewords.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xFF])
    doublewords.replaceSubrange(4..<8, with: [2, 0, 0, 0])
    var doublewordSource = [UInt8](repeating: 0, count: 32)
    doublewordSource.replaceSubrange(0..<4, with: [1, 0, 0, 0])
    doublewordSource.replaceSubrange(4..<8, with: [1, 0, 0, 0])
    state.floatingPoint.ymm[0] = try .init(bytes: doublewords, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: doublewordSource, expectedByteCount: 32)
    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
      Issue.record("PCMPGTD unexpectedly faulted")
      return
    }
    #expect(state.floatingPoint.ymm[0].bytes[0..<4] == [0, 0, 0, 0][...])
    #expect(state.floatingPoint.ymm[0].bytes[4..<8] == [0xFF, 0xFF, 0xFF, 0xFF][...])
  }

  @Test func sseScalarComparisonsSetOnlyArchitecturalStatusFlags() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x0F, 0x2F, 0xC1, 0x66, 0x0F, 0x2E, 0xC1]
        + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    var lhs = [UInt8](repeating: 0, count: 32)
    var rhs = [UInt8](repeating: 0, count: 32)
    lhs.replaceSubrange(0..<4, with: littleEndian(UInt64(Float(-1).bitPattern)).prefix(4))
    rhs.replaceSubrange(0..<4, with: littleEndian(UInt64(Float(2).bitPattern)).prefix(4))
    floatingPoint.ymm[0] = try .init(bytes: lhs, expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: rhs, expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(
      rip: 0x1000,
      rflags: [.reservedOne, .overflow, .sign, .auxiliaryCarry],
      floatingPoint: floatingPoint
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.overflow))
    #expect(!state.rflags.contains(.sign))
    #expect(!state.rflags.contains(.auxiliaryCarry))

    lhs.replaceSubrange(0..<8, with: littleEndian(Double.nan.bitPattern))
    rhs.replaceSubrange(0..<8, with: littleEndian(Double(2).bitPattern))
    state.floatingPoint.ymm[0] = try .init(bytes: lhs, expectedByteCount: 32)
    state.floatingPoint.ymm[1] = try .init(bytes: rhs, expectedByteCount: 32)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.rflags.contains([.zero, .parity, .carry]))
  }

  @Test func sse2InterleavesLowAndHighPackedLanes() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x66, 0x0F, 0x60, 0xC1, 0x66, 0x0F, 0x6D, 0xC1]
        + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: Array(0x40..<0x60), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(rip: 0x1000, floatingPoint: floatingPoint)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.floatingPoint.ymm[0].bytes[0..<8] == [0, 0x40, 1, 0x41, 2, 0x42, 3, 0x43][...])
    #expect(state.floatingPoint.ymm[0].bytes[16..<32] == Array(16..<32)[...])

    state.floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      Array(state.floatingPoint.ymm[0].bytes[0..<16]) == Array(8..<16) + Array(0x48..<0x50))
  }

  @Test func sseShufflesSelectArchitecturalSourceLanes() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [
        0x66, 0x0F, 0x70, 0xC1, 0x1B,
        0x0F, 0xC6, 0xC1, 0x4E,
        0x66, 0x0F, 0xC6, 0xC1, 0x01,
      ] + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: Array(0x40..<0x60), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(rip: 0x1000, floatingPoint: floatingPoint)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      Array(state.floatingPoint.ymm[0].bytes[0..<16])
        == Array(0x4C..<0x50) + Array(0x48..<0x4C) + Array(0x44..<0x48) + Array(0x40..<0x44))

    state.floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(Array(state.floatingPoint.ymm[0].bytes[0..<8]) == Array(8..<16))
    #expect(Array(state.floatingPoint.ymm[0].bytes[8..<16]) == Array(0x40..<0x48))

    state.floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(Array(state.floatingPoint.ymm[0].bytes[0..<8]) == Array(8..<16))
    #expect(Array(state.floatingPoint.ymm[0].bytes[8..<16]) == Array(0x40..<0x48))
  }

  @Test func sseScalarIntegerConversionsHonorWidthRoundingAndIndefiniteResults() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [
        0xF2, 0x48, 0x0F, 0x2A, 0xC0,
        0xF2, 0x48, 0x0F, 0x2C, 0xC8,
        0xF3, 0x0F, 0x2D, 0xD0,
        0xF3, 0x0F, 0x2D, 0xD8,
        0xF2, 0x48, 0x0F, 0x2C, 0xD0,
      ] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(registers: .init(rax: 42), rip: 0x1000)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    let doubleBits = try memoryInteger(bytes: Array(state.floatingPoint.ymm[0].bytes[0..<8]))
    #expect(Double(bitPattern: doubleBits) == 42)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rcx == 42)

    var scalar = state.floatingPoint.ymm[0].bytes
    scalar.replaceSubrange(0..<4, with: littleEndian(UInt64(Float(2.75).bitPattern)).prefix(4))
    state.floatingPoint.ymm[0] = try .init(bytes: scalar, expectedByteCount: 32)
    state.floatingPoint.mxcsr = (state.floatingPoint.mxcsr & ~(3 << 13)) | (1 << 13)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rdx == 2)
    state.floatingPoint.mxcsr = (state.floatingPoint.mxcsr & ~(3 << 13)) | (2 << 13)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rbx == 3)

    scalar.replaceSubrange(0..<8, with: littleEndian(Double.nan.bitPattern))
    state.floatingPoint.ymm[0] = try .init(bytes: scalar, expectedByteCount: 32)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rdx == 0x8000_0000_0000_0000)
  }

  @Test func sse2PackedShiftsHonorLaneWidthsAndSaturatingCounts() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [
        0x66, 0x0F, 0x71, 0xF0, 0x04,
        0x66, 0x0F, 0x72, 0xE2, 0xFF,
        0x66, 0x0F, 0xD3, 0xD9,
      ] + .init(repeating: 0, count: 16)
    )
    var floatingPoint = try DoryX86FloatingPointState()
    var words = [UInt8](repeating: 0, count: 32)
    for (lane, value) in [UInt16(0x8001), 0x7FFF, 0x1234, 0xFFFF].enumerated() {
      words.replaceSubrange(
        lane * 2..<lane * 2 + 2,
        with: littleEndian(UInt64(value)).prefix(2)
      )
    }
    var doublewords = [UInt8](repeating: 0, count: 32)
    for (lane, value) in [UInt32(0x8000_0000), 0x7FFF_FFFF, 0xFFFF_FFFF, 1].enumerated() {
      doublewords.replaceSubrange(
        lane * 4..<lane * 4 + 4,
        with: littleEndian(UInt64(value)).prefix(4)
      )
    }
    var count = [UInt8](repeating: 0, count: 32)
    count.replaceSubrange(0..<8, with: littleEndian(64))
    floatingPoint.ymm[0] = try .init(bytes: words, expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: count, expectedByteCount: 32)
    floatingPoint.ymm[2] = try .init(bytes: doublewords, expectedByteCount: 32)
    floatingPoint.ymm[3] = try .init(
      bytes: Array(repeating: 0xFF, count: 32), expectedByteCount: 32)
    var state = try DoryX86ArchitecturalState(rip: 0x1000, floatingPoint: floatingPoint)

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      Array(state.floatingPoint.ymm[0].bytes[0..<8]) == [
        0x10, 0, 0xF0, 0xFF, 0x40, 0x23, 0xF0, 0xFF,
      ])
    #expect(Array(state.floatingPoint.ymm[0].bytes[16..<32]) == Array(words[16..<32]))

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      Array(state.floatingPoint.ymm[2].bytes[0..<16])
        == [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(Array(state.floatingPoint.ymm[3].bytes[0..<16]) == Array(repeating: 0, count: 16))
  }

  @Test func byteExtendMoveUsesTheWideModRMDestinationRegister() throws {
    var bytes = [UInt8](repeating: 0, count: 0x20)
    bytes.replaceSubrange(0..<4, with: [0x0F, 0xB6, 0x71, 0x02])
    bytes[0x12] = 0x0D
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 0x1010, rdx: 0x81_EE_70),
      rip: 0x1000,
      cs: .init(selector: 0x38, attributes: 0xA09B, limit: .max)
    )

    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("MOVZX unexpectedly faulted: \(result)")
      return
    }
    #expect(state.registers.rsi == 0x0D)
    #expect(state.registers.rdx == 0x81_EE_70)
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

  @Test func platformIdentityMSRIsStableAndReadOnly() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x6800,
      bytes: [0x0F, 0x32, 0x0F, 0x30] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: .max, rcx: 0x17, rdx: .max),
      rip: 0x6800,
      cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
    )

    let read = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = read else {
      Issue.record("IA32_PLATFORM_ID unexpectedly faulted: \(read)")
      return
    }
    #expect(state.registers.rax == 0)
    #expect(state.registers.rdx == 0)

    state.registers.rax = 1
    let write = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(
      write
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: 0x6802
          )))
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

  @Test func systemSegmentStoresExposeSelectorsAndHonorUMIP() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1_000,
      bytes: [0x66, 0x0F, 0x00, 0xC8, 0x0F, 0x00, 0x01]
        + [UInt8](repeating: 0, count: 32)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xFFFF_FFFF_FFFF_0000, rcx: 0x1_010),
      rip: 0x1_000,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max),
      tr: .init(selector: 0x40),
      ldtr: .init(selector: 0x28)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0xFFFF_FFFF_FFFF_0040)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    let storedLDTR = try memory.read(at: 0x1_010, byteCount: 2)
    #expect(storedLDTR == [0x28, 0])

    state.rip = 0x1_000
    state.cs.selector = 3
    state.control.cr4 |= 1 << 11
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .exception(let exception) = result else {
      Issue.record("UMIP did not reject STR outside ring zero")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(state.rip == 0x1_000)
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

  @Test func scalarPortIOUsesTheDeviceBusAndAccumulatorWidths() throws {
    let program: [UInt8] = [0xE4, 0x60, 0xE6, 0x61, 0x66, 0xED, 0xEF]
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x1_000,
      bytes: program + .init(repeating: 0, count: 16)
    )
    let bus = RecordingIOBus(readValues: [0x60: 0xA5, 0x64: 0xBEEF])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xAABB_CCDD_1122_3344, rdx: 0x64),
      rip: 0x1_000,
      cs: .init(selector: 0, attributes: 0xC09A, limit: .max)
    )
    state.control.cr0 |= 1

    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    #expect(state.registers.rax == 0xAABB_CCDD_1122_33A5)
    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    #expect(state.registers.rax == 0xAABB_CCDD_1122_BEEF)
    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)

    #expect(
      bus.events
        == [
          .read(port: 0x60, width: .byte),
          .write(port: 0x61, value: 0xA5, width: .byte),
          .read(port: 0x64, width: .word),
          .write(port: 0x64, value: 0x1122_BEEF, width: .doubleword),
        ]
    )
  }

  @Test func tssIOBitmapControlsUnprivilegedPortAccess() throws {
    var bytes = [UInt8](repeating: 0, count: 0x400)
    bytes.replaceSubrange(0x100..<0x104, with: [0xE4, 0x60, 0xE4, 0x61])
    bytes.replaceSubrange(0x266..<0x268, with: [0x68, 0])
    bytes[0x274] = 0b0000_0010
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    let bus = RecordingIOBus(readValues: [0x60: 0x11, 0x61: 0x22])
    var state = try DoryX86ArchitecturalState(
      rip: 0x100,
      cs: .init(selector: 3, attributes: 0xC0FA, limit: .max),
      tr: .init(selector: 8, attributes: 0x008B, limit: 0x100, base: 0x200)
    )
    state.control.cr0 |= 1

    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    #expect(state.registers.rax == 0x11)
    #expect(state.rip == 0x102)
    let denied = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    guard case .exception(let exception) = denied else {
      Issue.record("denied TSS I/O-bitmap port did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(state.rip == 0x102)
    #expect(bus.events == [.read(port: 0x60, width: .byte)])
  }

  @Test func repeatStringPortIOTransfersDeviceBlocksRestartably() throws {
    var bytes = [UInt8](repeating: 0, count: 0x500)
    bytes.replaceSubrange(0x100..<0x105, with: [0xF3, 0x6C, 0xF3, 0x66, 0x6F])
    bytes.replaceSubrange(0x300..<0x304, with: [0x34, 0x12, 0x78, 0x56])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    let bus = RecordingIOBus(readValues: [0x1F0: 0x7A])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 3, rdx: 0x1F0, rdi: 0x200),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0xC09A, limit: .max),
      ds: .init(selector: 8, attributes: 0xC093, limit: .max),
      es: .init(selector: 8, attributes: 0xC093, limit: .max)
    )
    state.control.cr0 |= 1

    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    #expect(try memory.read(at: 0x200, byteCount: 3) == [0x7A, 0x7A, 0x7A])
    #expect(state.registers.rdi == 0x203)
    #expect(state.registers.rcx == 0)

    state.registers.rcx = 2
    state.registers.rsi = 0x300
    _ = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    #expect(state.registers.rsi == 0x304)
    #expect(state.registers.rcx == 0)
    #expect(
      bus.events
        == [
          .read(port: 0x1F0, width: .byte),
          .read(port: 0x1F0, width: .byte),
          .read(port: 0x1F0, width: .byte),
          .write(port: 0x1F0, value: 0x1234, width: .word),
          .write(port: 0x1F0, value: 0x5678, width: .word),
        ]
    )
  }

  @Test func stringInputPreflightsMemoryBeforeConsumingDeviceData() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x100,
      bytes: [0x6C] + .init(repeating: 0, count: 15)
    )
    let bus = RecordingIOBus(readValues: [0x60: 0xAA])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rdx: 0x60, rdi: 0x500),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0xC09A, limit: .max),
      es: .init(selector: 8, attributes: 0xC093, limit: .max)
    )
    state.control.cr0 |= 1

    let result = interpreter.step(
      state: &state, memory: memory, mode: .protected32, ioBus: bus)
    guard case .exception(let exception) = result else {
      Issue.record("unmapped INS destination did not fault")
      return
    }
    #expect(exception.kind == .pageFault)
    #expect(state.registers.rdi == 0x500)
    #expect(bus.events.isEmpty)
  }

  @Test func realModeStackOperationsUseSSBaseAndSixteenBitSP() throws {
    var bytes = [UInt8](repeating: 0, count: 0x400)
    bytes.replaceSubrange(0x100..<0x102, with: [0x50, 0x5B])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x1234, rsp: 0xAAAA_0010),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x93, limit: 0xffff),
      ss: .init(selector: 0x20, attributes: 0x93, limit: 0xffff, base: 0x200)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.registers.rsp == 0xAAAA_000E)
    #expect(try memory.read(at: 0x20E, byteCount: 2) == [0x34, 0x12])
    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.registers.rbx & 0xffff == 0x1234)
    #expect(state.registers.rsp == 0xAAAA_0010)
  }

  @Test func stackLimitViolationsRaisePreciseStackSegmentFaults() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x100,
      bytes: [0x50] + .init(repeating: 0, count: 0x200)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 7, rsp: 1),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x93, limit: 0xffff),
      ss: .init(selector: 0x20, attributes: 0x93, limit: 0xff, base: 0x100)
    )

    let result = interpreter.step(state: &state, memory: memory, mode: .real16)
    guard case .exception(let exception) = result else {
      Issue.record("out-of-limit PUSH did not fault")
      return
    }
    #expect(exception.kind == .stackSegment)
    #expect(exception.vector == 12)
    #expect(state.registers.rsp == 1)
    #expect(state.rip == 0x100)
  }

  @Test func poppingRSPLeavesThePoppedValueAsTheFinalPointer() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes[0x100] = 0x5C
    bytes.replaceSubrange(
      0x200..<0x208,
      with: [0x34, 0x12, 0, 0, 0, 0, 0, 0]
    )
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0x200),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max),
      ss: .init(selector: 8, attributes: 0xC093, limit: .max)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rsp == 0x1234)
  }

  @Test func memoryPopUsesThePostIncrementStackPointerForItsDestination() throws {
    var bytes = [UInt8](repeating: 0, count: 0x300)
    bytes.replaceSubrange(0x100..<0x103, with: [0x8F, 0x04, 0x24])
    bytes.replaceSubrange(
      0x200..<0x208,
      with: [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0]
    )
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0x200),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max),
      ss: .init(selector: 8, attributes: 0xC093, limit: .max)
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)

    #expect(state.registers.rsp == 0x208)
    #expect(
      try memory.read(at: 0x208, byteCount: 8)
        == [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0]
    )
  }

  @Test func doublePrecisionShiftsMergeOperandsAndSetDefinedFlags() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x100,
      bytes: [
        0x48, 0x0F, 0xA4, 0xD0, 0x04,  // shld rax,rdx,4
        0x0F, 0xAD, 0xD0,  // shrd eax,edx,cl
      ] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(
        rax: 0x1234_5678_9ABC_DEF0,
        rcx: 1,
        rdx: 0xFEDC_BA98_7654_3210
      ),
      rip: 0x100,
      rflags: [.reservedOne]
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0x2345_6789_ABCD_EF0F)
    #expect(state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.sign))
    #expect(state.rflags.contains(.parity))

    state.registers.rax = 0x8000_0001
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0x0000_0000_4000_0000)
    #expect(state.rflags.contains(.carry))
    #expect(state.rflags.contains(.overflow))
  }

  @Test func zeroCountDoubleShiftPreservesDestinationAndFlags() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x180,
      bytes: [0x48, 0x0F, 0xA5, 0xD0] + .init(repeating: 0, count: 16)
    )
    let originalFlags: DoryX86RFLAGS = [.reservedOne, .carry, .overflow, .zero]
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x1234, rcx: 0, rdx: .max),
      rip: 0x180,
      rflags: originalFlags
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)

    #expect(state.registers.rax == 0x1234)
    #expect(state.rflags == originalFlags)
  }

  @Test func instructionFetchEnforcesExecutableCSAndItsLimit() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x100,
      bytes: [0xB8, 1, 2, 3, 4] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      rip: 0x100,
      cs: .init(selector: 8, attributes: 0xC09A, limit: 0x102)
    )
    state.control.cr0 |= 1

    let crossedLimit = interpreter.step(
      state: &state, memory: memory, mode: .protected32)
    guard case .exception(let exception) = crossedLimit else {
      Issue.record("cross-limit instruction fetch did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(state.rip == 0x100)

    state.cs.attributes = 0xC092
    state.cs.limit = .max
    let nonExecutable = interpreter.step(
      state: &state, memory: memory, mode: .protected32)
    guard case .exception(let exception) = nonExecutable else {
      Issue.record("fetch through a data segment did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
  }

  @Test func executesAbsoluteMovesBitScansByteSwapsAndLoops() throws {
    var bytes = [UInt8](repeating: 0, count: 0x500)
    bytes.replaceSubrange(
      0x100..<0x116,
      with: [
        0xA1, 0, 2, 0, 0,
        0xA3, 4, 2, 0, 0,
        0x0F, 0xBC, 0xC8,
        0x0F, 0xBD, 0xD0,
        0x0F, 0xCA,
        0xE2, 0xFE,
        0xE3, 2,
      ]
    )
    bytes.replaceSubrange(0x200..<0x204, with: [0x10, 0, 0, 0x80])
    let memory = DoryX86ByteArrayMemory(bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2),
      rip: 0x100,
      cs: .init(selector: 8, attributes: 0xC09A, limit: .max),
      ds: .init(selector: 16, attributes: 0xC093, limit: .max)
    )
    state.control.cr0 |= 1

    for _ in 0..<5 {
      _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    }
    #expect(state.registers.rax == 0x8000_0010)
    #expect(try memory.read(at: 0x204, byteCount: 4) == [0x10, 0, 0, 0x80])
    #expect(state.registers.rcx == 4)
    #expect(state.registers.rdx == 0x1F00_0000)

    state.registers.rcx = 2
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.registers.rcx == 1)
    #expect(state.rip == 0x112)
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.registers.rcx == 0)
    #expect(state.rip == 0x114)
    _ = interpreter.step(state: &state, memory: memory, mode: .protected32)
    #expect(state.rip == 0x118)
  }

  @Test func flagByteTransfersOnlyTheArchitecturalStatusBits() throws {
    let memory = DoryX86ByteArrayMemory(
      baseAddress: 0x100,
      bytes: [0x9F, 0x9E] + .init(repeating: 0, count: 16)
    )
    var state = try DoryX86ArchitecturalState(
      rip: 0x100,
      rflags: [.reservedOne, .carry, .zero, .sign]
    )

    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect((state.registers.rax >> 8) & 0xff == 0xC3)
    state.registers.rax = (state.registers.rax & ~UInt64(0xff00)) | 0x1500
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.rflags.contains(.carry))
    #expect(state.rflags.contains(.parity))
    #expect(state.rflags.contains(.auxiliaryCarry))
    #expect(!state.rflags.contains(.zero))
    #expect(!state.rflags.contains(.sign))
  }

  private func readQuadword(_ memory: DoryX86ByteArrayMemory, at address: UInt64) -> UInt64 {
    try! memory.read(at: address, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func memoryInteger(bytes: [UInt8]) throws -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}

private enum IOEvent: Sendable, Hashable {
  case read(port: UInt16, width: DoryX86OperandWidth)
  case write(port: UInt16, value: UInt32, width: DoryX86OperandWidth)
}

private final class RecordingIOBus: DoryX86IOBus, @unchecked Sendable {
  private let lock = NSLock()
  private let readValues: [UInt16: UInt32]
  private var recordedEvents: [IOEvent] = []

  init(readValues: [UInt16: UInt32]) {
    self.readValues = readValues
  }

  var events: [IOEvent] {
    lock.withLock { recordedEvents }
  }

  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    try lock.withLock {
      recordedEvents.append(.read(port: port, width: width))
      guard let value = readValues[port] else {
        throw DoryX86IOBusError.unmappedPort(port, width: width)
      }
      return value
    }
  }

  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) {
    lock.withLock {
      recordedEvents.append(.write(port: port, value: value, width: width))
    }
  }
}
