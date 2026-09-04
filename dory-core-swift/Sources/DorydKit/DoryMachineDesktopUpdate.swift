import CryptoKit
import DoryOperations
import Foundation

/// Private immutable recovery input for one compound desktop update. The resolver's receipt
/// template identifies selected component bytes; its input hash is deliberately not installed
/// state. Guest-observed input, publication and qualification are appended as typed checkpoints.
struct DoryMachineDesktopUpdateJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var request: DoryDesktopUpdateRequest
    var machineID: String
    var sourceConfigurationData: Data
    var sourceWorkspaceData: Data
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity
    var sourceRuntimeOperationID: UUID?
    var componentAuthority: DoryInstalledDesktopPayloadReceipt
    var snapshotID: String

    var sourceConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData) }
    }

    var sourceWorkspace: DoryWorkspaceRepositoryRecord {
        get throws { try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData) }
    }

    var authoritySHA256: String {
        get throws { try Self.digest(componentAuthority) }
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let source = try sourceConfiguration
        let workspace = try sourceWorkspace
        let live = [.running, .paused].contains(operation.source.state)
        guard sourceRuntimeIdentity.validate().isEmpty,
              sourceRuntimeIdentity.mode == .resolvedPlan,
              let plan = sourceRuntimeIdentity.resolvedPlan,
              let planDigest = sourceRuntimeIdentity.resolvedPlanSHA256 else {
            throw MachineManagerError.persistence("desktop update source has no resolved runtime")
        }
        let expectedRuntime = DoryWorkspaceRuntimeBinding.resolvedPlan(
            .init(planRevision: plan.planRevision, planDigest: planDigest,
                  backendID: plan.backend.rawValue,
                  backendRuntimeBuildID: plan.backendRuntimeBuildIdentifier,
                  virtualHardwareABIVersion: plan.virtualHardwareABIVersion),
            runtimeIdentityDigest: try Self.digest(sourceRuntimeIdentity)
        )
        let sourceDistribution = workspace.definition.guestIdentityIntent.desktop?.distributionIdentifier
            ?? source.effectiveInstalledDesktopPayloadReceipt?.distributionIdentifier
            ?? source.environment[DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey]
        let (memoryBytes, memoryOverflow) = source.memoryMB.multipliedReportingOverflow(by: 1_048_576)
        guard schemaVersion == 1, operation.validate().isEmpty, operation.kind == .updating,
              operation.desktopUpdateSpecificationDigest != nil,
              operation.configurationUpdateSpecificationDigest == nil,
              operation.operationID == request.operationID,
              operation.source.workspaceID == machineID, operation.target.workspaceID == machineID,
              source.id == machineID, source.bootMode == .linuxKernel, source.displayMode == .desktop,
              source.guestFamily == .linux, source.guestArchitecture == nil || source.guestArchitecture == .arm64,
              sourceDistribution == request.distro,
              workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              workspace.definition.identity.id == machineID, workspace.definition.validate().isEmpty,
              // Reserve both forward and compensating publication before mutating the guest.
              workspace.definition.lifecycle.revision <= UInt64.max - 2,
              workspace.definition.lifecycle.updatedAtUnixMilliseconds <= Int64.max - 2,
              workspace.definition.guest == DoryGuestPlatform(family: .linux, architecture: .arm64),
              workspace.definition.workload == .desktop,
              source.cpuCount > 0, UInt64(source.cpuCount) == workspace.definition.resources.virtualCPUCount,
              !memoryOverflow, memoryBytes == workspace.definition.resources.memoryBytes,
              plan.machineID == machineID, plan.guest == workspace.definition.guest,
              plan.definitionRevision == workspace.definition.lifecycle.revision,
              plan.definitionSHA256 == (try Self.digest(workspace.definition)),
              workspace.definition.platform == nil || plan.platform == workspace.definition.platform,
              plan.virtualHardwareABIVersion == workspace.definition.virtualHardwareABIVersion,
              operation.source.definitionRevision == workspace.definition.lifecycle.revision,
              operation.target.definitionRevision == workspace.definition.lifecycle.revision + 1,
              operation.source.configurationAuthority?.legacyConfigurationSHA256 == Self.sha256(sourceConfigurationData),
              operation.source.configurationAuthority?.canonicalDefinitionSHA256 == (try Self.digest(workspace.definition)),
              operation.source.runtime == expectedRuntime,
              live ? sourceRuntimeOperationID != nil : sourceRuntimeOperationID == nil,
              sourceRuntimeOperationID != request.operationID,
              sourceRuntimeOperationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              componentAuthority.isValid, componentAuthority.provenance == .verifiedUpdateBundle,
              componentAuthority.inputSHA256 == String(repeating: "0", count: 64),
              componentAuthority.distributionIdentifier == request.distro,
              componentAuthority.releaseVersion == request.version,
              componentAuthority.distributionInstallationName == request.distributionInstallationName,
              componentAuthority.runtimeInstallationName == request.runtimeInstallationName,
              operation.target.desktopUpdate?.authoritySHA256 == (try authoritySHA256),
              operation.target.desktopUpdate?.virtualHardwareABIVersion == sourceRuntimeIdentity.virtualHardwareABIVersion,
              snapshotID == "du-" + request.operationID.uuidString.lowercased() else {
            throw MachineManagerError.persistence("desktop update recovery specification is invalid")
        }
        if workspace.legacyConfigurationSHA256 != nil {
            guard workspace.legacyConfigurationSHA256 == Self.sha256(sourceConfigurationData) else {
                throw MachineManagerError.persistence("desktop update legacy source is stale")
            }
        } else if workspace.legacyMigrationFactsSHA256 != nil || !source.environment.isEmpty {
            throw MachineManagerError.persistence("desktop update native source has legacy write authority")
        }
    }

    func installedConfiguration(inputSHA256: String) throws -> DoryMachineConfiguration {
        var receipt = componentAuthority
        receipt.inputSHA256 = inputSHA256
        guard receipt.isValid, inputSHA256 != String(repeating: "0", count: 64) else {
            throw MachineManagerError.persistence("desktop installation fingerprint is unavailable")
        }
        var result = try sourceConfiguration
        result.installedDesktopPayloadReceipt = receipt
        result.environment.removeValue(forKey: DoryInstalledDesktopPayloadReceipt.legacyReleaseVersionEnvironmentKey)
        result.environment.removeValue(forKey: DoryInstalledDesktopPayloadReceipt.legacyInputSHA256EnvironmentKey)
        return result
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.desktopUpdateSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation is not a desktop update")
        }
        let value = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try value.validate(operation: operation)
        return value
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String { sha256(try canonicalData(value)) }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum DoryMachineDesktopUpdateCheckpoint: String {
    case snapshotIntent = "snapshot-intent"
    case snapshotReady = "snapshot-ready"
    case sourcePlan = "source-plan"
    case guestMutation = "guest-mutation"
    case targetPublication = "target-publication"
    case targetPlan = "target-plan"
    case qualified
    case rollbackPublication = "rollback-publication"
    case rollbackPlan = "rollback-plan"

    var permitsPlanRenewal: Bool {
        self == .sourcePlan || self == .targetPlan || self == .rollbackPlan
    }
}

