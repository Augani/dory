import Foundation
import Testing

@testable import DoryExecutionContracts

@Suite struct SnapshotBarrierContractTests {
  private struct State: Codable, Sendable, Equatable {
    let programCounter: UInt64
    let status: UInt64
  }

  @Test func barrierOnlyAdvancesOnePrecisePhaseAtATime() throws {
    let requested = try DorySnapshotBarrierProgress(
      snapshotGeneration: 4,
      executionGeneration: 9
    )
    let quiesced = try requested.advanced(to: .executionQuiesced)
    let sealed = try quiesced.advanced(to: .memorySealed)
    let captured = try sealed.advanced(to: .architecturalStateCaptured)
    let released = try captured.advanced(to: .released)
    #expect(released.phase == .released)

    #expect(
      throws: DoryExecutionContractError.invalidBarrierTransition(
        from: .requested,
        to: .memorySealed
      )
    ) {
      try requested.advanced(to: .memorySealed)
    }
    #expect(
      throws: DoryExecutionContractError.invalidBarrierTransition(
        from: .released,
        to: .requested
      )
    ) {
      try released.advanced(to: .requested)
    }
  }

  @Test func receiptRequiresEveryExpectedVCPUAndCapturedPhase() throws {
    let clock = try clockState()
    let requested = try DorySnapshotBarrierProgress(
      snapshotGeneration: 4,
      executionGeneration: 9
    )
    let captured =
      try requested
      .advanced(to: .executionQuiesced)
      .advanced(to: .memorySealed)
      .advanced(to: .architecturalStateCaptured)
    let memory = [
      try DorySnapshotMemoryGeneration(
        regionID: 1,
        mappingGeneration: 6,
        dirtyEpoch: 3
      )
    ]

    let receipt = try DorySnapshotBarrierReceipt(
      progress: captured,
      expectedVCPUs: [DoryVCPUIdentifier(1), DoryVCPUIdentifier(0)],
      quiescedVCPUs: [DoryVCPUIdentifier(0), DoryVCPUIdentifier(1)],
      memory: memory,
      clock: clock
    )
    #expect(receipt.quiescedVCPUs == [DoryVCPUIdentifier(0), DoryVCPUIdentifier(1)])

    #expect(
      throws: DoryExecutionContractError.incompleteVCPUQuiescence(
        expected: [DoryVCPUIdentifier(0), DoryVCPUIdentifier(1)],
        actual: [DoryVCPUIdentifier(0)]
      )
    ) {
      try DorySnapshotBarrierReceipt(
        progress: captured,
        expectedVCPUs: [DoryVCPUIdentifier(0), DoryVCPUIdentifier(1)],
        quiescedVCPUs: [DoryVCPUIdentifier(0)],
        memory: memory,
        clock: clock
      )
    }
  }

  @Test func snapshotRoundTripContainsOnlyArchitecturalDurableState() throws {
    let snapshot = try DoryExecutionSnapshot(
      architecture: .x86_64,
      snapshotGeneration: 2,
      executionGeneration: 5,
      clock: clockState(),
      memory: [
        try DorySnapshotMemoryGeneration(
          regionID: 1,
          mappingGeneration: 7,
          dirtyEpoch: 8
        )
      ],
      vcpus: [
        DoryVCPUArchitecturalState(
          vcpu: DoryVCPUIdentifier(0),
          state: State(programCounter: 0x1000, status: 2)
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(snapshot)
    let decoded = try JSONDecoder().decode(DoryExecutionSnapshot<State>.self, from: encoded)
    let reencoded = try encoder.encode(decoded)

    #expect(encoded == reencoded)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.vcpus.first?.state == State(programCounter: 0x1000, status: 2))
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.contains("jit"))
    #expect(!json.contains("translated"))
    #expect(!json.contains("hostPointer"))
  }

  @Test func monotonicClockRejectsBackwardMovement() throws {
    let clock = try clockState()
    let advanced = try clock.advanced(
      to: 12_000,
      wallClockNanosecondsSinceUnixEpoch: 1_800_000_000_000_000_000
    )
    #expect(advanced.monotonicTicks == 12_000)
    #expect(throws: DoryExecutionContractError.clockMovedBackward(previous: 10_000, next: 9_999)) {
      try clock.advanced(
        to: 9_999,
        wallClockNanosecondsSinceUnixEpoch: 1_800_000_000_000_000_000
      )
    }
  }

  private func clockState() throws -> DoryVirtualClockState {
    try DoryVirtualClockState(
      generation: 3,
      frequencyHz: 1_000_000_000,
      monotonicTicks: 10_000,
      wallClockNanosecondsSinceUnixEpoch: 1_800_000_000_000_000_000,
      isPaused: true
    )
  }
}
