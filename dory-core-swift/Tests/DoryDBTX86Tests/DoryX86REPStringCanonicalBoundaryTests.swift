import Testing

@testable import DoryDBTX86

@Suite struct DoryX86REPStringCanonicalBoundaryTests {
  private let interpreter = DoryX86Interpreter()
  private let rip: UInt64 = 0x1000
  private let lastLowCanonical: UInt64 = 0x0000_7fff_ffff_ffff
  private let firstNoncanonical: UInt64 = 0x0000_8000_0000_0000

  @Test func bulkMOVSBDeclinesSourceSpanAtCanonicalBoundaryAndCommitsOnlyValidPrefix() throws {
    let memory = SparseStringBulkMemory()
    memory.install([0xF3, 0xA4], at: rip)  // REP MOVSB
    memory.install([0x5A], at: lastLowCanonical)
    memory.install([0xA5], at: firstNoncanonical)
    memory.install([0, 0], at: 0x2000)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: lastLowCanonical, rdi: 0x2000),
      rip: rip,
      rflags: [.reservedOne, .carry]
    )

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: rip,
            commitsPartialProgress: true
          )))
    #expect(memory.bulkCopyCalls == 0)
    #expect(memory.dataReads == [lastLowCanonical])
    #expect(memory.dataWrites == [0x2000])
    #expect(memory.bytes(at: 0x2000, count: 2) == [0x5A, 0])
    #expect(state.rip == rip)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == firstNoncanonical)
    #expect(state.registers.rdi == 0x2001)
    #expect(state.rflags == [.reservedOne, .carry])
  }

  @Test func bulkMOVSBDeclinesDestinationSpanBeforeReadingInvalidIteration() throws {
    let memory = SparseStringBulkMemory()
    memory.install([0xF3, 0xA4], at: rip)  // REP MOVSB
    memory.install([0x11, 0x22], at: 0x2000)
    memory.install([0, 0], at: lastLowCanonical)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: 0x2000, rdi: lastLowCanonical),
      rip: rip
    )

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: rip,
            commitsPartialProgress: true
          )))
    #expect(memory.bulkCopyCalls == 0)
    #expect(memory.dataReads == [0x2000])
    #expect(memory.dataWrites == [lastLowCanonical])
    #expect(memory.bytes(at: lastLowCanonical, count: 2) == [0x11, 0])
    #expect(state.rip == rip)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == 0x2001)
    #expect(state.registers.rdi == firstNoncanonical)
  }

  @Test func stackOverrideRetainsPartialStackFaultAtSourceCanonicalBoundary() throws {
    let memory = SparseStringBulkMemory()
    memory.install([0x36, 0xF3, 0xA4], at: rip)  // SS: REP MOVSB
    memory.install([0x5A], at: lastLowCanonical)
    memory.install([0xA5], at: firstNoncanonical)
    memory.install([0, 0], at: 0x2000)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: lastLowCanonical, rdi: 0x2000), rip: rip)

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .stackSegment,
            vector: 12,
            errorCode: 0,
            instructionPointer: rip,
            commitsPartialProgress: true
          )))
    #expect(memory.bulkCopyCalls == 0)
    #expect(memory.dataReads == [lastLowCanonical])
    #expect(memory.dataWrites == [0x2000])
    #expect(state.rip == rip)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == firstNoncanonical)
    #expect(state.registers.rdi == 0x2001)
  }

  @Test func bulkMOVSQDeclinesSourceSpanAtCanonicalBoundaryAndCommitsOnlyValidPrefix() throws {
    let memory = SparseStringBulkMemory()
    memory.install([0xF3, 0x48, 0xA5], at: rip)  // REP MOVSQ
    memory.install([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17], at: lastLowCanonical - 7)
    memory.install([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], at: 0x2000)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: lastLowCanonical - 7, rdi: 0x2000), rip: rip)

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: rip,
            commitsPartialProgress: true
          )))
    #expect(memory.bulkCopyElementCalls == 0)
    #expect(
      memory.dataReads == (0..<8).map { lastLowCanonical - 7 + UInt64($0) })
    #expect(memory.dataWrites == (0..<8).map { UInt64(0x2000 + $0) })
    #expect(
      memory.bytes(at: 0x2000, count: 16)
        == [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0, 0, 0, 0, 0, 0, 0, 0]
    )
    #expect(state.rip == rip)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == firstNoncanonical)
    #expect(state.registers.rdi == 0x2008)
  }

  @Test func bulkSTOSDeclinesDestinationSpanAndPreservesREPRestartState() throws {
    let memory = SparseStringBulkMemory()
    memory.install([0xF3, 0xAA], at: rip)  // REP STOSB
    memory.install([0, 0], at: lastLowCanonical)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x7E, rcx: 2, rdi: lastLowCanonical),
      rip: rip
    )

    #expect(
      interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: rip,
            commitsPartialProgress: true
          )))
    #expect(memory.bulkFillCalls == 0)
    #expect(memory.dataWrites == [lastLowCanonical])
    #expect(memory.bytes(at: lastLowCanonical, count: 2) == [0x7E, 0])
    #expect(state.rip == rip)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rdi == firstNoncanonical)
  }

  @Test func canonicalMOVSBAndSTOSSpansStillUseBulkBackends() throws {
    let moveMemory = SparseStringBulkMemory()
    moveMemory.install([0xF3, 0xA4], at: rip)
    moveMemory.install([0x31, 0x32], at: 0x2000)
    moveMemory.install([0, 0], at: 0x3000)
    var moveState = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: 0x2000, rdi: 0x3000), rip: rip)

    guard
      case .retired = interpreter.step(
        state: &moveState, memory: moveMemory, mode: .long64)
    else {
      Issue.record("canonical REP MOVSB did not retire")
      return
    }
    #expect(moveMemory.bulkCopyCalls == 1)
    #expect(moveMemory.bytes(at: 0x3000, count: 2) == [0x31, 0x32])
    #expect(moveState.registers.rcx == 0)

    let qwordMoveMemory = SparseStringBulkMemory()
    qwordMoveMemory.install([0xF3, 0x48, 0xA5], at: rip)  // REP MOVSQ
    qwordMoveMemory.install(
      [
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x12,
      ], at: 0x5000)
    qwordMoveMemory.install(Array(repeating: 0, count: 16), at: 0x6000)
    var qwordMoveState = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: 0x5000, rdi: 0x6000), rip: rip)

    guard
      case .retired = interpreter.step(
        state: &qwordMoveState, memory: qwordMoveMemory, mode: .long64)
    else {
      Issue.record("canonical REP MOVSQ did not retire")
      return
    }
    #expect(qwordMoveMemory.bulkCopyElementCalls == 1)
    #expect(
      qwordMoveMemory.bytes(at: 0x6000, count: 16)
        == [
          0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
          0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x12,
        ]
    )
    #expect(qwordMoveState.registers.rcx == 0)
    #expect(qwordMoveState.registers.rsi == 0x5010)
    #expect(qwordMoveState.registers.rdi == 0x6010)

    let storeMemory = SparseStringBulkMemory()
    storeMemory.install([0xF3, 0x48, 0xAB], at: rip)  // REP STOSQ
    storeMemory.install(Array(repeating: 0, count: 16), at: 0x4000)
    var storeState = try DoryX86ArchitecturalState(
      registers: .init(rax: 0x1122_3344_5566_7788, rcx: 2, rdi: 0x4000), rip: rip)

    guard
      case .retired = interpreter.step(
        state: &storeState, memory: storeMemory, mode: .long64)
    else {
      Issue.record("canonical REP STOSQ did not retire")
      return
    }
    #expect(storeMemory.bulkFillCalls == 1)
    #expect(
      storeMemory.bytes(at: 0x4000, count: 16)
        == [
          0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
          0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        ]
    )
    #expect(storeState.registers.rcx == 0)
  }
}