struct DoryMachineDesktopUpdatePublication: Codable, Sendable, Equatable {
    var configurationData: Data
    var nativeDefinition: DoryVirtualMachineDefinition?
    var expectedWorkspaceRevision: UInt64

    var configuration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: configurationData) }
    }

    func validate(update: DoryMachineDesktopUpdateJournal, rollback: Bool) throws {
        let source = try update.sourceWorkspace
        let machine = try configuration
        if rollback {
            guard configurationData == update.sourceConfigurationData else {
                throw MachineManagerError.persistence("desktop rollback changes source metadata")
            }
        } else {
            guard let receipt = machine.installedDesktopPayloadReceipt,
                  machine == (try update.installedConfiguration(inputSHA256: receipt.inputSHA256)) else {
                throw MachineManagerError.persistence("desktop publication changes unrequested settings")
            }
        }
        guard expectedWorkspaceRevision >= source.definition.lifecycle.revision,
              expectedWorkspaceRevision - source.definition.lifecycle.revision <= (rollback ? 1 : 0) else {
            throw MachineManagerError.persistence("desktop publication revision is outside its operation")
        }
        if source.legacyConfigurationSHA256 == nil {
            guard let nativeDefinition, expectedWorkspaceRevision < UInt64.max,
                  nativeDefinition.lifecycle.revision == expectedWorkspaceRevision + 1,
                  nativeDefinition.lifecycle.createdAtUnixMilliseconds == source.definition.lifecycle.createdAtUnixMilliseconds,
                  nativeDefinition.lifecycle.updatedAtUnixMilliseconds > source.definition.lifecycle.updatedAtUnixMilliseconds,
                  nativeDefinition.validate().isEmpty else {
                throw MachineManagerError.persistence("desktop native publication lineage is invalid")
            }
            var expected = source.definition
            expected.lifecycle = nativeDefinition.lifecycle
            guard expected == nativeDefinition else {
                throw MachineManagerError.persistence("desktop update changed native device intent")
            }
        } else if nativeDefinition != nil {
            throw MachineManagerError.persistence("desktop legacy update manufactured native authority")
        }
    }
}

