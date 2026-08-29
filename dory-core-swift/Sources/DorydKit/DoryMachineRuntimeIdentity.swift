import CryptoKit
import DoryOperations
import Foundation

public enum DoryMachineRuntimeIdentityMode: String, Codable, Sendable, Hashable {
    case legacyCompatibility = "legacy-compatibility"
    case resolvedPlan = "resolved-plan"
    /// The machine is governed by the resolved-plan launch policy, but its current desired
    /// state or mutable artifacts are not covered by a launch-authorizing plan yet.
    case requiresReplanning = "requires-replanning"
}

public enum DoryMachineRuntimeIdentityInvalidationReason: String, Codable, Sendable, Hashable {
    case definitionChanged = "definition-changed"
    case restoredSnapshot = "restored-snapshot"
    case planRecoveryFailed = "plan-recovery-failed"
    case planNotInstalled = "plan-not-installed"
    case importedSnapshot = "imported-snapshot"
}

public enum DoryMachineRuntimeIdentityValidationCode: String, Codable, Sendable, Hashable {
    case unsupportedSchemaVersion = "unsupported-schema-version"
    case legacyCarriesResolvedEvidence = "legacy-carries-resolved-evidence"
    case missingResolvedEvidence = "missing-resolved-evidence"
    case invalidResolvedPlan = "invalid-resolved-plan"
    case invalidPlanDigest = "invalid-plan-digest"
    case planDigestMismatch = "plan-digest-mismatch"
    case invalidVirtualHardwareABI = "invalid-virtual-hardware-abi"
    case invalidInvalidationReason = "invalid-invalidation-reason"
}

