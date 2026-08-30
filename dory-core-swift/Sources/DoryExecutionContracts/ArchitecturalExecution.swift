public enum DoryArchitecturalAccessDirection: String, Codable, Sendable, Hashable {
  case read
  case write
}

public struct DoryExecutionResumeToken: Codable, Sendable, Hashable {
  public let vcpu: DoryVCPUIdentifier
  public let executionGeneration: UInt64
  public let sequence: UInt64

  public init(vcpu: DoryVCPUIdentifier, executionGeneration: UInt64, sequence: UInt64) throws {
    guard executionGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "execution",
        value: executionGeneration
      )
    }
    guard sequence > 0 else {
      throw DoryExecutionContractError.invalidGeneration(type: "exit sequence", value: sequence)
    }
    self.vcpu = vcpu
    self.executionGeneration = executionGeneration
    self.sequence = sequence
  }

  private enum CodingKeys: String, CodingKey { case vcpu, executionGeneration, sequence }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      vcpu: container.decode(DoryVCPUIdentifier.self, forKey: .vcpu),
      executionGeneration: container.decode(UInt64.self, forKey: .executionGeneration),
      sequence: container.decode(UInt64.self, forKey: .sequence)
    )
  }
}

public struct DoryArchitecturalMemoryAccess: Codable, Sendable, Hashable {
  public let address: DoryGuestPhysicalAddress
  public let widthBytes: UInt8
  public let direction: DoryArchitecturalAccessDirection
  public let value: [UInt8]

  public init(
    address: DoryGuestPhysicalAddress,
    widthBytes: UInt8,
    direction: DoryArchitecturalAccessDirection,
    value: [UInt8] = []
  ) throws {
    guard [1, 2, 4, 8, 16].contains(widthBytes) else {
      throw DoryExecutionContractError.invalidAccessWidth(widthBytes)
    }
    let expected = direction == .write ? Int(widthBytes) : 0
    guard value.count == expected else {
      throw DoryExecutionContractError.invalidAccessPayload(
        expected: expected,
        actual: value.count
      )
    }
    self.address = address
    self.widthBytes = widthBytes
    self.direction = direction
    self.value = value
  }

  private enum CodingKeys: String, CodingKey { case address, widthBytes, direction, value }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      address: container.decode(DoryGuestPhysicalAddress.self, forKey: .address),
      widthBytes: container.decode(UInt8.self, forKey: .widthBytes),
      direction: container.decode(DoryArchitecturalAccessDirection.self, forKey: .direction),
      value: container.decode([UInt8].self, forKey: .value)
    )
  }
}

public struct DoryArchitecturalPortAccess: Codable, Sendable, Hashable {
  public let port: UInt16
  public let widthBytes: UInt8
  public let direction: DoryArchitecturalAccessDirection
  public let value: [UInt8]

  public init(
    port: UInt16,
    widthBytes: UInt8,
    direction: DoryArchitecturalAccessDirection,
    value: [UInt8] = []
  ) throws {
    guard [1, 2, 4].contains(widthBytes) else {
      throw DoryExecutionContractError.invalidAccessWidth(widthBytes)
    }
    let expected = direction == .write ? Int(widthBytes) : 0
    guard value.count == expected else {
      throw DoryExecutionContractError.invalidAccessPayload(
        expected: expected,
        actual: value.count
      )
    }
    self.port = port
    self.widthBytes = widthBytes
    self.direction = direction
    self.value = value
  }

  private enum CodingKeys: String, CodingKey { case port, widthBytes, direction, value }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      port: container.decode(UInt16.self, forKey: .port),
      widthBytes: container.decode(UInt8.self, forKey: .widthBytes),
      direction: container.decode(DoryArchitecturalAccessDirection.self, forKey: .direction),
      value: container.decode([UInt8].self, forKey: .value)
    )
  }
}

public enum DoryArchitecturalFaultKind: String, Codable, Sendable, Hashable {
  case instructionAbort
  case dataAbort
  case pageFault
  case generalProtection
  case undefinedInstruction
  case alignment
}

public struct DoryArchitecturalFault: Codable, Sendable, Hashable {
  public let kind: DoryArchitecturalFaultKind
  public let programCounter: UInt64
  public let address: DoryGuestPhysicalAddress?
  public let access: DoryArchitecturalAccessDirection?
  public let architectureCode: UInt64

  public init(
    kind: DoryArchitecturalFaultKind,
    programCounter: UInt64,
    address: DoryGuestPhysicalAddress? = nil,
    access: DoryArchitecturalAccessDirection? = nil,
    architectureCode: UInt64
  ) {
    self.kind = kind
    self.programCounter = programCounter
    self.address = address
    self.access = access
    self.architectureCode = architectureCode
  }
}

public enum DoryCPUExitReason: Codable, Sendable, Hashable {
  case halted
  case waitingForInterrupt
  case memoryMappedIO(DoryArchitecturalMemoryAccess, resume: DoryExecutionResumeToken)
  case portIO(DoryArchitecturalPortAccess, resume: DoryExecutionResumeToken)
  case hypercall(number: UInt64, arguments: [UInt64], resume: DoryExecutionResumeToken)
  case fault(DoryArchitecturalFault)
  case breakpoint(programCounter: UInt64)
  case cancelled(DoryExecutionCancellationRequest)
}

