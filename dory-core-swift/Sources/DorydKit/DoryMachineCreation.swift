import DoryOperations
import DoryVZMacCore
import Foundation

/// Caller intent stays stable across acquisition and retry; private preparation may normalize
/// paths and platform resources without changing which request owns the new workspace.
struct DoryMachineCreationRequest: Codable, Sendable, Equatable {
    var configuration: DoryMachineConfiguration
    var typedSettings: DoryMachineTypedSettingsPatch?
    var sandboxPolicy: DoryVMSandboxPolicy?
    var sourceMachineID: String?
    var sourceSnapshotID: String?

    func digest() throws -> String { try DoryMachineDesktopUpdateJournal.digest(self) }
}

struct DoryMachineCreationJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var request: DoryMachineCreationRequest
    var normalizedConfigurationData: Data
    var machineDirectory: String
    var runtimePolicy: DoryWorkspaceRuntimePolicy
    var usesNativeWorkspaceAuthority: Bool
    var virtualHardwareABIVersion: UInt16
    var createdAtUnixMilliseconds: Int64
    var snapshot: DoryMachineSnapshot?
    var sourceConfigurationData: Data?
    var sourceWorkspaceData: Data?
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity?

    var machineID: String { request.configuration.id }
    var stagingDirectory: String {
        URL(fileURLWithPath: machineDirectory).deletingLastPathComponent()
            .appendingPathComponent(".dory-creation-\(operationID.uuidString.lowercased())").path
    }
    var normalizedConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: normalizedConfigurationData) }
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let machine = try normalizedConfiguration
        var normalizedIntent = request.configuration
        normalizedIntent.guestArchitecture = machine.guestArchitecture
        normalizedIntent.address = machine.address
        normalizedIntent.cloneReceipt = nil
        guard request.configuration.address?.trimmingCharacters(in: .whitespacesAndNewlines) == machine.address
                || (request.configuration.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    && machine.address == nil,
              request.configuration.shares.count == machine.shares.count else {
            throw MachineManagerError.persistence("creation normalization changed caller intent")
        }
        for (requested, sealed) in zip(request.configuration.shares, machine.shares) {
            guard requested.tag == sealed.tag, requested.hostPath == sealed.hostPath,
                  requested.guestPath == sealed.guestPath, requested.readOnly == sealed.readOnly,
                  requested.authorizationBookmark == sealed.authorizationBookmark else {
                throw MachineManagerError.persistence("creation normalization changed a selected share")
            }
        }
        normalizedIntent.shares = machine.shares
        guard schemaVersion == 1, operation.validate().isEmpty,
              normalizedIntent == machine,
              operation.creationSpecificationDigest != nil,
              operationID == operation.operationID,
              machine.id == machineID, operation.target.workspaceID == machineID,
              machine.guestFamily == request.configuration.guestFamily,
              request.configuration.guestArchitecture == nil
                || machine.guestArchitecture == request.configuration.guestArchitecture,
              virtualHardwareABIVersion > 0,
              !usesNativeWorkspaceAuthority || runtimePolicy == .requireResolvedPlan,
              createdAtUnixMilliseconds == operation.createdAtUnixMilliseconds,
              operation.target.creation == DoryWorkspaceCreationRequirement(
                requestSHA256: try request.digest(), virtualHardwareABIVersion: virtualHardwareABIVersion,
                runtimePolicy: runtimePolicy
              ),
              machineDirectory.hasPrefix("/"), !machineDirectory.contains("\0"),
              URL(fileURLWithPath: machineDirectory).standardizedFileURL.path == machineDirectory,
              URL(fileURLWithPath: machineDirectory).lastPathComponent == machineID,
              machine.cloneReceipt == nil else {
            throw MachineManagerError.persistence("workspace creation recovery authority is invalid")
        }
        if let snapshot {
            guard operation.kind == .cloning,
                  request.sourceMachineID == snapshot.machineID, request.sourceSnapshotID == snapshot.id,
                  operation.source.workspaceID == snapshot.machineID, snapshot.machineID != machineID,
                  operation.targetResourceID == snapshot.id,
                  snapshot.runtimeIdentity.virtualHardwareABIVersion == virtualHardwareABIVersion,
                  let evidence = snapshot.artifactEvidence, evidence.isValid else {
                throw MachineManagerError.persistence("clone source authority is incomplete")
            }
            if operation.source.state == .absent {
                guard sourceConfigurationData == nil, sourceWorkspaceData == nil, sourceRuntimeIdentity == nil,
                      runtimePolicy == .requireResolvedPlan else {
                    throw MachineManagerError.persistence("detached snapshot clone cannot invent workspace authority")
                }
            } else {
                guard let sourceConfigurationData, let sourceWorkspaceData, let sourceRuntimeIdentity,
                      sourceRuntimeIdentity.validate().isEmpty,
                      sourceRuntimeIdentity.virtualHardwareABIVersion == virtualHardwareABIVersion else {
                    throw MachineManagerError.persistence("clone source workspace authority is incomplete")
                }
                let source = try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData)
                let workspace = try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData)
                guard source.id == snapshot.machineID, workspace.definition.identity.id == source.id,
                      workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
                      workspace.definition.validate().isEmpty,
                      operation.source.definitionRevision == workspace.definition.lifecycle.revision,
                      operation.source.configurationAuthority?.legacyConfigurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(sourceConfigurationData),
                      operation.source.configurationAuthority?.canonicalDefinitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(workspace.definition)),
                      operation.source.runtime == (try Self.binding(sourceRuntimeIdentity)) else {
                    throw MachineManagerError.persistence("clone source workspace authority changed")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard operation.targetSnapshotAuthority == DoryWorkspaceSnapshotAuthority(
                    descriptorSHA256: DoryMachineConfigurationUpdateJournal.sha256(try encoder.encode(snapshot)),
                    artifactEvidenceSHA256: try DoryMachineDesktopUpdateJournal.digest(evidence)
                  ),
                  machine.kernelPath == snapshot.kernelPath, machine.rootfsPath == snapshot.rootfsPath,
                  machine.bootMode == snapshot.bootMode, machine.memoryMB == snapshot.memoryMB,
                  machine.cpuCount == snapshot.cpuCount, machine.displayMode == snapshot.displayMode,
                  machine.guestArchitecture?.rawValue == snapshot.architecture else {
                throw MachineManagerError.persistence("clone source differs from immutable snapshot authority")
            }
        } else {
            guard operation.kind == .provisioning, operation.source.state == .absent,
                  operation.source.workspaceID == machineID,
                  request.sourceMachineID == nil, request.sourceSnapshotID == nil,
                  sourceConfigurationData == nil, sourceWorkspaceData == nil, sourceRuntimeIdentity == nil else {
                throw MachineManagerError.persistence("creation cannot carry clone source authority")
            }
        }
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.creationSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation is not workspace creation")
        }
        let journal = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try journal.validate(operation: operation)
        return journal
    }

    private static func binding(_ identity: DoryMachineRuntimeIdentity) throws -> DoryWorkspaceRuntimeBinding {
        let digest = try DoryMachineDesktopUpdateJournal.digest(identity)
        switch identity.mode {
        case .legacyCompatibility:
            return .legacyCompatibility(virtualHardwareABIVersion: identity.virtualHardwareABIVersion, runtimeIdentityDigest: digest)
        case .requiresReplanning:
            return .requiresReplanning(virtualHardwareABIVersion: identity.virtualHardwareABIVersion, runtimeIdentityDigest: digest)
        case .resolvedPlan:
            guard let plan = identity.resolvedPlan else {
                throw MachineManagerError.persistence("clone source has no resolved plan")
            }
            return .resolvedPlan(.init(planRevision: plan.planRevision, planDigest: try plan.canonicalSHA256(),
                backendID: plan.backend.rawValue, backendRuntimeBuildID: plan.backendRuntimeBuildIdentifier,
                virtualHardwareABIVersion: plan.virtualHardwareABIVersion), runtimeIdentityDigest: digest)
        }
    }
}

