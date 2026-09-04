import CryptoKit
import DoryOperations
import Foundation

/// Private caller intent for stable update retries. This is never returned in status or XPC
/// diagnostics: compatibility environment values and share bookmarks may contain secrets.
struct DoryMachineConfigurationUpdateRequest: Codable, Sendable, Equatable {
    var memoryMB: UInt64?
    var cpuCount: Int?
    var address: String?
    var updatesAddress: Bool
    var shares: [DoryMachineShareConfiguration]?
    var updatesShares: Bool
    var environment: [String: String]?
    var updatesEnvironment: Bool
    var typedSettingsPatch: DoryMachineTypedSettingsPatch?
    var installerMediaAttached: Bool?

    func canonicalSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return DoryMachineConfigurationUpdateJournal.sha256(try encoder.encode(self))
    }
}

/// Exact private recovery input stored as a content-addressed specification in the one lifecycle
/// journal. The public lifecycle contract binds its digest; no second update-state file is used.
struct DoryMachineConfigurationUpdateJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var machineID: String
    var requestSHA256: String
    var sourceConfigurationData: Data
    var targetConfigurationData: Data
    var sourceWorkspaceData: Data
    var targetNativeDefinition: DoryVirtualMachineDefinition?
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity
    var requiresResolvedPlan: Bool
    var installerTransition: DoryMachineInstallerTransitionIntent? = nil

    var sourceConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData) }
    }

    var targetConfiguration: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: targetConfigurationData) }
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let source = try sourceConfiguration
        let target = try targetConfiguration
        let workspace = try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let runtimeDigest = Self.sha256(try encoder.encode(sourceRuntimeIdentity))
        let validNativeLineage = targetNativeDefinition.map {
            workspace.legacyConfigurationSHA256 == nil
                && workspace.legacyMigrationFactsSHA256 == nil
                && workspace.definition.lifecycle.revision < UInt64.max
                && $0.lifecycle.revision == workspace.definition.lifecycle.revision + 1
                && $0.lifecycle.createdAtUnixMilliseconds == workspace.definition.lifecycle.createdAtUnixMilliseconds
                && $0.lifecycle.updatedAtUnixMilliseconds > workspace.definition.lifecycle.updatedAtUnixMilliseconds
        } ?? (workspace.legacyConfigurationSHA256 == Self.sha256(sourceConfigurationData))
        guard schemaVersion == 1, operation.kind == .updating,
              operationID == operation.operationID,
              machineID == operation.source.workspaceID, machineID == operation.target.workspaceID,
              source.id == machineID, target.id == machineID,
              source != target || targetNativeDefinition != nil,
              sourceRuntimeIdentity.validate().isEmpty,
              runtimeDigest == operation.source.runtime?.runtimeIdentityDigest,
              installerTransition != nil || operation.target.state == .stopped,
              installerTransition != nil || operation.target.plannedRuntime == nil,
              workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              validNativeLineage,
              workspace.definition.identity.id == machineID, workspace.definition.validate().isEmpty,
              requestSHA256.count == 64, requestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              operation.source.configurationAuthority?.legacyConfigurationSHA256 == Self.sha256(sourceConfigurationData),
              operation.target.configurationAuthority?.legacyConfigurationSHA256 == Self.sha256(targetConfigurationData),
              targetNativeDefinition.map({ $0.identity.id == machineID && $0.validate().isEmpty }) ?? true else {
            throw MachineManagerError.persistence("configuration update recovery authority is invalid")
        }
        try installerTransition?.validate(update: self, operation: operation, sourceWorkspace: workspace)
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.configurationUpdateSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation is not a configuration update")
        }
        let value = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try value.validate(operation: operation)
        return value
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Additional intent for the compound removable-media operation. Firmware checkpoints and
/// exact resolved-plan observations are appended to the same operation after quiescence.
struct DoryMachineInstallerTransitionIntent: Codable, Sendable, Equatable {
    var attached: Bool
    var rollbackNativeDefinition: DoryVirtualMachineDefinition?
    var sourceRuntimeOperationID: UUID?

    func validate(
        update: DoryMachineConfigurationUpdateJournal,
        operation: DoryWorkspaceLifecycleOperation,
        sourceWorkspace: DoryWorkspaceRepositoryRecord
    ) throws {
        let source = try update.sourceConfiguration
        let target = try update.targetConfiguration
        var expectedTarget = source
        expectedTarget.installerISOPath = target.installerISOPath
        let requiresBoot = !attached || [.running, .paused].contains(operation.source.state)
        let activeSource = [.running, .paused].contains(operation.source.state)
        guard update.requiresResolvedPlan, source.bootMode == .efi,
              (source.installerISOPath != nil) != attached,
              (target.installerISOPath != nil) == attached, target == expectedTarget,
              operation.target.state == (requiresBoot ? .running : .stopped),
              operation.source.runtime?.policy == .requireResolvedPlan,
              activeSource ? sourceRuntimeOperationID.flatMap({
                  DoryOperationIdentity.parseCanonical($0.uuidString.lowercased())
              }) != nil : sourceRuntimeOperationID == nil,
              sourceRuntimeOperationID != update.operationID,
              requiresBoot ? operation.target.plannedRuntime?.configurationSHA256
                == DoryMachineConfigurationUpdateJournal.sha256(update.targetConfigurationData)
                : operation.target.runtime?.authorizationState == .requiresReplanning else {
            throw MachineManagerError.persistence("installer transition recovery intent is invalid")
        }
        if let targetDefinition = update.targetNativeDefinition {
            guard let rollbackNativeDefinition, targetDefinition.lifecycle.revision < UInt64.max,
                  rollbackNativeDefinition.lifecycle.revision == targetDefinition.lifecycle.revision + 1,
                  rollbackNativeDefinition.lifecycle.updatedAtUnixMilliseconds > targetDefinition.lifecycle.updatedAtUnixMilliseconds,
                  rollbackNativeDefinition.lifecycle.createdAtUnixMilliseconds == sourceWorkspace.definition.lifecycle.createdAtUnixMilliseconds,
                  rollbackNativeDefinition.validate().isEmpty else {
                throw MachineManagerError.persistence("installer rollback revision authority is invalid")
            }
            var original = sourceWorkspace.definition
            original.lifecycle = rollbackNativeDefinition.lifecycle
            guard original == rollbackNativeDefinition else {
                throw MachineManagerError.persistence("installer rollback changes the original desired definition")
            }
        } else if rollbackNativeDefinition != nil {
            throw MachineManagerError.persistence("legacy installer transition cannot manufacture native rollback authority")
        }
    }
}

/// Captured only after the source helper is confirmed stopped. An operation event binds the
/// manifest digest before any promotion/reset, so interrupted rollback cannot guess old NVRAM.
struct DoryMachineInstallerFirmwareCheckpoint: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var machineID: String
    var installedNVRAM: Data?
    var installerNVRAM: Data?
    var pcVariableStore: Data?
}
