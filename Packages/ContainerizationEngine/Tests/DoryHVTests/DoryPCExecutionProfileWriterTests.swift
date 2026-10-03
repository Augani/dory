import DoryDBTX86
import DoryFirmware
import DoryMachinePC
import DoryOperations
import DoryVMContracts
import DorydKit
import Foundation
import Testing
@testable import dory_hv

@Suite struct DoryPCExecutionProfileWriterTests {
  @Test func recordsCorrelatedMachineSamplesWithoutGuestTools() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-pc-profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: Int(DoryPCV1ABI.minimumProductMemoryBytes),
      instrumentationEnabled: true
    )
    let writer = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path,
      admittedEnvelope: makeProfileEnvelope()
    )
    try writer.record(reason: .machineStarted, machineSequence: 1, machine: machine,
                      bootTimeline: nil)
    try writer.record(reason: .periodic, machineSequence: 1, machine: machine,
                      bootTimeline: nil)

    let data = try Data(contentsOf: directory.appendingPathComponent(
      "pc-execution-profile.ndjson"))
    let lines = data.split(separator: 0x0A)
    #expect(lines.count == 2)
    let first = try #require(JSONSerialization.jsonObject(with: Data(lines[0]))
      as? [String: Any])
    let second = try #require(JSONSerialization.jsonObject(with: Data(lines[1]))
      as? [String: Any])
    #expect(first["machineID"] as? String == "profile-machine")
    #expect(first["operationID"] as? String == DoryOperationIdentity.canonical(profileOperationID))
    #expect(first["schemaVersion"] as? Int == 1)
    #expect(first["sequence"] as? Int == 1)
    #expect(second["sequence"] as? Int == 2)
    #expect(first["launchID"] as? String == second["launchID"] as? String)
    #expect(first["reason"] as? String == "machineStarted")
    #expect(second["reason"] as? String == "periodic")
    #expect((first["physicalMemoryByProcessor"] as? [Any])?.count == 1)
    #expect((first["pagingByProcessor"] as? [Any])?.count == 1)
    #expect((first["hostExecution"] as? [String: Any])?["enabled"] as? Bool == true)
    let memoryAccess = try profileMemoryAccess(first)
    #expect(memoryAccess.schemaVersion == 1)
    #expect(memoryAccess == machine.memoryAccessDiagnostics)
  }

  @Test func retainsMachineWideLiveAndCompletedMemoryContention() throws {
    let directory = try profileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: Int(DoryPCV1ABI.minimumProductMemoryBytes), instrumentationEnabled: true)
    let writer = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path, admittedEnvelope: makeProfileEnvelope())
    let coordinator = machine.physicalMemory.memoryAccessCoordinator
    let ranges = try #require(try machine.physicalMemory.memoryAccessRanges(
      at: 0x1000, byteCount: 8, access: .read))
    let holder = coordinator.acquireExclusive(ranges: ranges)
    defer { holder.release() }
    let before = machine.memoryAccessDiagnostics
    let finished = DispatchSemaphore(value: 0)
    let failure = ProfileContentionFailure()
    Thread.detachNewThread {
      do { _ = try machine.physicalMemory.read(at: 0x1000, byteCount: 8) }
      catch { failure.record(error) }
      finished.signal()
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while machine.memoryAccessDiagnostics.waitingOrdinaryLeases == 0,
      DispatchTime.now().uptimeNanoseconds < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    try #require(machine.memoryAccessDiagnostics.waitingOrdinaryLeases == 1)
    try writer.record(reason: .periodic, machineSequence: 1, machine: machine, bootTimeline: nil)
    holder.release()
    try #require(finished.wait(timeout: .now() + 2) == .success)
    if let error = failure.error { throw error }
    try writer.record(reason: .periodic, machineSequence: 1, machine: machine, bootTimeline: nil)
    let snapshots = try profileSamples(directory).map(profileMemoryAccess)
    #expect(snapshots.count == 2)
    #expect(snapshots[0].ordinaryAcquisitions == before.ordinaryAcquisitions)
    #expect(snapshots[0].contendedOrdinaryAcquisitions == before.contendedOrdinaryAcquisitions + 1)
    #expect(snapshots[0].waitingOrdinaryLeases == 1)
    #expect(snapshots[0].activeExclusiveLeases == 1)
    #expect(snapshots[0].ordinaryWaitNanoseconds == before.ordinaryWaitNanoseconds)
    #expect(snapshots[1].ordinaryAcquisitions == before.ordinaryAcquisitions + 1)
    #expect(snapshots[1].contendedOrdinaryAcquisitions == snapshots[0].contendedOrdinaryAcquisitions)
    #expect(snapshots[1].ordinaryWaitNanoseconds > snapshots[0].ordinaryWaitNanoseconds)
    #expect(snapshots[1].waitingOrdinaryLeases == 0)
    #expect(snapshots[1].activeOrdinaryLeases == 0 && snapshots[1].activeExclusiveLeases == 0)
    #expect(snapshots[1] == machine.memoryAccessDiagnostics)
  }

  @Test func refusesSymlinkProfileTarget() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-pc-profile-link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("outside")
    try Data("unchanged".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("pc-execution-profile.ndjson"),
      withDestinationURL: target
    )
    #expect(throws: (any Error).self) {
      _ = try DoryPCExecutionProfileWriter(
        stateDirectory: directory.path,
        admittedEnvelope: makeProfileEnvelope()
      )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
  }

  @Test func identityRecordsActualOptionsAndExplicitlyUnavailableBuildEvidence() throws {
    let directory = try profileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let envelope = try makeProfileEnvelope(tier: .baselineJIT)
    let machine = try profileTestMachine(
      tier1: false, predictors: .indirectBranchTargetCache,
      coherence: .checkedCallbacks, clock: .hostMonotonic, instrumentation: true
    )
    let writer = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path, admittedEnvelope: envelope)
    try writer.record(reason: .machineStarted, machineSequence: 1, machine: machine,
      bootTimeline: nil)
    let sample = try profileSamples(directory)[0]
    let identity = try profileIdentity(sample)
    #expect(sample["schemaVersion"] as? Int == 1)
    #expect(identity.schemaVersion == 1)
    #expect(identity.operationID == envelope.operationID)
    #expect(identity.resolvedPlanSHA256 == envelope.resolvedPlanSHA256)
    #expect(identity.planRevision == envelope.planRevision)
    #expect(identity.executionComponentBuildIdentifier == envelope.executionComponentBuildIdentifier)
    #expect(identity.virtualHardwareABIVersion == envelope.virtualHardwareABIVersion)
    #expect(identity.schedulingPolicyRevision == envelope.executionResources.schedulingPolicyRevision)
    let resolved = try DoryX86ProfileRegistry.resolve(.baselineV1)
    #expect(identity.cpuProfileID == resolved.identifier)
    #expect(identity.cpuProfileFingerprint == resolved.fingerprint)
    #expect(identity.unavailableFromLaunchContract == [
      .executionSourceRevision, .executionBinarySHA256, .qualifiedHostClass,
    ])
    #expect(identity.machineConfiguration == machine.executionConfiguration)
    #expect(identity.machineConfiguration.baselineJITTier1Enabled == false)
    #expect(identity.machineConfiguration.rawTargetPredictionOptionBits
      == DoryARM64RawTargetPredictionOptions.indirectBranchTargetCache.rawValue)
    #expect(identity.machineConfiguration.baselineCodeByteLimitsByProcessor == [65_536])
    #expect(identity.machineConfiguration.optimizingCodeByteLimitsByProcessor.isEmpty)
    #expect(identity.machineConfiguration.jitWriteCoherencePolicy == .checkedCallbacks)
    #expect(identity.machineConfiguration.clockKind == .hostMonotonic)
    #expect(identity.machineConfiguration.instrumentationEnabled)
  }

  @Test func buildPlanAndActualSettingsChangesHaveDifferentImmutableIdentities() throws {
    let directory = try profileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstEnvelope = try makeProfileEnvelope(tier: .baselineJIT)
    let secondEnvelope = try makeProfileEnvelope(
      tier: .baselineJIT, build: "dory-dbt-profile-test.2", planHash: String(repeating: "c", count: 64),
      planRevision: 2)
    let first = try profileTestMachine(tier1: true)
    let second = try profileTestMachine(tier1: false, predictors: .shadowReturnStack)
    let writer = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path, admittedEnvelope: firstEnvelope)
    try writer.record(reason: .machineStarted, machineSequence: 1, machine: first, bootTimeline: nil)
    try writer.record(reason: .machineReplaced, machineSequence: 2, machine: second, bootTimeline: nil)
    let replacementWriter = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path, admittedEnvelope: secondEnvelope)
    try replacementWriter.record(reason: .machineStarted, machineSequence: 1, machine: second,
      bootTimeline: nil)
    let samples = try profileSamples(directory)
    let identities = try samples.map(profileIdentity)
    #expect(identities.count == 3)
    #expect(identities[0] != identities[1])
    #expect(identities[1] != identities[2])
    #expect(identities[0].machineConfiguration == first.executionConfiguration)
    #expect(identities[1].machineConfiguration == second.executionConfiguration)
    #expect(identities[1].resolvedPlanSHA256 == firstEnvelope.resolvedPlanSHA256)
    #expect(identities[2].resolvedPlanSHA256 == secondEnvelope.resolvedPlanSHA256)
    #expect(identities[2].planRevision == 2)
    #expect(identities[2].executionComponentBuildIdentifier == "dory-dbt-profile-test.2")
    #expect(samples[0]["launchID"] as? String == samples[1]["launchID"] as? String)
    #expect(samples[1]["launchID"] as? String != samples[2]["launchID"] as? String)
  }

  @Test func substitutedMachineConfigurationIsRejectedWithoutAppendingOrConsumingSequence() throws {
    let directory = try profileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let envelope = try makeProfileEnvelope()
    let writer = try DoryPCExecutionProfileWriter(
      stateDirectory: directory.path, admittedEnvelope: envelope)
    let valid = try DoryPCDirectKernelMachine(
      memoryBytes: Int(DoryPCV1ABI.minimumProductMemoryBytes))
    try writer.record(reason: .machineStarted, machineSequence: 1, machine: valid, bootTimeline: nil)
    for variant in ["profile", "tier", "memory", "processor-count"] {
      let substituted = try DoryPCDirectKernelMachine(
        memoryBytes: variant == "memory" ? 2 * 1_024 * 1_024 : valid.memoryByteCount,
        processorCount: variant == "processor-count" ? 2 : 1,
        interpreter: .init(profile: variant == "profile" ? .intelCompatibleV1 : .compatibleV1),
        executionTier: variant == "tier" ? .baselineJIT : .interpreter,
        baselineJITMaximumCodeBytes: 65_536)
      #expect(throws: DoryPCExecutionProfileWriter.AdmissionError.machineConfigurationMismatch) {
        try writer.record(reason: .machineReplaced, machineSequence: 2, machine: substituted,
          bootTimeline: nil)
      }
    }
    try writer.record(reason: .periodic, machineSequence: 1, machine: valid, bootTimeline: nil)
    let samples = try profileSamples(directory)
    #expect(samples.count == 2)
    #expect(samples[0]["sequence"] as? Int == 1)
    #expect(samples[1]["sequence"] as? Int == 2)
  }

  @Test func malformedLaunchIdentityIsRejectedBeforeCreatingOutput() throws {
    let directory = try profileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let envelope = try makeProfileEnvelope(planHash: "not-an-admitted-plan")
    #expect(throws: (any Error).self) {
      _ = try DoryPCExecutionProfileWriter(stateDirectory: directory.path, admittedEnvelope: envelope)
    }
    #expect(!FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("pc-execution-profile.ndjson").path))
  }
}