struct DoryMachineCreationDirectoryOwnership: Codable, Sendable, Equatable {
    var operationID: UUID
    var machineID: String
    var device: UInt64
    var inode: UInt64
}

struct DoryMachineCreationNativePreparation: Codable, Sendable, Equatable {
    var manifest: DoryVZMacMachineManifest
    var configuration: DoryMachineConfiguration
}

struct DoryMachineCreationPublication: Codable, Sendable, Equatable {
    var configurationData: Data
    var workspaceData: Data
    var runtimeIdentity: DoryMachineRuntimeIdentity

    var configuration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: configurationData) }
    }
    var workspace: DoryWorkspaceRepositoryRecord {
        get throws { try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: workspaceData) }
    }

    func validate(creation: DoryMachineCreationJournal, native: DoryMachineCreationNativePreparation?) throws {
        let machine = try configuration
        let workspace = try workspace
        var expected = try creation.normalizedConfiguration
        if expected.guestFamily == .macOS {
            guard let native, native.manifest.resources.cpuCount == native.configuration.cpuCount,
                  native.manifest.resources.memoryBytes / 1_048_576 == native.configuration.memoryMB,
                  native.manifest.resources.diskBytes == native.configuration.diskSizeBytes else {
                throw MachineManagerError.persistence("native creation has no exact prepared platform")
            }
            try native.manifest.validate()
            var preparedIntent = expected
            preparedIntent.cpuCount = native.configuration.cpuCount
            preparedIntent.memoryMB = native.configuration.memoryMB
            preparedIntent.diskSizeBytes = native.configuration.diskSizeBytes
            preparedIntent.macOSMachineBundlePath = creation.stagingDirectory + "/Machine.dorymac"
            guard native.configuration == preparedIntent else {
                throw MachineManagerError.persistence("native preparation changed caller intent")
            }
            expected.cpuCount = native.configuration.cpuCount
            expected.memoryMB = native.configuration.memoryMB
            expected.diskSizeBytes = native.configuration.diskSizeBytes
            expected.guestArchitecture = .arm64
            expected.macOSRestoreImagePath = creation.machineDirectory + "/Restore.ipsw"
            expected.macOSMachineBundlePath = creation.machineDirectory + "/Machine.dorymac"
        } else {
            guard native == nil else { throw MachineManagerError.persistence("Linux creation cannot use native macOS preparation") }
            expected.kernelPath = creation.machineDirectory + "/kernel"
            expected.rootfsPath = creation.machineDirectory + "/rootfs.ext4"
            expected.diskSizeBytes = nil
            if expected.installerISOPath != nil { expected.installerISOPath = creation.machineDirectory + "/installer.iso" }
        }
        if let snapshot = creation.snapshot, let evidence = snapshot.artifactEvidence {
            expected.cloneReceipt = .init(sourceMachineID: snapshot.machineID, sourceSnapshotID: snapshot.id,
                sourceRootfsSHA256: evidence.rootfs.sha256, sourceRootfsByteCount: evidence.rootfs.byteCount,
                createdAtUnixMilliseconds: creation.createdAtUnixMilliseconds)
        }
        guard machine == expected, workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              workspace.definition.identity.id == creation.machineID, workspace.definition.validate().isEmpty,
              workspace.definition.lifecycle.revision == 1, runtimeIdentity.validate().isEmpty,
              runtimeIdentity.virtualHardwareABIVersion == creation.virtualHardwareABIVersion,
              runtimeIdentity.mode == (creation.runtimePolicy == .requireResolvedPlan ? .requiresReplanning : .legacyCompatibility) else {
            throw MachineManagerError.persistence("created workspace differs from its caller-owned publication")
        }
        if creation.usesNativeWorkspaceAuthority {
            let memory = machine.memoryMB.multipliedReportingOverflow(by: 1_048_576)
            guard workspace.legacyConfigurationSHA256 == nil, workspace.legacyMigrationFactsSHA256 == nil,
                  machine.environment.isEmpty, !memory.overflow, machine.cpuCount > 0,
                  workspace.definition.guest.family == machine.guestFamily,
                  workspace.definition.guest.architecture == machine.guestArchitecture,
                  workspace.definition.workload == (machine.displayMode == .desktop ? .desktop : .server),
                  workspace.definition.resources.virtualCPUCount == UInt64(machine.cpuCount),
                  workspace.definition.resources.memoryBytes == memory.partialValue,
                  workspace.definition.sandboxPolicy == creation.request.sandboxPolicy,
                  try (creation.request.typedSettings ?? DoryMachineTypedSettingsPatch())
                    .applying(to: workspace.definition, displayMode: machine.displayMode) == workspace.definition else {
                throw MachineManagerError.persistence("new resolved workspace cannot acquire legacy authority")
            }
        } else {
            guard workspace.legacyConfigurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(configurationData),
                  workspace.legacyMigrationFactsSHA256 != nil else {
                throw MachineManagerError.persistence("legacy creation publication has no exact projection")
            }
        }
    }
}

