import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 1 §§4.9.2, 8.1.7, 8.2.2, 8.5.1–8.5.6 and
// Vol. 2A FBLD/FBSTP/FILD/FIST/FISTTP/FLD/FST.
// This suite covers the finite set of already-decoded x87 numeric transfers.
// Arithmetic exception generation and x87 transcendental accuracy are separate.
@Suite struct DoryX86X87NumericTransferTests {
  private var one: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3FFF)
  }
  private var denormal: [UInt8] { binary80(significand: 1, exponent: 0) }
  private var pseudoDenormal: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0)
  }
  private var unsupported: [UInt8] {
    binary80(significand: 0x4000_0000_0000_0000, exponent: 0x3FFF)
  }
  private var infinity: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFF)
  }
  private var quietNaN: [UInt8] {
    binary80(significand: 0xC000_0000_0000_0001, exponent: 0x7FFF)
  }
  private var signalingNaN: [UInt8] {
    binary80(significand: 0xA000_0000_0000_0001, exponent: 0x7FFF)
  }

  @Test func extendedMemoryTransfersPreserveEveryPayloadAndClassifyItsActualTag() throws {
    let cases: [([UInt8], UInt16)] = [
      (binary80(significand: 0, exponent: 0), 1), (one, 0), (denormal, 2),
      (pseudoDenormal, 2), (unsupported, 2), (infinity, 2), (quietNaN, 2),
      (signalingNaN, 2),
    ]
    for (payload, expectedTag) in cases {
      let memory = NumericTransferMemory(code: [0xDB, 0x28, 0xDB, 0x38], image: payload)
      var state = try makeState(empty: true)
      try retire(&state, memory: memory)
      #expect(state.floatingPoint.x87[7].bytes == payload)
      #expect(tag(7, state.floatingPoint) == expectedTag)
      try retire(&state, memory: memory)
      #expect(memory.image == payload)
      #expect(memory.reads == 1 && memory.writes == 1 && memory.preflights == [10])
      #expect(top(state.floatingPoint) == 0 && tag(7, state.floatingPoint) == 3)
      #expect(state.floatingPoint.x87StatusWord & 0x3F == 0)
    }
  }

  @Test func registerLoadPreservesUnsupportedPayloadAndReclassifiesDestination() throws {
    var state = try makeState(empty: true)
    state.floatingPoint.x87[0] = try register(unsupported)
    state.floatingPoint.x87TagWord &= ~UInt16(3)
    let memory = NumericTransferMemory(code: [0xD9, 0xC0])
    try retire(&state, memory: memory)
    #expect(state.floatingPoint.x87[7].bytes == unsupported)
    #expect(tag(7, state.floatingPoint) == 2)
    #expect(state.floatingPoint.x87[0].bytes == unsupported)
    #expect(memory.reads == 0 && memory.writes == 0)
  }

  @Test func everyUnsupportedEncodingGetsSpecialTagAndInvalidNarrowingResponse() {
    // J=0 is unsupported for every nonzero exponent. This includes the
    // exponent-all-ones form that must not be classified as a NaN.
    let encodings = [
      binary80(significand: 0, exponent: 0x3FFF),
      binary80(significand: 0x4000_0000_0000_1234, exponent: 0x3FFF),
      binary80(significand: 0, exponent: 0x7FFF, negative: true),
      binary80(significand: 0x4000_0000_0000_5678, exponent: 0x7FFF, negative: true),
    ]
    for encoding in encodings {
      #expect(DoryX86X87Transfer.binary80Class(encoding) == .unsupported)
      let loaded = DoryX86X87Transfer.load(bytes: encoding, format: .extended80)
      #expect(loaded.bytes == encoding && loaded.tag == 2 && loaded.flags == 0)
      let registerLoaded = DoryX86X87Transfer.registerLoad(bytes: encoding)
      #expect(registerLoaded.bytes == encoding && registerLoaded.tag == 2)

      let extendedStore = DoryX86X87Transfer.store(
        bytes: encoding, format: .extended80, truncate: false, controlWord: 0x037E)
      #expect(extendedStore.bytes == encoding && extendedStore.flags == 0)
      #expect(!extendedStore.suppressWriteAndPop)

      let masked = DoryX86X87Transfer.store(
        bytes: encoding, format: .float32, truncate: false, controlWord: 0x037F)
      #expect(masked.bytes == [0, 0, 0xC0, 0xFF] && masked.flags == 1)
      #expect(!masked.suppressWriteAndPop)
      let unmasked = DoryX86X87Transfer.store(
        bytes: encoding, format: .float32, truncate: false, controlWord: 0x037E)
      #expect(unmasked.bytes.isEmpty && unmasked.flags == 1)
      #expect(unmasked.suppressWriteAndPop)
    }
  }

  @Test func signalingFloatLoadsQuietOnlyWhenInvalidIsMasked() throws {
    let forms: [([UInt8], [UInt8], [UInt8])] = [
      ([0xD9, 0x00], littleEndian(0x7F80_0001, count: 4),
        binary80(significand: 0xC000_0100_0000_0000, exponent: 0x7FFF)),
      ([0xDD, 0x00], littleEndian(0x7FF0_0000_0000_0001, count: 8),
        binary80(significand: 0xC000_0000_0000_0800, exponent: 0x7FFF)),
    ]
    for (opcode, source, expected) in forms {
      for masked in [false, true] {
        let memory = NumericTransferMemory(code: opcode + [0x9B], image: source)
        var state = try makeState(empty: true, controlWord: masked ? 0x037F : 0x037E)
        let before = state.floatingPoint
        try retire(&state, memory: memory)
        #expect(state.floatingPoint.x87StatusWord & 0x8081 == (masked ? 1 : 0x8081))
        if masked {
          #expect(top(state.floatingPoint) == 7)
          #expect(state.floatingPoint.x87[7].bytes == expected)
          #expect(tag(7, state.floatingPoint) == 2)
        } else {
          #expect(top(state.floatingPoint) == 0)
          #expect(state.floatingPoint.x87 == before.x87)
          #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
          let atWait = state
          #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: .x87FloatingPoint, vector: 16,
              instructionPointer: UInt64(0x1000 + opcode.count))))
          #expect(state == atWait)
        }
      }
    }
  }

  @Test func denormalFloatLoadsPushTheExactWidenedValueEvenWhenUnmasked() throws {
    let forms: [([UInt8], [UInt8], [UInt8])] = [
      ([0xD9, 0x00], littleEndian(1, count: 4),
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3F6A)),
      ([0xDD, 0x00], littleEndian(1, count: 8),
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3BCD)),
    ]
    for (opcode, source, expected) in forms {
      for masked in [false, true] {
        let memory = NumericTransferMemory(code: opcode + [0x9B], image: source)
        var state = try makeState(empty: true, controlWord: masked ? 0x037F : 0x037D)
        try retire(&state, memory: memory)
        #expect(top(state.floatingPoint) == 7)
        #expect(state.floatingPoint.x87[7].bytes == expected)
        #expect(tag(7, state.floatingPoint) == 0)
        #expect(state.floatingPoint.x87StatusWord & 0x8082 == (masked ? 2 : 0x8082))
        if !masked {
          #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: .x87FloatingPoint, vector: 16,
              instructionPointer: UInt64(0x1000 + opcode.count))))
        }
      }
    }
  }

  @Test func fullStackOverflowTakesPriorityOverDenormalSourceStatus() throws {
    for masked in [false, true] {
      let memory = NumericTransferMemory(code: [0xD9, 0x00], image: littleEndian(1, count: 4))
      var state = try makeState(empty: false, controlWord: masked ? 0x037F : 0x037E)
      state.floatingPoint.x87TagWord = 0 // Every physical register is nonempty.
      let before = state.floatingPoint
      try retire(&state, memory: memory)
      #expect(state.floatingPoint.x87StatusWord & 0x82C3
        == (masked ? UInt16(0x0241) : UInt16(0x82C1)))
      #expect(state.floatingPoint.x87StatusWord & 2 == 0)
      if masked {
        #expect(state.floatingPoint.x87[7].bytes == DoryX86X87Stack.indefinite.bytes())
      } else {
        #expect(state.floatingPoint.x87 == before.x87)
        #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
      }
    }
  }

  @Test func integerStoresCoverWidthsRoundingPrecisionAndTruncation() throws {
    let exactCases: [(DoryX87MemoryFormat, Int64, [UInt8])] = [
      (.signedInteger16, Int64(Int16.min), littleEndian(0x8000, count: 2)),
      (.signedInteger16, Int64(Int16.max), littleEndian(0x7FFF, count: 2)),
      (.signedInteger32, Int64(Int32.min), littleEndian(0x8000_0000, count: 4)),
      (.signedInteger32, Int64(Int32.max), littleEndian(0x7FFF_FFFF, count: 4)),
      (.signedInteger64, .min, littleEndian(0x8000_0000_0000_0000, count: 8)),
      (.signedInteger64, .max, littleEndian(0x7FFF_FFFF_FFFF_FFFF, count: 8)),
    ]
    for (format, value, expected) in exactCases {
      let result = DoryX86X87Transfer.store(bytes: DoryX86ExtendedFloat(value).bytes(),
        format: format, truncate: false, controlWord: 0x037F)
      #expect(result.bytes == expected && result.flags == 0 && !result.suppressWriteAndPop)
    }

    var state = try makeState(value: DoryX86ExtendedFloat(1.5).bytes(), controlWord: 0x037F)
    let rounded = NumericTransferMemory(code: [0xDF, 0x18])
    try retire(&state, memory: rounded)
    #expect(Array(rounded.image.prefix(2)) == [2, 0])
    #expect(state.floatingPoint.x87StatusWord & 0x0220 == 0x0220)
    #expect(top(state.floatingPoint) == 1)

    state = try makeState(value: DoryX86ExtendedFloat(1.9).bytes(), controlWord: 0x037F)
    let truncated = NumericTransferMemory(code: [0xDF, 0x08])
    try retire(&state, memory: truncated)
    #expect(Array(truncated.image.prefix(2)) == [1, 0])
    #expect(state.floatingPoint.x87StatusWord & 0x0220 == 0x0020)
    #expect(top(state.floatingPoint) == 1)
  }

  @Test func invalidIntegerStoresUseIndefiniteOnlyWhenMaskedAndPreserveDestinationOtherwise() throws {
    let invalidSources = [quietNaN, signalingNaN, infinity, unsupported,
      DoryX86ExtendedFloat(Int64(32_768)).bytes()]
    for source in invalidSources {
      let masked = DoryX86X87Transfer.store(bytes: source, format: .signedInteger16,
        truncate: false, controlWord: 0x037F)
      #expect(masked.bytes == [0, 0x80] && masked.flags == 1 && !masked.suppressWriteAndPop)
      let unmasked = DoryX86X87Transfer.store(bytes: source, format: .signedInteger16,
        truncate: false, controlWord: 0x037E)
      #expect(unmasked.bytes.isEmpty && unmasked.flags == 1 && unmasked.suppressWriteAndPop)
    }

    let memory = NumericTransferMemory(code: [0xDF, 0x18])
    var state = try makeState(value: quietNaN, controlWord: 0x037E)
    let before = state.floatingPoint
    try retire(&state, memory: memory)
    #expect(memory.image == Array(repeating: 0xA5, count: 32))
    #expect(memory.preflights.isEmpty && memory.writes == 0)
    #expect(top(state.floatingPoint) == top(before))
    #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(state.floatingPoint.x87StatusWord & 0x8081 == 0x8081)
  }

  @Test func denormalIntegerStoresHonorDenormalMaskBeforePrecisionConversion() {
    for source in [denormal, pseudoDenormal] {
      let masked = DoryX86X87Transfer.store(bytes: source, format: .signedInteger32,
        truncate: false, controlWord: 0x037F)
      #expect(masked.bytes == [0, 0, 0, 0])
      #expect(masked.flags == 0x22 && !masked.suppressWriteAndPop)
      let unmasked = DoryX86X87Transfer.store(bytes: source, format: .signedInteger32,
        truncate: false, controlWord: 0x037D)
      #expect(unmasked.bytes.isEmpty && unmasked.flags == 2 && unmasked.suppressWriteAndPop)
    }
  }

  @Test func packedBCDUsesAllEighteenDigitsAndKeepsUndefinedInputDeterministic() throws {
    let maximum = DoryX86ExtendedFloat(Int64(999_999_999_999_999_999)).bytes()
    let stored = DoryX86X87Transfer.packedBCDStore(bytes: maximum, controlWord: 0x037F)
    #expect(stored.bytes == Array(repeating: 0x99, count: 9) + [0])
    #expect(stored.flags == 0 && !stored.suppressWriteAndPop)

    let negativeZero = binary80(significand: 0, exponent: 0, negative: true)
    #expect(DoryX86X87Transfer.packedBCDStore(bytes: negativeZero, controlWord: 0x037F).bytes
      == Array(repeating: 0, count: 9) + [0x80])
    let loadedNegativeZero = DoryX86X87Transfer.packedBCDLoad(
      Array(repeating: 0, count: 9) + [0x80])
    #expect(loadedNegativeZero.bytes == negativeZero && loadedNegativeZero.tag == 1)

    var undefined = [UInt8](repeating: 0, count: 10); undefined[0] = 0x0A
    let loadedUndefined = DoryX86X87Transfer.packedBCDLoad(undefined)
    #expect(loadedUndefined.bytes == DoryX86ExtendedFloat(Int64(10)).bytes())
    #expect(loadedUndefined.flags == 0 && loadedUndefined.tag == 0)

    let loadMemory = NumericTransferMemory(code: [0xDF, 0x20], image: undefined)
    var state = try makeState(empty: true)
    try retire(&state, memory: loadMemory)
    #expect(state.floatingPoint.x87[7].bytes == DoryX86ExtendedFloat(Int64(10)).bytes())
    #expect(state.floatingPoint.x87StatusWord & 0x3F == 0)

    let storeMemory = NumericTransferMemory(code: [0xDF, 0x30])
    state = try makeState(value: maximum)
    try retire(&state, memory: storeMemory)
    #expect(Array(storeMemory.image.prefix(10)) == Array(repeating: 0x99, count: 9) + [0])
    #expect(top(state.floatingPoint) == 1)

    for masked in [false, true] {
      let invalid = DoryX86X87Transfer.packedBCDStore(bytes: quietNaN,
        controlWord: masked ? 0x037F : 0x037E)
      #expect(invalid.flags == 1)
      #expect(invalid.suppressWriteAndPop == !masked)
      #expect(invalid.bytes == (masked ? DoryX86X87Stack.packedBCDIndefinite : []))
    }
  }

  @Test func floatingStoresHonorInvalidOverflowUnderflowAndPrecisionMasks() throws {
    for format in [DoryX87MemoryFormat.float32, .float64] {
      for source in [signalingNaN, unsupported] {
        let masked = DoryX86X87Transfer.store(bytes: source, format: format,
          truncate: false, controlWord: 0x037F)
        #expect(masked.flags == 1 && !masked.suppressWriteAndPop)
        let unmasked = DoryX86X87Transfer.store(bytes: source, format: format,
          truncate: false, controlWord: 0x037E)
        #expect(unmasked.flags == 1 && unmasked.suppressWriteAndPop)
      }
      let quiet = DoryX86X87Transfer.store(bytes: quietNaN, format: format,
        truncate: false, controlWord: 0x037E)
      #expect(quiet.flags == 0 && !quiet.suppressWriteAndPop)
    }

    let overflow = binary80(significand: 0x8000_0000_0000_0000, exponent: 0x407F)
    let maskedOverflow = DoryX86X87Transfer.store(bytes: overflow, format: .float32,
      truncate: false, controlWord: 0x037F)
    #expect(maskedOverflow.bytes == [0, 0, 0x80, 0x7F])
    #expect(maskedOverflow.flags == 0x28 && !maskedOverflow.suppressWriteAndPop)
    let unmaskedOverflow = DoryX86X87Transfer.store(bytes: overflow, format: .float32,
      truncate: false, controlWord: 0x0377)
    #expect(unmaskedOverflow.flags == 8 && unmaskedOverflow.suppressWriteAndPop)

    let underflow = binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3F69)
    let maskedUnderflow = DoryX86X87Transfer.store(bytes: underflow, format: .float32,
      truncate: false, controlWord: 0x037F)
    #expect(maskedUnderflow.bytes == [0, 0, 0, 0])
    #expect(maskedUnderflow.flags == 0x30 && !maskedUnderflow.suppressWriteAndPop)
    let unmaskedUnderflow = DoryX86X87Transfer.store(bytes: underflow, format: .float32,
      truncate: false, controlWord: 0x036F)
    #expect(unmaskedUnderflow.flags == 0x10 && unmaskedUnderflow.suppressWriteAndPop)

    let halfway32 = binary80(significand: 0x8000_0080_0000_0000, exponent: 0x3FFF)
    let precision32 = DoryX86X87Transfer.store(bytes: halfway32, format: .float32,
      truncate: false, controlWord: 0x035F)
    #expect(precision32.bytes == [0, 0, 0x80, 0x3F])
    #expect(precision32.flags == 0x20 && !precision32.suppressWriteAndPop)
    let halfway64 = binary80(significand: 0x8000_0000_0000_0400, exponent: 0x3FFF)
    let precision64 = DoryX86X87Transfer.store(bytes: halfway64, format: .float64,
      truncate: false, controlWord: 0x035F)
    #expect(precision64.bytes == littleEndian(0x3FF0_0000_0000_0000, count: 8))
    #expect(precision64.flags == 0x20 && !precision64.suppressWriteAndPop)

    let memory = NumericTransferMemory(code: [0xD9, 0x18, 0x9B])
    var state = try makeState(value: halfway32, controlWord: 0x035F)
    try retire(&state, memory: memory)
    #expect(Array(memory.image.prefix(4)) == [0, 0, 0x80, 0x3F])
    #expect(state.floatingPoint.x87StatusWord & 0x80A0 == 0x80A0)
    #expect(top(state.floatingPoint) == 1)
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .x87FloatingPoint, vector: 16, instructionPointer: 0x1002)))
  }

  @Test func operandPageFaultsPublishNoNumericStatusTagPopOrMemoryEffects() throws {
    let storeMemory = NumericTransferMemory(code: [0xD9, 0x18])
    storeMemory.failWrites = true
    var state = try makeState(value: binary80(
      significand: 0x8000_0080_0000_0000, exponent: 0x3FFF), controlWord: 0x037F)
    let beforeStore = state
    expectPageFault(&state, memory: storeMemory, errorCode: 6)
    var expectedStore = beforeStore; expectedStore.control.cr2 = 0x8001
    #expect(state == expectedStore)
    #expect(storeMemory.preflights == [4] && storeMemory.writes == 0)
    #expect(storeMemory.image == Array(repeating: 0xA5, count: 32))

    let loadMemory = NumericTransferMemory(code: [0xD9, 0x00], image: littleEndian(1, count: 4))
    loadMemory.failReads = true
    state = try makeState(empty: true)
    let beforeLoad = state
    expectPageFault(&state, memory: loadMemory, errorCode: 4)
    var expectedLoad = beforeLoad; expectedLoad.control.cr2 = 0x8001
    #expect(state == expectedLoad)
    #expect(loadMemory.reads == 1 && loadMemory.writes == 0)
  }

  private var interpreter: DoryX86Interpreter {
    .init(profile: .init(identifier: "test-only.x87-numeric-transfer",
      features: DoryX86CPUProfile.compatibleV1.features.union([.sse3]),
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000))
  }

  private func makeState(
    value: [UInt8]? = nil, empty: Bool = false, controlWord: UInt16 = 0x037F
  ) throws -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState(x87ControlWord: controlWord,
      x87StatusWord: 0, x87TagWord: empty ? 0xFFFF : 0xFFFC)
    if let value { fp.x87[0] = try register(value) }
    return try .init(registers: .init(rax: 0x8000), rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: fp)
  }

  private func register(_ bytes: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: bytes, expectedByteCount: 10)
  }

  private func top(_ state: DoryX86FloatingPointState) -> Int {
    Int(state.x87StatusWord >> 11) & 7
  }

  private func tag(_ physical: Int, _ state: DoryX86FloatingPointState) -> UInt16 {
    state.x87TagWord >> UInt16(physical * 2) & 3
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState, memory: NumericTransferMemory
  ) throws {
    let decoded = try DoryX86Decoder().decode(
      memory.instructionBytes(at: state.rip, maximumCount: 15), at: state.rip, mode: .long64)
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
  }

  private func expectPageFault(
    _ state: inout DoryX86ArchitecturalState, memory: NumericTransferMemory, errorCode: UInt32
  ) {
    guard case .exception(let fault) = interpreter.step(state: &state, memory: memory, mode: .long64)
    else { Issue.record("Expected operand page fault"); return }
    #expect(fault == .init(kind: .pageFault, vector: 14, errorCode: errorCode,
      instructionPointer: 0x1000, linearAddress: 0x8001))
  }

  private func binary80(
    significand: UInt64, exponent: UInt16, negative: Bool = false
  ) -> [UInt8] {
    littleEndian(significand, count: 8)
      + littleEndian(UInt64(exponent | (negative ? 0x8000 : 0)), count: 2)
  }

  private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}

private final class NumericTransferMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  var image: [UInt8]
  var reads = 0
  var writes = 0
  var preflights: [Int] = []
  var failReads = false
  var failWrites = false

  init(code: [UInt8], image: [UInt8] = Array(repeating: 0xA5, count: 32)) {
    self.code = code
    self.image = image
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < code.count else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads += 1
    if failReads { throw DoryX86MemoryError.pageFault(address: 0x8001, errorCode: 4) }
    return Array(image.prefix(byteCount))
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    preflights.append(byteCount)
    if failWrites { throw DoryX86MemoryError.pageFault(address: 0x8001, errorCode: 6) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes += 1
    if image.count < bytes.count { image += Array(repeating: 0xA5, count: bytes.count - image.count) }
    image.replaceSubrange(0..<bytes.count, with: bytes)
  }
}