/// Machine-model response to one restartable execution exit. The engine validates the response
/// against the pending token before changing architectural state or advancing the guest PC.
public enum DoryCPUExitResponse: Codable, Sendable, Hashable {
  case completedWrite
  case readValue([UInt8])
  case hypercallResult([UInt64])
}

public struct DoryCPUExit: Codable, Sendable, Hashable {
  public let vcpu: DoryVCPUIdentifier
  public let retiredInstructions: UInt64
  public let reason: DoryCPUExitReason

  public init(
    vcpu: DoryVCPUIdentifier,
    retiredInstructions: UInt64,
    reason: DoryCPUExitReason
  ) throws {
    let resumeVCPU: DoryVCPUIdentifier?
    switch reason {
    case .memoryMappedIO(_, let resume),
      .portIO(_, let resume),
      .hypercall(_, _, let resume):
      resumeVCPU = resume.vcpu
    default:
      resumeVCPU = nil
    }
    if let resumeVCPU, resumeVCPU != vcpu {
      throw DoryExecutionContractError.vcpuMismatch(expected: vcpu, actual: resumeVCPU)
    }
    self.vcpu = vcpu
    self.retiredInstructions = retiredInstructions
    self.reason = reason
  }

  private enum CodingKeys: String, CodingKey { case vcpu, retiredInstructions, reason }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      vcpu: container.decode(DoryVCPUIdentifier.self, forKey: .vcpu),
      retiredInstructions: container.decode(UInt64.self, forKey: .retiredInstructions),
      reason: container.decode(DoryCPUExitReason.self, forKey: .reason)
    )
  }
}

public enum DoryArchitecturalInterruptKind: String, Codable, Sendable, Hashable {
  case maskable
  case nonMaskable
}

public struct DoryArchitecturalInterrupt: Codable, Sendable, Hashable {
  public let architecture: DoryExecutionArchitecture
  public let kind: DoryArchitecturalInterruptKind
  public let vector: UInt32
  public let deliveryGeneration: UInt64

  public init(
    architecture: DoryExecutionArchitecture,
    kind: DoryArchitecturalInterruptKind,
    vector: UInt32,
    deliveryGeneration: UInt64
  ) throws {
    switch architecture {
    case .arm64:
      guard kind == .maskable else { throw DoryExecutionContractError.invalidInterruptKind }
      guard vector <= 1_019 else {
        throw DoryExecutionContractError.invalidInterruptVector(
          architecture: architecture,
          vector: vector
        )
      }
    case .x86_64:
      guard vector <= 255 else {
        throw DoryExecutionContractError.invalidInterruptVector(
          architecture: architecture,
          vector: vector
        )
      }
      if kind == .nonMaskable, vector != 2 {
        throw DoryExecutionContractError.invalidInterruptKind
      }
    }
    guard deliveryGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "interrupt delivery",
        value: deliveryGeneration
      )
    }
    self.architecture = architecture
    self.kind = kind
    self.vector = vector
    self.deliveryGeneration = deliveryGeneration
  }

  private enum CodingKeys: String, CodingKey {
    case architecture, kind, vector, deliveryGeneration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      architecture: container.decode(DoryExecutionArchitecture.self, forKey: .architecture),
      kind: container.decode(DoryArchitecturalInterruptKind.self, forKey: .kind),
      vector: container.decode(UInt32.self, forKey: .vector),
      deliveryGeneration: container.decode(UInt64.self, forKey: .deliveryGeneration)
    )
  }
}

public struct DoryInterruptAcknowledgement: Codable, Sendable, Hashable {
  public let vcpu: DoryVCPUIdentifier
  public let vector: UInt32
  public let deliveryGeneration: UInt64

  public init(vcpu: DoryVCPUIdentifier, interrupt: DoryArchitecturalInterrupt) {
    self.vcpu = vcpu
    self.vector = interrupt.vector
    self.deliveryGeneration = interrupt.deliveryGeneration
  }
}

public enum DoryExecutionTraceKind: String, Codable, Sendable, Hashable {
  case enteredGuest
  case exitedGuest
  case interruptInjected
  case interruptAcknowledged
  case cancellationObserved
  case snapshotBoundary
}

/// A sequence-bearing trace marker. It carries no host timestamp and therefore cannot alter or be
/// mistaken for guest-visible clock ordering.
public struct DoryExecutionTracePoint: Codable, Sendable, Hashable {
  public let sequence: UInt64
  public let executionGeneration: UInt64
  public let vcpu: DoryVCPUIdentifier
  public let kind: DoryExecutionTraceKind
  public let programCounter: UInt64?

  public init(
    sequence: UInt64,
    executionGeneration: UInt64,
    vcpu: DoryVCPUIdentifier,
    kind: DoryExecutionTraceKind,
    programCounter: UInt64? = nil
  ) throws {
    guard sequence > 0 else {
      throw DoryExecutionContractError.invalidGeneration(type: "trace sequence", value: sequence)
    }
    guard executionGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "execution",
        value: executionGeneration
      )
    }
    self.sequence = sequence
    self.executionGeneration = executionGeneration
    self.vcpu = vcpu
    self.kind = kind
    self.programCounter = programCounter
  }
}
