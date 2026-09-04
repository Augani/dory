import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86DifferentialIsolationTests {
  private func state() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rbx: 0x1080), rip: 0x1000,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max))
  }

  @Test func readModifyWriteUsesIndependentMemoryAndLeavesSourceUntouched() throws {
    #if arch(arm64)
      // mov rax,[rbx]; add rax,1; mov [rbx],rax
      let bytes: [UInt8] = [0x48, 0x8B, 0x03, 0x48, 0x83, 0xC0, 0x01, 0x48, 0x89, 0x03]
      let source = try DoryX86ByteArrayMemory(baseAddress: 0x1000, validatingByteCount: 256)
      try source.write(at: 0x1000, bytes: bytes)
      try source.writeScalar(at: 0x1080, value: 0x41, byteCount: 8)
      let before = source.snapshot()
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: state(), memory: source, mode: .long64)
      #expect(result.agrees)
      #expect(result.jitState.registers.rax == 0x42)
      #expect(result.interpreterMemory.memory[0x80] == 0x42)
      #expect(result.jitMemory.memory[0x80] == 0x42)
      #expect(source.snapshot() == before)
    #endif
  }

  @Test func deviceReadsStartFromIndependentIdenticalState() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x8B, 0x03]
      let source = try DifferentialDeviceMemory(instructions: bytes)
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: state(), memory: source, mode: .long64)
      #expect(result.agrees)
      #expect(result.interpreterState.registers.rax == 7)
      #expect(result.jitState.registers.rax == 7)
      #expect(result.interpreterMemory.devices == [8])
      #expect(result.jitMemory.devices == [8])
      #expect(try source.differentialState().devices == [7])
    #endif
  }

  @Test func sharedCopiesAndUnknownMemoryCannotProduceAgreement() throws {
    let source = try DifferentialDeviceMemory(instructions: [0x90], cloneBehavior: .reuseSelf)
    #expect(throws: DoryX86DifferentialError.sharedMemoryInstance) {
      try DoryX86DifferentialHarness().compare(
        bytes: [0x90], initialState: state(), memory: source, mode: .long64)
    }
    let unknown = DifferentialUnknownMemory()
    #expect(throws: DoryX86DifferentialError.memoryDoesNotSupportIndependentCopies) {
      try DoryX86DifferentialHarness().compare(
        bytes: [0x90], initialState: state(), memory: unknown, mode: .long64)
    }
  }

  @Test func unequalDeviceInitialStateRejectsBeforeExecutingEitherEngine() throws {
    let source = try DifferentialDeviceMemory(instructions: [0x90], cloneBehavior: .changeDevice)
    #expect(throws: DoryX86DifferentialError.unequalInitialMemoryState) {
      try DoryX86DifferentialHarness().compare(
        bytes: [0x90], initialState: state(), memory: source, mode: .long64)
    }
    #expect(try source.differentialState().devices == [7])
  }

  @Test func distinctWrappersSharingBackingCannotProduceAgreement() throws {
    #if arch(arm64)
      // An idempotent store can appear to agree if snapshots are deferred until
      // after both engines have written the same shared RAM.
      let bytes: [UInt8] = [0x48, 0x89, 0x03]
      for sharesOriginal in [false, true] {
        let source = try DifferentialShallowMemory(instructions: bytes, sharesOriginal: sharesOriginal)
        var initial = try state()
        initial.registers.rax = 0x42
        #expect(throws: DoryX86DifferentialError.sharedMemoryBacking) {
          try DoryX86DifferentialHarness().compare(
            bytes: bytes, initialState: initial, memory: source, mode: .long64)
        }
      }
    #endif
  }

  @Test func comparedProgramMustMatchTheInterpreterInstructionSource() throws {
    #if arch(arm64)
      let source = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x90])
      #expect(throws: DoryX86DifferentialError.instructionBytesDoNotMatchMemory) {
        try DoryX86DifferentialHarness().compare(
          bytes: [0xF4], initialState: state(), memory: source, mode: .long64)
      }
    #endif
  }

  @Test func permissionFaultRetainsPreciseEvidenceAndDoesNotCountFallbackAsAgreement() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x89, 0x03]  // mov [rbx],rax
      let source = try DifferentialDeviceMemory(instructions: bytes, rejectWrites: true)
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: state(), memory: source, mode: .long64)
      let expected = DoryX86MemoryError.pageFault(address: 0x1080, errorCode: 7)
      #expect(result.interpreterMemoryFault == expected)
      #expect(result.jitMemoryFault == expected)
      #expect(
        result.interpreterResult
          == .exception(
            .init(
              kind: .pageFault, vector: 14, errorCode: 7,
              instructionPointer: 0x1000, linearAddress: 0x1080)))
      #expect(result.interpreterState.control.cr2 == 0x1080)
      #expect(result.jitExit == .interpreter)
      #expect(!result.agrees)
      #expect(result.interpreterMemory == result.jitMemory)
      #expect(try source.differentialState() == result.interpreterMemory)
    #endif
  }

  @Test func agreementIncludesExtendedStateMemoryDevicesAndExit() throws {
    #if arch(arm64)
      let source = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x90])
      let result = try DoryX86DifferentialHarness().compare(
        bytes: [0x90], initialState: state(), memory: source, mode: .long64)
      #expect(result.agrees)
      func replacing(
        state: DoryX86ArchitecturalState? = nil,
        memory: DoryX86DifferentialMemoryState? = nil,
        exit: DoryJITExitCode? = nil
      ) -> DoryX86DifferentialResult {
        .init(
          block: result.block, compiled: result.compiled,
          interpreterState: result.interpreterState, jitState: state ?? result.jitState,
          interpreterResult: result.interpreterResult,
          interpreterRetiredInstructionCount: result.interpreterRetiredInstructionCount,
          interpreterMemory: result.interpreterMemory, jitMemory: memory ?? result.jitMemory,
          interpreterMemoryFault: result.interpreterMemoryFault,
          jitMemoryFault: result.jitMemoryFault, jitExit: exit ?? result.jitExit)
      }
      let perturbations: [(inout DoryX86ArchitecturalState) -> Void] = [
        { $0.control.cr2 = 1 }, { $0.debug.dr0 = 1 }, { $0.fs.base = 1 },
        { $0.gdtr.base = 1 }, { $0.modelSpecific.fsBase = 1 },
        { $0.floatingPoint.mxcsr ^= 1 }, { $0.tsc = 1 }, { $0.tscAux = 1 },
      ]
      for perturb in perturbations {
        var changed = result.jitState
        perturb(&changed)
        #expect(!replacing(state: changed).agrees)
      }
      #expect(!replacing(memory: .init(memory: [0xF4])).agrees)
      #expect(!replacing(memory: .init(memory: [0x90], devices: [1])).agrees)
      #expect(!replacing(exit: .interpreter).agrees)
      #expect(!replacing(exit: .halt).agrees)
    #endif
  }

  @Test func guardedNativeFallbackDoesNotPublishScratchRegisterChanges() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x83, 0xC3, 1, 0xFF, 0xE0]  // add rbx,1; jmp rax
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      var initial = try state()
      initial.registers.rax = 0x0000_8000_0000_0000
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: initial, memory: memory, mode: .long64)
      #expect(result.jitExit == .interpreter)
      #expect(result.jitState == initial)
      #expect(result.interpreterState.registers.rbx == initial.registers.rbx + 1)
      #expect(!result.agrees)
    #endif
  }
}

