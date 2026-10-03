import Testing

@testable import DoryDBTX86

// Independent literal flag vectors from Intel SDM Vol. 2B, POPF Table 4-15
// and PUSHF Operation. Neither public baseline admits CR4.VME.
// https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2b-manual.pdf
@Suite struct DoryX86FlagsStackContractTests {
  private let profiles: [DoryX86CPUProfile] = [.compatibleV1, .intelCompatibleV1]

  @Test func protectedPopUsesExecutingCPLAndOriginalIOPL() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
        for word in [false, true] {
          let width = byteCount(mode, word: word)
          let code = instruction(0x9D, mode: mode, word: word)
          for cpl: UInt16 in [0, 1, 2, 3] {
            for oldIOPL: UInt64 in [0, 1, 2, 3] {
              for requestedSet in [false, true] {
                let memory = try memory(code)
                let oldSet = !requestedSet
                let oldFlags = UInt64(2) | oldIOPL << 12 | 0x0001_0000
                  | (oldSet ? 0x003C_0201 : 0)
                var state = try state(mode, cpl: cpl, flags: oldFlags)
                let image: UInt64 = requestedSet ? .max : 0
                try memory.writeScalar(at: 0x800, value: image, byteCount: width)
                let snapshot = memory.snapshot()

                #expect(DoryX86Interpreter(profile: profile).step(
                  state: &state, memory: memory, mode: mode)
                  == .retired(try DoryX86Decoder().decode(code, at: 0x100, mode: mode)))

                // Ordinary low flags all come from the stack; IOPL changes only
                // at CPL0, and IF uses the OLD IOPL even if CPL0 pops a new one.
                let expectedIOPL = cpl == 0 ? (requestedSet ? UInt64(3) : 0) : oldIOPL
                let expectedIF = UInt64(cpl) <= oldIOPL ? requestedSet : oldSet
                let expectedUpper = (oldSet ? UInt64(0x0018_0000) : 0)
                  | ((word ? oldSet : requestedSet) ? UInt64(0x0024_0000) : 0)
                let expected = UInt64(2) | expectedIOPL << 12 | expectedUpper
                  | (requestedSet ? 0x4DD5 : 0) | (expectedIF ? 0x200 : 0)
                #expect(state.rflags.rawValue == expected)
                #expect(state.registers.rsp == 0x800 + UInt64(width))
                #expect(state.rip == 0x100 + UInt64(code.count))
                #expect(memory.snapshot() == snapshot)
              }
            }
          }
        }
      }
    }
  }

  @Test func realPopIgnoresSelectorPrivilegeAndPreservesWordUpperFlags() throws {
    for profile in profiles {
      for word in [false, true] {
        let code = instruction(0x9D, mode: .real16, word: word)
        let memory = try memory(code)
        var state = try state(.real16, cpl: 3, flags: 0x003D_0002)
        try memory.writeScalar(at: 0x800, value: 0x3201, byteCount: byteCount(.real16, word: word))

        #expect(DoryX86Interpreter(profile: profile).step(
          state: &state, memory: memory, mode: .real16)
          == .retired(try DoryX86Decoder().decode(code, at: 0x100, mode: .real16)))
        #expect(state.rflags.rawValue == (word ? 0x003C_3203 : 0x0018_3203))
        #expect(state.registers.rsp == (word ? 0x802 : 0x804))
      }
    }
  }

  @Test func virtualPopAtIOPLThreePreservesVMIOPLAndVirtualInterruptFlags() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
        for word in [false, true] {
          for oldVirtualInterrupts in [false, true] {
            let code = instruction(0x9D, mode: mode, word: word)
            let memory = try memory(code)
            // Selector RPL0 must not defeat virtual-8086's effective CPL3.
            let old = UInt64(0x0003_3002) | (oldVirtualInterrupts ? 0x0018_0000 : 0)
            var state = try state(mode, flags: old)
            let image = UInt64(0x0024_0201) | (oldVirtualInterrupts ? 0 : 0x0018_0000)
            try memory.writeScalar(at: 0x800, value: image, byteCount: byteCount(mode, word: word))

            #expect(DoryX86Interpreter(profile: profile).step(
              state: &state, memory: memory, mode: mode)
              == .retired(try DoryX86Decoder().decode(code, at: 0x100, mode: mode)))
            let expected = UInt64(0x0002_3203)
              | (oldVirtualInterrupts ? 0x0018_0000 : 0) | (word ? 0 : 0x0024_0000)
            #expect(state.rflags.rawValue == expected)
            #expect(state.registers.rsp == 0x800 + UInt64(byteCount(mode, word: word)))
          }
        }
      }
    }
  }

  @Test func virtualLowIOPLFaultsBeforeAnyStackAccess() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
        for opcode: UInt8 in [0x9C, 0x9D] {
          for word in [false, true] {
            for ioPrivilege: UInt64 in [0, 1, 2] {
              let memory = try FlagsStackFaultMemory(instruction(opcode, mode: mode, word: word))
              var state = try state(mode, flags: 0x0003_0203 | ioPrivilege << 12)
              let before = state
              #expect(DoryX86Interpreter(profile: profile).step(
                state: &state, memory: memory, mode: mode)
                == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0,
                  instructionPointer: 0x100)))
              #expect(state == before)
              #expect(memory.stackReadCount == 0 && memory.stackWriteCount == 0)
              #expect(memory.stackReadValidationCount == 0 && memory.stackWriteValidationCount == 0)
            }
          }
        }
      }
    }
  }

  @Test func pushImageClearsRFAndVMWithoutChangingTheExecutingMode() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
        for word in [false, true] {
          let code = instruction(0x9C, mode: mode, word: word)
          let memory = try memory(code)
          try memory.write(at: 0x7F0, bytes: Array(repeating: 0xA5, count: 32))
          let old: UInt64 = mode == .long64 ? 0x003D_7ED7 : 0x003F_7ED7
          var state = try state(mode, flags: old)
          let initial = state
          let width = byteCount(mode, word: word)
          let pushedAt = 0x800 - UInt64(width)
          var expectedMemory = memory.snapshot()
          let image: UInt64 = word ? 0x7ED7 : 0x003C_7ED7
          expectedMemory.replaceSubrange(Int(pushedAt)..<0x800, with: bytes(image, count: width))

          #expect(DoryX86Interpreter(profile: profile).step(
            state: &state, memory: memory, mode: mode)
            == .retired(try DoryX86Decoder().decode(code, at: 0x100, mode: mode)))
          var expected = initial
          expected.registers.rsp = pushedAt
          expected.rip = 0x100 + UInt64(code.count)
          expected.rflags = .init(rawValue: old & ~UInt64(0x0001_0000))
          #expect(state == expected)
          #expect(memory.snapshot() == expectedMemory)
        }
      }
    }
  }

  @Test func popStackFaultPublishesOnlyCR2NotFlagsOrStackProgress() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
        for word in [false, true] {
          let memory = try FlagsStackFaultMemory(instruction(0x9D, mode: mode, word: word))
          // Existing TF/RF, upper flags, and nonzero IOPL must survive a fault.
          var state = try state(mode, cpl: 3, flags: 0x003D_3303)
          state.debug.dr6 = 5
          var expected = state
          expected.control.cr2 = 0x800
          #expect(DoryX86Interpreter(profile: profile).step(
            state: &state, memory: memory, mode: mode)
            == .exception(.init(kind: .pageFault, vector: 14, errorCode: 4,
              instructionPointer: 0x100, linearAddress: 0x800)))
          #expect(state == expected)
          #expect(memory.stackReadCount == 1 && memory.stackWriteCount == 0)
          #expect(memory.stackWriteValidationCount == 0)
        }
      }
    }
  }

  @Test func pushStackFaultPreservesRFAndVirtualMode() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
        for word in [false, true] {
          let memory = try FlagsStackFaultMemory(instruction(0x9C, mode: mode, word: word))
          let old: UInt64 = mode == .long64 ? 0x003D_3303 : 0x003F_3303
          var state = try state(mode, cpl: 3, flags: old)
          let address = 0x800 - UInt64(byteCount(mode, word: word))
          var expected = state
          expected.control.cr2 = address
          let snapshot = memory.snapshot()
          #expect(DoryX86Interpreter(profile: profile).step(
            state: &state, memory: memory, mode: mode)
            == .exception(.init(kind: .pageFault, vector: 14, errorCode: 6,
              instructionPointer: 0x100, linearAddress: address)))
          #expect(state == expected)
          #expect(memory.snapshot() == snapshot)
          #expect(memory.stackWriteValidationCount == 1)
          #expect(memory.stackReadCount == 0 && memory.stackWriteCount == 0)
        }
      }
    }
  }

  @Test func userPopCannotGrantTheFollowingCLIPrivilege() throws {
    for profile in profiles {
      for mode: DoryX86ExecutionMode in [.protected32, .long64] {
        let memory = try memory([0x9D, 0xFA]) // POPFD/Q; CLI
        try memory.writeScalar(at: 0x800, value: 0x3203, byteCount: mode == .long64 ? 8 : 4)
        var state = try state(mode, cpl: 3)
        let interpreter = DoryX86Interpreter(profile: profile)
        #expect(interpreter.step(state: &state, memory: memory, mode: mode)
          == .retired(try DoryX86Decoder().decode([0x9D], at: 0x100, mode: mode)))
        #expect(state.rflags.rawValue == 3)
        let afterPop = state
        #expect(interpreter.step(state: &state, memory: memory, mode: mode)
          == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0,
            instructionPointer: 0x101)))
        #expect(state == afterPop)
      }
    }
  }

  @Test func nativeLoweringKeepsPopAndLegacyPushAtExactInterpreterBoundaries() throws {
    for profile in profiles {
      let translator = DoryX86IRTranslator(profile: profile)
      for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
        for word in [false, true] {
          for opcode: UInt8 in [0x9C, 0x9D] {
            let code = instruction(opcode, mode: mode, word: word)
            let block = try translator.translate(code, at: 0x100, mode: mode)
            if mode == .long64 && !word && opcode == 0x9C {
              // This existing lowering independently masks RF/VM. All privilege-
              // sensitive forms below remain in the corrected interpreter path.
              #expect(block.statements == [.stackPushFlags])
              #expect(block.terminator == .next(0x101))
            } else {
              #expect(block.statements == [.helper(identifier: "x86.interpret.one", payload: code)])
              #expect(block.terminator == .exit(.interpreter, resumeAt: 0x100))
              for tier: DoryARM64CompilationTier in [.baseline, .optimizing] {
                #expect(DoryARM64BaselineEmitter().compile(block, tier: tier).tier == .interpreterFallback)
              }
            }
          }
        }
      }
      let prefix = try translator.translate([0x48, 0xFF, 0xC3, 0x9D], at: 0x100, mode: .long64)
      #expect(prefix.guestInstructionCount == 1 && prefix.guestByteCount == 3)
      #expect(prefix.terminator == .next(0x103))
    }
  }

  private func instruction(_ opcode: UInt8, mode: DoryX86ExecutionMode, word: Bool) -> [UInt8] {
    let defaultWord = mode == .real16 || mode == .protected16
    return defaultWord == word ? [opcode] : [0x66, opcode]
  }

  private func byteCount(_ mode: DoryX86ExecutionMode, word: Bool) -> Int {
    word ? 2 : (mode == .long64 ? 8 : 4)
  }

  private func bytes(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  private func memory(_ code: [UInt8]) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    try memory.write(at: 0x100, bytes: code)
    return memory
  }

  private func state(_ mode: DoryX86ExecutionMode, cpl: UInt16 = 0, flags: UInt64 = 2)
    throws -> DoryX86ArchitecturalState
  {
    let default32: UInt16 = mode == .protected32 ? 0x4000 : 0
    return try .init(registers: .init(rsp: 0x800), rip: 0x100, rflags: .init(rawValue: flags),
      cs: .init(selector: 8 | cpl,
        attributes: (mode == .long64 ? 0xA09B : 0x009B | default32) | cpl << 5, limit: .max),
      ss: .init(selector: 16 | cpl, attributes: 0x0093 | default32 | cpl << 5, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11,
        efer: mode == .long64 ? 1 << 10 : 0))
  }
}

// The fetch is independent from the intentionally faulting stack. These counts
// detect forbidden stack calls even when an incorrect implementation still faults.
private final class FlagsStackFaultMemory: DoryX86Memory, @unchecked Sendable {
  private let backing: DoryX86ByteArrayMemory
  private(set) var stackReadCount = 0
  private(set) var stackWriteCount = 0
  private(set) var stackReadValidationCount = 0
  private(set) var stackWriteValidationCount = 0

  init(_ code: [UInt8]) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    try backing.write(at: 0x100, bytes: code)
  }

  func snapshot() -> [UInt8] { backing.snapshot() }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    stackReadCount += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 4)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    stackReadValidationCount += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 4)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    stackWriteValidationCount += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 6)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    stackWriteCount += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 6)
  }

  func synchronize() {}
}
