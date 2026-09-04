import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86ReplayTests {
  @Test func capturesSerializesAndReplaysMemoryAndPortIOExactly() throws {
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0xE4, 0x60] + .init(repeating: 0, count: 16)
    )
    let bus = ConstantReplayBus(value: 0xAB)
    let state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x1234),
      rip: 0x1000,
      cs: .init(selector: 0, attributes: 0xC09A, limit: .max)
    )
    let recorder = DoryX86ReplayRecorder()
    let record = recorder.recordStep(
      initialState: state,
      memory: memory,
      mode: .protected32,
      ioBus: bus
    )

    #expect(record.finalState.registers.rax == 0x12AB)
    #expect(record.ioEvents == [.read(port: 0x60, width: .byte, outcome: .value(0xAB))])
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(DoryX86ReplayRecord.self, from: data)
    #expect(decoded == record)
    try recorder.replay(decoded)
  }

  @Test func replaysPreciseFaultsWithoutAccessingOriginalMemory() throws {
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x2000,
      bytes: [0x48, 0x8B, 0x00] + .init(repeating: 0, count: 8)
    )
    let state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xDEAD_0000),
      rip: 0x2000,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max)
    )
    let recorder = DoryX86ReplayRecorder()
    let record = recorder.recordStep(
      initialState: state,
      memory: memory,
      mode: .long64
    )

    guard case .exception(let exception) = record.result else {
      Issue.record("expected recorded page fault")
      return
    }
    #expect(exception.kind == .pageFault)
    try recorder.replay(record)
  }

  @Test func reconstructsPagingConfigurationAndReplaysPageTableWalks() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0000
    try installFourLevelMapping(linear: linear, physicalPage: 0x8000, memory: memory)
    try memory.write(at: 0x8000, bytes: [0x90])
    let state = try DoryX86ArchitecturalState(
      rip: linear,
      cs: .init(selector: 0, attributes: 0xA09A, limit: .max),
      control: .init(
        cr0: 0x8001_0011,
        cr3: 0x1000,
        cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)
      )
    )
    let recorder = DoryX86ReplayRecorder()
    let record = recorder.recordStep(
      initialState: state,
      memory: memory,
      mode: .long64,
      pagingUnit: .init(physicalAddressBits: 48, maximumEntryCount: 64)
    )

    #expect(record.pagingPhysicalAddressBits == 48)
    #expect(record.pagingMaximumEntryCount == 64)
    #expect(record.finalState.rip == linear + 1)
    try recorder.replay(record)
  }

  private func installFourLevelMapping(
    linear: UInt64,
    physicalPage: UInt64,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let indices = [linear >> 39, linear >> 30, linear >> 21, linear >> 12].map { $0 & 0x1FF }
    try write64(memory, at: 0x1000 + indices[0] * 8, value: 0x2007)
    try write64(memory, at: 0x2000 + indices[1] * 8, value: 0x3007)
    try write64(memory, at: 0x3000 + indices[2] * 8, value: 0x4007)
    try write64(memory, at: 0x4000 + indices[3] * 8, value: physicalPage | 0x7)
  }

  private func write64(
    _ memory: DoryX86ByteArrayMemory,
    at address: UInt64,
    value: UInt64
  ) throws {
    try memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    )
  }
}

private final class ConstantReplayBus: DoryX86IOBus, @unchecked Sendable {
  let value: UInt32
  init(value: UInt32) { self.value = value }
  func read(port: UInt16, width: DoryX86OperandWidth) -> UInt32 { value }
  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) {}
}