/// A small explicitly clonable MMIO fixture. Its read counter represents device state that must
/// neither leak between engines nor disappear from the comparison.
private final class DifferentialDeviceMemory: DoryX86DifferentialMemory, @unchecked Sendable {
  enum CloneBehavior { case independent, reuseSelf, changeDevice }
  private let ram: DoryX86ByteArrayMemory
  private let lock = NSLock()
  private var counter: UInt8 = 7
  private let cloneBehavior: CloneBehavior
  private let rejectWrites: Bool

  init(
    instructions: [UInt8], cloneBehavior: CloneBehavior = .independent, rejectWrites: Bool = false
  ) throws {
    ram = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: instructions + Array(repeating: 0, count: 256 - instructions.count))
    self.cloneBehavior = cloneBehavior
    self.rejectWrites = rejectWrites
  }

  func makeDifferentialCopy() throws -> any DoryX86DifferentialMemory {
    if cloneBehavior == .reuseSelf { return self }
    return try lock.withLock {
      let copy = try DifferentialDeviceMemory(instructions: ram.snapshot(), rejectWrites: rejectWrites)
      copy.counter = cloneBehavior == .changeDevice ? counter &+ 1 : counter
      return copy
    }
  }

  func differentialState() throws -> DoryX86DifferentialMemoryState {
    lock.withLock { .init(memory: ram.snapshot(), devices: [counter]) }
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try ram.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address == 0x1080, byteCount == 8 {
      return lock.withLock {
        let value = counter
        counter &+= 1
        return [value] + Array(repeating: 0, count: 7)
      }
    }
    return try ram.read(at: address, byteCount: byteCount)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    if rejectWrites, address == 0x1080 {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 7)
    }
    try ram.validateWrite(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
    try ram.write(at: address, bytes: bytes)
  }
}

private final class DifferentialUnknownMemory: DoryX86Memory, @unchecked Sendable {
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] { [0x90] }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] { [] }
  func write(at address: UInt64, bytes: [UInt8]) throws {}
}

private final class DifferentialShallowMemory: DoryX86DifferentialMemory, @unchecked Sendable {
  private let ram: DoryX86ByteArrayMemory
  private let cloneRAM: DoryX86ByteArrayMemory

  init(instructions: [UInt8], sharesOriginal: Bool) throws {
    let bytes = instructions + Array(repeating: UInt8(0), count: 256 - instructions.count)
    ram = try .init(baseAddress: 0x1000, bytes: bytes)
    if sharesOriginal {
      cloneRAM = ram
    } else {
      cloneRAM = try .init(baseAddress: 0x1000, bytes: bytes)
    }
  }

  private init(ram: DoryX86ByteArrayMemory) {
    self.ram = ram
    cloneRAM = ram
  }

  func makeDifferentialCopy() throws -> any DoryX86DifferentialMemory {
    DifferentialShallowMemory(ram: cloneRAM)
  }

  func differentialState() throws -> DoryX86DifferentialMemoryState {
    .init(memory: ram.snapshot())
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try ram.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try ram.read(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws { try ram.write(at: address, bytes: bytes) }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try ram.validateWrite(at: address, byteCount: byteCount)
  }
}
