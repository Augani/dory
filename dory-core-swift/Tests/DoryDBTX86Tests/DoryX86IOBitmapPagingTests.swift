import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A §§5.6.1/5.7: implicit system-data accesses are supervisor
// accesses, SMAP ignores AC for them, and #PF U/S describes the access that faulted.
@Suite struct DoryX86IOBitmapPagingTests {
  @Test func userAndVirtual8086IOReadSupervisorTSSWithoutChangingOperandPrivilege() throws {
    for mode in modes {
      for bytes in ioInstructions {
        for smap in [false, true] {
          let fixture = try makeFixture(mode: mode, bytes: bytes, smap: smap)
          var state = fixture.state
          let bus = BitmapIOBus()
          let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: mode)
          #expect(step(&state, fixture, bus) == .retired(decoded))
          #expect(bus.accessCount == 1)
          #expect(state.rflags == fixture.state.rflags)
          // The supervisor TSS read must neither mutate the translated-memory context nor
          // leave a translation usable by an ordinary user operand, including in v8086.
          #expect(throws: DoryX86MemoryError.pageFault(address: 0x2066, errorCode: 5)) {
            try fixture.translated.read(at: 0x2066, byteCount: 2)
          }
          if bytes == [0xE4, 0x20] { #expect(state.registers.rax == 0xA5) }
          if bytes == [0x6C] {
            #expect(try fixture.memory.read(at: 0x14000, byteCount: 1) == [0xA5])
          }
        }
      }
    }
  }

  @Test func deniedBitmapStillFaultsBeforePortOrStringOperandEffects() throws {
    for mode in modes {
      for bytes in ioInstructions {
        let fixture = try makeFixture(mode: mode, bytes: bytes, smap: true)
        try fixture.memory.write(at: 0x13004, bytes: [1])
        var state = fixture.state
        let bus = BitmapIOBus()
        #expect(step(&state, fixture, bus) == .exception(.init(
          kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
        #expect(state == fixture.state)
        #expect(bus.accessCount == 0)
        #expect(try fixture.memory.read(at: 0x14000, byteCount: 1) == [0x5A])
      }
    }
  }

  @Test func missingTSSPagesReportSupervisorReadFaultsAndPreciseCR2() throws {
    for mode in modes {
      for bytes in ioInstructions {
        for page in [2, 3] {
          let fixture = try makeFixture(mode: mode, bytes: bytes)
          try setPage(page, flags: 0, fixture: fixture)
          var state = fixture.state
          let bus = BitmapIOBus()
          let address: UInt64 = page == 2 ? 0x2066 : 0x3004
          #expect(step(&state, fixture, bus) == pageFault(address, code: 0))
          var expected = fixture.state
          expected.control.cr2 = address
          #expect(state == expected)
          #expect(bus.accessCount == 0)
          #expect(try fixture.memory.read(at: 0x14000, byteCount: 1) == [0x5A])
        }
      }
    }
  }

  @Test func smapControlsImplicitUserTSSReadsRegardlessOfAC() throws {
    for mode in modes {
      for smap in [false, true] {
        for alignmentCheck in [false, true] {
          for page in [2, 3] {
            let fixture = try makeFixture(mode: mode, bytes: [0xE4, 0x20],
              smap: smap, alignmentCheck: alignmentCheck)
            try setPage(page, flags: 7, fixture: fixture)
            var state = fixture.state
            let bus = BitmapIOBus()
            let result = step(&state, fixture, bus)
            if smap {
              let address: UInt64 = page == 2 ? 0x2066 : 0x3004
              #expect(result == pageFault(address, code: 1))
              var expected = fixture.state
              expected.control.cr2 = address
              #expect(state == expected)
              #expect(bus.accessCount == 0)
            } else {
              let decoded = try DoryX86Decoder().decode([0xE4, 0x20], at: 0x1000, mode: mode)
              #expect(result == .retired(decoded))
              #expect(state.registers.rax == 0xA5)
              #expect(bus.accessCount == 1)
            }
          }
        }
      }
    }
  }

  @Test func implicitReadsCannotReuseExplicitSupervisorACEnabledSMAPTranslation() throws {
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      let fixture = try makeFixture(mode: mode, bytes: [0x90],
        smap: true, alignmentCheck: true)
      try setPage(2, flags: 7, fixture: fixture)
      var supervisor = fixture.state
      supervisor.cs.selector = 0
      fixture.translated.updateContext(.init(state: supervisor, mode: mode))
      #expect(try fixture.translated.read(at: 0x2066, byteCount: 2) == [0, 0x10])
      #expect(fixture.paging.cachedTranslationCount == 1)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x2066, errorCode: 1)) {
        try fixture.translated.readImplicitSupervisor(at: 0x2066, byteCount: 2)
      }
      // The implicit access failed without clearing AC or otherwise altering explicit access.
      #expect(try fixture.translated.read(at: 0x2066, byteCount: 2) == [0, 0x10])
    }
  }

  @Test func stringOperandsRemainUserAccessesAfterSuccessfulTSSPermissionRead() throws {
    for mode in modes {
      for opcode: UInt8 in [0x6C, 0x6E] {
        let fixture = try makeFixture(mode: mode, bytes: [opcode], smap: true)
        try setPage(4, flags: 3, fixture: fixture)
        var state = fixture.state
        let bus = BitmapIOBus()
        let code: UInt32 = opcode == 0x6C ? 7 : 5
        #expect(step(&state, fixture, bus) == pageFault(0x4000, code: code))
        var expected = fixture.state
        expected.control.cr2 = 0x4000
        #expect(state == expected)
        #expect(bus.accessCount == 0)
        #expect(try fixture.memory.read(at: 0x14000, byteCount: 1) == [0x5A])
      }
    }
  }

  @Test func crossPageMapBaseReadPreservesSupervisorFaultAddress() throws {
    for mode in modes {
      let fixture = try makeFixture(mode: mode, bytes: [0xE4, 0x20])
      var state = fixture.state
      state.tr.base = 0x2F99  // I/O map base field at 0x2FFF spans two pages.
      try fixture.memory.write(at: 0x12FFF, bytes: [0, 0x10])
      try setPage(3, flags: 0, fixture: fixture)
      let bus = BitmapIOBus()
      var expected = state
      expected.control.cr2 = 0x3000
      #expect(step(&state, fixture, bus) == pageFault(0x3000, code: 0))
      #expect(state == expected)
      #expect(bus.accessCount == 0)
    }
  }

  private var modes: [DoryX86ExecutionMode] { [.protected32, .protected16, .long64] }
  private var ioInstructions: [[UInt8]] { [[0xE4, 0x20], [0xE6, 0x20], [0x6C], [0x6E]] }

  private struct Fixture {
    let mode: DoryX86ExecutionMode
    let state: DoryX86ArchitecturalState
    let memory: DoryX86ByteArrayMemory
    let paging: DoryX86PagingUnit
    let translated: DoryX86TranslatedMemory
  }

  private func makeFixture(
    mode: DoryX86ExecutionMode,
    bytes: [UInt8],
    smap: Bool = false,
    alignmentCheck: Bool = false
  ) throws -> Fixture {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20000)
    let long = mode == .long64
    let virtual = mode == .protected16
    let entryBytes = long ? 8 : 4
    if long {
      try memory.writeScalar(at: 0x8000, value: 0x9007, byteCount: 8)
      try memory.writeScalar(at: 0x9000, value: 0xA007, byteCount: 8)
    }
    try memory.writeScalar(at: 0xA000, value: 0xB007, byteCount: entryBytes)
    for page in 1...4 {
      let flags: UInt64 = page == 2 || page == 3 ? 3 : 7
      try memory.writeScalar(at: 0xB000 + UInt64(page * entryBytes),
        value: 0x10000 + UInt64(page * 0x1000) | flags, byteCount: entryBytes)
    }
    try memory.write(at: 0x11000, bytes: bytes)
    try memory.writeScalar(at: 0x12066, value: 0x1000, byteCount: 2)
    try memory.write(at: 0x13004, bytes: [0])
    try memory.write(at: 0x14000, bytes: [0x5A])
    var flags: DoryX86RFLAGS = [.reservedOne]
    // IOPL3 still requires the bitmap in v8086 mode.
    if virtual { flags = .init(rawValue: flags.rawValue | (1 << 17) | (3 << 12)) }
    if alignmentCheck { flags.insert(.alignmentCheck) }
    let dataSegment = DoryX86SegmentState(
      selector: virtual ? 0 : 0x23, attributes: virtual ? 0x93 : 0xC0F3, limit: 0xFFFF_FFFF)
    let state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x5A, rcx: 1, rdx: 0x20, rsi: 0x4000, rdi: 0x4000),
      rip: 0x1000, rflags: flags,
      cs: .init(selector: virtual ? 0 : 0x1B,
        attributes: long ? 0xA0FB : virtual ? 0x9B : 0xC0FB, limit: 0xFFFF_FFFF),
      ds: dataSegment, es: dataSegment, ss: dataSegment,
      tr: .init(selector: 0x28, attributes: 0x8B, limit: 0x1100, base: 0x2000),
      control: .init(cr0: 0x8000_0011, cr3: long ? 0x8000 : 0xA000,
        cr4: (long ? 1 << 5 : 0) | (smap ? 1 << 21 : 0), efer: long ? 0x500 : 0)
    )
    let paging = DoryX86PagingUnit()
    return .init(mode: mode, state: state, memory: memory, paging: paging,
      translated: DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
        context: .init(state: state, mode: mode)))
  }

  private func setPage(_ page: Int, flags: UInt64, fixture: Fixture) throws {
    let entryBytes = fixture.mode == .long64 ? 8 : 4
    try fixture.memory.writeScalar(at: 0xB000 + UInt64(page * entryBytes),
      value: 0x10000 + UInt64(page * 0x1000) | flags, byteCount: entryBytes)
  }

  private func step(_ state: inout DoryX86ArchitecturalState, _ fixture: Fixture,
    _ bus: BitmapIOBus) -> DoryX86InterpreterResult {
    DoryX86Interpreter().step(state: &state, memory: fixture.memory, mode: fixture.mode,
      pagingUnit: fixture.paging, translatedMemory: fixture.translated, ioBus: bus)
  }

  private func pageFault(_ address: UInt64, code: UInt32) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: code,
      instructionPointer: 0x1000, linearAddress: address))
  }
}

private final class BitmapIOBus: DoryX86IOBus, @unchecked Sendable {
  private(set) var accessCount = 0

  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    accessCount += 1
    return 0xA5
  }

  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    accessCount += 1
  }
}
