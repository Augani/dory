import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MmapAllocationTests {
  @Test func byteCountInitializerReturnsConfigurationAndHostMappingErrors() throws {
    for count in [Int.min, -1, 0] {
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86MmapMemory(byteCount: count)
      }
    }
    #expect(throws: DoryX86MemoryAllocationError.addressOverflow(baseAddress: .max, byteCount: 1)) {
      try DoryX86MmapMemory(baseAddress: .max, byteCount: 1)
    }
    do {
      _ = try DoryX86MmapMemory(byteCount: .max)
      Issue.record("An impossible address-space reservation unexpectedly succeeded")
    } catch let error as DoryX86MemoryAllocationError {
      guard case .mappingFailed(let count, let number) = error else {
        Issue.record("Expected a recoverable mmap error, received \(error)")
        return
      }
      #expect(count == Int.max)
      #expect(number != 0)
    }
    let memory = try DoryX86MmapMemory(byteCount: 4096)
    #expect(try memory.readScalar(at: 4088, byteCount: 8) == 0)
    try memory.writeScalar(at: 4088, value: .max, byteCount: 8)
    #expect(try memory.readScalar(at: 4088, byteCount: 8) == .max)
  }
}