struct DoryMachineDesktopUpdateQualification: Codable, Sendable, Equatable {
    var inputSHA256: String
    var planSHA256: String
    var operationID: UUID
}

extension DoryOperationLease {
    func desktopCheckpoint<T: Decodable>(
        _ checkpoint: DoryMachineDesktopUpdateCheckpoint, as type: T.Type = T.self
    ) throws -> T? {
        let update = try DoryMachineDesktopUpdateJournal.read(from: self)
        let prefix = "desktop.checkpoint.\(checkpoint.rawValue)."
        let events = try events().filter { $0.stepID.hasPrefix(prefix) }
        if checkpoint.permitsPlanRenewal {
            var latest: DoryResolvedMachinePlan?
            for event in events {
                let data = try readManifest(digest: String(event.stepID.dropFirst(prefix.count)))
                let plan = try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data)
                try validateDesktopPlanCheckpoint(plan, previous: latest, update: update)
                latest = plan
            }
            guard let latest else { return nil }
            guard let typed = latest as? T else {
                throw MachineManagerError.persistence("desktop plan checkpoint has the wrong type")
            }
            return typed
        }
        guard events.count <= 1 else {
            throw MachineManagerError.persistence("desktop checkpoint is ambiguous")
        }
        guard let event = events.first else { return nil }
        return try JSONDecoder().decode(type, from: readManifest(digest: String(event.stepID.dropFirst(prefix.count))))
    }

    func publishDesktopCheckpoint<T: Codable & Equatable>(
        _ value: T, at checkpoint: DoryMachineDesktopUpdateCheckpoint
    ) throws {
        if checkpoint.permitsPlanRenewal {
            guard let plan = value as? DoryResolvedMachinePlan else {
                throw MachineManagerError.persistence("desktop plan checkpoint requires a resolved plan")
            }
            let existing: DoryResolvedMachinePlan? = try desktopCheckpoint(checkpoint)
            if existing == plan { return }
            let update = try DoryMachineDesktopUpdateJournal.read(from: self)
            try validateDesktopPlanCheckpoint(plan, previous: existing, update: update)
        } else if let existing: T = try desktopCheckpoint(checkpoint) {
            guard existing == value else {
                throw MachineManagerError.persistence("desktop checkpoint cannot be replaced")
            }
            return
        }
        let digest = try publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(value))
        let state = try read().state
        _ = try transition(to: state.phase, status: state.status, expectedRevision: state.revision,
                           stepID: "desktop.checkpoint.\(checkpoint.rawValue).\(digest)")
    }

    /// A recovered admission lease may require a new plan generation for the same desired
    /// definition. Each generation remains immutable; the whole recorded chain is checked.
    private func validateDesktopPlanCheckpoint(
        _ plan: DoryResolvedMachinePlan,
        previous: DoryResolvedMachinePlan?,
        update: DoryMachineDesktopUpdateJournal
    ) throws {
        guard plan.validate().isEmpty, plan.machineID == update.machineID,
              plan.virtualHardwareABIVersion == update.sourceRuntimeIdentity.virtualHardwareABIVersion else {
            throw MachineManagerError.persistence("desktop plan checkpoint is invalid")
        }
        if let previous {
            guard plan.planRevision > previous.planRevision,
                  plan.machineID == previous.machineID,
                  plan.definitionRevision == previous.definitionRevision,
                  plan.definitionSHA256 == previous.definitionSHA256,
                  plan.virtualHardwareABIVersion == previous.virtualHardwareABIVersion,
                  plan.backend == previous.backend,
                  plan.guest == previous.guest, plan.platform == previous.platform else {
                throw MachineManagerError.persistence("desktop plan renewal changed composition authority")
            }
        }
    }
}
