public enum DoryExecutionArchitecture: String, Codable, CaseIterable, Sendable, Hashable {
  case arm64
  case x86_64 = "x86-64"
}

public enum DoryExecutionContractError: Error, Equatable, Sendable, CustomStringConvertible {
  case zeroIdentifier(type: String)
  case emptyRange
  case addressOverflow(base: UInt64, byteCount: UInt64)
  case invalidPageSize(UInt64)
  case unalignedRange(base: UInt64, byteCount: UInt64, pageSize: UInt64)
  case emptyPermissions
  case duplicatePermission(DoryGuestMemoryPermission)
  case invalidGeneration(type: String, value: UInt64)
  case dirtyPageOffsetOutOfRange(UInt64)
  case dirtyPageOffsetUnaligned(UInt64)
  case nonCanonicalDirtyPageOffsets
  case architectureMismatch(expected: DoryExecutionArchitecture, actual: DoryExecutionArchitecture)
  case invalidInterruptVector(architecture: DoryExecutionArchitecture, vector: UInt32)
  case invalidInterruptKind
  case invalidAccessWidth(UInt8)
  case invalidAccessPayload(expected: Int, actual: Int)
  case vcpuMismatch(expected: DoryVCPUIdentifier, actual: DoryVCPUIdentifier)
  case invalidClockFrequency(UInt64)
  case clockMovedBackward(previous: UInt64, next: UInt64)
  case invalidBarrierTransition(from: DorySnapshotBarrierPhase, to: DorySnapshotBarrierPhase)
  case duplicateVCPU(DoryVCPUIdentifier)
  case incompleteVCPUQuiescence(expected: [DoryVCPUIdentifier], actual: [DoryVCPUIdentifier])
  case nonCanonicalCollection(type: String)

  public var description: String {
    switch self {
    case .zeroIdentifier(let type):
      "\(type) must be nonzero"
    case .emptyRange:
      "guest address range must not be empty"
    case .addressOverflow(let base, let byteCount):
      "guest address range overflows: base \(base), byte count \(byteCount)"
    case .invalidPageSize(let size):
      "guest page size must be a nonzero power of two: \(size)"
    case .unalignedRange(let base, let byteCount, let pageSize):
      "guest range \(base)+\(byteCount) is not aligned to page size \(pageSize)"
    case .emptyPermissions:
      "guest memory region must grant at least one permission"
    case .duplicatePermission(let permission):
      "guest memory permission is duplicated: \(permission.rawValue)"
    case .invalidGeneration(let type, let value):
      "\(type) generation must be nonzero: \(value)"
    case .dirtyPageOffsetOutOfRange(let offset):
      "dirty page offset is outside its guest memory region: \(offset)"
    case .dirtyPageOffsetUnaligned(let offset):
      "dirty page offset is not page aligned: \(offset)"
    case .nonCanonicalDirtyPageOffsets:
      "dirty page offsets must be strictly increasing"
    case .architectureMismatch(let expected, let actual):
      "execution architecture mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
    case .invalidInterruptVector(let architecture, let vector):
      "invalid \(architecture.rawValue) interrupt vector: \(vector)"
    case .invalidInterruptKind:
      "interrupt kind is invalid for the selected architecture"
    case .invalidAccessWidth(let width):
      "architectural access width is invalid: \(width)"
    case .invalidAccessPayload(let expected, let actual):
      "architectural access payload has \(actual) bytes; expected \(expected)"
    case .vcpuMismatch(let expected, let actual):
      "vCPU mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
    case .invalidClockFrequency(let frequency):
      "virtual clock frequency must be nonzero: \(frequency)"
    case .clockMovedBackward(let previous, let next):
      "virtual monotonic clock moved backward from \(previous) to \(next)"
    case .invalidBarrierTransition(let from, let to):
      "invalid snapshot barrier transition from \(from.rawValue) to \(to.rawValue)"
    case .duplicateVCPU(let id):
      "duplicate vCPU identifier: \(id.rawValue)"
    case .incompleteVCPUQuiescence(let expected, let actual):
      "snapshot quiescence mismatch: expected \(expected.map(\.rawValue)), got \(actual.map(\.rawValue))"
    case .nonCanonicalCollection(let type):
      "\(type) must be strictly ordered and duplicate-free"
    }
  }
}

public struct DoryVCPUIdentifier: RawRepresentable, Codable, Sendable, Hashable, Comparable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct DoryVCPU: Codable, Sendable, Hashable {
  public let id: DoryVCPUIdentifier
  public let architecture: DoryExecutionArchitecture

  public init(id: DoryVCPUIdentifier, architecture: DoryExecutionArchitecture) {
    self.id = id
    self.architecture = architecture
  }
}
