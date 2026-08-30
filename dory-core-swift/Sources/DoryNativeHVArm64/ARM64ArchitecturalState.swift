import DoryExecutionContracts

public struct DoryARM64SIMDRegister: Codable, Sendable, Hashable {
  public let low: UInt64
  public let high: UInt64

  public init(low: UInt64, high: UInt64) {
    self.low = low
    self.high = high
  }

  public static let zero = Self(low: 0, high: 0)
}

/// Mutable ARM64 system registers owned by the execution engine. Read-only CPU identity registers
/// belong to the pinned CPU profile and GIC state belongs to the machine model, so neither is
/// duplicated in this state payload.
public enum DoryARM64SystemRegister: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
  case actlrEL1
  case afsr0EL1
  case afsr1EL1
  case amairEL1
  case apiAKeyHighEL1
  case apiAKeyLowEL1
  case apiBKeyHighEL1
  case apiBKeyLowEL1
  case apdAKeyHighEL1
  case apdAKeyLowEL1
  case apdBKeyHighEL1
  case apdBKeyLowEL1
  case apgAKeyHighEL1
  case apgAKeyLowEL1
  case contextIDREL1
  case cpacrEL1
  case csselrEL1
  case cntkctlEL1
  case cntvControlEL0
  case cntvCompareEL0
  case elrEL1
  case esrEL1
  case farEL1
  case mairEL1
  case mpidrEL1
  case parEL1
  case sctlrEL1
  case spEL0
  case spEL1
  case spsrEL1
  case tcrEL1
  case tpidrEL0
  case tpidrEL1
  case tpidrroEL0
  case ttbr0EL1
  case ttbr1EL1
  case vbarEL1

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct DoryARM64SystemRegisterValue: Codable, Sendable, Hashable, Comparable {
  public let register: DoryARM64SystemRegister
  public let value: UInt64

  public init(register: DoryARM64SystemRegister, value: UInt64) {
    self.register = register
    self.value = value
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.register < rhs.register
  }
}

public enum DoryARM64ArchitecturalStateError: Error, Equatable, Sendable,
  CustomStringConvertible
{
  case unsupportedSchemaVersion(UInt32)
  case invalidGeneralRegisterCount(actual: Int)
  case invalidSIMDRegisterCount(actual: Int)
  case invalidSystemRegisterSet(
    expected: [DoryARM64SystemRegister], actual: [DoryARM64SystemRegister])

  public var description: String {
    switch self {
    case .unsupportedSchemaVersion(let version):
      "unsupported ARM64 architectural state schema: \(version)"
    case .invalidGeneralRegisterCount(let actual):
      "ARM64 architectural state has \(actual) general registers; expected 31"
    case .invalidSIMDRegisterCount(let actual):
      "ARM64 architectural state has \(actual) SIMD registers; expected 32"
    case .invalidSystemRegisterSet(let expected, let actual):
      "ARM64 system register set mismatch: expected \(expected.map(\.rawValue)), got \(actual.map(\.rawValue))"
    }
  }
}

/// Complete version-one engine-owned ARM64 state. There is deliberately no Hypervisor.framework
/// handle, host pointer, translated block, code-cache entry, or machine-device state here.
public struct DoryARM64ArchitecturalState: Codable, Sendable, Hashable {
  public static let schemaVersion: UInt32 = 1
  public static let generalRegisterCount = 31
  public static let simdRegisterCount = 32
  public static let requiredSystemRegisters = DoryARM64SystemRegister.allCases.sorted()

  public let schemaVersion: UInt32
  public let generalRegisters: [UInt64]
  public let programCounter: UInt64
  public let floatingPointControl: UInt64
  public let floatingPointStatus: UInt64
  public let currentProgramStatus: UInt64
  public let simdRegisters: [DoryARM64SIMDRegister]
  public let systemRegisters: [DoryARM64SystemRegisterValue]
  public let irqPending: Bool
  public let fiqPending: Bool
  public let virtualTimerMasked: Bool

