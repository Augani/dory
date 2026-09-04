import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2A §2.5 exception Types 1–7 (legacy versus VEX conditions),
// Vol. 3A Tables 16-1/16-2 (legacy #UD priority over TS), and Vol. 1 §13.3 (XCR0).
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86SIMDControlStateTests {
  private let profile = DoryX86CPUProfile(identifier: "test-only.simd-enable-state",
    features: DoryX86CPUProfile.compatibleV1.features.union([
      .sse3, .ssse3, .sse41, .sse42, .xsave, .avx, .avx2,
    ]), physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000)

  private let legacy: [[UInt8]] = [
    [0x0F, 0x10, 0x03], [0x0F, 0x29, 0x03], // MOVUPS load / MOVAPS store
    [0xF3, 0x0F, 0x10, 0x03], [0x0F, 0x12, 0x03], // MOVSS / MOVLPS
    [0xF2, 0x0F, 0x12, 0x03], // MOVDDUP
    [0x66, 0x0F, 0x38, 0x00, 0x03], // PSHUFB
    [0x66, 0x0F, 0x38, 0x17, 0x03], // PTEST
    [0x66, 0x0F, 0x3A, 0x63, 0x03, 0], // PCMPISTRI
    [0x66, 0x0F, 0xC4, 0x03, 0], [0x66, 0x0F, 0xC5, 0xC0, 0], // PINSRW / PEXTRW XMM
    [0x66, 0x0F, 0xD7, 0xC0], // PMOVMSKB XMM
    [0x66, 0x0F, 0x6E, 0x03], [0x66, 0x0F, 0x7E, 0x03], // MOVD both directions
    [0x66, 0x0F, 0xE6, 0x03], [0xF2, 0x0F, 0xE6, 0x03], [0xF3, 0x0F, 0xE6, 0x03],
    [0xF2, 0x0F, 0x51, 0x03], [0xF3, 0x0F, 0x2A, 0x03], // SQRTSD / CVTSI2SS
    [0x0F, 0xAE, 0x13], [0x0F, 0xAE, 0x1B], // LDMXCSR / STMXCSR
  ]
  private let vex: [[UInt8]] = [
    [0xC5, 0xF8, 0x10, 0x03], [0xC5, 0xFC, 0x11, 0x03], // VMOVUPS XMM load / YMM store
    [0xC5, 0xFD, 0xEF, 0x03], // VPXOR YMM
    [0xC5, 0xF8, 0xAE, 0x1B], // VSTMXCSR
    [0xC5, 0xF8, 0x77], // VZEROUPPER
  ]

  @Test func legacyEMAndOSFXSRFaultBeforeTSOrAnyDataOperand() throws {
    for bytes in legacy {
      for em in [false, true] {
        for osfxsr in [false, true] where em || !osfxsr {
          for ts in [false, true] {
            for mp in [false, true] {
              var state = try state(cr0: 0x11 | (em ? 4 : 0) | (ts ? 8 : 0) | (mp ? 2 : 0),
                cr4: osfxsr ? 1 << 9 : 0)
              try expectEarlyFault(bytes, state: &state, expected: .invalidOpcode)
            }
          }
        }
      }
    }
  }

  @Test func legacyTaskSwitchedRaisesDeviceNotAvailableWithNoEffects() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for bytes in legacy {
        var state = try state(mode: mode, cr0: 0x19, cr4: 1 << 9)
        try expectEarlyFault(bytes, state: &state, mode: mode, expected: .deviceNotAvailable)
      }
    }
  }

  @Test func legacySSEDoesNotRequireOSXSAVEOrXCR0SSEBit() throws {
    let bytes: [UInt8] = [0x0F, 0x57, 0xC0] // XORPS XMM0,XMM0
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      var state = try state(mode: mode, cr4: 1 << 9, xcr0: 1)
      let before = state
      let memory = SIMDControlMemory(code: bytes)
      try expectRetired(bytes, state: &state, memory: memory, mode: mode)
      #expect(state.floatingPoint.ymm[0].bytes == Array(repeating: 0, count: 16)
        + before.floatingPoint.ymm[0].bytes.suffix(16))
      #expect(state.control == before.control && memory.dataAccesses == 0)
    }
  }

  @Test func AVXRequiresOSXSAVEAndBothXCR0ComponentsBeforeTSOrDataAccess() throws {
    for bytes in vex {
      for osxsave in [false, true] {
        for xcr0: UInt64 in [1, 3, 5, 7] where !osxsave || xcr0 != 7 {
          for ts in [false, true] {
            var state = try state(cr0: 0x13 | (ts ? 8 : 0),
              cr4: (1 << 9) | (osxsave ? 1 << 18 : 0), xcr0: xcr0)
            try expectEarlyFault(bytes, state: &state, expected: .invalidOpcode)
          }
        }
      }
      var state = try state(cr0: 0x1B)
      try expectEarlyFault(bytes, state: &state, expected: .deviceNotAvailable)
    }
  }

  @Test func enabledAVXIgnoresLegacyEMAndOSFXSRButStillChecksTS() throws {
    for bytes: [UInt8] in [[0xC5, 0xFC, 0x57, 0xC0], [0xC5, 0xF8, 0x77]] {
      for em in [false, true] {
        for osfxsr in [false, true] {
          var state = try state(cr0: 0x13 | (em ? 4 : 0),
            cr4: (1 << 18) | (osfxsr ? 1 << 9 : 0))
          let memory = SIMDControlMemory(code: bytes)
          try expectRetired(bytes, state: &state, memory: memory)
          #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0, count: 16))
          state.rip = 0x1000
          state.control.cr0 |= 8
          try expectEarlyFault(bytes, state: &state, expected: .deviceNotAvailable)
        }
      }
    }
  }

  @Test func AVXRejectsRealAndVirtual8086ModesEvenWhenItsStateIsEnabled() throws {
    // The decoder currently admits VEX only in long64; this preserves its earlier
    // #UD boundary and does not qualify AVX decoding in protected/compatibility mode.
    for bytes in vex {
      var real = try state(mode: .real16, cr0: 0x10)
      try expectEarlyFault(bytes, state: &real, mode: .real16, expected: .invalidOpcode,
        expectDecoded: false)
      var virtual = try state(mode: .protected16)
      virtual.rflags.insert(.virtual8086)
      try expectEarlyFault(bytes, state: &virtual, mode: .protected16, expected: .invalidOpcode,
        expectDecoded: false)
    }
  }

  @Test func absentOptionalFeaturesAndFetchFaultsKeepTheirOwnPriority() throws {
    for bytes in [legacy[4]] + vex {
      var state = try state(cr0: 0x1B)
      try expectEarlyFault(bytes, state: &state, expected: .invalidOpcode, profile: .compatibleV1)
      let before = state
      let memory = SIMDControlMemory(code: bytes,
        fetchFailure: .pageFault(address: 0x1000, errorCode: 0x14))
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0x14,
          instructionPointer: 0x1000, linearAddress: 0x1000)))
      var expected = before
      expected.control.cr2 = 0x1000
      #expect(state == expected && memory.dataAccesses == 0)
    }
  }

  @Test func enabledInstructionsReachDataFaultsAndNonSIMDOperationsIgnoreTheseControls() throws {
    for bytes in [legacy[0], legacy[1], vex[0], vex[1]] {
      var state = try state()
      let before = state
      let memory = SIMDControlMemory(code: bytes)
      let errorCode: UInt32 = bytes == legacy[0] || bytes == vex[0] ? 5 : 7
      #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .pageFault, vector: 14, errorCode: errorCode,
          instructionPointer: 0x1000, linearAddress: 0x4000)))
      var expected = before
      expected.control.cr2 = 0x4000
      #expect(state == expected && memory.dataAccesses == 1)
    }
    for bytes: [UInt8] in [
      [0x0F, 0xAE, 0xE8], [0x0F, 0xAE, 0xF0], [0x0F, 0xAE, 0xF8], [0xF3, 0x90],
    ] {
      var state = try state(cr0: 0x1F, cr4: 0, xcr0: 1)
      let memory = SIMDControlMemory(code: bytes)
      try expectRetired(bytes, state: &state, memory: memory)
      #expect(memory.dataAccesses == 0)
      #expect(memory.synchronizations == (bytes == [0xF3, 0x90] ? 0 : 1))
    }
    // MOVNTI writes integer state and is an explicit exception to the SSE control table.
    let bytes: [UInt8] = [0x0F, 0xC3, 0x03]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000,
      bytes: bytes + Array(repeating: 0, count: 0x3010))
    var state = try state(cr0: 0x1F, cr4: 0, xcr0: 1)
    try expectRetired(bytes, state: &state, memory: memory)
    #expect(try memory.read(at: 0x4000, byteCount: 4) == [0x55, 0xAA, 0, 0])
  }

  @Test func bothNativeTiersDeclineSIMDAndLeaveItsStateFaultToTheInterpreter() throws {
    #if os(macOS) && arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for bytes in [legacy[0], vex[0], vex[4]] {
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          let memory = SIMDControlMemory(code: bytes)
          var state = try state(cr0: 0x1B)
          let before = state
          #expect(try executor.executeSummary(byteProvider: { Array(bytes.prefix($0)) },
            at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
          #expect(state == before && memory.dataAccesses == 0)
          try expectEarlyFault(bytes, state: &state, expected: .deviceNotAvailable)
        }
      }
    #endif
  }

  private func state(mode: DoryX86ExecutionMode = .long64, cr0: UInt64 = 0x13,
    cr4: UInt64 = (1 << 9) | (1 << 18), xcr0: UInt64 = 7) throws -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState()
    fp.ymm[0] = try .init(bytes: Array(repeating: 0xA5, count: 32), expectedByteCount: 32)
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0xAA55, rbx: 0x4000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? cr0 & ~1 : cr0,
        cr2: 0xABC0, cr4: cr4, xcr0: xcr0), floatingPoint: fp)
  }

  private func expectEarlyFault(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode = .long64, expected kind: DoryX86Exception.Kind,
    profile selectedProfile: DoryX86CPUProfile? = nil, expectDecoded: Bool = true) throws {
    if expectDecoded {
      _ = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
    } else {
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
      }
    }
    let before = state
    let memory = SIMDControlMemory(code: bytes)
    #expect(DoryX86Interpreter(profile: selectedProfile ?? profile).step(state: &state,
      memory: memory, mode: mode) == .exception(.init(kind: kind,
        vector: kind == .invalidOpcode ? 6 : 7, instructionPointer: 0x1000)))
    #expect(state == before)
    #expect(memory.dataAccesses == 0 && memory.synchronizations == 0)
  }

  private func expectRetired(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory, mode: DoryX86ExecutionMode = .long64) throws {
    let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
    #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: mode)
      == .retired(instruction))
    #expect(state.rip == 0x1000 + UInt64(bytes.count))
  }
}

/// A serial observer owned by one test case; data callbacks must not run on an enable-state fault.
private final class SIMDControlMemory: DoryX86Memory, @unchecked Sendable {
  private let code: [UInt8]
  private let fetchFailure: DoryX86MemoryError?
  private(set) var dataAccesses = 0
  private(set) var synchronizations = 0
  init(code: [UInt8], fetchFailure: DoryX86MemoryError? = nil) {
    self.code = code
    self.fetchFailure = fetchFailure
  }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    if let fetchFailure { throw fetchFailure }
    return Array(code.prefix(maximumCount))
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 5)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 7)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 7)
  }
  func synchronize() { synchronizations += 1 }
}
