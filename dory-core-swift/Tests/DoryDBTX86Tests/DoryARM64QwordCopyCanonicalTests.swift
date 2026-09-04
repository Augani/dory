import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64QwordCopyCanonicalTests {
  private let loopAddress: UInt64 = 0x1000
  private let loop: [UInt8] = [
    0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
    0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
    0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
  ]

  @Test func sourceSpanCrossingCanonicalBoundaryDeclinesBothTiersBeforeBulkAccess() throws {
    #if arch(arm64)
      try verifyCanonicalBoundaryDecline(
        source: 0x0000_7fff_ffff_fff8,
        destination: 0x4000
      )
    #endif
  }

  @Test func destinationSpanCrossingCanonicalBoundaryDeclinesBothTiersBeforeBulkAccess() throws {
    #if arch(arm64)
      try verifyCanonicalBoundaryDecline(
        source: 0x4000,
        destination: 0x0000_7fff_ffff_fff8
      )
    #endif
  }

  @Test func canonicalSourceAndDestinationSpansRemainAcceleratedInBothTiers() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let source: UInt64 = 0x3000
        let destination: UInt64 = 0x4000
        let payload = Array(UInt8(0x10)...UInt8(0x1f))
        let memory = PermissiveQwordBulkMemory()
        memory.install(payload, at: source)
        memory.install(Array(repeating: 0, count: payload.count), at: destination)
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        )
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0, rcx: 0x55, rdx: 16, rsi: source, rdi: destination),
          rip: loopAddress,
          rflags: [.reservedOne, .overflow, .zero, .interruptEnable]
        )

        let summary = try #require(
          executor.executeChainedSummary(
            byteProvider: loopBytes,
            at: loopAddress,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 14,
            state: &state,
            memory: memory
          ))

        #expect(summary.guestInstructionCount == 14)
        #expect(summary.residentBlockCount == 4)
        #expect(summary.tier == (optimization == .baseline ? .baseline : .optimizing))
        #expect(summary.exitCode == .dispatch)
        #expect(memory.bulkRequests == [.init(source: source, destination: destination, count: 2)])
        #expect(memory.bytes(at: destination, count: payload.count) == payload)
        #expect(state.registers.rax == 16)
        #expect(state.registers.rcx == 0)
        #expect(state.rip == loopAddress + UInt64(loop.count))
      }
    #endif
  }

  #if arch(arm64)
    private func verifyCanonicalBoundaryDecline(source: UInt64, destination: UInt64) throws {
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let payload = Array(UInt8(0x20)...UInt8(0x2f))
        let memory = PermissiveQwordBulkMemory()
        memory.install(payload, at: source)
        memory.install(Array(repeating: 0, count: payload.count), at: destination)
        let destinationBefore = memory.bytes(at: destination, count: payload.count)
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        )
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: 0, rcx: 0x55, rdx: 16, rsi: source, rdi: destination),
          rip: loopAddress,
          rflags: [.reservedOne, .carry, .interruptEnable]
        )
        var state = initial

        let summary = try executor.executeChainedSummary(
          byteProvider: loopBytes,
          at: loopAddress,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 14,
          state: &state,
          memory: memory
        )

        #expect(summary == nil)
        #expect(memory.bulkRequests.isEmpty)
        #expect(memory.dataReads.isEmpty)
        #expect(memory.dataWrites.isEmpty)
        #expect(memory.bytes(at: destination, count: payload.count) == destinationBefore)
        #expect(state == initial)
        #expect(executor.diagnostics.chainedRetiredInstructions == 0)
      }
    }

    private func loopBytes(_ address: UInt64, _ maximumCount: Int) -> [UInt8] {
      guard address >= loopAddress else { return [] }
      let offset = Int(address - loopAddress)
      guard loop.indices.contains(offset) else { return [] }
      return Array(loop[offset..<min(loop.count, offset + maximumCount)])
    }
  #endif
}

private struct QwordBulkRequest: Equatable {
  let source: UInt64
  let destination: UInt64
  let count: Int
}

private final class PermissiveQwordBulkMemory: DoryX86BulkMemory, @unchecked Sendable {
  private var storage: [UInt64: UInt8] = [:]
  private(set) var bulkRequests: [QwordBulkRequest] = []
  private(set) var dataReads: [UInt64] = []
  private(set) var dataWrites: [UInt64] = []

  func install(_ bytes: [UInt8], at address: UInt64) {
    for (offset, byte) in bytes.enumerated() {
      storage[address &+ UInt64(offset)] = byte
    }
  }

  func bytes(at address: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { storage[address &+ UInt64($0)] ?? 0 }
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(
      address: address,
      byteCount: maximumCount,
      access: .instructionFetch
    )
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    let result = try checkedBytes(at: address, byteCount: byteCount, access: .read)
    dataReads.append(contentsOf: (0..<byteCount).map { address &+ UInt64($0) })
    return result
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    _ = try checkedBytes(at: address, byteCount: byteCount, access: .read)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    _ = try checkedBytes(at: address, byteCount: byteCount, access: .write)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
    for (offset, byte) in bytes.enumerated() {
      let target = address &+ UInt64(offset)
      storage[target] = byte
      dataWrites.append(target)
    }
  }

  func synchronize() {}

  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    maximumByteCount
  }

  func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    nil
  }

  func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    guard elementByteCount == 8 else { return nil }
    bulkRequests.append(
      .init(
        source: sourceAddress,
        destination: destinationAddress,
        count: maximumElementCount
      ))
    let byteCount = elementByteCount * maximumElementCount
    let bytes = try read(at: sourceAddress, byteCount: byteCount)
    try write(at: destinationAddress, bytes: bytes)
    return maximumElementCount
  }

  private func checkedBytes(
    at address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind
  ) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    for offset in 0..<byteCount {
      let target = address &+ UInt64(offset)
      guard let byte = storage[target] else {
        throw DoryX86MemoryError.unmapped(
          address: target,
          byteCount: byteCount - offset,
          access: access
        )
      }
      result.append(byte)
    }
    return result
  }
}
