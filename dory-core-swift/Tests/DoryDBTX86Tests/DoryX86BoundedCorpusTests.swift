import Testing

@testable import DoryDBTX86

/// Synthetic, deterministic P02-21 inputs. Seeds and case indices reproduce failures;
/// this is neither exhaustive ISA coverage nor an independent physical CPU reference.
@Suite struct DoryX86BoundedCorpusTests {
  private static let seeds: [UInt64] = [0xD002_0021_0000_0001, 0xD002_0021_1357_2468,
    0xD002_0021_89AB_CDEF, 0xD002_0021_FFFF_FFFF]
  private static let maximumInputBytes = 15
  private static let maximumMemoryBytes = 65_536
  private static let maximumREPCount: UInt64 = 8

  @Test func prefixEscapeAndTruncationCorpusHasStableInstructionBoundaries() throws {
    let decoder = DoryX86Decoder()
    let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]
    for seed in Self.seeds {
      var random = CorpusRandom(seed: seed)
      for index in 0..<128 {
        let bytes = structuredBytes(index: index, random: &random)
        let address = index.isMultiple(of: 2) ? UInt64(0x1000) : UInt64.max - 7
        for mode in modes {
          let decoded: DoryX86DecodedInstruction
          do {
            decoded = try decoder.decode(bytes, at: address, mode: mode)
          } catch let error as DoryX86DecodeError {
            switch error {
            case .truncated(let faultRIP), .instructionTooLong(let faultRIP),
              .unsupportedOpcode(let faultRIP, _), .invalidEncoding(let faultRIP, _):
              #expect(faultRIP == address, "seed \(seed), case \(index), \(mode)")
            }
            continue
          }
          try #require((1...Self.maximumInputBytes).contains(Int(decoded.length)), "seed \(seed), case \(index), \(mode)")
          try #require(decoded.bytes == Array(bytes.prefix(Int(decoded.length))))
          #expect(decoded.address == address)
          #expect(decoded.nextInstructionAddress == address &+ UInt64(decoded.length))
          // A complete first instruction cannot depend on unconsumed following bytes.
          #expect(try decoder.decode(decoded.bytes, at: address, mode: mode) == decoded)
          let suffix = (Int(decoded.length)..<Self.maximumInputBytes).map { UInt8(truncatingIfNeeded: ($0 * 37) ^ index) }
          #expect(try decoder.decode(decoded.bytes + suffix, at: address, mode: mode) == decoded)
        }
      }
    }
  }

  @Test func arbitrarySingleInstructionFaultsKeepPreciseStateWithBoundedREPInput() throws {
    let interpreter = DoryX86Interpreter()
    for seed in Self.seeds.prefix(2) {
      var random = CorpusRandom(seed: seed ^ 0xE0E0)
      for index in 0..<128 {
        var bytes = structuredBytes(index: index, random: &random)
        while bytes.count < Self.maximumInputBytes { bytes.append(random.byte()) }
        let memory = try DoryX86ByteArrayMemory(byteCount: 4096)
        try memory.write(at: 0x80, bytes: bytes)
        var registers = DoryX86GeneralRegisters()
        for register in DoryX86GeneralRegister.allCases {
          // Exercise both accessible addresses and unbacked, boundary-biased operands.
          registers[register] = index.isMultiple(of: 3) ? random.next() : random.next() & 0x1FFF
        }
        registers.rcx = random.next() % Self.maximumREPCount
        registers.rsp = 0x800
        var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x80,
          rflags: .init(rawValue: 2 | (random.next() & 0xCD5)), control: .init(cr2: 0xCAFE))
        let before = state
        let result = interpreter.step(state: &state, memory: memory, mode: .long64)
        switch result {
        case .exception(let fault):
          try #require(fault.instructionPointer == before.rip, "seed \(seed), case \(index)")
          #expect(state.rip == before.rip)
          if !fault.commitsPartialProgress {
            var expected = before
            if fault.kind == .pageFault { expected.control.cr2 = fault.linearAddress ?? 0 }
            try #require(state == expected, "seed \(seed), case \(index), bytes \(bytes)")
          }
        case .retired(let instruction), .halted(let instruction), .yielded(let instruction):
          #expect(instruction.address == before.rip)
          #expect((1...Self.maximumInputBytes).contains(Int(instruction.length)))
          #expect(instruction.bytes == Array(bytes.prefix(Int(instruction.length))))
        }
        #expect(state.rflags.contains(.reservedOne))
        #expect(memory.snapshot().count == 4096)
        #expect(state.floatingPoint.x87.count == 8 && state.floatingPoint.ymm.count == 16)
      }
    }
  }

  @Test func boundedREPMatchesByteCopyOracleAndRetainsCompletedFaultProgress() throws {
    var random = CorpusRandom(seed: Self.seeds[2])
    for index in 0..<64 {
      let count = Int(random.next() % Self.maximumREPCount)
      let reverse = index.isMultiple(of: 2)
      let shouldFault = !reverse && count > 0 && index.isMultiple(of: 3)
      let completed = shouldFault ? count - 1 : count
      let source = reverse ? 0x180 + count : 0x180
      let destination = shouldFault ? 1024 - completed : (reverse ? 0x280 + count : 0x280)
      let memory = try DoryX86ByteArrayMemory(byteCount: 1024)
      let instruction: [UInt8] = [0xF3, 0xA4]  // REP MOVSB: at most seven byte iterations.
      try memory.write(at: 0x40, bytes: instruction)
      try memory.write(at: 0x180, bytes: (0..<32).map { _ in random.byte() })
      var state = try DoryX86ArchitecturalState(
        registers: .init(rcx: UInt64(count), rsi: UInt64(source), rdi: UInt64(destination)), rip: 0x40,
        rflags: reverse ? [.reservedOne, .carry, .direction] : [.reservedOne, .carry])
      let before = state
      var expectedBytes = memory.snapshot()
      for step in 0..<completed {
        let delta = reverse ? -step : step
        expectedBytes[destination + delta] = expectedBytes[source + delta]
      }
      let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      var expected = before
      let distance = reverse ? -completed : completed
      expected.registers.rsi = UInt64(source + distance)
      expected.registers.rdi = UInt64(destination + distance)
      expected.registers.rcx = UInt64(count - completed)
      if shouldFault {
        guard case .exception(let fault) = result else {
          Issue.record("seed \(Self.seeds[2]), case \(index): missing REP boundary fault")
          return
        }
        #expect(fault.kind == .pageFault && fault.vector == 14)
        #expect(fault.instructionPointer == 0x40 && fault.linearAddress == 1024)
        #expect(fault.commitsPartialProgress == (completed > 0))
        expected.control.cr2 = 1024
      } else {
        guard case .retired = result else {
          Issue.record("seed \(Self.seeds[2]), case \(index): bounded REP did not retire")
          return
        }
        expected.rip = 0x42
      }
      #expect(state == expected)
      #expect(memory.snapshot() == expectedBytes)
    }
  }

  @Test func randomizedPageTablePoliciesPreserveOffsetsAndInvalidateRevocations() throws {
    var random = CorpusRandom(seed: Self.seeds[3])
    for index in 0..<96 {
      let layout = PageLayout(random: &random)
      let policy = index % 6 // unrestricted, read-only, supervisor, NX, absent, reserved physical bit.
      let level = Int(random.next() % 4)
      let memory = try DoryX86ByteArrayMemory(byteCount: Self.maximumMemoryBytes)
      try layout.install(in: memory)
      let entryAddress = layout.entryAddresses[level]
      var entry = try memory.readScalar(at: entryAddress, byteCount: 8)
      switch policy {
      case 1: entry &= ~UInt64(2)
      case 2: entry &= ~UInt64(4)
      case 3: entry |= 1 << 63
      case 4: entry &= ~UInt64(1)
      case 5: entry |= 1 << 45 // Beyond the explicitly selected 40-bit physical profile.
      default: break
      }
      try memory.writeScalar(at: entryAddress, value: entry, byteCount: 8)
      let paging = DoryX86PagingUnit(physicalAddressBits: 40, maximumEntryCount: 4)
      let context = DoryX86PagingContext(control: .init(cr0: 0x8001_0011, cr3: 0x1000,
        cr4: 1 << 5, efer: (1 << 10) | (1 << 11)), rflags: .reservedOne,
        currentPrivilegeLevel: 3, mode: .long64)
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let denied = policy >= 4 || policy == 2 || (policy == 1 && access == .write)
          || (policy == 3 && access == .instructionFetch)
        if denied {
          // Architectural PF bits: P, W/R, U/S, RSVD, I/D. All these probes are CPL3 with NXE.
          var code: UInt32 = policy == 4 ? 4 : 5
          if access == .write { code |= 2 }
          if access == .instructionFetch { code |= 16 }
          if policy == 5 { code |= 8 }
          #expect(throws: DoryX86MemoryError.pageFault(address: layout.linear, errorCode: code)) {
            try paging.translate(linearAddress: layout.linear, access: access, context: context, physicalMemory: memory)
          }
        } else {
          let result = try paging.translate(linearAddress: layout.linear, access: access, context: context, physicalMemory: memory)
          #expect(result.physicalAddress == layout.physicalPage + layout.offset)
          #expect(result.linearAddress == layout.linear && result.pageSize == 4096)
          #expect(result.userAccessible && result.writable == (policy != 1) && result.executable == (policy != 3))
        }
      }
      // Publish a new all-access mapping, observe it, then revoke user access. Both hot and
      // dictionary TLB entries must obey explicit invalidation; the offset never changes.
      let remappedPage: UInt64 = layout.physicalPage == 0x8000 ? 0x9000 : 0x8000
      try layout.install(in: memory, physicalPage: remappedPage)
      paging.invalidate(linearAddress: layout.linear)
      #expect(try paging.translate(linearAddress: layout.linear, access: .read, context: context,
        physicalMemory: memory).physicalAddress == remappedPage + layout.offset)
      let leaf = layout.entryAddresses[3]
      let current = try memory.readScalar(at: leaf, byteCount: 8)
      try memory.writeScalar(at: leaf, value: current & ~UInt64(4), byteCount: 8)
      paging.invalidate(linearAddress: layout.linear)
      #expect(throws: DoryX86MemoryError.pageFault(address: layout.linear, errorCode: 5)) {
        try paging.translate(linearAddress: layout.linear, access: .read, context: context, physicalMemory: memory)
      }
      #expect(paging.cachedTranslationCount <= 4)
      #expect(try memory.read(at: 0x8000, byteCount: 0x8000) == Array(repeating: 0, count: 0x8000))
    }
  }

  @Test func noncanonicalPageWalkInputsCannotTouchPageTables() throws {
    var random = CorpusRandom(seed: Self.seeds[0] ^ 0xCA11)
    for index in 0..<64 {
      let memory = try DoryX86ByteArrayMemory(byteCount: Self.maximumMemoryBytes)
      let lower = random.next() & 0x0000_7FFF_FFFF_FFFF
      // Deliberately disagree between bit 47 and the upper sixteen bits, in both directions.
      let linear = index.isMultiple(of: 2) ? lower | (1 << 47) : lower | 0xFFFF_0000_0000_0000
      let context = DoryX86PagingContext(control: .init(cr0: 0x8000_0011, cr3: 0x1000,
        cr4: 1 << 5, efer: 1 << 10), rflags: .reservedOne, currentPrivilegeLevel: 0, mode: .long64)
      #expect(throws: DoryX86MemoryError.addressOverflow(address: linear, byteCount: 1)) {
        try DoryX86PagingUnit().translate(linearAddress: linear, access: .read, context: context, physicalMemory: memory)
      }
      #expect(memory.snapshot() == Array(repeating: 0, count: Self.maximumMemoryBytes))
    }
  }

  private func structuredBytes(index: Int, random: inout CorpusRandom) -> [UInt8] {
    let prefixes: [UInt8] = [0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x64, 0x65, 0x40, 0x48, 0x4F]
    let stems: [[UInt8]] = [[0x0F], [0x0F, 0x38], [0x0F, 0x3A], [0xC4], [0xC5],
      [0x8B, 0x04], [0xC7, 0x84, 0x24], [0xF7], [0xFF], [0xF3, 0xA4], [0xD9], [0x90]]
    let length = index % (Self.maximumInputBytes + 1)
    if index % 8 == 7 {
      return (0..<length).map { _ in prefixes[Int(random.next() % UInt64(prefixes.count))] }
    }
    var result = (0..<(index % 7)).map { _ in prefixes[Int(random.next() % UInt64(prefixes.count))] }
    result += stems[index % stems.count]
    while result.count < length { result.append(random.byte()) }
    return Array(result.prefix(length))
  }
}

private struct CorpusRandom {
  var seed: UInt64
  mutating func next() -> UInt64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return seed
  }
  mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

private struct PageLayout {
  let linear: UInt64, physicalPage: UInt64, offset: UInt64
  let entryAddresses: [UInt64]
  init(random: inout CorpusRandom) {
    let slots = [random.next() % 256, random.next() % 512, random.next() % 512, random.next() % 512]
    offset = random.next() % 4096
    linear = (slots[0] << 39) | (slots[1] << 30) | (slots[2] << 21) | (slots[3] << 12) | offset
    physicalPage = 0x8000 + (random.next() % 8) * 4096
    entryAddresses = slots.enumerated().map { (UInt64($0.offset) + 1) * 4096 + $0.element * 8 }
  }
  func install(in memory: DoryX86ByteArrayMemory, physicalPage replacement: UInt64? = nil) throws {
    let destinations: [UInt64] = [0x2000, 0x3000, 0x4000, replacement ?? physicalPage]
    for (address, destination) in zip(entryAddresses, destinations) {
      try memory.writeScalar(at: address, value: destination | 7, byteCount: 8)
    }
  }
}
