import DoryOperations
import Foundation

/// Exact private input for a snapshot restore. The existing lifecycle journal owns publication,
/// replanning and return to the requested power state under the caller's operation identity.
struct DoryMachineSnapshotRestoreJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var machineID: String
    var snapshot: DoryMachineSnapshot
    var sourceConfigurationData: Data
    var targetConfigurationData: Data
    var sourceWorkspaceData: Data
    var targetNativeDefinition: DoryVirtualMachineDefinition?
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity
    var sourceRuntimeOperationID: UUID?

    var sourceConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData) }
    }

    var targetConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: targetConfigurationData) }
    }

    var sourceWorkspace: DoryWorkspaceRepositoryRecord {
        get throws { try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData) }
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let source = try sourceConfiguration
        let target = try targetConfiguration
        let workspace = try sourceWorkspace
        var expected = source
        expected.memoryMB = snapshot.memoryMB
        expected.cpuCount = snapshot.cpuCount
        expected.displayMode = snapshot.displayMode
        expected.address = snapshot.address
        expected.shares = snapshot.shares
        expected.environment = targetNativeDefinition == nil ? snapshot.environment : [:]
        expected.installedDesktopPayloadReceipt = snapshot.installedDesktopPayloadReceipt.flatMap {
            $0.matchesLegacyEnvironment(snapshot.environment) ? nil : $0
        }
        let active = [.running, .paused].contains(operation.source.state)
        let runtimeDigest = try DoryMachineDesktopUpdateJournal.digest(sourceRuntimeIdentity)
        let descriptorEncoder = JSONEncoder()
        descriptorEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let descriptorSHA256 = DoryMachineConfigurationUpdateJournal.sha256(try descriptorEncoder.encode(snapshot))
        guard schemaVersion == 1, operation.kind == .restoring,
              operation.operationID == operationID, operation.source.workspaceID == machineID,
              operation.target.workspaceID == machineID, source.id == machineID, target.id == machineID,
              snapshot.machineID == machineID, snapshot.id == operation.targetResourceID,
              snapshot.bootMode == source.bootMode, target == expected,
              snapshot.runtimeIdentity.virtualHardwareABIVersion == sourceRuntimeIdentity.virtualHardwareABIVersion,
              sourceRuntimeIdentity.validate().isEmpty, sourceRuntimeIdentity.mode != .legacyCompatibility,
              operation.source.runtime?.runtimeIdentityDigest == runtimeDigest,
              operation.source.definitionRevision == workspace.definition.lifecycle.revision,
              operation.source.configurationAuthority?.legacyConfigurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(sourceConfigurationData),
              operation.source.configurationAuthority?.canonicalDefinitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(workspace.definition)),
              operation.target.configurationAuthority?.legacyConfigurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(targetConfigurationData),
              operation.target.plannedRuntime?.configurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(targetConfigurationData),
              operation.target.plannedRuntime?.virtualHardwareABIVersion == sourceRuntimeIdentity.virtualHardwareABIVersion,
              operation.target.state == (active ? operation.source.state : .stopped),
              active ? sourceRuntimeOperationID != nil : sourceRuntimeOperationID == nil,
              sourceRuntimeOperationID != operationID,
              operation.sourceRuntimeOperationID == sourceRuntimeOperationID,
              workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              workspace.definition.identity.id == machineID, workspace.definition.validate().isEmpty,
              let evidence = snapshot.artifactEvidence, evidence.isValid,
              operation.targetSnapshotAuthority == DoryWorkspaceSnapshotAuthority(
                descriptorSHA256: descriptorSHA256,
                artifactEvidenceSHA256: try DoryMachineDesktopUpdateJournal.digest(evidence)
              ) else {
            throw MachineManagerError.persistence("snapshot restore recovery authority is invalid")
        }
        if let definition = targetNativeDefinition {
            guard workspace.legacyConfigurationSHA256 == nil,
                  workspace.legacyMigrationFactsSHA256 == nil,
                  definition.validate().isEmpty, definition.identity.id == machineID,
                  workspace.definition.lifecycle.revision < UInt64.max,
                  definition.lifecycle.revision == workspace.definition.lifecycle.revision + 1,
                  definition.lifecycle.createdAtUnixMilliseconds == workspace.definition.lifecycle.createdAtUnixMilliseconds,
                  definition.lifecycle.updatedAtUnixMilliseconds > workspace.definition.lifecycle.updatedAtUnixMilliseconds,
                  operation.target.definitionRevision == definition.lifecycle.revision,
                  operation.target.configurationAuthority?.canonicalDefinitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(definition)) else {
                throw MachineManagerError.persistence("snapshot restore native revision is invalid")
            }
        } else {
            guard workspace.legacyConfigurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(sourceConfigurationData),
                  workspace.legacyMigrationFactsSHA256 != nil, operation.target.definitionRevision == nil,
                  operation.target.configurationAuthority?.canonicalDefinitionSHA256 == nil else {
                throw MachineManagerError.persistence("snapshot restore migration authority is invalid")
            }
        }
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.snapshotRestoreSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation is not a snapshot restore")
        }
        let restore = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try restore.validate(operation: operation)
        return restore
    }
}

