public struct DoryVirtualDeadline: Codable, Sendable, Hashable, Comparable {
  public let monotonicTicks: UInt64

  public init(monotonicTicks: UInt64) {
    self.monotonicTicks = monotonicTicks
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.monotonicTicks < rhs.monotonicTicks
  }
}

public struct DoryVirtualClockState: Codable, Sendable, Hashable {
  public let generation: UInt64
  public let frequencyHz: UInt64
  public let monotonicTicks: UInt64
  public let wallClockNanosecondsSinceUnixEpoch: Int64
  public let isPaused: Bool

  public init(
    generation: UInt64,
    frequencyHz: UInt64,
    monotonicTicks: UInt64,
    wallClockNanosecondsSinceUnixEpoch: Int64,
    isPaused: Bool
  ) throws {
    guard generation > 0 else {
      throw DoryExecutionContractError.invalidGeneration(type: "clock", value: generation)
    }
    guard frequencyHz > 0 else {
      throw DoryExecutionContractError.invalidClockFrequency(frequencyHz)
    }
    self.generation = generation
    self.frequencyHz = frequencyHz
    self.monotonicTicks = monotonicTicks
    self.wallClockNanosecondsSinceUnixEpoch = wallClockNanosecondsSinceUnixEpoch
    self.isPaused = isPaused
  }

  private enum CodingKeys: String, CodingKey {
    case generation, frequencyHz, monotonicTicks, wallClockNanosecondsSinceUnixEpoch, isPaused
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      generation: container.decode(UInt64.self, forKey: .generation),
      frequencyHz: container.decode(UInt64.self, forKey: .frequencyHz),
      monotonicTicks: container.decode(UInt64.self, forKey: .monotonicTicks),
      wallClockNanosecondsSinceUnixEpoch: container.decode(
        Int64.self,
        forKey: .wallClockNanosecondsSinceUnixEpoch
      ),
      isPaused: container.decode(Bool.self, forKey: .isPaused)
    )
  }

  public func advanced(
    to monotonicTicks: UInt64,
    wallClockNanosecondsSinceUnixEpoch: Int64
  ) throws -> Self {
    guard monotonicTicks >= self.monotonicTicks else {
      throw DoryExecutionContractError.clockMovedBackward(
        previous: self.monotonicTicks,
        next: monotonicTicks
      )
    }
    return try Self(
      generation: generation,
      frequencyHz: frequencyHz,
      monotonicTicks: monotonicTicks,
      wallClockNanosecondsSinceUnixEpoch: wallClockNanosecondsSinceUnixEpoch,
      isPaused: isPaused
    )
  }
}

public enum DoryExecutionCancellationReason: String, Codable, Sendable, Hashable {
  case userRequested
  case leaseRevoked
  case operationSuperseded
  case hostShutdown
  case deadlineExceeded
}

public struct DoryExecutionCancellationRequest: Codable, Sendable, Hashable {
  public let executionGeneration: UInt64
  public let cancellationGeneration: UInt64
  public let reason: DoryExecutionCancellationReason

  public init(
    executionGeneration: UInt64,
    cancellationGeneration: UInt64,
    reason: DoryExecutionCancellationReason
  ) throws {
    guard executionGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "execution",
        value: executionGeneration
      )
    }
    guard cancellationGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "cancellation",
        value: cancellationGeneration
      )
    }
    self.executionGeneration = executionGeneration
    self.cancellationGeneration = cancellationGeneration
    self.reason = reason
  }

  private enum CodingKeys: String, CodingKey {
    case executionGeneration, cancellationGeneration, reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      executionGeneration: container.decode(UInt64.self, forKey: .executionGeneration),
      cancellationGeneration: container.decode(UInt64.self, forKey: .cancellationGeneration),
      reason: container.decode(DoryExecutionCancellationReason.self, forKey: .reason)
    )
  }

  public func applies(to executionGeneration: UInt64) -> Bool {
    self.executionGeneration == executionGeneration
  }
}

public enum DorySnapshotBarrierPhase: String, Codable, CaseIterable, Sendable, Hashable {
  case requested
  case executionQuiesced
  case memorySealed
  case architecturalStateCaptured
  case released

