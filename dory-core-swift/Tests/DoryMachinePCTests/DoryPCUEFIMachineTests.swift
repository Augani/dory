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
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.rip == 0xfff1)
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .halted(instructionCount: 0))
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

  @Test func rejectsCustomSMBIOSRangeOverlappingACPIBeforeAnyWrite() throws {
    // The ACPI RSDP begins at the ACPI base. A custom SMBIOS entry point placed on top
    // of it is rejected before any table byte is written and before the boot payload is
    // consumed, so guest firmware discovery cannot be silently corrupted.
    let flash = try DoryPCFirmwareFlash(image: Data(repeating: 0xf4, count: 4_096))
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      smbiosLayout: .init(
        entryPoint: DoryPCV1ABI.acpiBase,
        structureTable: DoryPCV1ABI.smbiosBase + 0x1000
      ),
      platformMMIODevices: [flash]
    )

    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      try machine.loadUEFI()
    }
    #expect(machine.state == nil)
    // No ACPI or SMBIOS bytes reached guest RAM.
    #expect(
      try machine.memory.read(at: DoryPCV1ABI.acpiBase, byteCount: 8)
        == .init(repeating: 0, count: 8))
    #expect(
      try machine.memory.read(at: DoryPCV1ABI.smbiosBase, byteCount: 5)
        == .init(repeating: 0, count: 5))
    // consumedPayload was not set: a retry fails the same admission, not alreadyLoaded.
    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      try machine.loadUEFI()
    }
  }

  @Test func validCustomSMBIOSLayoutReachesUEFIResetVector() throws {
    var image = Data(repeating: 0xf4, count: 4_096)
    image[image.count - 16] = 0x90
    let flash = try DoryPCFirmwareFlash(image: image)
    // A corrected, non-overlapping custom SMBIOS layout is still admitted and boots to
    // the UEFI reset vector.
    let entryPoint = DoryPCV1ABI.smbiosBase + 0x800
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      smbiosLayout: .init(
        entryPoint: entryPoint,
        structureTable: DoryPCV1ABI.smbiosBase + 0x2000
      ),
      platformMMIODevices: [flash]
    )

    try machine.loadUEFI()
    let state = try #require(machine.state)
    #expect(state.cs.base + state.rip == DoryPCV1ABI.uefiResetAddress)
    #expect(
      try machine.memory.read(at: DoryPCV1ABI.acpiBase, byteCount: 8) == Array("RSD PTR ".utf8))
    #expect(
      try machine.memory.read(at: entryPoint, byteCount: 5) == Array("_SM3_".utf8))
  }
}
