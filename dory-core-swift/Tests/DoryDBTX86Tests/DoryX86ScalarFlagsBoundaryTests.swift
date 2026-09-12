import Testing

@testable import DoryDBTX86

// A07.2: Scalar results and flags boundary tests for MUL/DIV overflow and
// ADC/SBB carry chains. These complement the existing multiply/divide and
// ADC/SBB tests with specific boundary conditions.
@Suite struct DoryX86ScalarFlagsBoundaryTests {
  private let interpreter = DoryX86Interpreter()

  // MUL: CF/OF clear when the high half of the product is zero.
  @Test func mulClearsCarryAndOverflowWhenHighHalfIsZero() throws {
    // F7 E3: MUL EBX (32-bit, EAX=3, EBX=4 → EDX:EAX = 0x0000_000C)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF7, 0xE3])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 3, rbx: 4), rip: 0x1000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 12)
    #expect(state.registers.rdx == 0)
    #expect(!state.rflags.contains(.carry))
    #expect(!state.rflags.contains(.overflow))
  }

  // MUL: 64-bit overflow produces nonzero RDX.
  @Test func mul64BitOverflowSetsCarryAndOverflow() throws {
    // 48 F7 E3: MUL RBX (64-bit, RAX=max, RBX=2 → RDX:RAX = 0x1_FFFF...FFFE)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x48, 0xF7, 0xE3])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: .max, rbx: 2), rip: 0x1000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rdx == 1)
    #expect(state.rflags.contains(.carry))
    #expect(state.rflags.contains(.overflow))
  }

  // DIV: divide by zero raises #DE with precise state preservation.
  @Test func divByZeroRaisesDivideErrorWithPreciseState() throws {
    // F7 F3: DIV EBX (RAX=1, RBX=0 → #DE)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF7, 0xF3])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 1, rbx: 0), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow])
    let before = state
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(result == .exception(.init(kind: .divideError, vector: 0, instructionPointer: 0x1000)))
    #expect(state == before)
  }

  // DIV: normal division produces correct quotient and remainder.
  @Test func divNormalProducesCorrectQuotientAndRemainder() throws {
    // F7 F3: DIV EBX (RAX=17, RBX=5 → quotient=3, remainder=2)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF7, 0xF3])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 17, rbx: 5), rip: 0x1000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 3)
    #expect(state.registers.rdx & 0xFFFFFFFF == 2)
  }

  // ADC: carry-in propagates through the addition.
  @Test func adcPropagatesCarryInput() throws {
    // 11 D8: ADC EAX, EBX (RAX=1, RBX=1, CF=1 → RAX=3)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x11, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 1, rbx: 1), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 3)
    #expect(!state.rflags.contains(.carry))
  }

  // ADC: carry-in causes overflow at the boundary.
  @Test func adcCarryInputCausesOverflow() throws {
    // 11 D8: ADC EAX, EBX (RAX=0xFFFF_FFFF, RBX=0, CF=1 → RAX=0, CF=1)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x11, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xFFFF_FFFF, rbx: 0), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(state.rflags.contains(.carry))
  }

  // SBB: borrow-in propagates through the subtraction.
  @Test func sbbPropagatesBorrowInput() throws {
    // 19 D8: SBB EAX, EBX (RAX=3, RBX=1, CF=1 → RAX=1)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x19, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 3, rbx: 1), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 1)
  }

  // SBB: borrow-in causes underflow at the boundary.
  @Test func sbbBorrowInputCausesUnderflow() throws {
    // 19 D8: SBB EAX, EBX (RAX=0, RBX=0, CF=1 → RAX=0xFFFF_FFFF, CF=1)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x19, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0, rbx: 0), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 0xFFFF_FFFF)
    #expect(state.rflags.contains(.carry))
  }

  // ADC: 64-bit width carry propagation.
  @Test func adc64BitCarryPropagation() throws {
    // 48 11 D8: ADC RAX, RBX (RAX=max, RBX=0, CF=1 → RAX=0, CF=1)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x48, 0x11, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: .max, rbx: 0), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == 0)
    #expect(state.rflags.contains(.carry))
  }

  // SBB: 64-bit width borrow propagation.
  @Test func sbb64BitBorrowPropagation() throws {
    // 48 19 D8: SBB RAX, RBX (RAX=0, RBX=0, CF=1 → RAX=max, CF=1)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x48, 0x19, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0, rbx: 0), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax == .max)
    #expect(state.rflags.contains(.carry))
  }

  // ADC chain: two ADCs in sequence propagate carry correctly.
  @Test func adcChainPropagatesCarryAcrossTwoInstructions() throws {
    // 11 D8 11 D8: ADC EAX,EBX; ADC EAX,EBX
    // RAX=1, RBX=0x7FFF_FFFF, CF=1
    // First: RAX = 1 + 0x7FFF_FFFF + 1 = 0x8000_0001, CF=0, OF=1
    // Second: RAX = 0x8000_0001 + 0x7FFF_FFFF + 0 = 0x1_0000_0000 → RAX=0, CF=1
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x11, 0xD8, 0x11, 0xD8])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 1, rbx: 0x7FFF_FFFF), rip: 0x1000,
      rflags: [.reservedOne, .carry])
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 0x8000_0001)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rax & 0xFFFFFFFF == 0)
    #expect(state.rflags.contains(.carry))
  }
}
