import Testing

@testable import DoryDBTX86

@Suite struct DoryX86BitTestAddressingTests {
  @Test(arguments: [2, 4, 8])
  func immediateHighBitsDoNotAdvanceTheMemoryOperand(byteCount: Int) throws {
    for operation: UInt8 in 4...7 {
      for locked in [false, true] where !locked || operation != 4 {
        let prefixes: [UInt8] = (locked ? [0xF0] : [])
          + (byteCount == 2 ? [0x66] : byteCount == 8 ? [0x48] : [])
        let bytes = prefixes + [0x0F, 0xBA, operation << 3 | 7, 0xFF]
        // The selected word ends at the backing boundary. An incorrect carry from the
        // immediate into the effective address would fault instead of touching its last bit.
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x80 + byteCount)
        try memory.write(at: 0, bytes: bytes)
        let bit = UInt64(1) << UInt64(byteCount * 8 - 1)
        let initial: UInt64 = operation == 5 ? 0 : bit
        try memory.writeScalar(at: 0x80, value: initial, byteCount: byteCount)
        var state = try DoryX86ArchitecturalState(
          registers: .init(rdi: 0x80), rip: 0, rflags: [.reservedOne]
        )
        let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)

        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
        #expect(state.rflags.contains(.carry) == (initial != 0))
        #expect(try memory.readScalar(at: 0x80, byteCount: byteCount)
          == (operation <= 5 ? bit : 0))
      }
    }
  }

  @Test(arguments: [-1, 67])
  func registerIndicesStillAddressTheSurroundingBitString(index: Int) throws {
    let bytes: [UInt8] = [0x48, 0x0F, 0xA3, 0x0F] // bt [rdi], rcx
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
    try memory.write(at: 0, bytes: bytes)
    try memory.writeScalar(
      at: index < 0 ? 0x78 : 0x88,
      value: index < 0 ? UInt64(1) << 63 : 8,
      byteCount: 8
    )
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: UInt64(bitPattern: Int64(index)), rdi: 0x80),
      rip: 0, rflags: [.reservedOne]
    )
    let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .retired(decoded))
    #expect(state.rflags.contains(.carry))
  }
}
