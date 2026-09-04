// Intel SDM 092 Vol. 1 §§8.1.7–8.1.10, Figures 8-9–8-12, and §10.5.1;
// Vol. 2A FLDENV/FNSTENV/FXSAVE/FXRSTOR. Reserved output bits are zeroed as
// a deterministic implementation choice, not a claim about physical CPUs.
enum DoryX86FloatingPointEnvironment {
  static func byteCount(mode: DoryX86ExecutionMode, operandSizeOverride: Bool, rexW: Bool) -> Int {
    // Intel XED's FLDENV/FNSTENV mode64 rexw_prefix forms are mem28,
    // including when 66 is present; there is no 64-bit environment image.
    // https://github.com/intelxed/xed/blob/main/datafiles/xed-isa.txt
    if mode == .long64 && rexW { return 28 }
    let default16 = mode == .real16 || mode == .protected16
    return default16 != operandSizeOverride ? 14 : 28
  }

  static func usesRealFormat(mode: DoryX86ExecutionMode, virtual8086: Bool) -> Bool {
    mode == .real16 || virtual8086
  }

  static func save(_ state: DoryX86FloatingPointState, byteCount: Int, realFormat: Bool) -> [UInt8] {
    precondition(byteCount == 14 || byteCount == 28)
    let stride = byteCount == 14 ? 2 : 4
    var bytes = [UInt8](repeating: 0, count: byteCount)
    put(state.x87ControlWord, in: &bytes, at: 0)
    put(state.x87StatusWord, in: &bytes, at: stride)
    put(state.x87TagWord, in: &bytes, at: stride * 2)
    let ip = state.x87InstructionPointer
    let dp = state.x87DataPointer
    if realFormat {
      // The real/v8086 image stores the linear pointer, unlike the protected
      // image's separate offset and selector. Wrapping/truncation is defined by
      // the image's 20-bit (14-byte) or 32-bit (28-byte) pointer fields.
      let linearIP = ip &+ (UInt64(state.x87InstructionSelector) << 4)
      let linearDP = dp &+ (UInt64(state.x87DataSelector) << 4)
      put(UInt16(truncatingIfNeeded: linearIP), in: &bytes, at: stride * 3)
      put(UInt16(truncatingIfNeeded: linearDP), in: &bytes, at: stride * 5)
      if byteCount == 14 {
        put(UInt16((linearIP >> 4) & 0xF000) | (state.x87Opcode & 0x7FF), in: &bytes, at: 8)
        put(UInt16((linearDP >> 4) & 0xF000), in: &bytes, at: 12)
      } else {
        put(UInt32((linearIP >> 4) & 0x0FFF_F000) | UInt32(state.x87Opcode & 0x7FF), in: &bytes, at: 16)
        put(UInt32((linearDP >> 4) & 0x0FFF_F000), in: &bytes, at: 24)
      }
    } else if byteCount == 14 {
      put(UInt16(truncatingIfNeeded: ip), in: &bytes, at: 6)
      put(state.x87InstructionSelector, in: &bytes, at: 8)
      put(UInt16(truncatingIfNeeded: dp), in: &bytes, at: 10)
      put(state.x87DataSelector, in: &bytes, at: 12)
    } else {
      put(UInt32(truncatingIfNeeded: ip), in: &bytes, at: 12)
      put(state.x87InstructionSelector, in: &bytes, at: 16)
      put(state.x87Opcode & 0x7FF, in: &bytes, at: 18)
      put(UInt32(truncatingIfNeeded: dp), in: &bytes, at: 20)
      put(state.x87DataSelector, in: &bytes, at: 24)
    }
    return bytes
  }

