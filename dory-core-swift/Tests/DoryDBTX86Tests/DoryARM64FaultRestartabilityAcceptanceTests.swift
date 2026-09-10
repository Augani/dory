import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64FaultRestartabilityAcceptanceTests {
  enum FaultPoint: CaseIterable, CustomStringConvertible {
    case rmwRead
    case rmwWrite
    case crossPageRead
    case mmioReadDecline

    var description: String {
      switch self {
      case .rmwRead: "RMW read fault"
      case .rmwWrite: "RMW write fault"
      case .crossPageRead: "cross-page RMW read"
      case .mmioReadDecline: "MMIO restartability decline"
      }
    }
  }

  @Test(arguments: FaultPoint.allCases, [
    DoryARM64JITOptimization.baseline,
    .optimizing,
  ])
  func failedRMWRetiresOnlyTheSafePrefix(
    faultPoint: FaultPoint,
    optimization: DoryARM64JITOptimization
  ) throws {
    #if arch(arm64)
      // INC RCX; INC qword ptr [RBX]. The first instruction is the recoverable prefix.
      let bytes: [UInt8] = [0x48, 0xFF, 0xC1, 0x48, 0xFF, 0x03]
      let dataAddress: UInt64 = faultPoint == .crossPageRead ? 0xFC : 0x80
      let memory = try FaultPointMemory(byteCount: 0x100, faultPoint: faultPoint)
      if faultPoint != .crossPageRead {
        try memory.backing.writeScalar(at: dataAddress, value: 5, byteCount: 8)
      }
      let beforeMemory = try memory.backing.read(at: 0, byteCount: 0x100)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        optimization: optimization
      )
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xAAAA, rcx: 0, rbx: dataAddress),
        rip: 0x1000,
        rflags: [.reservedOne, .carry, .direction, .overflow],
        cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
      )

      let summary = try #require(executor.executeChainedSummary(
        byteProvider: { address, maximumCount in
          guard address >= 0x1000, address - 0x1000 < UInt64(bytes.count) else { return [] }
          return Array(bytes[Int(address - 0x1000)...].prefix(maximumCount))
        },
        at: state.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &state,
        memory: memory
      ))

      #expect(summary.guestInstructionCount == 1)
      #expect(summary.residentBlockCount == 1)
      #expect(summary.exitCode == .dispatch)
      #expect(state.rip == 0x1003)
      #expect(state.registers.rcx == 1)
      #expect(state.registers.rax == 0xAAAA)
      #expect(state.registers.rbx == dataAddress)
      #expect(try memory.backing.read(at: 0, byteCount: 0x100) == beforeMemory)
      #expect(memory.restartableReadAttempts == 1)
      #expect(memory.ordinaryScalarReads == 0)
      #expect(memory.writeAttempts == (faultPoint == .rmwWrite ? 1 : 0))
    #endif
  }
}

private final class FaultPointMemory: DoryX86ScalarMemory, DoryX86RestartableScalarMemory,
  @unchecked Sendable
{
  let backing: DoryX86ByteArrayMemory
  let faultPoint: DoryARM64FaultRestartabilityAcceptanceTests.FaultPoint
  private(set) var restartableReadAttempts = 0
  private(set) var ordinaryScalarReads = 0
  private(set) var writeAttempts = 0

  init(
    byteCount: Int,
    faultPoint: DoryARM64FaultRestartabilityAcceptanceTests.FaultPoint
  ) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: byteCount)
    self.faultPoint = faultPoint
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() {
    backing.synchronize()
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    ordinaryScalarReads += 1
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    restartableReadAttempts += 1
    switch faultPoint {
    case .rmwRead:
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
    case .mmioReadDecline:
      return nil
    case .rmwWrite, .crossPageRead:
      return try backing.readScalar(at: address, byteCount: byteCount)
    }
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    writeAttempts += 1
    if faultPoint == .rmwWrite {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 3)
    }
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }
}