  fileprivate var ordinal: Int {
    Self.allCases.firstIndex(of: self)!
  }
}

public struct DorySnapshotBarrierProgress: Codable, Sendable, Hashable {
  public let snapshotGeneration: UInt64
  public let executionGeneration: UInt64
  public let phase: DorySnapshotBarrierPhase

  public init(
    snapshotGeneration: UInt64,
    executionGeneration: UInt64,
    phase: DorySnapshotBarrierPhase = .requested
  ) throws {
    guard snapshotGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "snapshot",
        value: snapshotGeneration
      )
    }
    guard executionGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "execution",
        value: executionGeneration
      )
    }
    self.snapshotGeneration = snapshotGeneration
    self.executionGeneration = executionGeneration
    self.phase = phase
  }

  private enum CodingKeys: String, CodingKey {
    case snapshotGeneration, executionGeneration, phase
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      snapshotGeneration: container.decode(UInt64.self, forKey: .snapshotGeneration),
      executionGeneration: container.decode(UInt64.self, forKey: .executionGeneration),
      phase: container.decode(DorySnapshotBarrierPhase.self, forKey: .phase)
    )
  }

  public func advanced(to next: DorySnapshotBarrierPhase) throws -> Self {
    guard next.ordinal == phase.ordinal + 1 else {
      throw DoryExecutionContractError.invalidBarrierTransition(from: phase, to: next)
    }
    return try Self(
      snapshotGeneration: snapshotGeneration,
      executionGeneration: executionGeneration,
      phase: next
    )
  }
}

public struct DorySnapshotMemoryGeneration: Codable, Sendable, Hashable, Comparable {
  public let regionID: UInt32
  public let mappingGeneration: UInt64
  public let dirtyEpoch: UInt64?

  public init(regionID: UInt32, mappingGeneration: UInt64, dirtyEpoch: UInt64?) throws {
    guard regionID > 0 else {
      throw DoryExecutionContractError.zeroIdentifier(type: "memory region")
    }
    guard mappingGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "memory mapping",
        value: mappingGeneration
      )
    }
    if let dirtyEpoch, dirtyEpoch == 0 {
      throw DoryExecutionContractError.invalidGeneration(type: "dirty epoch", value: dirtyEpoch)
    }
    self.regionID = regionID
    self.mappingGeneration = mappingGeneration
    self.dirtyEpoch = dirtyEpoch
  }

  private enum CodingKeys: String, CodingKey {
    case regionID, mappingGeneration, dirtyEpoch
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      regionID: container.decode(UInt32.self, forKey: .regionID),
      mappingGeneration: container.decode(UInt64.self, forKey: .mappingGeneration),
      dirtyEpoch: container.decodeIfPresent(UInt64.self, forKey: .dirtyEpoch)
    )
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.regionID < rhs.regionID
  }
}

public struct DoryVCPUArchitecturalState<State: Codable & Sendable>: Codable, Sendable {
  public let vcpu: DoryVCPUIdentifier
  public let state: State

  public init(vcpu: DoryVCPUIdentifier, state: State) {
    self.vcpu = vcpu
    self.state = state
  }
}

public struct DoryExecutionSnapshot<State: Codable & Sendable>: Codable, Sendable {
  public let schemaVersion: UInt32
  public let architecture: DoryExecutionArchitecture
  public let snapshotGeneration: UInt64
  public let executionGeneration: UInt64
  public let clock: DoryVirtualClockState
  public let memory: [DorySnapshotMemoryGeneration]
  public let vcpus: [DoryVCPUArchitecturalState<State>]

