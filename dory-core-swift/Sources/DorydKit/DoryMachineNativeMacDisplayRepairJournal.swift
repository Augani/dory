import CryptoKit
import DoryOperations
import DoryVZMacCore
import Foundation

/// Private recovery input in the existing workspace-repair journal. No caller paths,
/// launch authority, or implicit saved-RAM compatibility migration are accepted.
struct DoryMachineNativeMacDisplayRepairJournal: Codable, Sendable, Equatable {
    var schemaVersion: UInt16 = 1
    var operationID: UUID
    var machineID: String
    var originalManifestSHA256: String
    var selectedDisplayIndex: Int
    var sourceConfigurationData: Data
    var sourceWorkspaceData: Data
    var sourceRuntimeIdentity: DoryMachineRuntimeIdentity
    var targetManifest: DoryVZMacMachineManifest
    var targetDefinition: DoryVirtualMachineDefinition
    var targetRuntimeIdentity: DoryMachineRuntimeIdentity

    var machine: DoryMachineConfiguration {
        get throws { try JSONDecoder().decode(DoryMachineConfiguration.self, from: sourceConfigurationData) }
    }
    var sourceWorkspace: DoryWorkspaceRepositoryRecord {
        get throws { try JSONDecoder().decode(DoryWorkspaceRepositoryRecord.self, from: sourceWorkspaceData) }
    }

    static func selectedManifest(_ assessment: DoryVZMacDisplayRepairAssessment, index: Int) throws -> DoryVZMacMachineManifest {
        guard assessment.displays.indices.contains(index),
              assessment.pendingSelectedDisplayIndex == nil || assessment.pendingSelectedDisplayIndex == index else {
            throw MachineManagerError.persistence("display repair must retain its original selected display")
        }
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment.candidateManifest)) as? [String: Any],
              var resources = object["resources"] as? [String: Any] else {
            throw MachineManagerError.persistence("display repair manifest encoding is invalid")
        }
        resources["displays"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([assessment.displays[index]]))
        object["resources"] = resources
        return try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func definition(from source: DoryVirtualMachineDefinition, manifest: DoryVZMacMachineManifest,
                           updatedAt: Int64) throws -> DoryVirtualMachineDefinition {
        guard source.lifecycle.revision < UInt64.max, source.lifecycle.updatedAtUnixMilliseconds < Int64.max,
              updatedAt > source.lifecycle.updatedAtUnixMilliseconds,
              let choice = manifest.resources.displays.first,
              let width = UInt32(exactly: choice.widthInPixels), let height = UInt32(exactly: choice.heightInPixels),
              let density = UInt16(exactly: choice.pixelsPerInch) else {
            throw MachineManagerError.persistence("display repair cannot publish this geometry or lifecycle revision")
        }
        var target = source
        var display = source.displays.first ?? DoryVMDisplayConfiguration()
        display.id = "display-0"
        display.enabled = true
        display.widthPixels = width; display.heightPixels = height; display.pixelsPerInch = density
        target.displays = [display]
        target.resources = DoryVMProductionResourceBudget.make(for: target)
        target.boot = try MachineManager.nativeMacOSBootConfiguration(installationState: manifest.installationState,
            restoreReference: MachineManager.nativeMacOSRestoreReference(machineID: source.identity.id, manifest: manifest),
            systemReference: MachineManager.nativeMacOSSystemDiskReference(machineID: source.identity.id, manifest: manifest))
        target.lifecycle = .init(revision: source.lifecycle.revision + 1,
            createdAtUnixMilliseconds: source.lifecycle.createdAtUnixMilliseconds, updatedAtUnixMilliseconds: updatedAt)
        try MachineManager.validateNativeMacOSWorkspaceAuthority(definition: target, machineID: source.identity.id,
            restoreReference: MachineManager.nativeMacOSRestoreReference(machineID: source.identity.id, manifest: manifest),
            systemReference: MachineManager.nativeMacOSSystemDiskReference(machineID: source.identity.id, manifest: manifest), manifest: manifest)
        return target
    }

    func condition(target: Bool) throws -> DoryWorkspaceLifecycleCondition {
        let definition = try target ? targetDefinition : sourceWorkspace.definition
        let identity = target ? targetRuntimeIdentity : sourceRuntimeIdentity
        return .init(workspaceID: machineID, state: target ? .stopped : .failed,
            definitionRevision: definition.lifecycle.revision,
            runtime: .requiresReplanning(virtualHardwareABIVersion: identity.virtualHardwareABIVersion,
                runtimeIdentityDigest: try Self.digest(identity)),
            configurationAuthority: .init(legacyConfigurationSHA256: Self.hash(sourceConfigurationData),
                canonicalDefinitionSHA256: try Self.digest(definition)))
    }

    func validate(operation: DoryWorkspaceLifecycleOperation) throws {
        let machine = try machine, workspace = try sourceWorkspace
        guard schemaVersion == 1, operationID == operation.operationID, operation.kind == .repairing,
              machine.id == machineID, machineID == operation.source.workspaceID,
              machineID == operation.target.workspaceID, machine.bootMode == .macOSRestore,
              machine.guestFamily == .macOS, machine.guestArchitecture == .arm64,
              workspace.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              workspace.legacyConfigurationSHA256 == nil, workspace.legacyMigrationFactsSHA256 == nil,
              workspace.definition.identity.id == machineID, workspace.definition.validate().isEmpty,
              sourceRuntimeIdentity.mode == .requiresReplanning, sourceRuntimeIdentity.validate().isEmpty,
              targetRuntimeIdentity.mode == .requiresReplanning, targetRuntimeIdentity.validate().isEmpty,
              sourceRuntimeIdentity.virtualHardwareABIVersion == targetRuntimeIdentity.virtualHardwareABIVersion,
              (0..<8).contains(selectedDisplayIndex), originalManifestSHA256.count == 64,
              originalManifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              targetManifest.resources.displays.count == 1,
              targetManifest.resources.cpuCount == machine.cpuCount,
              targetManifest.resources.memoryBytes / 1_048_576 == machine.memoryMB,
              targetManifest.resources.diskBytes == machine.diskSizeBytes,
              targetManifest.resources.dataDisks.map(\.byteCount) == machine.dataDiskBytes,
              targetDefinition == (try Self.definition(from: workspace.definition, manifest: targetManifest,
                updatedAt: targetDefinition.lifecycle.updatedAtUnixMilliseconds)),
              operation.source == (try condition(target: false)), operation.target == (try condition(target: true)),
              operation.readinessGates.isEmpty, operation.sourceRuntimeOperationID == nil,
              operation.nativeMacDisplayRepairSpecificationDigest == (try DoryOperationSpecification(canonical: self).digest) else {
            throw MachineManagerError.persistence("Mac display repair recovery authority is invalid")
        }
    }

    static func read(from lease: DoryOperationLease) throws -> Self {
        let operation = try lease.readWorkspaceLifecycleOperation()
        guard let digest = operation.nativeMacDisplayRepairSpecificationDigest else {
            throw MachineManagerError.persistence("lifecycle operation is not a Mac display repair")
        }
        let value = try JSONDecoder().decode(Self.self, from: lease.readSpecification(digest: digest))
        try value.validate(operation: operation)
        return value
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(value))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
