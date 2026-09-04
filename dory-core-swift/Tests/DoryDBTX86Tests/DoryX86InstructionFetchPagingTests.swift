import Testing

@testable import DoryDBTX86

// Intel SDM revision 092, Vol. 3A §§5.6-5.8, Figure 5-12, and Table 7-2:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86InstructionFetchPagingTests {
  @Test func crossPageFetchReportsTheSecondLinearPageAndExactProtectionClass() throws {
    struct FaultCase {
      let firstPTE: UInt64
      let secondPTE: UInt64
      let cpl: UInt16
      let cr4: UInt64
      let efer: UInt64
      let errorCode: UInt32
    }
    let presentUser: UInt64 = 0x9007
    let cases = [
      FaultCase(firstPTE: 0x8007, secondPTE: presentUser | (1 << 63), cpl: 3,
        cr4: 1 << 5, efer: (1 << 10) | (1 << 11), errorCode: 0x15), // XD
      FaultCase(firstPTE: 0x8007, secondPTE: 0x9003, cpl: 3,
        cr4: 1 << 5, efer: (1 << 10) | (1 << 11), errorCode: 0x15), // U/S
      FaultCase(firstPTE: 0x8003, secondPTE: presentUser, cpl: 0,
        cr4: (1 << 5) | (1 << 20), efer: (1 << 10) | (1 << 11), errorCode: 0x11), // SMEP
      FaultCase(firstPTE: 0x8007, secondPTE: presentUser | (1 << 63), cpl: 3,
        cr4: 1 << 5, efer: 1 << 10, errorCode: 0x0D), // NX reserved without NXE
      FaultCase(firstPTE: 0x8007, secondPTE: 0, cpl: 3,
        cr4: 1 << 5, efer: (1 << 10) | (1 << 11), errorCode: 0x14), // non-present
    ]

    for testCase in cases {
      let physical = try memory(firstPTE: testCase.firstPTE, secondPTE: testCase.secondPTE)
      var state = try state(cpl: testCase.cpl, cr4: testCase.cr4, efer: testCase.efer)
      let before = state
      let result = DoryX86Interpreter().step(
        state: &state, memory: physical, mode: .long64, pagingUnit: .init())

      #expect(result == .exception(.init(kind: .pageFault, vector: 14,
        errorCode: testCase.errorCode, instructionPointer: 0x400FFF,
        linearAddress: 0x401000)))
      var expected = before
      expected.control.cr2 = 0x401000
      #expect(state == expected)
      // The first page participated in the failed cross-page fetch. Page-fault
      // accessed-bit effects on the faulting protection entry are model-specific.
      #expect(try physical.readScalar(at: 0x4000, byteCount: 8) == testCase.firstPTE | 0x20)
      if testCase.secondPTE == 0 || (testCase.efer & (1 << 11)) == 0 {
        #expect(try physical.readScalar(at: 0x4008, byteCount: 8) == testCase.secondPTE)
      }
    }
  }

  @Test func translatedFetchUsesPhysicalExecutePermissionAndKeepsLinearFaultIdentity() throws {
    let backing = try memory(secondPTE: 0x9007)
    let physical = FetchPermissionMemory(backing: backing, deniedPage: 0x9000..<0xA000)
    var state = try state(cpl: 3)
    let before = state

    #expect(DoryX86Interpreter().step(
      state: &state, memory: physical, mode: .long64, pagingUnit: .init())
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0x14,
        instructionPointer: 0x400FFF, linearAddress: 0x401000)))
    var expected = before
    expected.control.cr2 = 0x401000
    #expect(state == expected)
    #expect(physical.fetchAddresses.contains(0x8FFF))
    #expect(physical.fetchAddresses.contains(0x9000))
    #expect(!physical.readAddresses.contains { $0 >= 0x8000 })
  }

  @Test func executableCrossPageInstructionUsesBothDiscontiguousPhysicalPages() throws {
    let physical = try memory(secondPTE: 0xA007, secondPhysicalAddress: 0xA000,
      bytes: [0x48, 0xFF, 0xC0]) // INC RAX
    var state = try state(cpl: 3)
    let decoded = try DoryX86Decoder().decode(
      [0x48, 0xFF, 0xC0], at: 0x400FFF, mode: .long64)

    #expect(DoryX86Interpreter().step(
      state: &state, memory: physical, mode: .long64, pagingUnit: .init())
      == .retired(decoded))
    #expect(state.rip == 0x401002)
    #expect(state.registers.rax == 1)
    #expect(state.control.cr2 == 0x1234)
    #expect(try physical.readScalar(at: 0x4000, byteCount: 8) == 0x8027)
    #expect(try physical.readScalar(at: 0x4008, byteCount: 8) == 0xA027)
  }

  private func memory(
    firstPTE: UInt64 = 0x8007,
    secondPTE: UInt64,
    secondPhysicalAddress: UInt64 = 0x9000,
    bytes: [UInt8] = [0x0F, 0x0B]
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try memory.writeScalar(at: 0x1000, value: 0x2007, byteCount: 8)
    try memory.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8)
    try memory.writeScalar(at: 0x3010, value: 0x4007, byteCount: 8)
    try memory.writeScalar(at: 0x4000, value: firstPTE, byteCount: 8)
    try memory.writeScalar(at: 0x4008, value: secondPTE, byteCount: 8)
    try memory.write(at: 0x8FFF, bytes: [bytes[0]])
    if bytes.count > 1 {
      try memory.write(at: secondPhysicalAddress, bytes: Array(bytes.dropFirst()))
    }
    return memory
  }

  private func state(
    cpl: UInt16,
    cr4: UInt64 = 1 << 5,
    efer: UInt64 = (1 << 10) | (1 << 11)
  ) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0), rip: 0x400FFF,
      rflags: [.reservedOne, .carry],
      cs: .init(selector: cpl, attributes: cpl == 3 ? 0xA0FB : 0xA09B, limit: .max),
      control: .init(cr0: 0x8001_0011, cr2: 0x1234, cr3: 0x1000, cr4: cr4,
        efer: efer))
  }
}

private final class FetchPermissionMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let deniedPage: Range<UInt64>
  var fetchAddresses: [UInt64] = []
  var readAddresses: [UInt64] = []

  init(backing: DoryX86ByteArrayMemory, deniedPage: Range<UInt64>) {
    self.backing = backing
    self.deniedPage = deniedPage
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    fetchAddresses.append(address)
    if deniedPage.contains(address) {
      throw DoryX86MemoryError.unmapped(
        address: address, byteCount: maximumCount, access: .instructionFetch)
    }
    return try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    readAddresses.append(address)
    return try backing.read(at: address, byteCount: byteCount)
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

  func synchronize() { backing.synchronize() }
}
