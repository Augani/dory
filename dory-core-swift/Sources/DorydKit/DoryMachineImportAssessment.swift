import DoryOperations
import Foundation

public enum DoryMachineImportDisposition: String, Codable, Sendable, Hashable {
    case ready
    case requiresComponents = "requires-components"
    case requiresReplanning = "requires-replanning"
    case unavailable
}

public enum DoryMachineImportIssueCode: String, Codable, Sendable, Hashable {
    case architectureMismatch = "architecture-mismatch"
    case virtualHardwareABIMismatch = "virtual-hardware-abi-mismatch"
    case backendRuntimeDiffers = "backend-runtime-differs"
    case missingComponents = "missing-components"
    case mismatchedComponents = "mismatched-components"
    case resolvedPlanRequiresReplanning = "resolved-plan-requires-replanning"
    case sourceRequiresReplanning = "source-requires-replanning"
    case legacyRequiresMigration = "legacy-requires-migration"
}

public enum DoryMachineImportComponentAvailability: String, Codable, Sendable, Hashable {
    case available
    case mismatched
    case missing
}

public struct DoryMachineImportComponentAssessment:
    Codable, Sendable, Equatable, Hashable
{
    public var componentIdentifier: String
    public var buildIdentifier: String
    public var artifactSHA256: String
    public var availability: DoryMachineImportComponentAvailability

    public init(
        componentIdentifier: String,
        buildIdentifier: String,
        artifactSHA256: String,
        availability: DoryMachineImportComponentAvailability
    ) {
        self.componentIdentifier = componentIdentifier
        self.buildIdentifier = buildIdentifier
        self.artifactSHA256 = artifactSHA256
        self.availability = availability
    }
}

/// Destination-owned evidence used to assess a portable archive. It is deliberately path-free:
/// import compatibility is based on verified runtime/component identities, never caller paths.
public struct DoryMachineImportEnvironment: Sendable, Equatable {
    public var backendRuntimeBuildIdentifiers: [DoryVirtualizationBackendIdentity: String]
    public var backendComponents:
        [DoryVirtualizationBackendIdentity: [DoryResolvedBackendComponentEvidence]]

    public init(
        backendRuntimeBuildIdentifiers: [DoryVirtualizationBackendIdentity: String] = [:],
        backendComponents:
            [DoryVirtualizationBackendIdentity: [DoryResolvedBackendComponentEvidence]] = [:]
    ) {
        self.backendRuntimeBuildIdentifiers = backendRuntimeBuildIdentifiers
        self.backendComponents = backendComponents.mapValues {
            $0.sorted { lhs, rhs in
                if lhs.componentIdentifier == rhs.componentIdentifier {
                    return lhs.buildIdentifier < rhs.buildIdentifier
                }
                return lhs.componentIdentifier < rhs.componentIdentifier
            }
        }
    }

    public static let unverified = Self()
}

/// A complete, read-only verification result for one portable machine archive. `contentID` binds
/// the metadata and every declared artifact digest after the daemon has streamed and verified all
/// artifact bodies. No path or secret crosses XPC.
public struct DoryMachineImportAssessment: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var contentID: String
    public var sourceMachineID: String
    public var sourceSnapshotID: String
    public var architecture: String
    public var bootMode: DoryMachineBootMode
    public var diskSizeBytes: UInt64
    public var virtualHardwareABIVersion: UInt16
    public var sourceRuntimeMode: DoryMachineRuntimeIdentityMode
    public var sourceBackend: DoryVirtualizationBackendIdentity?
    public var portable: Bool
    public var disposition: DoryMachineImportDisposition
    public var issues: [DoryMachineImportIssueCode]
    public var components: [DoryMachineImportComponentAssessment]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        contentID: String,
        sourceMachineID: String,
        sourceSnapshotID: String,
        architecture: String,
        bootMode: DoryMachineBootMode,
        diskSizeBytes: UInt64,
        virtualHardwareABIVersion: UInt16,
        sourceRuntimeMode: DoryMachineRuntimeIdentityMode,
        sourceBackend: DoryVirtualizationBackendIdentity?,
        portable: Bool,
        disposition: DoryMachineImportDisposition,
        issues: [DoryMachineImportIssueCode],
        components: [DoryMachineImportComponentAssessment]
    ) {
        self.schemaVersion = schemaVersion
        self.contentID = contentID
        self.sourceMachineID = sourceMachineID
        self.sourceSnapshotID = sourceSnapshotID
        self.architecture = architecture
        self.bootMode = bootMode
        self.diskSizeBytes = diskSizeBytes
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.sourceRuntimeMode = sourceRuntimeMode
        self.sourceBackend = sourceBackend
        self.portable = portable
        self.disposition = disposition
        self.issues = issues
        self.components = components
    }
}
