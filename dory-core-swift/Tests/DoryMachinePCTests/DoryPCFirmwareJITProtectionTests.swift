import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCFirmwareJITProtectionTests {
  private static let firmwareRIP: UInt64 = 0xFFFF_FEFF
  // MOV EAX,12345678; JMP +0. Match the seven-byte publication span which failed at firmware
  // startup, without executing a VM or depending on an external firmware build.
  private static let code: [UInt8] = [0xB8, 0x78, 0x56, 0x34, 0x12, 0xEB, 0]

  @Test(arguments: [false, true])
  func firmwareProtectionRetainsROMIdentityWithoutTouchingRAMPages(sealed: Bool) throws {
    let (ram, bus) = try fixture(sealed: sealed)
    let before = ram.translatedCodeProtectionGeneration
    #expect(try bus.instructionBytes(at: Self.firmwareRIP, maximumCount: 7) == Self.code)
    #expect(try bus.codeGeneration(at: Self.firmwareRIP, byteCount: 7) == 0)
    #expect(try bus.protectTranslatedCode(at: Self.firmwareRIP, byteCount: 7) == false)
    #expect(ram.protectedTranslatedCodePageCount == 0)
    #expect(ram.translatedCodeProtectionGeneration == before)
    #expect(try bus.codeGeneration(at: Self.firmwareRIP, byteCount: 7) == 0)

    #expect(try bus.protectTranslatedCode(at: 0x1000, byteCount: 7))
    #expect(ram.protectedTranslatedCodePageCount == 1)
    try bus.write(at: 0x1000, bytes: [0x90])
    #expect(ram.protectedTranslatedCodePageCount == 0)
  }

  @Test(arguments: [false, true])
  func nativeFirmwareBlockPublishesAndReusesExactROMGeneration(tier1Enabled: Bool) throws {
    #if arch(arm64)
      let (ram, bus) = try fixture(sealed: true)
      let initial = try DoryX86ArchitecturalState(
        rip: Self.firmwareRIP,
        cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
        ds: .init(selector: 16, attributes: 0xC093, limit: .max),
        control: .init(cr0: 0x11)
      )
      let translated = DoryX86TranslatedMemory(
        physicalMemory: bus, pagingUnit: .init(),
        context: .init(state: initial, mode: .protected32)
      )
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16_384, tier1Enabled: tier1Enabled)
      for _ in 0..<2 {
        var state = initial
        let result = try executor.executeSummary(
          byteProvider: { try translated.instructionBytes(at: Self.firmwareRIP, maximumCount: $0) },
          codeGenerationProvider: { try translated.codeGeneration(at: Self.firmwareRIP, byteCount: $0) },
          physicalRIPProvider: { try translated.physicalInstructionAddress(at: $0) },
          at: Self.firmwareRIP, mode: .protected32, addressSpaceID: 0,
          maximumInstructions: 2, state: &state, memory: translated
        )
        let execution = try #require(result)
        #expect(execution.guestInstructionCount == 2)
        #expect(execution.exitCode == .dispatch)
        #expect(execution.tier == (tier1Enabled ? .tier1 : .baseline))
        #expect(state.registers.rax == 0x1234_5678)
        #expect(state.rip == Self.firmwareRIP + 7)
      }
      #expect(executor.diagnostics.compiledBlocks == 1)
      #expect(executor.diagnostics.memoryGenerationHits == 1)
      #expect(ram.protectedTranslatedCodePageCount == 0)
    #endif
  }

  @Test func protectionStillRejectsInvalidOrCrossMappingSpans() throws {
    let (_, bus) = try fixture(sealed: true)
    let requests: [(UInt64, Int)] = [
      (DoryPCV1ABI.firmwareCodeBase - 1, 2),
      (0xFFFF_FFFF, 2),
      (0x4000, 1),
    ]
    for (address, byteCount) in requests {
      #expect(throws: DoryX86MemoryError.self) {
        try bus.protectTranslatedCode(at: address, byteCount: byteCount)
      }
    }
    #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 2)) {
      try bus.protectTranslatedCode(at: .max, byteCount: 2)
    }
    #expect(throws: DoryX86MemoryError.addressOverflow(address: 0, byteCount: -1)) {
      try bus.protectTranslatedCode(at: 0, byteCount: -1)
    }
  }

  @Test(arguments: [false, true])
  func overlaidDeviceProtectionChecksFetchPermissionAndExactReadableSpan(executable: Bool) throws {
    let ram = try DoryX86MmapMemory(validatingByteCount: 0x4000)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let device = ProtectionDevice(executable: executable)
    try bus.attach(device)
    bus.seal()
    if executable {
      #expect(try bus.protectTranslatedCode(at: 0x1000, byteCount: 7) == false)
      #expect(device.validationCalls == 1)
      #expect(throws: DoryPCPhysicalMemoryError.self) {
        try bus.protectTranslatedCode(at: 0x1007, byteCount: 2)
      }
    } else {
      #expect(throws: DoryX86MemoryError.self) {
        try bus.protectTranslatedCode(at: 0x1000, byteCount: 7)
      }
      #expect(device.validationCalls == 0)
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.protectTranslatedCode(at: 0x0FFF, byteCount: 2)
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.protectTranslatedCode(at: 0x10FF, byteCount: 2)
    }
    #expect(ram.protectedTranslatedCodePageCount == 0)
    #expect(device.readCalls == 0)
  }

  private func fixture(sealed: Bool) throws -> (DoryX86MmapMemory, DoryPCPhysicalMemoryBus) {
    let ram = try DoryX86MmapMemory(validatingByteCount: 0x4000)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    var image = Data(repeating: 0x90, count: 4096)
    let offset = Int(Self.firmwareRIP - 0xFFFF_F000)
    image.replaceSubrange(offset..<(offset + Self.code.count), with: Self.code)
    try bus.attach(DoryPCFirmwareFlash(image: image))
    if sealed { bus.seal() }
    return (ram, bus)
  }
}

private final class ProtectionDevice: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64 = 0x1000
  let byteCount: UInt64 = 0x100
  let allowsInstructionFetch: Bool
  private(set) var validationCalls = 0
  private(set) var readCalls = 0

  init(executable: Bool) { allowsInstructionFetch = executable }

  func validateRead(offset: UInt64, byteCount: Int) throws {
    validationCalls += 1
    guard offset < 8, byteCount > 0, UInt64(byteCount) <= 8 - offset else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset, byteCount: byteCount, write: false)
    }
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    readCalls += 1
    try validateRead(offset: offset, byteCount: byteCount)
    return .init(repeating: 0x90, count: byteCount)
  }

  func write(offset: UInt64, bytes: [UInt8]) throws {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: offset, byteCount: bytes.count, write: true)
  }
}
