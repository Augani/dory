import DoryExecutionContracts

public enum DoryNativeHVArm64Error: Error, Equatable, Sendable, CustomStringConvertible {
  case unsupportedHostArchitecture
  case hypervisorFailure(call: String, code: UInt32)
  case engineClosed
  case engineStillOwnsVCPUs([DoryVCPUIdentifier])
  case vcpuAlreadyExists(DoryVCPUIdentifier)
  case unknownVCPU(DoryVCPUIdentifier)
  case wrongVCPUArchitecture(DoryExecutionArchitecture)
  case wrongOwnerThread(vcpu: DoryVCPUIdentifier, expected: UInt64, actual: UInt64)
  case memoryRegionAlreadyMapped(UInt32)
  case memoryRangeOverlap(UInt32)
  case memoryMappingNotFound
  case memoryGenerationMismatch(expected: UInt64, actual: UInt64)
  case dirtyTrackingDisabled(UInt32)
  case dirtyEpochMismatch(expected: UInt64, actual: UInt64)
  case pendingExitMustBeCompleted(DoryVCPUIdentifier)
  case noPendingExit(DoryExecutionResumeToken)
  case staleResumeToken(expected: DoryExecutionResumeToken, actual: DoryExecutionResumeToken)
  case invalidExitResponse
  case deadlineNotImplemented
  case vcpuPaused(DoryVCPUIdentifier)
  case vcpuNotPaused(DoryVCPUIdentifier)
  case unexpectedExitReason(UInt32)
  case invalidDataAbortSyndrome(UInt64)
  case memorySizeTooLarge(UInt64)
  case invalidExecutionGeneration(UInt64)
  case snapshotGenerationMismatch(expected: UInt64, actual: UInt64)

  public var description: String {
    switch self {
    case .unsupportedHostArchitecture:
      "DoryNativeHVArm64 requires an Apple-silicon host"
    case .hypervisorFailure(let call, let code):
      "\(call) failed with Hypervisor.framework status 0x\(String(code, radix: 16))"
    case .engineClosed:
      "native ARM64 execution engine is closed"
    case .engineStillOwnsVCPUs(let ids):
      "native ARM64 execution engine still owns vCPUs \(ids.map(\.rawValue))"
    case .vcpuAlreadyExists(let id):
      "vCPU \(id.rawValue) already exists"
    case .unknownVCPU(let id):
      "vCPU \(id.rawValue) does not exist"
    case .wrongVCPUArchitecture(let architecture):
      "native ARM64 engine cannot operate on \(architecture.rawValue) vCPU"
    case .wrongOwnerThread(let vcpu, let expected, let actual):
      "vCPU \(vcpu.rawValue) belongs to thread \(expected), not \(actual)"
    case .memoryRegionAlreadyMapped(let id):
      "guest memory region \(id) is already mapped"
    case .memoryRangeOverlap(let id):
      "guest memory region \(id) overlaps an existing mapping"
    case .memoryMappingNotFound:
      "guest memory mapping was not found"
    case .memoryGenerationMismatch(let expected, let actual):
      "guest memory generation mismatch: expected \(expected), got \(actual)"
    case .dirtyTrackingDisabled(let id):
      "guest memory region \(id) has dirty tracking disabled"
    case .dirtyEpochMismatch(let expected, let actual):
      "dirty epoch mismatch: expected \(expected), got \(actual)"
    case .pendingExitMustBeCompleted(let id):
      "vCPU \(id.rawValue) has a restartable exit awaiting completion"
    case .noPendingExit(let token):
      "no pending exit exists for token \(token.sequence)"
    case .staleResumeToken(let expected, let actual):
      "stale resume token \(actual.sequence); expected \(expected.sequence)"
    case .invalidExitResponse:
      "machine-model response does not match the pending CPU exit"
    case .deadlineNotImplemented:
      "native ARM64 execution deadlines are not implemented"
    case .vcpuPaused(let id):
      "vCPU \(id.rawValue) is paused"
    case .vcpuNotPaused(let id):
      "vCPU \(id.rawValue) is not paused"
    case .unexpectedExitReason(let reason):
      "unexpected Hypervisor.framework exit reason \(reason)"
    case .invalidDataAbortSyndrome(let syndrome):
      "invalid ARM64 data-abort syndrome 0x\(String(syndrome, radix: 16))"
    case .memorySizeTooLarge(let size):
      "guest memory mapping is too large for this host: \(size)"
    case .invalidExecutionGeneration(let generation):
      "native ARM64 execution generation must be nonzero: \(generation)"
    case .snapshotGenerationMismatch(let expected, let actual):
      "snapshot generation mismatch: expected \(expected), got \(actual)"
    }
  }
}

#if arch(arm64)
  import Hypervisor

  @inline(__always)
  func doryNativeHVCheck(_ result: @autoclosure () -> hv_return_t, _ call: String) throws {
    let code = result()
    guard code == HV_SUCCESS else {
      throw DoryNativeHVArm64Error.hypervisorFailure(
        call: call,
        code: UInt32(bitPattern: code)
      )
    }
  }
#endif