  static func load(_ bytes: [UInt8], realFormat: Bool, into state: inout DoryX86FloatingPointState) {
    precondition(bytes.count == 14 || bytes.count == 28)
    let stride = bytes.count == 14 ? 2 : 4
    state.x87ControlWord = UInt16(read(bytes, at: 0, count: 2))
    state.x87StatusWord = UInt16(read(bytes, at: stride, count: 2))
    let tags = UInt16(read(bytes, at: stride * 2, count: 2))
    state.x87TagWord = classifiedTags(emptyTags: tags, registers: state.x87)
    if realFormat {
      let highMask: UInt64 = bytes.count == 14 ? 0xF000 : 0x0FFF_F000
      let ipHigh = read(bytes, at: stride * 4, count: stride)
      let dpHigh = read(bytes, at: stride * 6, count: stride)
      state.x87InstructionPointer = read(bytes, at: stride * 3, count: 2) | ((ipHigh & highMask) << 4)
      state.x87DataPointer = read(bytes, at: stride * 5, count: 2) | ((dpHigh & highMask) << 4)
      state.x87InstructionSelector = 0
      state.x87DataSelector = 0
      state.x87Opcode = UInt16(ipHigh & 0x7FF)
    } else {
      state.x87InstructionPointer = read(bytes, at: stride * 3, count: stride)
      state.x87InstructionSelector = UInt16(read(bytes, at: stride * 4, count: 2))
      state.x87DataPointer = read(bytes, at: stride * 5, count: stride)
      state.x87DataSelector = UInt16(read(bytes, at: stride * 6, count: 2))
      // Figure 8-11 has no opcode field. Use zero on its restoration, also
      // used by Bochs fpu_load_environment's protected 16-bit implementation.
      state.x87Opcode = bytes.count == 14 ? 0 : UInt16(read(bytes, at: 18, count: 2) & 0x7FF)
    }
  }

  // Tags are physical R0...R7. FLDENV and FXRSTOR use the supplied tag only
  // for emptiness; every nonempty tag is classified from actual binary80 data.
  static func classifiedTags(emptyTags: UInt16, registers: [DoryX86RegisterBytes]) -> UInt16 {
    var result: UInt16 = 0
    for index in 0..<8 {
      let shift = UInt16(index * 2)
      let tag: UInt16 = (emptyTags >> shift) & 3 == 3 ? 3 : tag(for: registers[index].bytes)
      result |= tag << shift
    }
    return result
  }

  private static func tag(for bytes: [UInt8]) -> UInt16 {
    let exponent = read(bytes, at: 8, count: 2) & 0x7FFF
    let significand = read(bytes, at: 0, count: 8)
    if exponent == 0 && significand == 0 { return 1 }
    // Denormals, pseudo-denormals, infinities, NaNs, and unnormal encodings
    // have special tags. Normal finite values require the explicit integer bit.
    if exponent == 0 || exponent == 0x7FFF || significand & (1 << 63) == 0 { return 2 }
    return 0
  }

  static func isNonControl(_ instruction: DoryX86DecodedInstruction) -> Bool {
    switch instruction.operation {
    case .loadX87, .storeX87, .exchangeX87, .x87Binary, .compareX87, .x87Special,
      .loadX87PackedBCD, .storeX87PackedBCD, .moveX87, .freeX87, .conditionalMoveX87:
      return true
    case .noOperation:
      return DoryX86LegacyFloatingPointPolicy.isX87NoOperation(instruction)
    default: return false
    }
  }

  static func memoryOperand(_ instruction: DoryX86DecodedInstruction) -> DoryX86MemoryOperand? {
    switch instruction.operation {
    case .loadX87(.memory(let memory, _)), .x87Binary(_, _, .memory(let memory, _), _),
      .compareX87(.memory(let memory, _), _, _, _), .storeX87(let memory, _, _, _),
      .loadX87PackedBCD(let memory), .storeX87PackedBCD(let memory, _): return memory
    default: return nil
    }
  }

  static func recordOpcodeIfNewUnmaskedException(
    _ instruction: DoryX86DecodedInstruction, previousStatus: UInt16,
    state: inout DoryX86FloatingPointState
  ) {
    // SDM §8.1.9's current-processor baseline updates FOP on unmasked x87
    // exceptions, not every operation. Dory has no legacy fopcode compatibility
    // MSR mode. This covers newly represented sticky exceptions only; complete
    // arithmetic exception generation and NE=0 FERR# remain separate work.
    guard state.x87StatusWord & ~previousStatus & ~state.x87ControlWord & 0x3F != 0 else { return }
    let opcode = instruction.bytes.drop(while: { byte in
      switch byte {
      case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x40...0x4F: true
      default: false
      }
    })
    guard opcode.count >= 2 else { return }
    state.x87Opcode = UInt16(opcode[opcode.startIndex] & 7) << 8 | UInt16(opcode[opcode.startIndex + 1])
  }

  private static func read(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
    (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
  }

  private static func put<T: FixedWidthInteger>(_ value: T, in bytes: inout [UInt8], at offset: Int) {
    for index in 0..<MemoryLayout<T>.size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
  }
}