  public init(
    architecture: DoryExecutionArchitecture,
    snapshotGeneration: UInt64,
    executionGeneration: UInt64,
    clock: DoryVirtualClockState,
    memory: [DorySnapshotMemoryGeneration],
    vcpus: [DoryVCPUArchitecturalState<State>]
  ) throws {
    guard snapshotGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "snapshot",
        value: snapshotGeneration
      )
    }
    guard executionGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "execution",
        value: executionGeneration
      )
    }
    let memoryIDs = memory.map(\.regionID)
    guard memoryIDs == memoryIDs.sorted(), Set(memoryIDs).count == memoryIDs.count else {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "snapshot memory generations")
    }
    let vcpuIDs = vcpus.map(\.vcpu)
    guard vcpuIDs == vcpuIDs.sorted(), Set(vcpuIDs).count == vcpuIDs.count else {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "snapshot vCPU state")
    }
    self.schemaVersion = 1
    self.architecture = architecture
    self.snapshotGeneration = snapshotGeneration
    self.executionGeneration = executionGeneration
    self.clock = clock
    self.memory = memory
    self.vcpus = vcpus
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, architecture, snapshotGeneration, executionGeneration, clock, memory, vcpus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(UInt32.self, forKey: .schemaVersion)
    guard version == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "unsupported execution snapshot schema \(version)"
      )
    }
    try self.init(
      architecture: container.decode(DoryExecutionArchitecture.self, forKey: .architecture),
      snapshotGeneration: container.decode(UInt64.self, forKey: .snapshotGeneration),
      executionGeneration: container.decode(UInt64.self, forKey: .executionGeneration),
      clock: container.decode(DoryVirtualClockState.self, forKey: .clock),
      memory: container.decode([DorySnapshotMemoryGeneration].self, forKey: .memory),
      vcpus: container.decode([DoryVCPUArchitecturalState<State>].self, forKey: .vcpus)
    )
  }
}

public struct DorySnapshotBarrierReceipt: Codable, Sendable, Hashable {
  public let snapshotGeneration: UInt64
  public let executionGeneration: UInt64
  public let expectedVCPUs: [DoryVCPUIdentifier]
  public let quiescedVCPUs: [DoryVCPUIdentifier]
  public let memory: [DorySnapshotMemoryGeneration]
  public let clock: DoryVirtualClockState

  public init(
    progress: DorySnapshotBarrierProgress,
    expectedVCPUs: [DoryVCPUIdentifier],
    quiescedVCPUs: [DoryVCPUIdentifier],
    memory: [DorySnapshotMemoryGeneration],
    clock: DoryVirtualClockState
  ) throws {
    guard progress.phase == .architecturalStateCaptured else {
      throw DoryExecutionContractError.invalidBarrierTransition(
        from: progress.phase,
        to: .architecturalStateCaptured
      )
    }
    let expected = expectedVCPUs.sorted()
    let actual = quiescedVCPUs.sorted()
    guard Set(expected).count == expected.count else {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "expected vCPUs")
    }
    guard Set(actual).count == actual.count else {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "quiesced vCPUs")
    }
    guard expected == actual else {
      throw DoryExecutionContractError.incompleteVCPUQuiescence(
        expected: expected,
        actual: actual
      )
    }
    let memoryIDs = memory.map(\.regionID)
    guard memoryIDs == memoryIDs.sorted(), Set(memoryIDs).count == memoryIDs.count else {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "snapshot memory generations")
    }
    self.snapshotGeneration = progress.snapshotGeneration
    self.executionGeneration = progress.executionGeneration
    self.expectedVCPUs = expected
    self.quiescedVCPUs = actual
    self.memory = memory
    self.clock = clock
  }

  private enum CodingKeys: String, CodingKey {
    case snapshotGeneration, executionGeneration, expectedVCPUs, quiescedVCPUs, memory, clock
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let progress = try DorySnapshotBarrierProgress(
      snapshotGeneration: container.decode(UInt64.self, forKey: .snapshotGeneration),
      executionGeneration: container.decode(UInt64.self, forKey: .executionGeneration),
      phase: .architecturalStateCaptured
    )
    try self.init(
      progress: progress,
      expectedVCPUs: container.decode([DoryVCPUIdentifier].self, forKey: .expectedVCPUs),
      quiescedVCPUs: container.decode([DoryVCPUIdentifier].self, forKey: .quiescedVCPUs),
      memory: container.decode([DorySnapshotMemoryGeneration].self, forKey: .memory),
      clock: container.decode(DoryVirtualClockState.self, forKey: .clock)
    )
  }
}
