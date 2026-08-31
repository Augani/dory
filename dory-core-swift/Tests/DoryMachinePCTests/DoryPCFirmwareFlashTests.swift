import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCFirmwareFlashTests {
  @Test func mapsRightAlignedImmutableFirmwareAtTheResetVector() throws {
    var image = Data(repeating: 0xa5, count: 4_096)
    image.replaceSubrange((image.count - 16)..<image.count, with: (0..<16).map(UInt8.init))
    let flash = try DoryPCFirmwareFlash(image: image)
    let bus = DoryPCPhysicalMemoryBus(ram: DoryX86ByteArrayMemory(byteCount: 1 << 20))
    try bus.attach(flash)
    bus.seal()

    #expect(flash.imageOffset == DoryPCV1ABI.firmwareCodeBytes - UInt64(image.count))
    #expect(
      try bus.read(at: DoryPCV1ABI.firmwareCodeBase, byteCount: 4)
        == [0xff, 0xff, 0xff, 0xff]
    )
    #expect(
      try bus.instructionBytes(at: DoryPCV1ABI.uefiResetAddress, maximumCount: 16)
        == Array(0..<16)
    )
    let generation = try #require(
      try bus.codeGeneration(at: DoryPCV1ABI.uefiResetAddress, byteCount: 16)
    )
    #expect(
      try bus.codeGeneration(at: DoryPCV1ABI.uefiResetAddress, byteCount: 16) == generation
    )
    #expect(
      try bus.readRestartableScalar(at: DoryPCV1ABI.uefiResetAddress, byteCount: 8)
        == 0x0706_0504_0302_0100
    )
    #expect(throws: DoryPCPhysicalMemoryError.self) {
      try bus.write(at: DoryPCV1ABI.uefiResetAddress, bytes: [0])
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.validateDMA(at: DoryPCV1ABI.uefiResetAddress, byteCount: 1, deviceWillWrite: false)
    }
  }

  @Test func rejectsImagesThatCannotBeMappedCanonically() {
    #expect(throws: DoryPCFirmwareFlashError.emptyImage) {
      _ = try DoryPCFirmwareFlash(image: Data())
    }
    #expect(throws: DoryPCFirmwareFlashError.unalignedImage(1)) {
      _ = try DoryPCFirmwareFlash(image: Data([0]))
    }
    #expect(
      throws: DoryPCFirmwareFlashError.imageTooLarge(
        maximum: DoryPCV1ABI.firmwareCodeBytes,
        actual: Int(DoryPCV1ABI.firmwareCodeBytes) + 4_096
      )
    ) {
      _ = try DoryPCFirmwareFlash(
        image: Data(repeating: 0xff, count: Int(DoryPCV1ABI.firmwareCodeBytes) + 4_096)
      )
    }
  }
}