enum DoryMachineSnapshotRestoreCheckpoint: String {
    case backups
    case artifactsPublished
    case plan
    case ready
}

struct DoryMachineSnapshotRestoreBackups: Codable, Sendable, Equatable {
    var rootfs: DoryMachineSnapshotArtifact
    var kernel: DoryMachineSnapshotArtifact
    var configuration: DoryMachineSnapshotArtifact
    var machineIdentifier: DoryMachineSnapshotArtifact?
    var nvram: DoryMachineSnapshotArtifact?
}

extension DoryOperationLease {
    func snapshotRestoreCheckpoint<T: Decodable>(
        _ checkpoint: DoryMachineSnapshotRestoreCheckpoint, as type: T.Type = T.self
    ) throws -> T? {
        let restore = try DoryMachineSnapshotRestoreJournal.read(from: self)
        let prefix = "restore.checkpoint.\(checkpoint.rawValue)."
        let matches = try events().filter { $0.stepID.hasPrefix(prefix) }
        if checkpoint == .plan {
            var latest: DoryResolvedMachinePlan?
            for event in matches {
                let data = try readManifest(digest: String(event.stepID.dropFirst(prefix.count)))
                let plan = try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data)
                try validateSnapshotRestorePlanCheckpoint(plan, previous: latest, restore: restore)
                latest = plan
            }
            guard let latest else { return nil }
            guard let typed = latest as? T else {
                throw MachineManagerError.persistence("snapshot restore plan checkpoint has wrong type")
            }
            return typed
        }
        guard matches.count <= 1 else {
            throw MachineManagerError.persistence("snapshot restore checkpoint is ambiguous")
        }
        guard let event = matches.first else { return nil }
        return try JSONDecoder().decode(type, from: readManifest(digest: String(event.stepID.dropFirst(prefix.count))))
    }

    func publishSnapshotRestoreCheckpoint<T: Codable & Equatable>(
        _ value: T, at checkpoint: DoryMachineSnapshotRestoreCheckpoint
    ) throws {
        if checkpoint == .plan {
            guard let plan = value as? DoryResolvedMachinePlan else {
                throw MachineManagerError.persistence("snapshot restore requires an exact plan checkpoint")
            }
            let previous: DoryResolvedMachinePlan? = try snapshotRestoreCheckpoint(checkpoint)
            if previous == plan { return }
            try validateSnapshotRestorePlanCheckpoint(plan, previous: previous,
                restore: DoryMachineSnapshotRestoreJournal.read(from: self))
        } else if let previous: T = try snapshotRestoreCheckpoint(checkpoint) {
            guard previous == value else {
                throw MachineManagerError.persistence("snapshot restore checkpoint cannot be replaced")
            }
            return
        }
        let digest = try publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(value))
        let state = try read().state
        _ = try transition(to: state.phase, status: state.status, expectedRevision: state.revision,
            stepID: "restore.checkpoint.\(checkpoint.rawValue).\(digest)")
    }

    private func validateSnapshotRestorePlanCheckpoint(
        _ plan: DoryResolvedMachinePlan, previous: DoryResolvedMachinePlan?,
        restore: DoryMachineSnapshotRestoreJournal
    ) throws {
        guard plan.validate().isEmpty, plan.machineID == restore.machineID,
              plan.virtualHardwareABIVersion == restore.sourceRuntimeIdentity.virtualHardwareABIVersion else {
            throw MachineManagerError.persistence("snapshot restore plan checkpoint is invalid")
        }
        if let definition = restore.targetNativeDefinition {
            guard plan.definitionRevision == definition.lifecycle.revision,
                  plan.definitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(definition)) else {
                throw MachineManagerError.persistence("snapshot restore plan differs from native publication")
            }
        }
        if let previous {
            guard plan.planRevision > previous.planRevision,
                  plan.definitionRevision == previous.definitionRevision,
                  plan.definitionSHA256 == previous.definitionSHA256,
                  plan.backend == previous.backend, plan.guest == previous.guest,
                  plan.platform == previous.platform else {
                throw MachineManagerError.persistence("snapshot restore plan renewal changed authority")
            }
        }
    }
}
