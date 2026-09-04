import DoryOperations
import Foundation

/// The immutable request is durable before guest quiescence. Artifact evidence is captured
/// only after the admitted guest has stopped, then bound by an append-only checkpoint.
struct DoryMachineSnapshotCreationJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var machineID: String
    var snapshotID: String
    var note: String
    var createdISO: String
    var sourceConfigurationData: Data
    var sourceWorkspaceData: Data
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity
    var sourceRuntimeOperationID: UUID?

    var configuration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData) }
    }
    var workspace: DoryWorkspaceRepositoryRecord {
        get throws { try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData) }
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let machine = try configuration
        let record = try workspace
        let digest = DoryMachineConfigurationUpdateJournal.sha256(sourceConfigurationData)
        let active = [.running, .paused].contains(operation.source.state)
        guard schemaVersion == 1, operation.kind == .snapshotting,
              operation.operationID == operationID, operation.source.workspaceID == machineID,
              operation.target.workspaceID == machineID, machine.id == machineID,
              operation.targetResourceID == snapshotID, operation.targetSnapshotAuthority == nil,
              record.definition.identity.id == machineID, record.definition.validate().isEmpty,
              operation.source.configurationAuthority?.legacyConfigurationSHA256 == digest,
              operation.target.configurationAuthority == operation.source.configurationAuthority,
              operation.source.configurationAuthority?.canonicalDefinitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(record.definition)),
              operation.source.definitionRevision == record.definition.lifecycle.revision,
              operation.target.definitionRevision == operation.source.definitionRevision,
              operation.source.runtime?.runtimeIdentityDigest == (try DoryMachineDesktopUpdateJournal.digest(sourceRuntimeIdentity)),
              sourceRuntimeIdentity.validate().isEmpty, sourceRuntimeIdentity.mode != .legacyCompatibility,
              operation.target.plannedRuntime?.configurationSHA256 == digest,
              operation.target.plannedRuntime?.virtualHardwareABIVersion == sourceRuntimeIdentity.virtualHardwareABIVersion,
              operation.target.state == (active ? operation.source.state : .stopped),
              operation.sourceRuntimeOperationID == sourceRuntimeOperationID,
              active ? sourceRuntimeOperationID != nil : sourceRuntimeOperationID == nil,
              sourceRuntimeOperationID != operationID else {
            throw MachineManagerError.persistence("snapshot request recovery authority is invalid")
        }
    }

    func validate(snapshot: DoryMachineSnapshot) throws {
        let machine = try configuration
        guard snapshot.id == snapshotID, snapshot.machineID == machineID,
              snapshot.note == note, snapshot.createdISO == createdISO,
              snapshot.memoryMB == machine.memoryMB, snapshot.cpuCount == machine.cpuCount,
              snapshot.bootMode == machine.bootMode, snapshot.displayMode == machine.displayMode,
              snapshot.address == machine.address, snapshot.shares == machine.shares,
              snapshot.environment == machine.environment,
              snapshot.runtimeIdentity == sourceRuntimeIdentity,
              snapshot.artifactEvidence?.isValid == true else {
            throw MachineManagerError.persistence("snapshot publication differs from its request")
        }
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.snapshotSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation has no snapshot request")
        }
        let value = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try value.validate(operation: operation)
        return value
    }
}

enum DoryMachineSnapshotCreationCheckpoint: String {
    // Written before the guest RPC: a lost response can leave a live source frozen.
    case quiesceAttempted
    case intent
    case published
    case plan
    case ready
    case cancellationRequested
}

extension DoryOperationLease {
    func snapshotCreationCheckpoint<T: Decodable>(
        _ checkpoint: DoryMachineSnapshotCreationCheckpoint, as type: T.Type = T.self
    ) throws -> T? {
        let request = try DoryMachineSnapshotCreationJournal.read(from: self)
        let prefix = "snapshot.checkpoint.\(checkpoint.rawValue)."
        let matches = try events().filter { $0.stepID.hasPrefix(prefix) }
        guard checkpoint == .plan || matches.count <= 1 else {
            throw MachineManagerError.persistence("snapshot checkpoint is ambiguous")
        }
        if checkpoint == .plan {
            var previous: DoryResolvedMachinePlan?
            for event in matches {
                let plan = try JSONDecoder().decode(DoryResolvedMachinePlan.self,
                    from: readManifest(digest: String(event.stepID.dropFirst(prefix.count))))
                try validateSnapshotCreationPlan(plan, previous: previous, request: request)
                previous = plan
            }
            return previous as? T
        }
        guard let event = matches.first else { return nil }
        return try JSONDecoder().decode(type,
            from: readManifest(digest: String(event.stepID.dropFirst(prefix.count))))
    }

    func publishSnapshotCreationCheckpoint<T: Codable & Equatable>(
        _ value: T, at checkpoint: DoryMachineSnapshotCreationCheckpoint
    ) throws {
        let previous: T? = try snapshotCreationCheckpoint(checkpoint)
        if previous == value { return }
        if checkpoint == .plan {
            guard let plan = value as? DoryResolvedMachinePlan else {
                throw MachineManagerError.persistence("snapshot plan checkpoint has wrong type")
            }
            try validateSnapshotCreationPlan(plan, previous: previous as? DoryResolvedMachinePlan,
                request: DoryMachineSnapshotCreationJournal.read(from: self))
        } else if previous != nil {
            throw MachineManagerError.persistence("snapshot checkpoint cannot be replaced")
        }
        let digest = try publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(value))
        let state = try read().state
        _ = try transition(to: state.phase, status: state.status, expectedRevision: state.revision,
            stepID: "snapshot.checkpoint.\(checkpoint.rawValue).\(digest)")
    }

    private func validateSnapshotCreationPlan(_ plan: DoryResolvedMachinePlan,
        previous: DoryResolvedMachinePlan?, request: DoryMachineSnapshotCreationJournal) throws {
        let workspace = try request.workspace
        guard plan.validate().isEmpty, plan.machineID == request.machineID,
              plan.definitionRevision == workspace.definition.lifecycle.revision,
              plan.definitionSHA256 == (try DoryMachineDesktopUpdateJournal.digest(workspace.definition)),
              plan.virtualHardwareABIVersion == request.sourceRuntimeIdentity.virtualHardwareABIVersion,
              previous == nil || plan.planRevision > previous!.planRevision else {
            throw MachineManagerError.persistence("snapshot replacement plan changed workspace authority")
        }
    }
}
