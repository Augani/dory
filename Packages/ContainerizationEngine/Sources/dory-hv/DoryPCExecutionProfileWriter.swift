import Darwin
import DoryDBTX86
import DoryHV
import DoryMachinePC
import DoryOperations
import DoryVMContracts
import DorydKit
import Foundation

/// Campaign-only samples from the actual PC UEFI runtime. Each line is self-identifying so a
/// daemon/runner restart or renderer replacement cannot silently merge two boot attempts.
final class DoryPCExecutionProfileWriter: @unchecked Sendable {
  enum Reason: String, Codable, Sendable {
    case machineStarted, bootMilestone, periodic, machineReplaced, executionEnded
  }

  enum AdmissionError: Error, Equatable {
    case unsupportedCPUContract
    case machineConfigurationMismatch
  }

  /// Additive, independently versioned identity preserves the existing outer sample schema.
  /// Unavailable source/binary/host evidence is explicit: an admitted component build name is
  /// not a source revision, a current-worktree hash, or a measured host qualification identity.
  struct Identity: Codable, Sendable, Equatable {
    enum UnavailableEvidence: String, Codable, Sendable {
      case executionSourceRevision, executionBinarySHA256, qualifiedHostClass
    }
    let schemaVersion: Int
    let operationID: UUID
    let resolvedPlanSHA256: String
    let planRevision: UInt64
    let executionComponentBuildIdentifier: String
    let virtualHardwareABIVersion: UInt16
    let schedulingPolicyRevision: UInt16
    let cpuProfileID: DoryX86ProfileRegistry.Identifier
    let cpuProfileFingerprint: String
    let unavailableFromLaunchContract: [UnavailableEvidence]
    let machineConfiguration: DoryPCExecutionConfiguration
  }

  private struct AdmittedLaunch: Sendable {
    let operationID: UUID
    let resolvedPlanSHA256: String
    let planRevision: UInt64
    let executionComponentBuildIdentifier: String
    let virtualHardwareABIVersion: UInt16
    let resources: DoryPCRuntimeLaunchEnvelope.ExecutionResources
    let profile: DoryX86ResolvedCPUProfile

    func identity(for machine: DoryPCDirectKernelMachine) throws -> Identity {
      let configuration = machine.executionConfiguration
      let expectedTier: DoryPCExecutionTier = switch resources.tier {
      case .interpreter: .interpreter
      case .baselineJIT: .baselineJIT
      case .optimizingJIT: .optimizingJIT
      }
      guard configuration.cpuProfile == profile.cpuProfile,
        configuration.tier == expectedTier,
        configuration.processorCount == Int(resources.virtualCPUCount),
        UInt64(configuration.memoryBytes) == resources.memoryMB * 1_024 * 1_024
      else { throw AdmissionError.machineConfigurationMismatch }
      return .init(
        schemaVersion: 1,
        operationID: operationID,
        resolvedPlanSHA256: resolvedPlanSHA256,
        planRevision: planRevision,
        executionComponentBuildIdentifier: executionComponentBuildIdentifier,
        virtualHardwareABIVersion: virtualHardwareABIVersion,
        schedulingPolicyRevision: resources.schedulingPolicyRevision,
        cpuProfileID: profile.identifier,
        cpuProfileFingerprint: profile.fingerprint,
        unavailableFromLaunchContract: [
          .executionSourceRevision, .executionBinarySHA256, .qualifiedHostClass,
        ],
        machineConfiguration: configuration
      )
    }
  }

  private struct Sample: Codable {
    let schemaVersion: Int
    let kind: String
    let launchID: UUID
    let machineID: String
    let operationID: String
    let sequence: UInt64
    let machineSequence: UInt64
    let monotonicNanoseconds: UInt64
    let reason: Reason
    let identity: Identity
    let execution: DoryPCExecutionStatistics
    let hostExecution: DoryPCHostExecutionDiagnostics
    let physicalMemoryByProcessor: [DoryPCPhysicalMemoryDiagnostics]
    let pagingByProcessor: [DoryX86PagingDiagnostics]
    let memoryAccess: DoryX86MemoryAccessDiagnostics
    let bootTimeline: DoryPCBootTimeline.Snapshot?
  }

  private let lock = NSLock()
  private let handle: FileHandle
  private let launchID = UUID()
  private let machineID: String
  private let operationID: String
  private let admittedLaunch: AdmittedLaunch
  private var sequence: UInt64 = 0

  init(stateDirectory: String, admittedEnvelope envelope: DoryPCRuntimeLaunchEnvelope) throws {
    // Validate the existing descriptor-only contract without opening or consuming any FD.
    // Reject malformed identity before creating even the campaign output file.
    _ = try envelope.validatedResources()
    guard envelope.platform.cpuProfile == .compatibleX8664V1 else {
      throw AdmissionError.unsupportedCPUContract
    }
    admittedLaunch = .init(
      operationID: envelope.operationID,
      resolvedPlanSHA256: envelope.resolvedPlanSHA256,
      planRevision: envelope.planRevision,
      executionComponentBuildIdentifier: envelope.executionComponentBuildIdentifier,
      virtualHardwareABIVersion: envelope.virtualHardwareABIVersion,
      resources: envelope.executionResources,
      profile: try DoryX86ProfileRegistry.resolve(.baselineV1)
    )
    let path = stateDirectory + "/pc-execution-profile.ndjson"
    let descriptor = Darwin.open(
      path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600
    )
    guard descriptor >= 0 else {
      throw VMError.invalidConfiguration(
        "could not open DoryPC execution profile: errno \(errno)"
      )
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      status.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw VMError.invalidConfiguration("DoryPC execution profile is not an owner-private file")
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    self.machineID = envelope.machineID
    self.operationID = DoryOperationIdentity.canonical(envelope.operationID)
  }

  func record(
    reason: Reason,
    machineSequence: UInt64,
    machine: DoryPCDirectKernelMachine,
    bootTimeline: DoryPCBootTimeline.Snapshot?
  ) throws {
    let identity = try admittedLaunch.identity(for: machine)
    let execution = machine.executionStatistics
    let hostExecution = machine.hostExecutionDiagnostics
    let physicalMemory = machine.physicalMemories.map(\.diagnostics)
    let paging = machine.pagingDiagnostics
    let memoryAccess = machine.memoryAccessDiagnostics
    try lock.withLock {
      guard sequence < .max else {
        throw VMError.bootFailure("DoryPC execution profile sequence exhausted")
      }
      sequence += 1
      let sample = Sample(
        schemaVersion: 1,
        kind: "dev.dory.pc-execution-profile",
        launchID: launchID,
        machineID: machineID,
        operationID: operationID,
        sequence: sequence,
        machineSequence: machineSequence,
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
        reason: reason,
        identity: identity,
        execution: execution,
        hostExecution: hostExecution,
        physicalMemoryByProcessor: physicalMemory,
        pagingByProcessor: paging,
        memoryAccess: memoryAccess,
        bootTimeline: bootTimeline
      )
      var line = try JSONEncoder().encode(sample)
      line.append(0x0A)
      try handle.write(contentsOf: line)
      try handle.synchronize()
    }
  }

  deinit { try? handle.close() }
}