enum DoryMachineCreationCheckpoint: String {
    case stagingOwnership
    case targetOwnership
    case nativePreparation
    case publication
    case plan
    case ready
    case cancellationRequested
}

extension DoryOperationLease {
    func creationCheckpoint<T: Decodable>(_ checkpoint: DoryMachineCreationCheckpoint, as type: T.Type = T.self) throws -> T? {
        let creation = try DoryMachineCreationJournal.read(from: self)
        let prefix = "creation.checkpoint.\(checkpoint.rawValue)."
        let matches = try events().filter { $0.stepID.hasPrefix(prefix) }
        if checkpoint == .plan {
            var previous: DoryResolvedMachinePlan?
            for event in matches {
                let data = try readManifest(digest: String(event.stepID.dropFirst(prefix.count)))
                let plan = try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data)
                try validateCreationPlanCheckpoint(plan, previous: previous, creation: creation)
                previous = plan
            }
            guard let previous else { return nil }
            guard let result = previous as? T else { throw MachineManagerError.persistence("creation plan checkpoint has wrong type") }
            return result
        }
        guard matches.count <= 1 else { throw MachineManagerError.persistence("creation checkpoint is ambiguous") }
        guard let event = matches.first else { return nil }
        return try JSONDecoder().decode(type, from: readManifest(digest: String(event.stepID.dropFirst(prefix.count))))
    }

    func publishCreationCheckpoint<T: Codable & Equatable>(_ value: T, at checkpoint: DoryMachineCreationCheckpoint) throws {
        if checkpoint == .plan {
            guard let plan = value as? DoryResolvedMachinePlan else { throw MachineManagerError.persistence("creation requires an exact plan") }
            let previous: DoryResolvedMachinePlan? = try creationCheckpoint(checkpoint)
            if previous == plan { return }
            try validateCreationPlanCheckpoint(plan, previous: previous, creation: DoryMachineCreationJournal.read(from: self))
        } else if let previous: T = try creationCheckpoint(checkpoint) {
            guard previous == value else { throw MachineManagerError.persistence("creation checkpoint cannot be replaced") }
            return
        }
        let digest = try publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(value))
        let state = try read().state
        _ = try transition(to: state.phase, status: state.status, expectedRevision: state.revision,
            stepID: "creation.checkpoint.\(checkpoint.rawValue).\(digest)")
    }

    private func validateCreationPlanCheckpoint(_ plan: DoryResolvedMachinePlan, previous: DoryResolvedMachinePlan?,
                                                creation: DoryMachineCreationJournal) throws {
        guard let publication: DoryMachineCreationPublication = try creationCheckpoint(.publication) else {
            throw MachineManagerError.persistence("creation plan has no exact new workspace publication")
        }
        let workspace = try publication.workspace
        guard plan.validate().isEmpty, plan.machineID == creation.machineID,
              plan.virtualHardwareABIVersion == creation.virtualHardwareABIVersion,
              plan.definitionRevision == workspace.definition.lifecycle.revision,
              plan.definitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(workspace.definition)),
              plan.guest == workspace.definition.guest, plan.resources == workspace.definition.resources,
              plan.devices == DoryDaemonVirtualMachinePlanningCoordinator.devices(for: workspace.definition),
              workspace.definition.graphics.acceptableLevels.contains(plan.graphics),
              workspace.definition.platform.map({ $0 == plan.platform }) ?? true else {
            throw MachineManagerError.persistence("creation plan does not match the exact new workspace")
        }
        if let previous {
            guard plan.planRevision > previous.planRevision, plan.definitionRevision == previous.definitionRevision,
                  plan.definitionSHA256 == previous.definitionSHA256, plan.backend == previous.backend,
                  plan.guest == previous.guest, plan.platform == previous.platform else {
                throw MachineManagerError.persistence("creation plan renewal changed workspace authority")
            }
        }
    }
}
