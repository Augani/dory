// Intel SDM092 Vol. 1 §§4.8.3.7, 4.9.2, 8.5.1.1 and 8.7.1.
// This helper covers transfer/constant-load and binary arithmetic/comparison
// stack faults. Conditional moves and transcendental stack responses remain
// separate work.
// Suppressed-store fault priority is a Dory compatibility choice correlated with
// https://github.com/bochs-emu/Bochs/blob/master/bochs/cpu/fpu/fpu_load_store.cc
// rather than a local physical-reference qualification.
enum DoryX86X87Stack {
  enum Fault { case underflow, overflow }

  static let indefinite = DoryX86ExtendedFloat(
    bytes: [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF])
  // SDM Vol. 1 Table 4-5: FFFFC000000000000000H, in little-endian order.
  static let packedBCDIndefinite: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF]

  static func isEmpty(_ logical: UInt8, state: DoryX86FloatingPointState) -> Bool {
    let physical = (Int(state.x87StatusWord >> 11) + Int(logical)) & 7
    return (state.x87TagWord >> UInt16(physical * 2)) & 3 == 3
  }

  static func loadFault(source: DoryX87Operand?, state: DoryX86FloatingPointState) -> Fault? {
    // SDM §4.9.2 explicitly gives source underflow priority over stack overflow.
    if let source, case .register(let register) = source, isEmpty(register, state: state) { return .underflow }
    return isEmpty(7, state: state) ? nil : .overflow
  }

  /// Binary arithmetic and comparisons consume their destination and any
  /// register source. Memory-source accessibility is checked by the caller
  /// before this tag decision so a data fault cannot acquire x87 side effects.
  static func binaryFault(
    destination: UInt8, source: DoryX87Operand, state: DoryX86FloatingPointState
  ) -> Fault? {
    if isEmpty(destination, state: state) { return .underflow }
    if case .register(let register) = source, isEmpty(register, state: state) {
      return .underflow
    }
    return nil
  }

  /// Records a generated stack exception and returns whether IM permits its
  /// masked result. An unmasked fault is deferred to the next waiting boundary;
  /// its instruction still retires without changing operands or TOP.
  static func record(_ fault: Fault, instruction: DoryX86DecodedInstruction,
    state: inout DoryX86FloatingPointState) -> Bool {
    state.x87StatusWord = (state.x87StatusWord & ~UInt16(0x0200)) | 0x0041
    if case .overflow = fault { state.x87StatusWord |= 0x0200 }
    DoryX86LegacyFloatingPointPolicy.updateExceptionSummary(state: &state)
    let masked = state.x87ControlWord & 1 != 0
    if !masked {
      // This instruction incurred an exception even if IE was already sticky.
      // Do not rely on the generic newly-set-flag tracker for this exact case.
      let opcode = instruction.bytes.drop(while: { byte in
        switch byte {
        case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x40...0x4F: true
        default: false
        }
      })
      if opcode.count >= 2 {
        state.x87Opcode = UInt16(opcode[opcode.startIndex] & 7) << 8 | UInt16(opcode[opcode.startIndex + 1])
      }
    }
    return masked
  }

  /// Commit after all operand accesses and stack-fault decisions. Preserve C1
  /// so a masked underflow cannot accidentally become overflow on the push.
  static func commitPush(_ value: DoryX86ExtendedFloat, state: inout DoryX86FloatingPointState) {
    let bytes = value.bytes()
    commitPush(bytes: bytes, tag: DoryX86X87Transfer.binary80Class(bytes).tag, state: &state)
  }

  /// The x87 register file stores the architectural binary80 payload. Transfer
  /// instructions must not canonicalize unsupported or pseudo-denormal forms.
  static func commitPush(
    bytes: [UInt8], tag: UInt16, state: inout DoryX86FloatingPointState
  ) {
    precondition(bytes.count == 10 && tag < 3)
    let top = (Int(state.x87StatusWord >> 11) - 1) & 7
    state.x87StatusWord = (state.x87StatusWord & ~UInt16(0x3800)) | UInt16(top << 11)
    state.x87[top] = try! .init(bytes: bytes, expectedByteCount: 10)
    let shift = UInt16(top * 2)
    state.x87TagWord = (state.x87TagWord & ~(UInt16(3) << shift)) | tag << shift
  }

  static func isConstantLoad(_ operation: DoryX87SpecialOperation) -> Bool {
    switch operation {
    case .loadOne, .loadLog2Ten, .loadLog2E, .loadPi, .loadLog10Two, .loadLnTwo, .loadZero: true
    default: false
    }
  }

  static func indefiniteBytes(for format: DoryX87MemoryFormat) -> [UInt8] {
    switch format {
    case .float32: [0, 0, 0xC0, 0xFF]
    case .float64: [0, 0, 0, 0, 0, 0, 0xF8, 0xFF]
    case .extended80: indefinite.bytes()
    case .signedInteger16: [0, 0x80]
    case .signedInteger32: [0, 0, 0, 0x80]
    case .signedInteger64: [0, 0, 0, 0, 0, 0, 0, 0x80]
    }
  }
}
