import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCUEFIMachineTests {
  @Test func entersResetVectorAndExecutesFromImmutableFirmware() throws {
    var image = Data(repeating: 0xf4, count: 4_096)
    image[image.count - 16] = 0x90
    let flash = try DoryPCFirmwareFlash(image: image)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      platformMMIODevices: [flash]
    )

    try machine.loadUEFI()
    let state = try #require(machine.state)
    #expect(state.cs.base + state.rip == DoryPCV1ABI.uefiResetAddress)
    #expect(
      try machine.memory.read(at: DoryPCV1ABI.acpiBase, byteCount: 8) == Array("RSD PTR ".utf8))
    #expect(
      try machine.memory.read(at: DoryPCV1ABI.smbiosBase, byteCount: 5) == Array("_SM3_".utf8))
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.rip == 0xfff1)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(try machine.run(maximumInstructions: 1) == .halted(instructionCount: 0))
  }

  @Test func requiresFirmwareAndAllowsOnlyOneBootPayload() throws {
    let missing = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    #expect(throws: Error.self) { try missing.loadUEFI() }

    let flash = try DoryPCFirmwareFlash(image: Data(repeating: 0xf4, count: 4_096))
    let loaded = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      platformMMIODevices: [flash]
    )
    try loaded.loadUEFI()
    #expect(throws: DoryPCMachineError.alreadyLoaded) { try loaded.loadUEFI() }
  }
}
