/// Feature/encoding admission for the instructions currently decoded by Dory.
/// This is not full ISA qualification or the CR0/CR4/XCR0 execution-state checks. In
/// particular, synthetic test profiles opting into AVX do not qualify XSAVE or AVX state.
/// Instruction requirements: Intel SDM Vol. 2, the named instruction's CPUID Feature Flag
/// and VEX encoding tables: https://cdrdv2-public.intel.com/774492/325383-sdm-vol-2abcd.pdf
enum DoryX86InstructionFeaturePolicy {
  /// Most absent instruction features fault with #UD. Intel separately specifies
  /// #GP(0) for CMPXCHG16B when CPUID.01H:ECX.CX16 is clear (SDM 092 Vol. 2A,
  /// page 3-198). Keep that fault distinct and ahead of data/alignment checks.
  /// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
  static func executionFault(
    _ instruction: DoryX86DecodedInstruction, profile: DoryX86CPUProfile
  ) -> DoryX86Exception? {
    guard !permits(instruction, profile: profile) else { return nil }
    if case .compareExchangePair(_, true) = instruction.operation,
      !profile.supports(.cmpxchg16b)
    {
      return .init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: instruction.address)
    }
    return .init(kind: .invalidOpcode, vector: 6, instructionPointer: instruction.address)
  }

  static func permits(_ instruction: DoryX86DecodedInstruction, profile: DoryX86CPUProfile) -> Bool {
    guard DoryX86LegacyFloatingPointPolicy.permitsFeatures(instruction, profile: profile) else {
      return false
    }
    switch instruction.operation {
    case .flaglessShift, .vexMaskMove:
      // SHLX/SHRX/SARX are BMI2, not AVX. No BMI2 feature or AVX-512 mask state is
      // modeled; decoding an encoding must not invent support or alias K registers to XMM.
      return false
    default: break
    }
    if let vex = instruction.prefixes.vex {
      guard profile.supports(.avx) else { return false }
      return permitsVEX(instruction, vex: vex, profile: profile)
    }
    switch instruction.operation {
    case .conditionalMove:
      return profile.supports(.cmov)
    case .populationCount:
      return profile.supports(.popcnt)
    case .compareExchangePair(_, let doubleQuadword):
      return profile.supports(doubleQuadword ? .cmpxchg16b : .cmpxchg8b)
    case .duplicateVectorScalar:
      return profile.supports(.sse3)
    case .shufflePackedBytes, .alignPackedBytes:
      return profile.supports(.ssse3)
    case .testPackedBits, .extendPackedDwordToQword, .extendPackedByteToQword,
      .comparePackedQwords, .insertPackedQword:
      return profile.supports(.sse41)
    case .packedCompareStringIndex:
      return profile.supports(.sse42)
    case .memoryFence(.store):
      return profile.supports(.sse)
    case .memoryFence(.load), .memoryFence(.full):
      return profile.supports(.sse2)
    case .saveFloatingPointState, .restoreFloatingPointState:
      return profile.supports(.fxsave)
    case .cacheLineFlush:
      return profile.supports(.clflush)
    case .loadMXCSR, .storeMXCSR:
      return profile.supports(.sse)
    case .moveVector128:
      // MOVUPS/MOVAPS are SSE; 66 selects MOVUPD/MOVAPD/MOVDQA/MOVNTDQ,
      // and F3 selects MOVDQU. All those latter full-vector moves are SSE2.
      return profile.supports(instruction.prefixes.operandSizeOverride
        || instruction.prefixes.repeatPrefix == 0xF3 ? .sse2 : .sse)
    case .moveVectorScalar(_, _, let byteCount, _):
      // MOVSS versus MOVSD/MOVQ; F3 MOVQ still transfers eight bytes.
      return profile.supports(byteCount == 4 ? .sse : .sse2)
    case .moveVectorQwordHalf, .vectorBitwise:
      return profile.supports(instruction.prefixes.operandSizeOverride ? .sse2 : .sse)
    case .unpackVector(_, let doublePrecision, _, _):
      return instruction.prefixes.repeatPrefix == nil
        && profile.supports(doublePrecision ? .sse2 : .sse)
    case .vectorFloatingBinary(_, let format, _, _), .scalarCompare(_, let format, _, _),
      .scalarSquareRoot(let format, _, _), .vectorFloatingCompare(let format, _, _, _),
      .convertIntegerToScalarFloat(let format, _, _), .convertScalarFloatToInteger(let format, _, _, _):
      return profile.supports(floatingFeature(format))
    case .scalarConvert, .convertPackedDoubleToDword, .convertPackedSingleToDword,
      .convertPackedDwordToDouble, .convertPackedSingleToDouble,
      .convertPackedDoubleToSingle, .convertPackedDwordToSingle,
      .moveIntegerToVector, .moveVectorToInteger, .moveMMXToVector, .moveVectorToMMX,
      .vectorIntegerBinary, .vectorIntegerShift,
      .vectorByteShift, .vectorIntegerInterleave, .vectorIntegerPack:
      return profile.supports(.sse2)
    case .vectorShuffle(let format, _, _, _):
      return profile.supports(format == .packedSingle ? .sse : .sse2)
    case .insertPackedWord(_, _, _, let mmx), .extractPackedWord(_, _, _, let mmx):
      // The MMX forms were introduced by SSE, the XMM forms by SSE2.
      return profile.supports(mmx ? .sse : .sse2)
    case .moveVectorMask(_, _, let laneWidth, let vectorByteCount):
      // MOVMSKPS is SSE; MOVMSKPD and PMOVMSKB XMM are SSE2.
      // PMOVMSKB MMX is an SSE extension using MMX state.
      return profile.supports(vectorByteCount == 8 || laneWidth == .doubleword ? .sse : .sse2)
    case .mmxIntegerBinary(let operation, let laneWidth, _, _):
      switch (operation, laneWidth) {
      case (.minimumUnsigned, .byte), (.maximumUnsigned, .byte),
        (.minimumSigned, .word), (.maximumSigned, .word),
        (.averageUnsigned, .byte), (.averageUnsigned, .word),
        (.multiplyHighUnsigned, .word), (.sumAbsoluteDifferences, .byte):
        return profile.supports(.sse)
      case (.add, .quadword), (.subtract, .quadword), (.multiplyUnsignedDoubleword, .doubleword):
        return profile.supports(.sse2)
      default: return true // Original MMX operations do not acquire an SSE requirement.
      }
    case .move:
      // MOVNTI shares the ordinary integer move operation, but requires SSE2.
      // This changes feature admission only; MOVNTI does not use XMM enable state.
      return !isNonTemporalIntegerStore(instruction) || profile.supports(.sse2)
    default:
      return true
    }
  }

  private static func floatingFeature(_ format: DoryX86VectorFloatingFormat) -> DoryX86Feature {
    switch format {
    case .packedSingle, .scalarSingle: .sse
    case .packedDouble, .scalarDouble: .sse2
    }
  }

  static func isNonTemporalIntegerStore(_ instruction: DoryX86DecodedInstruction) -> Bool {
    guard instruction.prefixes.vex == nil, case .move = instruction.operation else { return false }
    return legacyOpcode(instruction.bytes) == 0xC3
  }

  private static func legacyOpcode(_ bytes: [UInt8]) -> UInt8? {
    // Only consume leading prefixes. An 0F C3 sequence inside a displacement
    // or immediate must never turn an ordinary MOV into a MOVNTI feature check.
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x40...0x4F:
        index += 1
      default:
        guard bytes[index] == 0x0F, index + 1 < bytes.count else { return nil }
        return bytes[index + 1]
      }
    }
    return nil
  }

  private static func permitsVEX(
    _ instruction: DoryX86DecodedInstruction, vex: DoryX86VEXPrefix, profile: DoryX86CPUProfile
  ) -> Bool {
    // The decoder currently accepts VEX only at byte zero. Read only the opcode and ModRM
    // positions established by that prefix, never search immediates/displacements for an opcode.
    let opcodeIndex: Int
    switch instruction.bytes.first {
    case 0xC5: opcodeIndex = 2
    case 0xC4: opcodeIndex = 3
    default: return false
    }
    guard instruction.bytes.indices.contains(opcodeIndex) else { return false }
    let opcode = instruction.bytes[opcodeIndex]
    let modRM = instruction.bytes.indices.contains(opcodeIndex + 1) ? instruction.bytes[opcodeIndex + 1] : nil
    let registerOnly = modRM.map { $0 & 0xC0 == 0xC0 } ?? false
    let integerWidthPermitted = !vex.largeVector || profile.supports(.avx2)

    switch instruction.operation {
    case .vexZeroUpper:
      // VZEROALL (L=1) is currently misdecoded as VZEROUPPER; do not retire that alias.
      return vex.map == 1 && opcode == 0x77 && vex.pp == 0 && !vex.largeVector && vex.vvvv == 0
    case .vexMoveVector:
      guard vex.map == 1 && vex.vvvv == 0 else { return false }
      switch opcode {
      case 0x10, 0x11:
        // Only VMOVUPS is represented faithfully here: scalar forms and VMOVUPD
        // currently alias a full vector move or acquire the wrong alignment requirement.
        return vex.pp == 0
      case 0x28, 0x29: return vex.pp == 0 || vex.pp == 1 // VMOVAPS/VMOVAPD
      case 0x6F, 0x7F: return vex.pp == 1 // VMOVDQA, including YMM, requires AVX only.
      default: return false
      }
    case .vexVectorBinary:
      guard vex.map == 1 else { return false }
      switch opcode {
      case 0x54...0x57:
        return vex.pp == 0 || vex.pp == 1 // VAND*/VOR*/VXOR*: AVX at both widths.
      case 0xDB, 0xDF, 0xEB, 0xEF:
        return vex.pp == 1 && integerWidthPermitted // VPAND*/VPOR/VPXOR: AVX2 for YMM.
      default: return false
      }
    case .vexComparePackedIntegers, .vexComparePackedBytes:
      return vex.map == 1 && [0x64, 0x65, 0x66, 0x74, 0x76].contains(opcode)
        && vex.pp == 1 && integerWidthPermitted
    case .vexAddPackedIntegers:
      return vex.map == 1 && [0xFC, 0xFD, 0xFE].contains(opcode)
        && vex.pp == 1 && integerWidthPermitted
    case .vexPackedMinMax:
      return vex.map == 1 && [0xDA, 0xEA].contains(opcode) && vex.pp == 1 && integerWidthPermitted
    case .vexSubPackedIntegers:
      // The D8/D9 saturating forms have the represented byte/word widths. FA/FB
      // currently misdecode the dword/qword forms as byte/word, so remain rejected.
      return vex.map == 1 && [0xD8, 0xD9].contains(opcode) && vex.pp == 1 && integerWidthPermitted
    case .vexVectorFloatingBinary:
      return vex.map == 1 && [0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F].contains(opcode)
        && (vex.pp <= 1 || !vex.largeVector)
    case .vexCompareScalar:
      return vex.map == 1 && [0x2E, 0x2F].contains(opcode) && vex.pp <= 1
        && !vex.largeVector && vex.vvvv == 0
    case .vexScalarConvert:
      return vex.map == 1 && opcode == 0x5A && (vex.pp == 2 || vex.pp == 3) && !vex.largeVector
    case .vexUnpackLow, .vexUnpackHigh:
      return vex.map == 1 && [0x14, 0x15].contains(opcode) && vex.pp <= 1
    case .vexStoreMXCSR:
      return vex.map == 1 && opcode == 0xAE && vex.pp == 0 && !vex.largeVector
        && vex.vvvv == 0 && modRM != nil && !registerOnly
    case .vexMoveIntegerToVector, .vexMoveVectorToInteger:
      return vex.map == 1 && [0x6E, 0x7E].contains(opcode) && vex.pp == 1
        && !vex.largeVector && vex.vvvv == 0
    case .vexMoveMaskToInteger:
      return vex.map == 1 && opcode == 0xD7 && vex.pp == 1 && vex.vvvv == 0
        && registerOnly && integerWidthPermitted
    case .vexShufflePackedBytes:
      return vex.map == 2 && opcode == 0x00 && vex.pp == 1 && integerWidthPermitted
    case .vexBroadcast(_, let source, _, _):
      guard vex.map == 2 && vex.pp == 1 && !vex.w && vex.vvvv == 0 else { return false }
      let memorySource: Bool
      switch source { case .memory: memorySource = true; case .register: memorySource = false }
      switch opcode {
      case 0x18: return memorySource || profile.supports(.avx2) // VBROADCASTSS
      case 0x19: return vex.largeVector && (memorySource || profile.supports(.avx2)) // VBROADCASTSD
      case 0x1A: return vex.largeVector && memorySource // VBROADCASTF128: AVX
      case 0x5A: return vex.largeVector && memorySource && profile.supports(.avx2) // VBROADCASTI128
      default: return false // VPBROADCASTB currently aliases a dword broadcast.
      }
    case .vexLoadMXCSR, .vexConvertScalarToInteger, .vexVariableShift, .vexVectorShiftImmediate:
      // Reserved MXCSR values, reversed scalar-conversion/shift operands, and the wrong
      // opcode map for per-lane variable shifts have not been corrected or qualified.
      return false
    default:
      return false // Every additional VEX operation needs an explicit admission decision.
    }
  }
}
