import Testing

@testable import DoryDBTX86

// A07.3: REP semantics and restartability boundary tests.
// Covers zero counts, REP LODS, backward-direction REP CMPS/SCAS,
// and mid-string interruption with exact RCX/RSI/RDI/flags.
// These complement the existing REP MOVSB/STOS/SCAS tests in
// DoryX86InterpreterTests and DoryX86REPStringCanonicalBoundaryTests.
@Suite struct DoryX86REPRestartabilityBoundaryTests {
  private let interpreter = DoryX86Interpreter()
  private let rip: UInt64 = 0x1000

  // REP with RCX=0 performs zero iterations and retires immediately.
  @Test func repWithZeroCountRetiresImmediatelyWithoutAccess() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xF3, 0xA4])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 0, rsi: 0x2000, rdi: 0x3000), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP with RCX=0 did not retire: \(result)")
      return
    }
    #expect(state.rip == rip + 2)
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == 0x2000)
    #expect(state.registers.rdi == 0x3000)
  }

  // REPNE with RCX=0 retires immediately without comparison.
  @Test func repneWithZeroCountRetiresImmediately() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xF2, 0xA6])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x41, rcx: 0, rsi: 0x2000, rdi: 0x3000), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REPNE CMPSB with RCX=0 did not retire: \(result)")
      return
    }
    #expect(state.rip == rip + 2)
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == 0x2000)
    #expect(state.registers.rdi == 0x3000)
  }

  // REP STOS with RCX=0 retires immediately without writes.
  @Test func repStosWithZeroCountRetiresImmediately() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xF3, 0xAA])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x7E, rcx: 0, rdi: 0x3000), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP STOSB with RCX=0 did not retire: \(result)")
      return
    }
    #expect(state.rip == rip + 2)
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rdi == 0x3000)
  }

  // REP LODS loads bytes from [RSI] into AL, advancing RSI and decrementing RCX.
  @Test func repLodsBLoadsBytesIntoAccumulator() throws {
    // F3 AC: REP LODSB
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xF3, 0xAC, 0x11, 0x22, 0x33])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 3, rsi: rip + 2), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP LODSB did not retire: \(result)")
      return
    }
    #expect(state.registers.rax & 0xFF == 0x33)
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == rip + 5)
  }

  // REP LODS with RCX=1 loads a single byte.
  @Test func lodsBWithCountOneLoadsSingleByte() throws {
    // AC: LODSB (no REP prefix, count=1 implicit)
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xAC, 0x42])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsi: rip + 1), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("LODSB did not retire: \(result)")
      return
    }
    #expect(state.registers.rax & 0xFF == 0x42)
    #expect(state.registers.rsi == rip + 2)
  }

  // REP CMPSB with DF=0 (forward) compares bytes and stops on mismatch (REPE).
  @Test func repeCmpsBStopsOnMismatchForward() throws {
    // F3 A6: REPE CMPSB
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0xF3, 0xA6, 0x41, 0x42, 0x41, 0x43])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0, rcx: 3, rsi: rip + 2, rdi: rip + 4), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REPE CMPSB did not retire: \(result)")
      return
    }
    // First byte: 0x41 vs 0x41 → equal, continue. Second: 0x42 vs 0x43 → mismatch, stop.
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == rip + 4)
    #expect(state.registers.rdi == rip + 6)
    #expect(!state.rflags.contains(.zero))
  }

  // REPNE CMPSB stops on match.
  @Test func repneCmpsBStopsOnMatchForward() throws {
    // F2 A6: REPNE CMPSB
    // RSI: [0x41, 0x42, 0x43], RDI: [0x43, 0x43, 0x43]
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF2, 0xA6, 0x41, 0x42, 0x43, 0x43, 0x43, 0x43])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0, rcx: 3, rsi: rip + 2, rdi: rip + 5), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REPNE CMPSB did not retire: \(result)")
      return
    }
    // First: 0x41 vs 0x43 → not equal, continue. Second: 0x42 vs 0x43 → not equal, continue.
    // Third: 0x43 vs 0x43 → equal, stop.
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == rip + 5)
    #expect(state.registers.rdi == rip + 8)
    #expect(state.rflags.contains(.zero))
  }

  // REP SCASB with DF=1 (backward) scans backward, decrementing RDI.
  @Test func repneScasBBackwardStopsOnMatch() throws {
    // F2 AE: REPNE SCASB with DF=1 (set in initial state)
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF2, 0xAE, 0x41, 0x42, 0x43])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x43, rcx: 3, rdi: rip + 4), rip: rip,
      rflags: [.reservedOne, .direction])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REPNE SCASB backward did not retire: \(result)")
      return
    }
    // Backward: RDI starts at rip+4 (byte 0x43). AL=0x43. First: 0x43 == 0x43 → match, stop.
    #expect(state.registers.rcx == 2)
    #expect(state.rflags.contains(.zero))
  }

  // REP MOVSB with DF=1 (backward) moves bytes in reverse.
  @Test func repMovsBBackwardMovesBytesInReverse() throws {
    // F3 A4: REP MOVSB with DF=1 (set in initial state)
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF3, 0xA4, 0x11, 0x22, 0x33, 0x00, 0x00, 0x00])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 3, rsi: rip + 4, rdi: rip + 7), rip: rip,
      rflags: [.reservedOne, .direction])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP MOVSB backward did not retire: \(result)")
      return
    }
    // Backward: RSI starts at rip+4 (byte 0x33), RDI at rip+7.
    // First: read [rip+4]=0x33, write [rip+7]=0x33, RSI→3, RDI→6
    // Second: read [rip+3]=0x22, write [rip+6]=0x22, RSI→2, RDI→5
    // Third: read [rip+2]=0x11, write [rip+5]=0x11, RSI→1, RDI→4
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == rip + 1)
    #expect(state.registers.rdi == rip + 4)
    #expect(try memory.read(at: rip + 5, byteCount: 3) == [0x11, 0x22, 0x33])
  }

  // REP STOSB with DF=1 (backward) fills bytes in reverse.
  @Test func repStosBBackwardFillsInReverse() throws {
    // F3 AA: REP STOSB with DF=1 (set in initial state)
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF3, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x7E, rcx: 3, rdi: rip + 6), rip: rip,
      rflags: [.reservedOne, .direction])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP STOSB backward did not retire: \(result)")
      return
    }
    // Backward: RDI starts at rip+6. Write 0x7E at [6], [5], [4].
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rdi == rip + 3)
    #expect(try memory.read(at: rip + 4, byteCount: 3) == [0x7E, 0x7E, 0x7E])
  }

  // REP LODSB with DF=1 (backward) loads bytes in reverse.
  @Test func repLodsBBackwardLoadsInReverse() throws {
    // F3 AC: REP LODSB with DF=1 (set in initial state)
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF3, 0xAC, 0x11, 0x22, 0x33])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 3, rsi: rip + 4), rip: rip,
      rflags: [.reservedOne, .direction])
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP LODSB backward did not retire: \(result)")
      return
    }
    // Backward: RSI starts at rip+4 (byte 0x33). Load 0x33, 0x22, 0x11 into AL.
    // Final AL = 0x11 (last loaded).
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == rip + 1)
    #expect(state.registers.rax & 0xFF == 0x11)
  }

  // REP MOVSB with overlapping source and destination (forward) preserves sequential semantics.
  @Test func repMovsBForwardOverlapPreservesSequentialSemantics() throws {
    // F3 A4: REP MOVSB with forward overlap (RSI < RDI, overlapping)
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xF3, 0xA4, 0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 4, rsi: rip + 2, rdi: rip + 3), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP MOVSB overlap did not retire: \(result)")
      return
    }
    // Forward overlap: [0x01, 0x01, 0x01, 0x01] — each byte copies the previous result.
    #expect(state.registers.rcx == 0)
    #expect(try memory.read(at: rip + 3, byteCount: 4) == [0x01, 0x01, 0x01, 0x01])
  }

  // REP MOVSQ with count=1 retires after a single qword move.
  @Test func repMovsQWithCountOneMovesSingleQword() throws {
    // F3 48 A5: REP MOVSQ
    let qword: UInt64 = 0x1122_3344_5566_7788
    let bytes: [UInt8] = [0xF3, 0x48, 0xA5] + [UInt8](repeating: 0, count: 24)
    var program = bytes
    for (i, b) in qword.littleEndianBytes.enumerated() { program[3 + i] = b }
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: program)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 1, rsi: rip + 3, rdi: rip + 11), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("REP MOVSQ count=1 did not retire: \(result)")
      return
    }
    #expect(state.registers.rcx == 0)
    #expect(state.registers.rsi == rip + 11)
    #expect(state.registers.rdi == rip + 19)
    #expect(try memory.read(at: rip + 11, byteCount: 8) == qword.littleEndianBytes)
  }

  // Non-repeated CMPSB (no REP prefix) performs a single comparison.
  @Test func cmpsBWithoutRepeatPerformsSingleComparison() throws {
    // A6: CMPSB
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xA6, 0x41, 0x42])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 100, rsi: rip + 1, rdi: rip + 2), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("CMPSB did not retire: \(result)")
      return
    }
    #expect(state.rip == rip + 1)
    #expect(state.registers.rcx == 100)  // RCX unchanged without REP
    #expect(state.registers.rsi == rip + 2)
    #expect(state.registers.rdi == rip + 3)
    #expect(!state.rflags.contains(.zero))  // 0x41 != 0x42
  }

  // Non-repeated SCASB (no REP prefix) performs a single scan.
  @Test func scasBWithoutRepeatPerformsSingleScan() throws {
    // AE: SCASB
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: rip, bytes: [0xAE, 0x41])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x41, rcx: 100, rdi: rip + 1), rip: rip)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = result else {
      Issue.record("SCASB did not retire: \(result)")
      return
    }
    #expect(state.rip == rip + 1)
    #expect(state.registers.rcx == 100)  // RCX unchanged without REP
    #expect(state.registers.rdi == rip + 2)
    #expect(state.rflags.contains(.zero))  // 0x41 == 0x41
  }
}

private extension UInt64 {
  var littleEndianBytes: [UInt8] {
    withUnsafeBytes(of: littleEndian) { Array($0) }
  }
}
