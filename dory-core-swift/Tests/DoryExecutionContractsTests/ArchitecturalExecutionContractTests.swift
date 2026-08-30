import Testing

@testable import DoryExecutionContracts

@Suite struct ArchitecturalExecutionContractTests {
  @Test func mmioAndPortExitsCarryArchitectureNeutralRestartMetadata() throws {
    let token = try DoryExecutionResumeToken(
      vcpu: DoryVCPUIdentifier(2),
      executionGeneration: 7,
      sequence: 11
    )
    let write = try DoryArchitecturalMemoryAccess(
      address: DoryGuestPhysicalAddress(0x1000_0040),
      widthBytes: 4,
      direction: .write,
      value: [0x78, 0x56, 0x34, 0x12]
    )
    let exit = try DoryCPUExit(
      vcpu: DoryVCPUIdentifier(2),
      retiredInstructions: 99,
      reason: .memoryMappedIO(write, resume: token)
    )

    guard case .memoryMappedIO(let access, let resume) = exit.reason else {
      Issue.record("expected MMIO exit")
      return
    }
    #expect(access.value == [0x78, 0x56, 0x34, 0x12])
    #expect(resume == token)

    #expect(throws: DoryExecutionContractError.invalidAccessPayload(expected: 4, actual: 1)) {
      try DoryArchitecturalPortAccess(
        port: 0x3f8,
        widthBytes: 4,
        direction: .write,
        value: [0]
      )
    }
  }

  @Test func interruptContractRejectsCrossArchitectureShapes() throws {
    _ = try DoryArchitecturalInterrupt(
      architecture: .arm64,
      kind: .maskable,
      vector: 1_019,
      deliveryGeneration: 1
    )
    _ = try DoryArchitecturalInterrupt(
      architecture: .x86_64,
      kind: .nonMaskable,
      vector: 2,
      deliveryGeneration: 2
    )

    #expect(
      throws: DoryExecutionContractError.invalidInterruptVector(
        architecture: .arm64,
        vector: 1_020
      )
    ) {
      try DoryArchitecturalInterrupt(
        architecture: .arm64,
        kind: .maskable,
        vector: 1_020,
        deliveryGeneration: 1
      )
    }
    #expect(throws: DoryExecutionContractError.invalidInterruptKind) {
      try DoryArchitecturalInterrupt(
        architecture: .arm64,
        kind: .nonMaskable,
        vector: 2,
        deliveryGeneration: 1
      )
    }
  }

  @Test func cancellationIsBoundToOneExecutionGeneration() throws {
    let cancellation = try DoryExecutionCancellationRequest(
      executionGeneration: 8,
      cancellationGeneration: 3,
      reason: .leaseRevoked
    )
    #expect(cancellation.applies(to: 8))
    #expect(!cancellation.applies(to: 7))
    #expect(!cancellation.applies(to: 9))
  }
}
