import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCJITMetadataFaultTests {
  @Test func revokingCachedCodeReturnsArchitecturalFaultAndNeverReplaysCompletedStores() throws {
    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024,
        executionTier: tier, baselineJITMaximumCodeBytes: 64 * 1024,
        optimizingJITWarmupDispatches: 0)
      var code = [UInt8](repeating: 0x90, count: 0x110)
      let setup: [UInt8] = [
        0xB8, 0x10, 0, 0, 0, 0x0F, 0x22, 0xE0, // CR4.PSE
        0xB8, 0, 0, 0x08, 0, 0x0F, 0x22, 0xD8, // CR3=0x80000
        0xB8, 0x11, 0, 0, 0x80, 0x0F, 0x22, 0xC0, // CR0.PG|PE|ET
        0xBE, 0x80, 0, 0x10, 0, // ESI=return address0x100080
        0xBF, 0, 0x01, 0x50, 0, // EDI=cached target0x500100
        0xB8, 0, 0, 0x08, 0, // EAX=CR3 root for subsequent flush
        0xFF, 0xE7, // JMP EDI
      ]
      code.replaceSubrange(0..<setup.count, with: setup)
      let resume: [UInt8] = [
        0x0F, 0x22, 0xD8, // Reload CR3 to observe the revoked PDE.
        0xFF, 0x05, 0x30, 0, 0x18, 0, // INC dword [0x180030], must commit exactly once.
        0xFF, 0xC1, // INC ECX
        0xFF, 0xE7, // JMP EDI
      ]
      code.replaceSubrange(0x80..<(0x80 + resume.count), with: resume)
      let target: [UInt8] = [
        0xFF, 0x05, 0, 0, 0x18, 0, // INC dword [0x180000]
        0xFF, 0xC3, // INC EBX
        0xFF, 0xE6, // JMP ESI
      ]
      code.replaceSubrange(0x100..<(0x100 + target.count), with: target)
      try machine.load(kernel: makeELF(code), commandLine: "x")
      // Two 4 MiB linear ranges initially alias the same low physical memory.
      try write32(0x83, to: machine, at: 0x80000)
      try write32(0x83, to: machine, at: 0x80004)
      #expect(try machine.run(maximumInstructions: 13) == .instructionBudget(13))
      let warmed = try #require(machine.state)
      #expect(warmed.rip == 0x100080)
      #expect(try read32(machine, at: 0x180000) == 1)
      let originalRBX = warmed.registers.rbx
      try write32(0, to: machine, at: 0x80004)

      // Previously, the positive JIT generation probe threw to the host from this run.
      for attempt in 0..<2 {
        let stop = try machine.run(maximumInstructions: 16)
        guard case .exception(let exception, let completed) = stop else {
          Issue.record("Expected precise revoked-code page fault, got \(stop)")
          continue
        }
        #expect(exception.kind == .pageFault)
        #expect(exception.instructionPointer == 0x500100)
        #expect(exception.linearAddress == 0x500100)
        #expect(exception.errorCode == 0) // Legacy paging, supervisor instruction fetch.
        #expect(completed == (attempt == 0 ? 4 : 0))
        let state = try #require(machine.state)
        #expect(state.rip == 0x500100)
        #expect(state.control.cr2 == 0x500100)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rbx == originalRBX)
        #expect(try read32(machine, at: 0x180030) == 1)
        #expect(try read32(machine, at: 0x180000) == 1)
      }

      // Restoring the missing mapping lets the same architectural instruction resume.
      try write32(0x83, to: machine, at: 0x80004)
      #expect(try machine.run(maximumInstructions: 3) == .instructionBudget(3))
      let resumed = try #require(machine.state)
      #expect(resumed.rip == 0x100080)
      #expect(resumed.registers.rbx == originalRBX + 1)
      #expect(resumed.registers.rcx == 1)
      #expect(try read32(machine, at: 0x180030) == 1)
      #expect(try read32(machine, at: 0x180000) == 2)
      let statistics = machine.executionStatistics
      if tier == .baselineJIT { #expect(statistics.baselineJITInstructions > 0) }
      if tier == .optimizingJIT { #expect(statistics.optimizingJITInstructions > 0) }
    }
  }

  private var tiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private func write32(_ value: UInt32, to machine: DoryPCDirectKernelMachine, at address: UInt64) throws {
    try machine.memory.write(at: address,
      bytes: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  private func read32(_ machine: DoryPCDirectKernelMachine, at address: UInt64) throws -> UInt32 {
    try machine.memory.read(at: address, byteCount: 4).enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << ($1.offset * 8)
    }
  }

  private func makeELF(_ code: [UInt8]) -> Data {
    var data = Data(repeating: 0, count: 0x200 + code.count)
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    put(UInt16(2), into: &data, at: 16)
    put(UInt16(0x3E), into: &data, at: 18)
    put(UInt32(1), into: &data, at: 20)
    put(UInt64(0x40), into: &data, at: 32)
    put(UInt16(64), into: &data, at: 52)
    put(UInt16(56), into: &data, at: 54)
    put(UInt16(2), into: &data, at: 56)
    put(UInt32(1), into: &data, at: 0x40)
    put(UInt32(5), into: &data, at: 0x44)
    put(UInt64(0x200), into: &data, at: 0x48)
    put(UInt64(0x100000), into: &data, at: 0x50)
    put(UInt64(0x100000), into: &data, at: 0x58)
    put(UInt64(code.count), into: &data, at: 0x60)
    put(UInt64(code.count), into: &data, at: 0x68)
    put(UInt32(4), into: &data, at: 0x78)
    put(UInt64(0x180), into: &data, at: 0x80)
    put(UInt64(20), into: &data, at: 0x98)
    put(UInt64(20), into: &data, at: 0xA0)
    put(UInt32(4), into: &data, at: 0x180)
    put(UInt32(4), into: &data, at: 0x184)
    put(UInt32(0x12), into: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    put(UInt32(0x100000), into: &data, at: 0x190)
    data.replaceSubrange(0x200..<data.count, with: code)
    return data
  }

  private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
    }
  }
}
