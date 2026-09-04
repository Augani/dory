import Testing

@testable import DoryDBTX86

// Intel SDM 092: Vol. 2D Table A-6 (groups 6/7), Vol. 2B pp. 4-32 through
// 4-36 (MOV CR/DR), 4-656/679 (SLDT/STR). The existing checked-in ISA inventory
// checks exact recognized names; this corpus checks operand classes, byte consumption,
// unsupported execution faults and related ignored ModRM bits independently.
// https://cdrdv2-public.intel.com/922485/334569-092-sdm-vol-2d.pdf
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86SystemGroupDecodeTests {
  private let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]

  @Test func all256Group7ModRMBytesKeepTheirArchitecturalOperandClassAndLength() throws {
    for mode in modes {
      for modRM in UInt8.min...UInt8.max {
        let bytes = groupBytes(opcode: 1, modRM: modRM, mode: mode)
        if modRM == 0xF8, mode != .long64 {
          #expect(throws: DoryX86DecodeError.self) {
            try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
          }
          continue
        }
        let decoded = try DoryX86Decoder().decode(bytes + [0x90], at: 0x100, mode: mode)
        #expect(decoded.length == bytes.count)
        if modRM < 0xC0 {
          let group = (modRM >> 3) & 7
          switch (group, decoded.operation) {
          case (0, .descriptorTable(.global, false, _)), (1, .descriptorTable(.interrupt, false, _)),
            (2, .descriptorTable(.global, true, _)), (3, .descriptorTable(.interrupt, true, _)),
            (5, .undefinedInstruction), (7, .invalidatePage):
            break
          case (4, .machineStatusWord(false, .memory(let operand))),
            (6, .machineStatusWord(true, .memory(let operand))):
            #expect(operand.width == .word)
            #expect(operand.addressWidth == addressWidth(mode))
          default:
            Issue.record("0F01 memory group \(group) changed operand class: \(decoded.operation)")
          }
        } else if (0xE0...0xE7).contains(modRM) || (0xF0...0xF7).contains(modRM) {
          guard case .machineStatusWord(let load, .register(let register, let width)) = decoded.operation else {
            Issue.record("SMSW/LMSW register form lost its register operand")
            continue
          }
          #expect(load == (modRM >= 0xF0))
          #expect(register == DoryX86GeneralRegister.allCases[Int(modRM & 7)])
          #expect(width == (load || mode == .real16 || mode == .protected16 ? .word : .doubleword))
        } else {
          switch (modRM, decoded.operation) {
          case (0xC1, .vmCall), (0xD0, .readExtendedControlRegister),
            (0xD1, .writeExtendedControlRegister), (0xF8, .swapGS),
            (0xF9, .readTimestampCounter(true)):
            break
          case (_, .undefinedInstruction), (_, .unsupportedSystemInstruction):
            break
          default:
            Issue.record("Fixed 0F01 register byte aliased a successful unrelated operation")
          }
        }
      }
    }
  }

  @Test func unsupportedGroup7FormsRaiseUDAtBothPrivilegeLevelsWithoutOperandAccess() throws {
    // The compatible candidate does not expose XSAVE/RDTSCP/VMX/SVM or any of
    // the other fixed encodings below. Only SMSW/LMSW/SWAPGS escape this set.
    for mode in modes {
      for modRM in UInt8.min...UInt8.max {
        let isUnsupportedMemory = modRM < 0xC0 && (modRM >> 3) & 7 == 5
        let isUnsupportedRegister = modRM >= 0xC0
          && !(0xE0...0xE7).contains(modRM) && !(0xF0...0xF7).contains(modRM)
          && (modRM != 0xF8 || mode != .long64)
        guard isUnsupportedMemory || isUnsupportedRegister else { continue }
        for cpl: UInt16 in [0, 3] {
          try expectUD(groupBytes(opcode: 1, modRM: modRM, mode: mode), mode: mode, cpl: cpl)
        }
      }
    }
  }

  @Test func lockPrefixRejectsEveryGroup6And7ModRMAtBothPrivilegeLevels() throws {
    for opcode: UInt8 in [0, 1] {
      for modRM in UInt8.min...UInt8.max {
        let bytes = [UInt8(0xF0)] + groupBytes(opcode: opcode, modRM: modRM, mode: .long64)
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode(bytes, at: 0x100, mode: .long64)
        }
        for cpl: UInt16 in [0, 3] { try expectUD(bytes, mode: .long64, cpl: cpl) }
      }
    }
  }

  @Test func allMOVCRAndDRModRMBitsIgnoreMemoryAddressingAndConsumeOnlyOneByte() throws {
    for mode in modes {
      for opcode: UInt8 in [0x20, 0x21, 0x22, 0x23] {
        for modRM in UInt8.min...UInt8.max {
          let index = (modRM >> 3) & 7
          let debug = opcode & 1 != 0
          let bytes: [UInt8] = [0x0F, opcode, modRM]
          if !debug && ![0, 2, 3, 4].contains(index) {
            #expect(throws: DoryX86DecodeError.self) {
              try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
            }
          } else {
            // No SIB/displacement exists even when MOD/RM would normally demand one.
            let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
            #expect(decoded.length == 3)
            let register = DoryX86GeneralRegister.allCases[Int(modRM & 7)]
            #expect(decoded.operation == movOperation(opcode: opcode, index: index, register: register))
            let withSuffix = try DoryX86Decoder().decode(bytes + [0x25, 0x12, 0x34, 0x56, 0x78],
              at: 0x100, mode: mode)
            #expect(withSuffix == decoded)
          }
        }
      }
    }
  }

  @Test func MOVSystemRegisterREXExtensionsAndReservedNumbersMatchUDRules() throws {
    for rex: UInt8 in [0x40, 0x41, 0x44, 0x45, 0x48, 0x4C] {
      for opcode: UInt8 in [0x20, 0x21, 0x22, 0x23] {
        for modRM in UInt8.min...UInt8.max {
          let debug = opcode & 1 != 0
          let index = ((modRM >> 3) & 7) | (rex & 4 != 0 ? 8 : 0)
          let valid = debug ? index < 8 : [0, 2, 3, 4, 8].contains(index)
          let bytes = [rex, 0x0F, opcode, modRM]
          if valid {
            let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: .long64)
            #expect(decoded.length == 4)
            let register = DoryX86GeneralRegister.allCases[Int(modRM & 7) + (rex & 1 != 0 ? 8 : 0)]
            #expect(decoded.operation == movOperation(opcode: opcode, index: index, register: register))
          } else {
            #expect(throws: DoryX86DecodeError.self) {
              try DoryX86Decoder().decode(bytes, at: 0x100, mode: .long64)
            }
            for cpl: UInt16 in [0, 3] { try expectUD(bytes, mode: .long64, cpl: cpl) }
          }
        }
      }
    }
  }

  @Test func group6StoresUseRegisterOperandSizeButEveryMemoryAndLoadIs16Bits() throws {
    for mode in modes {
      for prefix: [UInt8] in [[], [0x66]] + (mode == .long64 ? [[0x48], [0x49]] : []) {
        let defaultWord = mode == .real16 || mode == .protected16
        let registerWidth: DoryX86OperandWidth = prefix.first == 0x48 || prefix.first == 0x49
          ? .quadword : ((prefix.first == 0x66) == defaultWord ? .doubleword : .word)
        for modRM in UInt8.min...UInt8.max {
          let group = (modRM >> 3) & 7
          let bytes = prefix + groupBytes(opcode: 0, modRM: modRM, mode: mode)
          if group >= 6 {
            #expect(throws: DoryX86DecodeError.self) {
              try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
            }
            continue
          }
          let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
          #expect(decoded.length == bytes.count)
          let operand: DoryX86Operand
          switch decoded.operation {
          case .storeSystemSegment(let task, let value):
            #expect(group == (task ? 1 : 0)); operand = value
          case .loadSystemSegment(let task, let value):
            #expect(group == (task ? 3 : 2)); operand = value
          case .verifySegment(let readable, let value):
            #expect(group == (readable ? 4 : 5)); operand = value
          default:
            Issue.record("0F00 form changed class"); continue
          }
          if case .register(_, let actualWidth) = operand {
            #expect(actualWidth == (group < 2 ? registerWidth : .word))
          } else if case .memory(let memory) = operand {
            #expect(memory.width == .word)
          }
        }
      }
    }
  }

  private func movOperation(opcode: UInt8, index: UInt8,
    register: DoryX86GeneralRegister) -> DoryX86InstructionOperation {
    switch opcode {
    case 0x20: .readControlRegister(index: index, destination: register)
    case 0x21: .readDebugRegister(index: index, destination: register)
    case 0x22: .writeControlRegister(index: index, source: register)
    default: .writeDebugRegister(index: index, source: register)
    }
  }

  private func groupBytes(opcode: UInt8, modRM: UInt8, mode: DoryX86ExecutionMode) -> [UInt8] {
    var bytes: [UInt8] = [0x0F, opcode, modRM]
    let mod = modRM >> 6
    let rm = modRM & 7
    guard mod != 3 else { return bytes }
    let is16 = addressWidth(mode) == .word
    if !is16, rm == 4 { bytes.append(0x24) } // [RSP/ESP], no index or implicit displacement.
    if mod == 0, (is16 && rm == 6) || (!is16 && rm == 5) {
      bytes += is16 ? [0x00, 0x40] : [0x00, 0x40, 0x00, 0x00]
    } else if mod == 1 { bytes.append(0x7F) }
    else if mod == 2 { bytes += is16 ? [0x00, 0x40] : [0x00, 0x40, 0x00, 0x00] }
    return bytes
  }

  private func addressWidth(_ mode: DoryX86ExecutionMode) -> DoryX86OperandWidth {
    mode == .long64 ? .quadword : (mode == .protected32 ? .doubleword : .word)
  }

  private func expectUD(_ bytes: [UInt8], mode: DoryX86ExecutionMode, cpl: UInt16) throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
    try memory.write(at: 0x100, bytes: bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xFFFF_FFFF, rcx: 0xFFFF_FFFF, rdx: 0xFFFF_FFFF,
        rbx: 0xFFFF_FFFF, rsp: 0xFFFF_FFFF, rbp: 0xFFFF_FFFF, rsi: 0xFFFF_FFFF, rdi: 0xFFFF_FFFF),
      rip: 0x100, cs: .init(selector: cpl, attributes: 0x009B, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11))
    let before = state
    let originalMemory = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
      == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x100)))
    #expect(state == before)
    #expect(memory.snapshot() == originalMemory)
  }
}