  public init(
    generalRegisters: [UInt64],
    programCounter: UInt64,
    floatingPointControl: UInt64,
    floatingPointStatus: UInt64,
    currentProgramStatus: UInt64,
    simdRegisters: [DoryARM64SIMDRegister],
    systemRegisters: [DoryARM64SystemRegisterValue],
    irqPending: Bool,
    fiqPending: Bool,
    virtualTimerMasked: Bool
  ) throws {
    try self.init(
      schemaVersion: Self.schemaVersion,
      generalRegisters: generalRegisters,
      programCounter: programCounter,
      floatingPointControl: floatingPointControl,
      floatingPointStatus: floatingPointStatus,
      currentProgramStatus: currentProgramStatus,
      simdRegisters: simdRegisters,
      systemRegisters: systemRegisters,
      irqPending: irqPending,
      fiqPending: fiqPending,
      virtualTimerMasked: virtualTimerMasked
    )
  }

  private init(
    schemaVersion: UInt32,
    generalRegisters: [UInt64],
    programCounter: UInt64,
    floatingPointControl: UInt64,
    floatingPointStatus: UInt64,
    currentProgramStatus: UInt64,
    simdRegisters: [DoryARM64SIMDRegister],
    systemRegisters: [DoryARM64SystemRegisterValue],
    irqPending: Bool,
    fiqPending: Bool,
    virtualTimerMasked: Bool
  ) throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DoryARM64ArchitecturalStateError.unsupportedSchemaVersion(schemaVersion)
    }
    guard generalRegisters.count == Self.generalRegisterCount else {
      throw DoryARM64ArchitecturalStateError.invalidGeneralRegisterCount(
        actual: generalRegisters.count)
    }
    guard simdRegisters.count == Self.simdRegisterCount else {
      throw DoryARM64ArchitecturalStateError.invalidSIMDRegisterCount(actual: simdRegisters.count)
    }
    let actualRegisters = systemRegisters.map(\.register)
    guard actualRegisters == Self.requiredSystemRegisters else {
      throw DoryARM64ArchitecturalStateError.invalidSystemRegisterSet(
        expected: Self.requiredSystemRegisters,
        actual: actualRegisters
      )
    }
    self.schemaVersion = schemaVersion
    self.generalRegisters = generalRegisters
    self.programCounter = programCounter
    self.floatingPointControl = floatingPointControl
    self.floatingPointStatus = floatingPointStatus
    self.currentProgramStatus = currentProgramStatus
    self.simdRegisters = simdRegisters
    self.systemRegisters = systemRegisters
    self.irqPending = irqPending
    self.fiqPending = fiqPending
    self.virtualTimerMasked = virtualTimerMasked
  }

  public static func reset(programCounter: UInt64, x0: UInt64 = 0) throws -> Self {
    var generalRegisters = [UInt64](repeating: 0, count: generalRegisterCount)
    generalRegisters[0] = x0
    return try Self(
      generalRegisters: generalRegisters,
      programCounter: programCounter,
      floatingPointControl: 0,
      floatingPointStatus: 0,
      currentProgramStatus: 0x3c5,
      simdRegisters: [DoryARM64SIMDRegister](repeating: .zero, count: simdRegisterCount),
      systemRegisters: requiredSystemRegisters.map {
        DoryARM64SystemRegisterValue(register: $0, value: 0)
      },
      irqPending: false,
      fiqPending: false,
      virtualTimerMasked: false
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case generalRegisters
    case programCounter
    case floatingPointControl
    case floatingPointStatus
    case currentProgramStatus
    case simdRegisters
    case systemRegisters
    case irqPending
    case fiqPending
    case virtualTimerMasked
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
      generalRegisters: container.decode([UInt64].self, forKey: .generalRegisters),
      programCounter: container.decode(UInt64.self, forKey: .programCounter),
      floatingPointControl: container.decode(UInt64.self, forKey: .floatingPointControl),
      floatingPointStatus: container.decode(UInt64.self, forKey: .floatingPointStatus),
      currentProgramStatus: container.decode(UInt64.self, forKey: .currentProgramStatus),
      simdRegisters: container.decode([DoryARM64SIMDRegister].self, forKey: .simdRegisters),
      systemRegisters: container.decode(
        [DoryARM64SystemRegisterValue].self,
        forKey: .systemRegisters
      ),
      irqPending: container.decode(Bool.self, forKey: .irqPending),
      fiqPending: container.decode(Bool.self, forKey: .fiqPending),
      virtualTimerMasked: container.decode(Bool.self, forKey: .virtualTimerMasked)
    )
  }
}
