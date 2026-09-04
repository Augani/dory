import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2A CMPXCHG and CMPXCHG8B/16B: both comparison outcomes
// perform a destination write cycle. These tests do not qualify multi-vCPU ordering.
@Suite struct DoryX86CompareExchangeWriteTests {
  @Test func scalarMemoryComparisonsWriteExactlyOnceOnBothOutcomes() throws {
    for width in [1, 2, 4, 8] {
      for locked in [false, true] {
        for matches in [false, true] {
          let code = (locked ? [UInt8(0xF0)] : []) + scalarCode(width)
          let memory = CompareExchangeMemory(code: code, byteCount: width)
          var state = try state(matches: matches)
          let before = state
          let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
          #expect(memory.writes == 1 && memory.reads == 1)
          #expect(memory.bytes[0] == (matches ? 3 : 2))
          #expect(state.rflags.contains(.zero) == matches)
          #expect(state.registers.rax == (matches ? before.registers.rax : 2))
        }
      }
    }
  }

  @Test func pairMemoryComparisonsWriteOriginalBytesOnMismatchAndOnlyChangeZF() throws {
    for wide in [false, true] {
      for locked in [false, true] {
        for matches in [false, true] {
          let code = (locked ? [UInt8(0xF0)] : []) + pairCode(wide)
          let memory = CompareExchangeMemory(code: code, byteCount: wide ? 16 : 8)
          var state = try state(matches: matches)
          let oldFlags = state.rflags
          let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
          #expect(memory.writes == 1 && memory.reads == 1)
          #expect(memory.bytes[0] == (matches ? 4 : 2))
          #expect(state.rflags.subtracting(.zero) == oldFlags.subtracting(.zero))
          #expect(state.rflags.contains(.zero) == matches)
          if !matches { #expect(state.registers.rax == 2 && state.registers.rdx == 0) }
        }
      }
    }
  }

  @Test func readableButWriteProtectedDestinationsFaultBeforeReadsOrFlagsOnEitherOutcome() throws {
    for (code, width) in forms {
      for matches in [false, true] {
        let memory = CompareExchangeMemory(code: code, byteCount: width, writableBytes: 0)
        var state = try state(matches: matches)
        let before = state
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        #expect(result == .exception(.init(kind: .pageFault, vector: 14, errorCode: 3,
          instructionPointer: 0x1000, linearAddress: 0x8000)))
        var expected = before
        expected.control.cr2 = 0x8000
        #expect(state == expected && memory.reads == 0 && memory.writes == 0)
        #expect(memory.bytes[0] == 2)
      }
    }
  }

  @Test func deniedTailPreflightPreventsPartialWritesAndAccumulatorUpdates() throws {
    for (code, width) in forms where width > 1 {
      let memory = CompareExchangeMemory(code: code, byteCount: width, writableBytes: width - 1)
      var state = try state(matches: false)
      let before = state
      guard case .exception(let fault) = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      else { Issue.record("Expected denied destination tail to fault"); continue }
      #expect(fault.kind == .pageFault && fault.errorCode == 3)
      #expect(fault.linearAddress == 0x8000 + UInt64(width - 1))
      var expected = before
      expected.control.cr2 = 0x8000 + UInt64(width - 1)
      #expect(state == expected && memory.reads == 0 && memory.writes == 0)
    }
  }

  @Test func memoryComparisonsValidateTheWholeUsableSegmentBeforeAnyDataAccess() throws {
    for (baseCode, width) in [1, 2, 4].map({ (scalarCode($0), $0) }) + [(pairCode(false), 8)] {
      for stack in [false, true] {
        for invalid in 0..<5 {
          let code = (stack ? [UInt8(0x36)] : []) + baseCode
          let memory = CompareExchangeMemory(code: code, byteCount: width)
          var state = try self.state(matches: false, mode: .protected32)
          var segment = state.ds
          if invalid == 0 { segment.limit = UInt32(0x8000 + width - 2) }
          if invalid == 1 { segment.attributes = 0x0091 }
          if invalid == 2 { segment.selector = 0 }
          if invalid == 3 { segment.attributes &= ~UInt16(0x80) }
          if invalid == 4 { segment.attributes &= ~UInt16(0x10) }
          if stack { state.ss = segment } else { state.ds = segment }
          let before = state
          let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
          #expect(result == .exception(.init(kind: stack ? .stackSegment : .generalProtection,
            vector: stack ? 12 : 13, errorCode: 0, instructionPointer: 0x1000)))
          #expect(state == before && memory.reads == 0 && memory.writes == 0)
        }
      }
    }
  }

  @Test func noncanonicalMemorySpansFaultBeforeBackingWithTheSelectedSegmentVector() throws {
    for (baseCode, width) in forms {
      for stack in [false, true] {
        for address: UInt64 in [0x0000_8000_0000_0000, UInt64.max] {
          let code = (stack ? [UInt8(0x36)] : []) + baseCode
          var state = try self.state(matches: false)
          state.registers.rdi = address
          let before = state
          let memory = CompareExchangeMemory(code: code, byteCount: width)
          let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          // A single byte at UInt64.max is canonical and has no overflowing tail.
          if width == 1 && address == UInt64.max {
            guard case .retired = result else { Issue.record("Canonical byte should retire"); continue }
            #expect(memory.reads == 1 && memory.writes == 1)
          } else {
            #expect(result == .exception(.init(kind: stack ? .stackSegment : .generalProtection,
              vector: stack ? 12 : 13, errorCode: 0, instructionPointer: 0x1000)))
            #expect(state == before && memory.reads == 0 && memory.writes == 0)
          }
        }
      }
    }
  }

  @Test func failedRegisterComparisonPreservesDestinationUpperBitsAndPairAlignmentStaysPrecise() throws {
    let code: [UInt8] = [0x0F, 0xB1, 0xCB] // CMPXCHG EBX,ECX
    var state = try self.state(matches: false)
    state.registers.rbx = 0x1122_3344_0000_0002
    let memory = CompareExchangeMemory(code: code, byteCount: 4)
    let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
    #expect(state.registers.rbx == 0x1122_3344_0000_0002 && state.registers.rax == 2)
    #expect(memory.reads == 0 && memory.writes == 0)
    var misaligned = try self.state(matches: false)
    misaligned.registers.rdi = 0x8001
    let before = misaligned
    let denied = CompareExchangeMemory(code: pairCode(true), byteCount: 16, writableBytes: 0)
    guard case .exception(let fault) = DoryX86Interpreter().step(state: &misaligned, memory: denied, mode: .long64)
    else { Issue.record("Expected CMPXCHG16B alignment fault"); return }
    #expect(fault.kind == .generalProtection && fault.errorCode == 0)
    #expect(misaligned == before && denied.reads == 0 && denied.writes == 0)
  }

  private var forms: [([UInt8], Int)] {
    [1, 2, 4, 8].map { (scalarCode($0), $0) } + [(pairCode(false), 8), (pairCode(true), 16)]
  }
  private func scalarCode(_ width: Int) -> [UInt8] {
    (width == 2 ? [UInt8(0x66)] : width == 8 ? [UInt8(0x48)] : [])
      + [0x0F, width == 1 ? 0xB0 : 0xB1, 0x0F] // [RDI],CL/CX/ECX/RCX
  }
  private func pairCode(_ wide: Bool) -> [UInt8] {
    (wide ? [UInt8(0x48)] : []) + [0x0F, 0xC7, 0x0F]
  }
  private func state(matches: Bool, mode: DoryX86ExecutionMode = .long64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: matches ? 2 : 1, rcx: 3, rdx: 0, rbx: 4, rdi: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .sign, .overflow],
      cs: .init(selector: 8, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0x0093, limit: .max), control: .init(cr0: 0x11, cr2: 0xDEAD))
  }
}

private final class CompareExchangeMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  var bytes: [UInt8]
  let writableBytes: Int
  private(set) var reads = 0
  private(set) var writes = 0
  init(code: [UInt8], byteCount: Int, writableBytes: Int? = nil) {
    self.code = code
    bytes = [2] + [UInt8](repeating: 0, count: byteCount - 1)
    self.writableBytes = writableBytes ?? byteCount
  }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads += 1
    return Array(bytes.prefix(byteCount))
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    if byteCount > writableBytes {
      throw DoryX86MemoryError.pageFault(address: address + UInt64(writableBytes), errorCode: 3)
    }
  }
  func write(at address: UInt64, bytes newBytes: [UInt8]) throws {
    writes += 1
    // Deliberately model a backend that could publish a prefix: preflight must
    // stop the interpreter before this method when a later byte is denied.
    bytes.replaceSubrange(0..<min(writableBytes, newBytes.count), with: newBytes.prefix(writableBytes))
    try validateWrite(at: address, byteCount: newBytes.count)
  }
  func synchronize() {}
}