public struct DoryMachineRuntimeIdentityValidationIssue:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public var code: DoryMachineRuntimeIdentityValidationCode
    public var field: String

    public init(code: DoryMachineRuntimeIdentityValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

/// Immutable, non-secret evidence identifying the exact runtime selected for a machine launch.
/// The resolved plan is retained whole so status, snapshots, exports, and diagnostics cannot drift
/// into mutually inconsistent subsets of definition, backend, media, component, or qualification
/// evidence. Legacy launches are represented explicitly and never masquerade as resolved evidence.
public struct DoryMachineRuntimeIdentity: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1
    /// The virtual-hardware ABI used by metadata written before runtime identity became
    /// explicit. This value is deliberately independent of the current ABI so a future ABI
    /// bump cannot relabel historical snapshots as newly compatible.
    public static let oldestLegacyVirtualHardwareABIVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var mode: DoryMachineRuntimeIdentityMode
    public var virtualHardwareABIVersion: UInt16
    public var invalidationReason: DoryMachineRuntimeIdentityInvalidationReason?
    public var resolvedPlanSHA256: String?
    public var resolvedPlan: DoryResolvedMachinePlan?

    public static func legacyCompatibility(virtualHardwareABIVersion: UInt16 = 1) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            mode: .legacyCompatibility,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            invalidationReason: nil,
            resolvedPlanSHA256: nil,
            resolvedPlan: nil
        )
    }

    public static func requiresReplanning(
        virtualHardwareABIVersion: UInt16 = 1,
        reason: DoryMachineRuntimeIdentityInvalidationReason
    ) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            mode: .requiresReplanning,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            invalidationReason: reason,
            resolvedPlanSHA256: nil,
            resolvedPlan: nil
        )
    }

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        mode: DoryMachineRuntimeIdentityMode,
        virtualHardwareABIVersion: UInt16,
        invalidationReason: DoryMachineRuntimeIdentityInvalidationReason? = nil,
        resolvedPlanSHA256: String?,
        resolvedPlan: DoryResolvedMachinePlan?
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.invalidationReason = invalidationReason
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.resolvedPlan = resolvedPlan
    }

    public init(resolvedPlan: DoryResolvedMachinePlan, planSHA256: String) throws {
        self.init(
            mode: .resolvedPlan,
            virtualHardwareABIVersion: resolvedPlan.virtualHardwareABIVersion,
            invalidationReason: nil,
            resolvedPlanSHA256: planSHA256.lowercased(),
            resolvedPlan: resolvedPlan
        )
        guard validate().isEmpty else {
            throw MachineManagerError.persistence("invalid immutable runtime identity")
        }
    }

    public var definitionRevision: UInt64? { resolvedPlan?.definitionRevision }
    public var definitionSHA256: String? { resolvedPlan?.definitionSHA256 }
    public var planRevision: UInt64? { resolvedPlan?.planRevision }
    public var backend: DoryVirtualizationBackendIdentity? { resolvedPlan?.backend }
    public var backendImplementationIdentifier: String? {
        resolvedPlan?.backendImplementationIdentifier
    }
    public var backendRuntimeBuildIdentifier: String? {
        resolvedPlan?.backendRuntimeBuildIdentifier
    }
    public var supportTier: DoryCapabilitySupportTier? { resolvedPlan?.supportTier }
    public var selectionDisposition: DoryResolvedMachineSelectionDisposition? {
        resolvedPlan?.selectionEvidence?.disposition
    }
    public var fallbackAuthorization: DoryResolvedMachineFallbackAuthorization? {
        resolvedPlan?.selectionEvidence?.fallbackAuthorization
    }
    public var experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization? {
        resolvedPlan?.experimentalAuthorization
    }
    public var qualificationEvidence: DoryResolvedMachineQualificationEvidence? {
        resolvedPlan?.qualificationEvidence
    }
    public var hostQualification: DoryResolvedHostQualificationEvidence? {
        resolvedPlan?.hostQualification
    }
    public var components: [DoryResolvedBackendComponentEvidence] {
        resolvedPlan?.components ?? []
    }
    public var bootMedia: DoryResolvedMachineBootMedia? { resolvedPlan?.bootMedia }

    public func validate() -> [DoryMachineRuntimeIdentityValidationIssue] {
        guard schemaVersion == Self.currentSchemaVersion else {
            return [DoryMachineRuntimeIdentityValidationIssue(
                code: .unsupportedSchemaVersion,
                field: "schemaVersion"
            )]
        }
        guard virtualHardwareABIVersion > 0 else {
            return [DoryMachineRuntimeIdentityValidationIssue(
                code: .invalidVirtualHardwareABI,
                field: "virtualHardwareABIVersion"
            )]
        }
        switch mode {
        case .legacyCompatibility:
            guard invalidationReason == nil,
                  resolvedPlanSHA256 == nil, resolvedPlan == nil else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .legacyCarriesResolvedEvidence,
                    field: "resolvedPlan"
                )]
            }
            return []
        case .requiresReplanning:
            guard invalidationReason != nil else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .invalidInvalidationReason,
                    field: "invalidationReason"
                )]
            }
            guard resolvedPlanSHA256 == nil, resolvedPlan == nil else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .legacyCarriesResolvedEvidence,
                    field: "resolvedPlan"
                )]
            }
            return []
        case .resolvedPlan:
            guard invalidationReason == nil else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .invalidInvalidationReason,
                    field: "invalidationReason"
                )]
            }
            guard let digest = resolvedPlanSHA256, let plan = resolvedPlan else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .missingResolvedEvidence,
                    field: resolvedPlan == nil ? "resolvedPlan" : "resolvedPlanSHA256"
                )]
            }
            guard Self.isSHA256(digest) else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .invalidPlanDigest,
                    field: "resolvedPlanSHA256"
                )]
            }
            guard plan.validate().isEmpty else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .invalidResolvedPlan,
                    field: "resolvedPlan"
                )]
            }
            guard plan.virtualHardwareABIVersion == virtualHardwareABIVersion else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .invalidVirtualHardwareABI,
                    field: "virtualHardwareABIVersion"
                )]
            }
            guard digest == Self.planSHA256(plan) else {
                return [DoryMachineRuntimeIdentityValidationIssue(
                    code: .planDigestMismatch,
                    field: "resolvedPlanSHA256"
                )]
            }
            return []
        }
    }

    public static func planSHA256(_ plan: DoryResolvedMachinePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mode
        case virtualHardwareABIVersion
        case invalidationReason
        case resolvedPlanSHA256
        case resolvedPlan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(
                UInt16.self,
                forKey: .schemaVersion
            ) ?? Self.currentSchemaVersion,
            mode: try container.decode(DoryMachineRuntimeIdentityMode.self, forKey: .mode),
            virtualHardwareABIVersion: try container.decodeIfPresent(
                UInt16.self,
                forKey: .virtualHardwareABIVersion
            ) ?? Self.oldestLegacyVirtualHardwareABIVersion,
            invalidationReason: try container.decodeIfPresent(
                DoryMachineRuntimeIdentityInvalidationReason.self,
                forKey: .invalidationReason
            ),
            resolvedPlanSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .resolvedPlanSHA256
            ),
            resolvedPlan: try container.decodeIfPresent(
                DoryResolvedMachinePlan.self,
                forKey: .resolvedPlan
            )
        )
    }
}

public struct DoryMachineSnapshotArtifact: Codable, Sendable, Equatable, Hashable {
    public var byteCount: UInt64
    public var sha256: String

    public init(byteCount: UInt64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
    }

    public var isValid: Bool {
        byteCount > 0
            && sha256.count == 64
            && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Content identity for the mutable artifacts captured by a snapshot. This deliberately carries
/// no daemon-local paths: exports can move across hosts without leaking or trusting host layout.
public struct DoryMachineSnapshotArtifactEvidence: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var rootfs: DoryMachineSnapshotArtifact
    public var kernel: DoryMachineSnapshotArtifact
    public var machineIdentifier: DoryMachineSnapshotArtifact?
    public var nvram: DoryMachineSnapshotArtifact?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        rootfs: DoryMachineSnapshotArtifact,
        kernel: DoryMachineSnapshotArtifact,
        machineIdentifier: DoryMachineSnapshotArtifact? = nil,
        nvram: DoryMachineSnapshotArtifact? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.rootfs = rootfs
        self.kernel = kernel
        self.machineIdentifier = machineIdentifier
        self.nvram = nvram
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && rootfs.isValid
            && kernel.isValid
            && (machineIdentifier?.isValid ?? true)
            && (nvram?.isValid ?? true)
            && ((machineIdentifier == nil) == (nvram == nil))
    }
}
