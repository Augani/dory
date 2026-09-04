/// Admission for the represented x87/MMX instructions and FX state transfers.
/// Intel SDM 092, Vol. 3A Tables 2-2 and 15-1; Vol. 2A FISTTP, FCMOVcc,
/// FCOMI, FNOP, FXSAVE/FXRSTOR; Vol. 2D WAIT/FWAIT:
/// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
/// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
/// Pending numeric exceptions, arithmetic precision/status and NE/FERR reporting
/// remain separate; this policy does not claim to implement those effects.
enum DoryX86LegacyFloatingPointPolicy {
  private enum StateUse { case x87, mmx, wait, fxState }

  static func permitsFeatures(
    _ instruction: DoryX86DecodedInstruction, profile: DoryX86CPUProfile
  ) -> Bool {
    switch stateUse(instruction) {
    case .x87:
      guard profile.supports(.x87) else { return false }
      switch instruction.operation {
      case .storeX87(_, _, _, let truncate) where truncate:
        return profile.supports(.sse3) // FISTTP uses x87 state despite its SSE3 feature bit.
      case .conditionalMoveX87, .compareX87(_, _, _, true):
        return profile.supports(.cmov)
      default: return true
      }
    case .mmx:
      // SSE/SSE2 extensions using MMX registers also retain their per-instruction
      // extension requirement in DoryX86InstructionFeaturePolicy.
      return profile.supports(.mmx)
    case .wait, .fxState, nil:
      // WAIT is available with software x87 emulation. FXSR is checked separately.
      return true
    }
  }

  /// Called after instruction feature admission, before any data operand access.
  static func executionFault(
    _ instruction: DoryX86DecodedInstruction, state: DoryX86ArchitecturalState
  ) -> DoryX86Exception? {
    let em = state.control.cr0 & 4 != 0
    let ts = state.control.cr0 & 8 != 0
    let unavailable: Bool
    switch stateUse(instruction) {
    case .x87:
      // Non-waiting FN instructions still check EM/TS. The "no wait" distinction
      // concerns pending numeric exceptions, not whether x87 state is enabled.
      unavailable = em || ts
    case .mmx:
      // Table 15-1 gives EM's #UD precedence with TS marked irrelevant.
      if em { return .init(kind: .invalidOpcode, vector: 6, instructionPointer: instruction.address) }
      unavailable = ts
    case .wait:
      unavailable = ts && state.control.cr0 & 2 != 0 // MP; EM has no effect on WAIT.
    case .fxState:
      // Vol. 2A lists both TS and EM under #NM for these transfers. MP and
      // OSFXSR do not affect admission (OSFXSR affects the transferred state).
      unavailable = em || ts
    case nil:
      return nil
    }
    return unavailable
      ? .init(kind: .deviceNotAvailable, vector: 7, instructionPointer: instruction.address) : nil
  }

  static func isX87NoOperation(_ instruction: DoryX86DecodedInstruction) -> Bool {
    guard instruction.prefixes.vex == nil, case .noOperation = instruction.operation else { return false }
    // Examine only the opcode after leading prefixes. A multi-byte integer NOP's
    // displacement may contain D9 D0 and must not acquire x87 controls/features.
    let opcode = instruction.bytes.drop(while: { byte in
      switch byte {
      case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x40...0x4F:
        return true
      default: return false
      }
    })
    return opcode.elementsEqual([0xD9, 0xD0])
  }

  private static func stateUse(_ instruction: DoryX86DecodedInstruction) -> StateUse? {
    guard instruction.prefixes.vex == nil else { return nil }
    switch instruction.operation {
    case .initializeFloatingPoint, .loadX87ControlWord, .storeX87ControlWord,
      .loadX87, .storeX87, .exchangeX87, .x87Binary, .compareX87, .x87Special,
      .loadX87Environment, .storeX87Environment, .loadX87PackedBCD, .storeX87PackedBCD,
      .moveX87, .freeX87, .conditionalMoveX87, .clearX87Exceptions, .storeX87StatusWord:
      return .x87
    case .noOperation:
      return isX87NoOperation(instruction) ? .x87 : nil
    case .waitForCoprocessor:
      return .wait
    case .moveMMX, .moveIntegerToMMX, .moveMMXToInteger, .mmxBitwise,
      .mmxIntegerBinary, .mmxIntegerShift, .mmxIntegerInterleave, .mmxIntegerPack, .emptyMMXState:
      return .mmx
    case .insertPackedWord(_, _, _, true), .extractPackedWord(_, _, _, true),
      .moveVectorMask(_, _, _, 8):
      return .mmx
    case .saveFloatingPointState, .restoreFloatingPointState:
      return .fxState
    default: return nil
    }
  }
}
