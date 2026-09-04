import Testing

@testable import DoryDBTX86

@Suite struct DoryX86TranslatedMemoryOverflowTests {
  @Test func wrappedDataSpansFailBeforeTranslationOrMutation() throws {
    let fixture = try fixture(highByte: 0xA5, zeroByte: 0x5A)
    let expected = DoryX86MemoryError.addressOverflow(address: .max, byteCount: 2)

    #expect(throws: expected) { try fixture.translated.read(at: .max, byteCount: 2) }
    #expect(throws: expected) { try fixture.translated.validateRead(at: .max, byteCount: 2) }
    #expect(throws: expected) {
      try fixture.translated.write(at: .max, bytes: [0x11, 0x22])
    }
    #expect(throws: expected) { try fixture.translated.validateWrite(at: .max, byteCount: 2) }
    #expect(throws: expected) { try fixture.translated.readScalar(at: .max, byteCount: 2) }
    #expect(throws: expected) {
      try fixture.translated.writeScalar(at: .max, value: 0x2211, byteCount: 2)
    }
    #expect(throws: expected) { try fixture.translated.codeGeneration(at: .max, byteCount: 2) }

    #expect(fixture.paging.cachedTranslationCount == 0)
    #expect(try fixture.memory.read(at: 0x8fff, byteCount: 1) == [0xA5])
    #expect(try fixture.memory.read(at: 0x9000, byteCount: 1) == [0x5A])
    for (address, value) in fixture.pageTableEntries {
      #expect(try read64(fixture.memory, address) == value)
    }
  }

  @Test func translatedSizesRejectNegativesLikePhysicalMemory() throws {
    let fixture = try fixture(highByte: 0x90, zeroByte: 0x90)
    let expected = DoryX86MemoryError.addressOverflow(address: 0, byteCount: -1)

    #expect(throws: expected) { try fixture.translated.instructionBytes(at: 0, maximumCount: -1) }
    #expect(throws: expected) { try fixture.translated.read(at: 0, byteCount: -1) }
    #expect(throws: expected) { try fixture.translated.validateRead(at: 0, byteCount: -1) }
    #expect(throws: expected) { try fixture.translated.validateWrite(at: 0, byteCount: -1) }
    #expect(throws: expected) { try fixture.translated.codeGeneration(at: 0, byteCount: -1) }
    #expect(fixture.paging.cachedTranslationCount == 0)
  }

  @Test func finalLinearByteCanHoldACompleteInstructionButCannotBorrowFromZero() throws {
    do {
      let fixture = try fixture(highByte: 0x90, zeroByte: 0xF4) // NOP, then unrelated HLT.
      #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: .max)) {
        try fixture.translated.instructionBytes(at: .max, maximumCount: .max)
      }
      var state = try longModeState(rip: .max)
      let result = DoryX86Interpreter().step(
        state: &state,
        memory: fixture.memory,
        mode: .long64,
        pagingUnit: fixture.paging
      )
      let decoded = try DoryX86Decoder().decode([0x90], at: .max, mode: .long64)
      #expect(result == .retired(decoded))
      #expect(state.rip == 0)
      #expect(try read64(fixture.memory, 0x1000) == 0x2007)
    }

    do {
      // 0F A2 is CPUID only if the fetch incorrectly wraps into linear address zero.
      let fixture = try fixture(highByte: 0x0F, zeroByte: 0xA2)
      var state = try longModeState(rip: .max)
      let before = state
      #expect(
        DoryX86Interpreter().step(
          state: &state,
          memory: fixture.memory,
          mode: .long64,
          pagingUnit: fixture.paging
        )
          == .exception(.init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: .max,
            linearAddress: .max
          )))
      #expect(state == before)
      #expect(try fixture.memory.read(at: 0x9000, byteCount: 1) == [0xA2])
      #expect(try read64(fixture.memory, 0x1000) == 0x2007)
    }
  }

  private struct Fixture {
    let memory: DoryX86ByteArrayMemory
    let paging: DoryX86PagingUnit
    let translated: DoryX86TranslatedMemory
    let pageTableEntries: [(UInt64, UInt64)]
  }

  private func fixture(highByte: UInt8, zeroByte: UInt8) throws -> Fixture {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0xA000)
    let entries: [(UInt64, UInt64)] = [
      (0x1000, 0x2007),
      (0x1ff8, 0x2007),
      (0x2000, 0x3007),
      (0x2ff8, 0x3007),
      (0x3000, 0x4007),
      (0x3ff8, 0x4007),
      (0x4000, 0x9007),
      (0x4ff8, 0x8007),
    ]
    for (address, value) in entries { try write64(memory, address, value) }
    try memory.write(at: 0x8fff, bytes: [highByte])
    try memory.write(at: 0x9000, bytes: [zeroByte])
    let paging = DoryX86PagingUnit()
    let context = DoryX86PagingContext(
      control: longModeControl(),
      rflags: .reset,
      currentPrivilegeLevel: 0,
      mode: .long64
    )
    return .init(
      memory: memory,
      paging: paging,
      translated: .init(physicalMemory: memory, pagingUnit: paging, context: context),
      pageTableEntries: entries
    )
  }

  private func longModeState(rip: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(
      rip: rip,
      cs: .init(selector: 0, attributes: 0xA09B, limit: .max),
      control: longModeControl()
    )
  }

  private func longModeControl() -> DoryX86ControlState {
    .init(
      cr0: 0x8001_0011,
      cr3: 0x1000,
      cr4: 1 << 5,
      efer: (1 << 10) | (1 << 11)
    )
  }

  private func write64(
    _ memory: DoryX86ByteArrayMemory,
    _ address: UInt64,
    _ value: UInt64
  ) throws {
    try memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    )
  }

  private func read64(_ memory: DoryX86ByteArrayMemory, _ address: UInt64) throws -> UInt64 {
    try memory.read(at: address, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }
}