private let profileOperationID = UUID(uuidString: "7ca00e75-0430-4aae-b13f-9c30b3d36389")!

private func profileTestDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("dory-pc-profile-identity-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}

private func profileSamples(_ directory: URL) throws -> [[String: Any]] {
  try Data(contentsOf: directory.appendingPathComponent("pc-execution-profile.ndjson"))
    .split(separator: 0x0A).map {
      try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
}

private func profileIdentity(_ sample: [String: Any]) throws -> DoryPCExecutionProfileWriter.Identity {
  let identity = try #require(sample["identity"] as? [String: Any])
  return try JSONDecoder().decode(DoryPCExecutionProfileWriter.Identity.self,
    from: JSONSerialization.data(withJSONObject: identity))
}

private func profileMemoryAccess(_ sample: [String: Any]) throws -> DoryX86MemoryAccessDiagnostics {
  let snapshot = try #require(sample["memoryAccess"] as? [String: Any])
  return try JSONDecoder().decode(DoryX86MemoryAccessDiagnostics.self,
    from: JSONSerialization.data(withJSONObject: snapshot))
}

private final class ProfileContentionFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var captured: (any Error)?
  var error: (any Error)? { lock.withLock { captured } }
  func record(_ error: any Error) { lock.withLock { captured = error } }
}

private func profileTestMachine(
  tier1: Bool,
  predictors: DoryARM64RawTargetPredictionOptions = [],
  coherence: DoryX86JITWriteCoherencePolicy = .protectedHostPages,
  clock: DoryPCClockSource = .deterministic,
  instrumentation: Bool = false
) throws -> DoryPCDirectKernelMachine {
  try .init(memoryBytes: Int(DoryPCV1ABI.minimumProductMemoryBytes), executionTier: .baselineJIT,
    baselineJITMaximumCodeBytes: 65_536, baselineJITTier1Enabled: tier1,
    baselineJITRawTargetPredictionOptions: predictors, jitWriteCoherencePolicy: coherence,
    clockSource: clock, instrumentationEnabled: instrumentation)
}

/// Descriptor-layout-only fixtures: no firmware, disk, helper, or guest is opened or started.
private func makeProfileEnvelope(
  tier: DoryPCRuntimeLaunchEnvelope.ExecutionTier = .interpreter,
  build: String = "dory-dbt-profile-test.1",
  planHash: String = String(repeating: "b", count: 64),
  planRevision: UInt64 = 1
) throws -> DoryPCRuntimeLaunchEnvelope {
  let digest = String(repeating: "a", count: 64)
  let firmware = try DoryFirmwareArtifactManifest(
    platform: .pcV1, buildIdentifier: "dory-pc-profile-test.1",
    source: .init(repository: "https://github.com/tianocore/edk2.git",
      revision: String(repeating: "a", count: 40)),
    sourceDateEpoch: 1, platformConfigurationSHA256: digest, toolchainSHA256: digest,
    firmwareCodeSHA256: digest, firmwareCodeByteCount: 4_096,
    variableStoreTemplateSHA256: digest, variableStoreTemplateByteCount: 4_096,
    sbomSHA256: digest, secureBootPolicy: .disabled, reproducible: true)
  let diskID = try DoryVirtualDeviceID("system-disk")
  let device = try DoryPCUEFIBootDevice(logicalID: diskID.rawValue, kind: .systemDisk,
    pciAddress: DoryPCV1ABI.systemDiskPCIAddress, readOnly: false)
  let plan = try DoryPCUEFILaunchPlan(firmware: firmware, variableStoreGeneration: 1,
    bootDevices: [device], bootOrder: [diskID.rawValue])
  return .resolvedUEFI(machineID: "profile-machine", operationID: profileOperationID,
    resolvedPlanSHA256: planHash, planRevision: planRevision,
    executionComponentBuildIdentifier: build, virtualHardwareABIVersion: 1,
    graphics: .software,
    devices: .init(networkInterface: .stable(machineID: "profile-machine"),
      displays: [.init(widthPixels: 1_280, heightPixels: 800)]),
    portForwards: [], executionResources: .init(
      memoryMB: DoryPCV1ABI.minimumProductMemoryBytes / 1_024 / 1_024, virtualCPUCount: 1, tier: tier),
    systemDiskCapacityBytes: 512 * 1_024 * 1_024, systemDiskLogicalID: diskID,
    launchPlan: plan, firmwareSBOMByteCount: 4_096)
}
