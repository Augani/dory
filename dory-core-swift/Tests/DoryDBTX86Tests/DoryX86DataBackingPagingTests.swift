import Testing

@testable import DoryDBTX86

// Intel SDM revision 092, Vol. 3A §§5.6-5.8: #PF identifies the linear
// access, including its read/write and user/supervisor classification.
@Suite struct DoryX86DataBackingPagingTests {
  private let codeAddress: UInt64 = 0x0040_0000
  private let dataAddress: UInt64 = 0x0050_0123

  @Test func interpreterDataReadKeepsGuestLinearFaultIdentity() throws {
    let physical = try memory(code: [0x48, 0x8B, 0x03])  // MOV RAX,[RBX]
    var state = try userState(rax: 0xA5A5_A5A5_A5A5_A5A5)
    let before = state

    #expect(
      DoryX86Interpreter().step(
        state: &state, memory: physical, mode: .long64, pagingUnit: .init())
        == .exception(
          .init(
            kind: .pageFault, vector: 14, errorCode: 0x4,
            instructionPointer: codeAddress, linearAddress: dataAddress)))
    var expected = before
    expected.control.cr2 = dataAddress
    #expect(state == expected)
    #expect(physical.deniedAccesses == [0x9123])
  }

  @Test func interpreterDataWriteKeepsGuestLinearFaultIdentity() throws {
    let physical = try memory(code: [0x48, 0x89, 0x03])  // MOV [RBX],RAX
    var state = try userState(rax: 0x1122_3344_5566_7788)
    let before = state

    #expect(
      DoryX86Interpreter().step(
        state: &state, memory: physical, mode: .long64, pagingUnit: .init())
        == .exception(
          .init(
            kind: .pageFault, vector: 14, errorCode: 0x6,
            instructionPointer: codeAddress, linearAddress: dataAddress)))
    var expected = before
    expected.control.cr2 = dataAddress
    #expect(state == expected)
    #expect(physical.deniedAccesses == [0x9123])
  }

  @Test func translatedValidationAndScalarPathsUseGuestLinearFaults() throws {
    for operation in 0..<5 {
      let physical = try memory(code: [0x90])
      let translated = DoryX86TranslatedMemory(
        physicalMemory: physical,
        pagingUnit: .init(),
        context: .init(state: try userState(), mode: .long64)
      )
      let expectedCode: UInt32 = operation < 3 ? 0x4 : 0x6
      #expect(
        throws: DoryX86MemoryError.pageFault(
          address: dataAddress, errorCode: expectedCode)
      ) {
        switch operation {
        case 0:
          try translated.validateRead(at: dataAddress, byteCount: 8)
        case 1:
          _ = try translated.readScalar(at: dataAddress, byteCount: 8)
        case 2:
          _ = try translated.readRestartableScalar(at: dataAddress, byteCount: 8)
        case 3:
          try translated.validateWrite(at: dataAddress, byteCount: 8)
        default:
          try translated.writeScalar(at: dataAddress, value: 1, byteCount: 8)
        }
      }
      #expect(physical.deniedAccesses == [0x9123])
    }
  }

  private func memory(code: [UInt8]) throws -> DataBackingPermissionMemory {
    let backing = try DoryX86ByteArrayMemory(byteCount: 0xA000)
    try backing.writeScalar(at: 0x1000, value: 0x2007, byteCount: 8)
    try backing.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8)
    try backing.writeScalar(at: 0x3010, value: 0x4007, byteCount: 8)
    try backing.writeScalar(at: 0x4000, value: 0x8007, byteCount: 8)
    try backing.writeScalar(at: 0x4800, value: 0x9007, byteCount: 8)
    try backing.write(at: 0x8000, bytes: code)
    return DataBackingPermissionMemory(backing: backing, deniedPage: 0x9000..<0xA000)
  }

  private func userState(rax: UInt64 = 0) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: rax, rbx: dataAddress),
      rip: codeAddress,
      rflags: [.reservedOne, .carry],
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(
        cr0: 0x8001_0011, cr2: 0xDEAD, cr3: 0x1000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11))
    )
  }
}

private final class DataBackingPermissionMemory: DoryX86Memory, DoryX86ScalarMemory,
  DoryX86RestartableScalarMemory, @unchecked Sendable
{
  let backing: DoryX86ByteArrayMemory
  let deniedPage: Range<UInt64>
  var deniedAccesses: [UInt64] = []

  init(backing: DoryX86ByteArrayMemory, deniedPage: Range<UInt64>) {
    self.backing = backing
    self.deniedPage = deniedPage
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try allow(address, byteCount: byteCount, access: .read)
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try allow(address, byteCount: byteCount, access: .read)
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try allow(address, byteCount: bytes.count, access: .write)
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try allow(address, byteCount: byteCount, access: .write)
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    try allow(address, byteCount: byteCount, access: .read)
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    try allow(address, byteCount: byteCount, access: .write)
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try readScalar(at: address, byteCount: byteCount)
  }

  func synchronize() { backing.synchronize() }

  private func allow(
    _ address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind
  ) throws {
    if deniedPage.contains(address) {
      deniedAccesses.append(address)
      throw DoryX86MemoryError.unmapped(
        address: address, byteCount: byteCount, access: access)
    }
  }
}