private final class SparseStringBulkMemory: DoryX86BulkMemory, @unchecked Sendable {
  private var storage: [UInt64: UInt8] = [:]
  private(set) var bulkCopyCalls = 0
  private(set) var bulkCopyElementCalls = 0
  private(set) var bulkFillCalls = 0
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
    var result: [UInt8] = []
    for offset in 0..<maximumCount {
      guard let byte = storage[address &+ UInt64(offset)] else { break }
      result.append(byte)
    }
    guard !result.isEmpty else {
      throw DoryX86MemoryError.unmapped(
        address: address, byteCount: maximumCount, access: .instructionFetch)
    }
    return result
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
    bulkCopyCalls += 1
    let bytes = try read(at: sourceAddress, byteCount: maximumByteCount)
    try write(at: destinationAddress, bytes: bytes)
    return maximumByteCount
  }

  func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int? {
    bulkFillCalls += 1
    let bytes = Array(repeating: pattern, count: maximumElementCount).flatMap { $0 }
    try write(at: destinationAddress, bytes: bytes)
    return maximumElementCount
  }

  func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    bulkCopyElementCalls += 1
    let byteCount = elementByteCount * maximumElementCount
    guard byteCount > 0 else { return 0 }
    let destinationRange = destinationAddress..<(destinationAddress + UInt64(byteCount))
    guard
      !excludingDestinationRanges.contains(where: { !$0.isEmpty && $0.overlaps(destinationRange) }
      )
    else { return nil }
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
          address: target, byteCount: byteCount - offset, access: access)
      }
      result.append(byte)
    }
    return result
  }
}
