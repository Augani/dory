import DoryOperations
import Foundation

public enum DoryResolvedMachinePlanMigrationDisposition: String, Codable, Sendable, Hashable {
    case current
    /// The record can be decoded for migration, but cannot authorize a launch.
    case requiresReplanning = "requires-replanning"
}

public struct DoryResolvedBackendComponentEvidence: Codable, Sendable, Equatable, Hashable {
    public var componentIdentifier: String
    public var buildIdentifier: String
    public var artifactSHA256: String

    init(
        componentIdentifier: String,
        buildIdentifier: String,
        artifactSHA256: String
    ) {
        self.componentIdentifier = componentIdentifier
        self.buildIdentifier = buildIdentifier
        self.artifactSHA256 = artifactSHA256
    }
}

/// Exact resolved media identity. Immutable media is content-addressed; mutable disks use a
/// daemon-issued provenance revision and receipt instead of pretending their bytes never change.
public struct DoryResolvedMachineBootMedia: Codable, Sendable, Equatable, Hashable {
    public var resolverReference: DoryVMResolverReference?
    public var media: DoryBootMedia
    public var inspectionEvidence: DoryBootMediaInspectionAuditEvidence?
    public var mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence?

    init(
        resolverReference: DoryVMResolverReference?,
        media: DoryBootMedia,
        inspectionEvidence: DoryBootMediaInspectionAuditEvidence? = nil,
        mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence? = nil
    ) {
        self.resolverReference = resolverReference
        self.media = media
        self.inspectionEvidence = inspectionEvidence
        self.mutableProvenanceEvidence = mutableProvenanceEvidence
    }
}

public enum DoryResolvedMachineLaunchArtifactUsageKind:
    String, Codable, Sendable, Equatable, Hashable
{
    case boot
    case storage
    case firmware
}

/// One launch-time use of an artifact. Keeping the stable desired-state identifier makes a plan
/// auditable without persisting any host path.
public struct DoryResolvedMachineLaunchArtifactUsage:
    Codable, Sendable, Equatable, Hashable
{
    public var kind: DoryResolvedMachineLaunchArtifactUsageKind
    public var identifier: String
    public var readOnly: Bool

    public init(
        kind: DoryResolvedMachineLaunchArtifactUsageKind,
        identifier: String,
        readOnly: Bool
    ) {
        self.kind = kind
        self.identifier = identifier
        self.readOnly = readOnly
    }
}

/// Exact, path-free authority for every artifact whose bytes can influence launch. Immutable
/// artifacts carry a content digest in `media`; mutable disks carry a daemon-issued provenance
/// revision and receipt. `authorityRevision` binds the exact private resolver publication.
public struct DoryResolvedMachineLaunchArtifact:
    Codable, Sendable, Equatable, Hashable
{
    public var resolverReference: DoryVMResolverReference
    public var media: DoryBootMedia
    public var authorityRevision: UInt64
    public var usages: [DoryResolvedMachineLaunchArtifactUsage]
    public var mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence?

    public init(
        resolverReference: DoryVMResolverReference,
        media: DoryBootMedia,
        authorityRevision: UInt64,
        usages: [DoryResolvedMachineLaunchArtifactUsage],
        mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence? = nil
    ) {
        self.resolverReference = resolverReference
        self.media = media
        self.authorityRevision = authorityRevision
        self.usages = usages
        self.mutableProvenanceEvidence = mutableProvenanceEvidence
    }
}

/// Persisted audit references only. Signature verification and qualification decisions remain
/// daemon-owned; these references let the daemon resolve and verify the exact evidence again.
public struct DoryResolvedMachineQualificationEvidence: Codable, Sendable, Equatable, Hashable {
    public var graphics: DorySignedArtifactQualificationEvidence?
    public var runtime: DoryVirtualMachineRuntimeQualificationEvidence?

    public init(
        graphics: DorySignedArtifactQualificationEvidence? = nil,
        runtime: DoryVirtualMachineRuntimeQualificationEvidence? = nil
    ) {
        self.graphics = graphics
        self.runtime = runtime
    }
}

/// Exact resource admission captured by the daemon policy immediately before plan publication.
/// The snapshot includes existing commitments and the reserve retained for macOS.
public struct DoryResolvedMachineResourceAdmissionEvidence: Codable, Sendable, Equatable, Hashable {
    public var admittedVirtualCPUCount: UInt64
    public var admittedMemoryBytes: UInt64
    public var admittedStorageBytes: UInt64
    public var hostLogicalCPUCount: UInt64
    public var hostPhysicalMemoryBytes: UInt64
    public var hostFreeStorageBytes: UInt64
    public var existingVirtualCPUCommitment: UInt64
    public var existingMemoryCommitmentBytes: UInt64
    public var existingStorageReservationBytes: UInt64
    public var hostReservedLogicalCPUCount: UInt64
    public var hostReservedMemoryBytes: UInt64
    public var hostReservedStorageBytes: UInt64
    public var admissionIdentity: String
    public var admissionReportSHA256: String
    public var assessorIdentifier: String
    public var assessorVersion: UInt16

    public init(
        admittedVirtualCPUCount: UInt64,
        admittedMemoryBytes: UInt64,
        admittedStorageBytes: UInt64,
        hostLogicalCPUCount: UInt64,
        hostPhysicalMemoryBytes: UInt64,
        hostFreeStorageBytes: UInt64,
        existingVirtualCPUCommitment: UInt64,
        existingMemoryCommitmentBytes: UInt64,
        existingStorageReservationBytes: UInt64,
        hostReservedLogicalCPUCount: UInt64,
        hostReservedMemoryBytes: UInt64,
        hostReservedStorageBytes: UInt64,
        admissionIdentity: String,
        admissionReportSHA256: String,
        assessorIdentifier: String,
        assessorVersion: UInt16
    ) {
        self.admittedVirtualCPUCount = admittedVirtualCPUCount
        self.admittedMemoryBytes = admittedMemoryBytes
        self.admittedStorageBytes = admittedStorageBytes
        self.hostLogicalCPUCount = hostLogicalCPUCount
        self.hostPhysicalMemoryBytes = hostPhysicalMemoryBytes
        self.hostFreeStorageBytes = hostFreeStorageBytes
        self.existingVirtualCPUCommitment = existingVirtualCPUCommitment
        self.existingMemoryCommitmentBytes = existingMemoryCommitmentBytes
        self.existingStorageReservationBytes = existingStorageReservationBytes
        self.hostReservedLogicalCPUCount = hostReservedLogicalCPUCount
        self.hostReservedMemoryBytes = hostReservedMemoryBytes
        self.hostReservedStorageBytes = hostReservedStorageBytes
        self.admissionIdentity = admissionIdentity
        self.admissionReportSHA256 = admissionReportSHA256
        self.assessorIdentifier = assessorIdentifier
        self.assessorVersion = assessorVersion
    }
}

/// Explicit host qualification key. A generic runtime qualification identity is not sufficient:
/// backend conformance also depends on the exact Mac model and operating-system build.
public struct DoryResolvedHostQualificationEvidence: Codable, Sendable, Equatable, Hashable {
    public var qualificationIdentity: String
    public var qualificationReportSHA256: String
    public var hostHardwareModelIdentifier: String
    public var hostOperatingSystemBuild: String
    public var backend: DoryVirtualizationBackendIdentity
    public var backendRuntimeBuildIdentifier: String
    public var virtualHardwareABIVersion: UInt16
    public var qualifierIdentifier: String
    public var qualifierVersion: UInt16

    public init(
        qualificationIdentity: String,
        qualificationReportSHA256: String,
        hostHardwareModelIdentifier: String,
        hostOperatingSystemBuild: String,
        backend: DoryVirtualizationBackendIdentity,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        qualifierIdentifier: String,
        qualifierVersion: UInt16
    ) {
        self.qualificationIdentity = qualificationIdentity
        self.qualificationReportSHA256 = qualificationReportSHA256
        self.hostHardwareModelIdentifier = hostHardwareModelIdentifier
        self.hostOperatingSystemBuild = hostOperatingSystemBuild
        self.backend = backend
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.qualifierIdentifier = qualifierIdentifier
        self.qualifierVersion = qualifierVersion
    }
}

/// Explicit opt-in captured when an experimental product support tier is selected.
public struct DoryResolvedExperimentalSupportAuthorization: Codable, Sendable, Equatable, Hashable {
    public var authorizationIdentity: String
    public var definitionRevision: UInt64
    public var backend: DoryVirtualizationBackendIdentity
    public var authorizedAtUnixMilliseconds: Int64

    public init(
        authorizationIdentity: String,
        definitionRevision: UInt64,
        backend: DoryVirtualizationBackendIdentity,
        authorizedAtUnixMilliseconds: Int64
    ) {
        self.authorizationIdentity = authorizationIdentity
        self.definitionRevision = definitionRevision
        self.backend = backend
        self.authorizedAtUnixMilliseconds = authorizedAtUnixMilliseconds
    }
}

public enum DoryResolvedMachineCandidateRejection: String, Codable, Sendable, Hashable {
    case unavailable
    case experimentalNotAuthorized = "experimental-not-authorized"
}

public struct DoryResolvedMachineRejectedCandidate: Codable, Sendable, Equatable, Hashable {
    public var backend: DoryVirtualizationBackendIdentity
    public var graphics: DoryGraphicsAccelerationLevel
    public var availability: DoryCapabilityAvailability
    public var rejection: DoryResolvedMachineCandidateRejection

    public init(
        backend: DoryVirtualizationBackendIdentity,
        graphics: DoryGraphicsAccelerationLevel,
        availability: DoryCapabilityAvailability,
        rejection: DoryResolvedMachineCandidateRejection
    ) {
        self.backend = backend
        self.graphics = graphics
        self.availability = availability
        self.rejection = rejection
    }
}

public struct DoryResolvedMachineFallbackAuthorization: Codable, Sendable, Equatable, Hashable {
    public var authorizationIdentity: String
    public var definitionRevision: UInt64
    public var fromBackend: DoryVirtualizationBackendIdentity
    public var fromGraphics: DoryGraphicsAccelerationLevel
    public var toBackend: DoryVirtualizationBackendIdentity
    public var toGraphics: DoryGraphicsAccelerationLevel
    public var authorizedAtUnixMilliseconds: Int64

    public init(
        authorizationIdentity: String,
        definitionRevision: UInt64,
        fromBackend: DoryVirtualizationBackendIdentity,
        fromGraphics: DoryGraphicsAccelerationLevel,
        toBackend: DoryVirtualizationBackendIdentity,
        toGraphics: DoryGraphicsAccelerationLevel,
        authorizedAtUnixMilliseconds: Int64
    ) {
        self.authorizationIdentity = authorizationIdentity
        self.definitionRevision = definitionRevision
        self.fromBackend = fromBackend
        self.fromGraphics = fromGraphics
        self.toBackend = toBackend
        self.toGraphics = toGraphics
        self.authorizedAtUnixMilliseconds = authorizedAtUnixMilliseconds
    }
}

public enum DoryResolvedMachineSelectionDisposition: String, Codable, Sendable, Hashable {
    case primary
    /// A later backend or graphics level explicitly listed by a required planner request.
    case explicitAlternative = "explicit-alternative"
    case approvedFallback = "approved-fallback"
}

/// Complete, non-secret selection trace. The original planner request is retained so diagnostics
/// can distinguish an explicit primary choice from an approved fallback.
public struct DoryResolvedMachineBackendSelectionEvidence: Codable, Sendable, Equatable, Hashable {
    public var disposition: DoryResolvedMachineSelectionDisposition
    public var plannerRequest: DoryVirtualMachineBackendPlanRequest
    public var selectedEvaluationIndex: UInt32
    public var rejectedCandidates: [DoryResolvedMachineRejectedCandidate]
    public var fallbackAuthorization: DoryResolvedMachineFallbackAuthorization?

    public init(
        disposition: DoryResolvedMachineSelectionDisposition,
        plannerRequest: DoryVirtualMachineBackendPlanRequest,
        selectedEvaluationIndex: UInt32,
        rejectedCandidates: [DoryResolvedMachineRejectedCandidate],
        fallbackAuthorization: DoryResolvedMachineFallbackAuthorization? = nil
    ) {
        self.disposition = disposition
        self.plannerRequest = plannerRequest
        self.selectedEvaluationIndex = selectedEvaluationIndex
        self.rejectedCandidates = rejectedCandidates
        self.fallbackAuthorization = fallbackAuthorization
    }

    public static func resolving(
        request: DoryVirtualMachineBackendPlanRequest,
        result: DoryVirtualMachineBackendPlanResult,
        definitionRevision: UInt64,
        fallbackAuthorization: DoryResolvedMachineFallbackAuthorization? = nil
    ) throws -> DoryResolvedMachineBackendSelectionEvidence {
        guard result.failure == nil,
              let selected = result.selectedDescriptor,
              let selectedIndex = result.evaluatedDescriptors.firstIndex(of: selected),
              selectedIndex <= Int(UInt32.max),
              selected.availability.isUsable,
              selected.request.guest == request.guest,
              selected.request.bootMedia == request.bootMedia,
              selected.request.devices == request.devices,
              selected.request.virtualHardwareABIVersion == request.virtualHardwareABIVersion,
              request.acceptableGraphics.contains(selected.request.graphics) else {
            throw DoryResolvedMachinePlanConstructionError.plannerResultInvalid
        }
        guard let orderedCandidates = orderedCandidates(for: request),
              orderedCandidates.indices.contains(selectedIndex),
              orderedCandidates[selectedIndex].0 == selected.request.backend,
              orderedCandidates[selectedIndex].1 == selected.request.graphics else {
            throw DoryResolvedMachinePlanConstructionError.plannerResultInvalid
        }

        var rejected: [DoryResolvedMachineRejectedCandidate] = []
        for (index, descriptor) in result.evaluatedDescriptors.prefix(selectedIndex).enumerated() {
            guard descriptor.request.guest == request.guest,
                  descriptor.request.bootMedia == request.bootMedia,
                  descriptor.request.devices == request.devices,
                  descriptor.request.virtualHardwareABIVersion == request.virtualHardwareABIVersion,
                  descriptor.request.backend == orderedCandidates[index].0,
                  descriptor.request.graphics == orderedCandidates[index].1 else {
                throw DoryResolvedMachinePlanConstructionError.plannerResultInvalid
            }
            let rejection: DoryResolvedMachineCandidateRejection
            if !descriptor.availability.isUsable {
                rejection = .unavailable
            } else if descriptor.availability.supportTier == .experimental,
                      !request.allowsExperimentalBackends {
                rejection = .experimentalNotAuthorized
            } else {
                throw DoryResolvedMachinePlanConstructionError.plannerResultInvalid
            }
            rejected.append(DoryResolvedMachineRejectedCandidate(
                backend: descriptor.request.backend,
                graphics: descriptor.request.graphics,
                availability: descriptor.availability,
                rejection: rejection
            ))
        }

        guard selectedIndex > 0 else {
            guard fallbackAuthorization == nil else {
                throw DoryResolvedMachinePlanConstructionError.fallbackAuthorizationInvalid
            }
            return DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: request,
                selectedEvaluationIndex: 0,
                rejectedCandidates: []
            )
        }
        if request.backendPreferencePolicy == .required {
            guard fallbackAuthorization == nil else {
                throw DoryResolvedMachinePlanConstructionError.fallbackAuthorizationInvalid
            }
            return DoryResolvedMachineBackendSelectionEvidence(
                disposition: .explicitAlternative,
                plannerRequest: request,
                selectedEvaluationIndex: UInt32(selectedIndex),
                rejectedCandidates: rejected
            )
        }
        guard let authorization = fallbackAuthorization else {
            throw DoryResolvedMachinePlanConstructionError.fallbackAuthorizationRequired
        }
        guard let first = rejected.first,
              authorization.definitionRevision == definitionRevision,
              authorization.fromBackend == first.backend,
              authorization.fromGraphics == first.graphics,
              authorization.toBackend == selected.request.backend,
              authorization.toGraphics == selected.request.graphics else {
            throw DoryResolvedMachinePlanConstructionError.fallbackAuthorizationInvalid
        }
        return DoryResolvedMachineBackendSelectionEvidence(
            disposition: .approvedFallback,
            plannerRequest: request,
            selectedEvaluationIndex: UInt32(selectedIndex),
            rejectedCandidates: rejected,
            fallbackAuthorization: authorization
        )
    }

    fileprivate static func orderedCandidates(
        for request: DoryVirtualMachineBackendPlanRequest
    ) -> [(DoryVirtualizationBackendIdentity, DoryGraphicsAccelerationLevel)]? {
        guard !request.acceptableGraphics.isEmpty,
              Set(request.acceptableGraphics).count == request.acceptableGraphics.count else {
            return nil
        }
        let defaults = DoryAppleSiliconVirtualMachineBackendPlanner.defaultBackends(
            for: request.guest,
            bootMedia: request.bootMedia.kind
        )
        let backends: [DoryVirtualizationBackendIdentity]
        if let preferences = request.backendPreferences {
            guard !preferences.isEmpty, Set(preferences).count == preferences.count else {
                return nil
            }
            if request.backendPreferencePolicy == .required {
                backends = preferences
            } else {
                var seen: Set<DoryVirtualizationBackendIdentity> = []
                backends = (preferences + defaults).filter { seen.insert($0).inserted }
            }
        } else {
            guard request.backendPreferencePolicy != .required else { return nil }
            backends = defaults
        }
        return request.acceptableGraphics.flatMap { graphics in
            backends.map { backend in (backend, graphics) }
        }
    }
}

public enum DoryResolvedMachinePlanConstructionError: Error, Sendable, Equatable {
    case backendDescriptorMismatch
    case capabilityDescriptorInvalid
    case plannerResultInvalid
    case fallbackDisallowed
    case fallbackAuthorizationRequired
    case fallbackAuthorizationInvalid
}

public enum DoryResolvedMachinePlanValidationCode: String, Codable, Sendable, Hashable {
    case unsupportedSchemaVersion = "unsupported-schema-version"
    case legacyPlanRequiresReplanning = "legacy-plan-requires-replanning"
    case invalidMachineIdentifier = "invalid-machine-identifier"
    case invalidRevision = "invalid-revision"
    case invalidDefinitionDigest = "invalid-definition-digest"
    case invalidBackendImplementation = "invalid-backend-implementation"
    case invalidBackendRuntimeBuild = "invalid-backend-runtime-build"
    case invalidVirtualHardwareABI = "invalid-virtual-hardware-abi"
    case invalidResolverReference = "invalid-resolver-reference"
    case invalidMediaBinding = "invalid-media-binding"
    case invalidMediaEvidence = "invalid-media-evidence"
    case invalidLaunchArtifactEvidence = "invalid-launch-artifact-evidence"
    case unsupportedRuntimeCombination = "unsupported-runtime-combination"
    case duplicateComponent = "duplicate-component"
    case unorderedComponents = "unordered-components"
    case invalidComponentEvidence = "invalid-component-evidence"
    case missingGraphicsQualification = "missing-graphics-qualification"
    case invalidGraphicsQualification = "invalid-graphics-qualification"
    case missingRuntimeQualification = "missing-runtime-qualification"
    case runtimeQualificationMismatch = "runtime-qualification-mismatch"
    case invalidResourceAdmission = "invalid-resource-admission"
    case invalidHostQualification = "invalid-host-qualification"
    case unsupportedSupportTier = "unsupported-support-tier"
    case missingExperimentalAuthorization = "missing-experimental-authorization"
    case invalidExperimentalAuthorization = "invalid-experimental-authorization"
    case missingSelectionEvidence = "missing-selection-evidence"
    case invalidSelectionEvidence = "invalid-selection-evidence"
    case fallbackDisallowed = "fallback-disallowed"
    case missingFallbackAuthorization = "missing-fallback-authorization"
    case invalidFallbackAuthorization = "invalid-fallback-authorization"
}

public struct DoryResolvedMachinePlanValidationIssue: Codable, Sendable, Equatable, Hashable {
    public var code: DoryResolvedMachinePlanValidationCode
    public var field: String

    public init(code: DoryResolvedMachinePlanValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

/// Durable output of capability resolution. Unlike desired state, every field is an exact launch
/// decision or non-secret audit reference and is replaced whenever any bound evidence changes.
public struct DoryResolvedMachinePlan: Codable, Sendable, Equatable, Hashable {
    public static let oldestSupportedSchemaVersion: UInt16 = 1
    public static let currentSchemaVersion: UInt16 = 3

    public var schemaVersion: UInt16
    public var sourceSchemaVersion: UInt16
    public var migrationDisposition: DoryResolvedMachinePlanMigrationDisposition
    public var machineID: String
    public var definitionRevision: UInt64
    public var definitionSHA256: String?
    public var planRevision: UInt64
    public var createdAtUnixMilliseconds: Int64
    public var updatedAtUnixMilliseconds: Int64
    public var guest: DoryGuestPlatform
    public var backend: DoryVirtualizationBackendIdentity
    public var backendImplementationIdentifier: String
    public var backendRuntimeBuildIdentifier: String
    public var virtualHardwareABIVersion: UInt16
    public var bootMedia: DoryResolvedMachineBootMedia
    public var launchArtifacts: [DoryResolvedMachineLaunchArtifact]
    public var components: [DoryResolvedBackendComponentEvidence]
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var graphics: DoryGraphicsAccelerationLevel
    public var supportTier: DoryCapabilitySupportTier
    public var selectionEvidence: DoryResolvedMachineBackendSelectionEvidence?
    public var qualificationEvidence: DoryResolvedMachineQualificationEvidence
    public var resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence?
    public var hostQualification: DoryResolvedHostQualificationEvidence?
    public var experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization?

    public init(
        machineID: String,
        definitionRevision: UInt64,
        definitionSHA256: String,
        planRevision: UInt64,
        createdAtUnixMilliseconds: Int64,
        updatedAtUnixMilliseconds: Int64,
        guest: DoryGuestPlatform,
        backend: DoryVirtualizationBackendIdentity,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        bootMedia: DoryResolvedMachineBootMedia,
        launchArtifacts: [DoryResolvedMachineLaunchArtifact],
        components: [DoryResolvedBackendComponentEvidence],
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        graphics: DoryGraphicsAccelerationLevel,
        supportTier: DoryCapabilitySupportTier,
        selectionEvidence: DoryResolvedMachineBackendSelectionEvidence,
        qualificationEvidence: DoryResolvedMachineQualificationEvidence,
        resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence,
        hostQualification: DoryResolvedHostQualificationEvidence,
        experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        sourceSchemaVersion = Self.currentSchemaVersion
        migrationDisposition = .current
        self.machineID = machineID
        self.definitionRevision = definitionRevision
        self.definitionSHA256 = definitionSHA256
        self.planRevision = planRevision
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
        self.guest = guest
        self.backend = backend
        self.backendImplementationIdentifier = backendImplementationIdentifier
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.bootMedia = bootMedia
        self.launchArtifacts = launchArtifacts
        self.components = components
        self.devices = devices
        self.graphics = graphics
        self.supportTier = supportTier
        self.selectionEvidence = selectionEvidence
        self.qualificationEvidence = qualificationEvidence
        self.resourceAdmission = resourceAdmission
        self.hostQualification = hostQualification
        self.experimentalAuthorization = experimentalAuthorization
    }

    /// Builds the durable record from the planner-selected capability without allowing the
    /// caller to substitute its backend, graphics, devices, ABI, or qualification references.
    public init(
        machineID: String,
        definitionRevision: UInt64,
        definitionSHA256: String,
        planRevision: UInt64,
        createdAtUnixMilliseconds: Int64,
        updatedAtUnixMilliseconds: Int64,
        backendDescriptor: MachineBackendDescriptor,
        backendRuntimeBuildIdentifier: String,
        resolverReference: DoryVMResolverReference?,
        launchArtifacts: [DoryResolvedMachineLaunchArtifact],
        components: [DoryResolvedBackendComponentEvidence],
        resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence,
        hostQualification: DoryResolvedHostQualificationEvidence,
        experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization? = nil,
        plannerRequest: DoryVirtualMachineBackendPlanRequest,
        plannerResult: DoryVirtualMachineBackendPlanResult,
        fallbackAuthorization: DoryResolvedMachineFallbackAuthorization? = nil
    ) throws {
        guard let selectedCapability = plannerResult.selectedDescriptor else {
            throw DoryResolvedMachinePlanConstructionError.plannerResultInvalid
        }
        guard backendDescriptor.identity == selectedCapability.request.backend else {
            throw DoryResolvedMachinePlanConstructionError.backendDescriptorMismatch
        }
        guard selectedCapability.schemaVersion
                == DoryVirtualMachineCapabilityDescriptor.currentSchemaVersion,
              selectedCapability.evaluatorVersion
                == DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
              selectedCapability.availability.isUsable,
              selectedCapability.availability.supportTier != .unsupported,
              selectedCapability.resolvedDevices == selectedCapability.request.devices else {
            throw DoryResolvedMachinePlanConstructionError.capabilityDescriptorInvalid
        }
        let selectionEvidence = try DoryResolvedMachineBackendSelectionEvidence.resolving(
            request: plannerRequest,
            result: plannerResult,
            definitionRevision: definitionRevision,
            fallbackAuthorization: fallbackAuthorization
        )
        self.init(
            machineID: machineID,
            definitionRevision: definitionRevision,
            definitionSHA256: definitionSHA256,
            planRevision: planRevision,
            createdAtUnixMilliseconds: createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: updatedAtUnixMilliseconds,
            guest: selectedCapability.request.guest,
            backend: selectedCapability.request.backend,
            backendImplementationIdentifier: backendDescriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: backendRuntimeBuildIdentifier,
            virtualHardwareABIVersion: selectedCapability.request.virtualHardwareABIVersion,
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: resolverReference,
                media: selectedCapability.request.bootMedia,
                inspectionEvidence: selectedCapability.bootMediaInspectionEvidence,
                mutableProvenanceEvidence: selectedCapability.mutableBootMediaProvenanceEvidence
            ),
            launchArtifacts: launchArtifacts,
            components: components,
            devices: selectedCapability.request.devices,
            graphics: selectedCapability.request.graphics,
            supportTier: selectedCapability.availability.supportTier,
            selectionEvidence: selectionEvidence,
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                graphics: selectedCapability.graphicsQualificationEvidence,
                runtime: selectedCapability.runtimeQualificationEvidence
            ),
            resourceAdmission: resourceAdmission,
            hostQualification: hostQualification,
            experimentalAuthorization: experimentalAuthorization
        )
        guard validate().isEmpty else {
            throw DoryResolvedMachinePlanConstructionError.capabilityDescriptorInvalid
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceSchemaVersion
        case migrationDisposition
        case machineID
        case definitionRevision
        case definitionSHA256
        case planRevision
        case createdAtUnixMilliseconds
        case updatedAtUnixMilliseconds
        case guest
        case backend
        case backendImplementationIdentifier
        case backendRuntimeBuildIdentifier
        case backendRuntimeBuildID
        case virtualHardwareABIVersion
        case bootMedia
        case launchArtifacts
        case components
        case componentDigests
        case devices
        case graphics
        case supportTier
        case selectionEvidence
        case qualificationEvidence
        case resourceAdmission
        case hostQualification
        case experimentalAuthorization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchema = try container.decode(UInt16.self, forKey: .schemaVersion)
        switch persistedSchema {
        case Self.oldestSupportedSchemaVersion:
            schemaVersion = Self.currentSchemaVersion
            sourceSchemaVersion = persistedSchema
            migrationDisposition = .requiresReplanning
            machineID = try container.decode(String.self, forKey: .machineID)
            definitionRevision = try container.decode(UInt64.self, forKey: .definitionRevision)
            definitionSHA256 = nil
            planRevision = try container.decode(UInt64.self, forKey: .planRevision)
            createdAtUnixMilliseconds = try container.decodeIfPresent(
                Int64.self,
                forKey: .createdAtUnixMilliseconds
            ) ?? 0
            updatedAtUnixMilliseconds = try container.decodeIfPresent(
                Int64.self,
                forKey: .updatedAtUnixMilliseconds
            ) ?? createdAtUnixMilliseconds
            guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
            backend = try container.decode(DoryVirtualizationBackendIdentity.self, forKey: .backend)
            backendImplementationIdentifier = "legacy-unresolved"
            backendRuntimeBuildIdentifier = try container.decode(
                String.self,
                forKey: .backendRuntimeBuildID
            )
            virtualHardwareABIVersion = try container.decode(
                UInt16.self,
                forKey: .virtualHardwareABIVersion
            )
            bootMedia = DoryResolvedMachineBootMedia(
                resolverReference: nil,
                media: try container.decode(DoryBootMedia.self, forKey: .bootMedia)
            )
            launchArtifacts = []
            let legacyDigests = try container.decode(
                [String: String].self,
                forKey: .componentDigests
            )
            components = legacyDigests.keys.sorted().map { identifier in
                DoryResolvedBackendComponentEvidence(
                    componentIdentifier: identifier,
                    buildIdentifier: "legacy-unresolved",
                    artifactSHA256: legacyDigests[identifier] ?? ""
                )
            }
            devices = try container.decodeIfPresent(
                DoryVirtualMachineDeviceCapabilityRequest.self,
                forKey: .devices
            ) ?? .minimumBootable
            graphics = try container.decode(DoryGraphicsAccelerationLevel.self, forKey: .graphics)
            supportTier = .experimental
            selectionEvidence = nil
            qualificationEvidence = DoryResolvedMachineQualificationEvidence()
            resourceAdmission = nil
            hostQualification = nil
            experimentalAuthorization = nil
        case 2, Self.currentSchemaVersion:
            schemaVersion = Self.currentSchemaVersion
            sourceSchemaVersion = persistedSchema
            migrationDisposition = persistedSchema == Self.currentSchemaVersion
                ? try container.decode(
                    DoryResolvedMachinePlanMigrationDisposition.self,
                    forKey: .migrationDisposition
                ) : .requiresReplanning
            machineID = try container.decode(String.self, forKey: .machineID)
            definitionRevision = try container.decode(UInt64.self, forKey: .definitionRevision)
            definitionSHA256 = try container.decodeIfPresent(String.self, forKey: .definitionSHA256)
            planRevision = try container.decode(UInt64.self, forKey: .planRevision)
            createdAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .createdAtUnixMilliseconds
            )
            updatedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .updatedAtUnixMilliseconds
            )
            guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
            backend = try container.decode(DoryVirtualizationBackendIdentity.self, forKey: .backend)
            backendImplementationIdentifier = try container.decode(
                String.self,
                forKey: .backendImplementationIdentifier
            )
            backendRuntimeBuildIdentifier = try container.decode(
                String.self,
                forKey: .backendRuntimeBuildIdentifier
            )
            virtualHardwareABIVersion = try container.decode(
                UInt16.self,
                forKey: .virtualHardwareABIVersion
            )
            bootMedia = try container.decode(DoryResolvedMachineBootMedia.self, forKey: .bootMedia)
            launchArtifacts = persistedSchema == Self.currentSchemaVersion
                ? try container.decode(
                    [DoryResolvedMachineLaunchArtifact].self,
                    forKey: .launchArtifacts
                ) : []
            components = try container.decode(
                [DoryResolvedBackendComponentEvidence].self,
                forKey: .components
            )
            devices = try container.decode(
                DoryVirtualMachineDeviceCapabilityRequest.self,
                forKey: .devices
            )
            graphics = try container.decode(DoryGraphicsAccelerationLevel.self, forKey: .graphics)
            supportTier = try container.decode(DoryCapabilitySupportTier.self, forKey: .supportTier)
            selectionEvidence = try container.decodeIfPresent(
                DoryResolvedMachineBackendSelectionEvidence.self,
                forKey: .selectionEvidence
            )
            qualificationEvidence = try container.decode(
                DoryResolvedMachineQualificationEvidence.self,
                forKey: .qualificationEvidence
            )
            resourceAdmission = try container.decodeIfPresent(
                DoryResolvedMachineResourceAdmissionEvidence.self,
                forKey: .resourceAdmission
            )
            hostQualification = try container.decodeIfPresent(
                DoryResolvedHostQualificationEvidence.self,
                forKey: .hostQualification
            )
            experimentalAuthorization = try container.decodeIfPresent(
                DoryResolvedExperimentalSupportAuthorization.self,
                forKey: .experimentalAuthorization
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported resolved machine plan schema \(persistedSchema)."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceSchemaVersion, forKey: .sourceSchemaVersion)
        try container.encode(migrationDisposition, forKey: .migrationDisposition)
        try container.encode(machineID, forKey: .machineID)
        try container.encode(definitionRevision, forKey: .definitionRevision)
        try container.encodeIfPresent(definitionSHA256, forKey: .definitionSHA256)
        try container.encode(planRevision, forKey: .planRevision)
        try container.encode(createdAtUnixMilliseconds, forKey: .createdAtUnixMilliseconds)
        try container.encode(updatedAtUnixMilliseconds, forKey: .updatedAtUnixMilliseconds)
        try container.encode(guest, forKey: .guest)
        try container.encode(backend, forKey: .backend)
        try container.encode(backendImplementationIdentifier, forKey: .backendImplementationIdentifier)
        try container.encode(backendRuntimeBuildIdentifier, forKey: .backendRuntimeBuildIdentifier)
        try container.encode(virtualHardwareABIVersion, forKey: .virtualHardwareABIVersion)
        try container.encode(bootMedia, forKey: .bootMedia)
        try container.encode(launchArtifacts, forKey: .launchArtifacts)
        try container.encode(components, forKey: .components)
        try container.encode(devices, forKey: .devices)
        try container.encode(graphics, forKey: .graphics)
        try container.encode(supportTier, forKey: .supportTier)
        try container.encodeIfPresent(selectionEvidence, forKey: .selectionEvidence)
        try container.encode(qualificationEvidence, forKey: .qualificationEvidence)
        try container.encodeIfPresent(resourceAdmission, forKey: .resourceAdmission)
        try container.encodeIfPresent(hostQualification, forKey: .hostQualification)
        try container.encodeIfPresent(experimentalAuthorization, forKey: .experimentalAuthorization)
    }

    public func validate() -> [DoryResolvedMachinePlanValidationIssue] {
        var issues: [DoryResolvedMachinePlanValidationIssue] = []
        func add(_ code: DoryResolvedMachinePlanValidationCode, _ field: String) {
            issues.append(DoryResolvedMachinePlanValidationIssue(code: code, field: field))
        }

        if schemaVersion != Self.currentSchemaVersion {
            add(.unsupportedSchemaVersion, "schemaVersion")
        }
        if migrationDisposition != .current || sourceSchemaVersion != Self.currentSchemaVersion {
            add(.legacyPlanRequiresReplanning, "migrationDisposition")
        }
        if !Self.isSafeIdentifier(machineID) {
            add(.invalidMachineIdentifier, "machineID")
        }
        if definitionRevision == 0 { add(.invalidRevision, "definitionRevision") }
        if planRevision == 0 { add(.invalidRevision, "planRevision") }
        if updatedAtUnixMilliseconds < createdAtUnixMilliseconds {
            add(.invalidRevision, "updatedAtUnixMilliseconds")
        }
        if !(definitionSHA256.map(Self.isSHA256) ?? false) {
            add(.invalidDefinitionDigest, "definitionSHA256")
        }
        if !Self.isSafeEvidenceIdentifier(backendImplementationIdentifier) {
            add(.invalidBackendImplementation, "backendImplementationIdentifier")
        }
        if !Self.isSafeEvidenceIdentifier(backendRuntimeBuildIdentifier) {
            add(.invalidBackendRuntimeBuild, "backendRuntimeBuildIdentifier")
        }
        if virtualHardwareABIVersion == 0 {
            add(.invalidVirtualHardwareABI, "virtualHardwareABIVersion")
        }

        validateBootMedia(into: &issues)
        validateLaunchArtifacts(into: &issues)
        validateComponents(into: &issues)
        validateQualifications(into: &issues)
        validateResourceAdmission(into: &issues)
        validateHostQualification(into: &issues)
        validateSupportAuthorization(into: &issues)
        validateSelectionEvidence(into: &issues)
        return issues
    }

    private func validateBootMedia(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        func add(_ code: DoryResolvedMachinePlanValidationCode, _ field: String) {
            issues.append(DoryResolvedMachinePlanValidationIssue(code: code, field: field))
        }
        if let reference = bootMedia.resolverReference,
           !Self.isSafeResolverReference(reference) {
            add(.invalidResolverReference, "bootMedia.resolverReference")
        }
        let immutable = bootMedia.media.artifactSHA256
        let mutable = bootMedia.media.mutableProvenance
        if immutable.map(Self.isSHA256) == false || (immutable == nil) == (mutable == nil) {
            add(.invalidMediaBinding, "bootMedia.media")
        }
        if bootMedia.media.kind == .virtualDisk {
            if mutable == nil || immutable != nil {
                add(.invalidMediaBinding, "bootMedia.media.mutableProvenance")
            }
        } else if immutable == nil || mutable != nil {
            add(.invalidMediaBinding, "bootMedia.media.artifactSHA256")
        }
        let runtimeCombinationIsImplemented: Bool
        switch (guest.family, backend) {
        case (.linux, .doryHypervisor):
            runtimeCombinationIsImplemented = bootMedia.media.kind == .installedLinuxBootBundle
        case (.linux, .appleVirtualizationFramework),
             (.linux, .qemuHypervisorFramework),
             (.windows, .qemuHypervisorFramework):
            runtimeCombinationIsImplemented = bootMedia.media.kind == .installerISO
                || bootMedia.media.kind == .virtualDisk
                || (backend == .appleVirtualizationFramework
                    && bootMedia.media.kind == .installedLinuxBootBundle)
        case (.macOS, .appleVirtualizationFramework):
            runtimeCombinationIsImplemented = bootMedia.media.kind == .macOSRestoreImage
                || bootMedia.media.kind == .virtualDisk
        default:
            runtimeCombinationIsImplemented = false
        }
        if !runtimeCombinationIsImplemented {
            add(.unsupportedRuntimeCombination, "bootMedia.media.kind")
        }
        if let inspection = bootMedia.inspectionEvidence {
            guard Self.isSafeEvidenceIdentifier(inspection.inspectionIdentity),
                  Self.isSHA256(inspection.artifactSHA256),
                  Self.isSHA256(inspection.inspectionReportSHA256),
                  Self.isSafeEvidenceIdentifier(inspection.inspectorID),
                  inspection.inspectorVersion > 0,
                  inspection.artifactSHA256.lowercased() == immutable?.lowercased() else {
                add(.invalidMediaEvidence, "bootMedia.inspectionEvidence")
                return
            }
        } else if bootMedia.media.kind == .installerISO
                    || bootMedia.media.kind == .macOSRestoreImage {
            add(.invalidMediaEvidence, "bootMedia.inspectionEvidence")
        }
        if let evidence = bootMedia.mutableProvenanceEvidence {
            guard Self.isSafeEvidenceIdentifier(evidence.receiptIdentity),
                  Self.isSHA256(evidence.receiptSHA256),
                  Self.isSafeEvidenceIdentifier(evidence.resolverID),
                  evidence.resolverVersion > 0,
                  evidence.provenance == mutable else {
                add(.invalidMediaEvidence, "bootMedia.mutableProvenanceEvidence")
                return
            }
        } else if mutable != nil {
            add(.invalidMediaEvidence, "bootMedia.mutableProvenanceEvidence")
        }
    }

    private func validateLaunchArtifacts(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        func add(_ field: String) {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidLaunchArtifactEvidence,
                field: field
            ))
        }
        guard !launchArtifacts.isEmpty else {
            add("launchArtifacts")
            return
        }
        let ordered = launchArtifacts.sorted { lhs, rhs in
            let left = lhs.resolverReference.namespace + "\0"
                + lhs.resolverReference.identifier
            let right = rhs.resolverReference.namespace + "\0"
                + rhs.resolverReference.identifier
            return left < right
        }
        if ordered != launchArtifacts { add("launchArtifacts") }

        var references: Set<DoryVMResolverReference> = []
        var bootBindingIsPresent = false
        for (index, artifact) in launchArtifacts.enumerated() {
            let field = "launchArtifacts[\(index)]"
            guard Self.isSafeResolverReference(artifact.resolverReference),
                  references.insert(artifact.resolverReference).inserted,
                  artifact.authorityRevision > 0,
                  !artifact.usages.isEmpty else {
                add(field)
                continue
            }
            let usages = artifact.usages.sorted {
                ($0.kind.rawValue, $0.identifier) < ($1.kind.rawValue, $1.identifier)
            }
            if usages != artifact.usages
                || Set(usages.map { $0.kind.rawValue + "\0" + $0.identifier }).count
                    != usages.count
                || usages.contains(where: { !Self.isSafeIdentifier($0.identifier) }) {
                add("\(field).usages")
            }

            let immutable = artifact.media.artifactSHA256
            let mutable = artifact.media.mutableProvenance
            let identityIsValid = (immutable.map(Self.isSHA256) ?? false)
                != (mutable != nil)
            if !identityIsValid { add("\(field).media") }
            if let evidence = artifact.mutableProvenanceEvidence {
                if mutable == nil
                    || evidence.provenance != mutable
                    || !Self.isSafeEvidenceIdentifier(evidence.receiptIdentity)
                    || !Self.isSHA256(evidence.receiptSHA256)
                    || !Self.isSafeEvidenceIdentifier(evidence.resolverID)
                    || evidence.resolverVersion == 0 {
                    add("\(field).mutableProvenanceEvidence")
                }
            } else if mutable != nil {
                add("\(field).mutableProvenanceEvidence")
            }
            if mutable != nil && artifact.media.kind != .virtualDisk {
                add("\(field).media.kind")
            }
            for usage in artifact.usages where usage.kind == .storage {
                if artifact.media.kind != .virtualDisk
                    || (usage.readOnly && immutable == nil)
                    || (!usage.readOnly && mutable == nil) {
                    add("\(field).usages")
                }
            }
            if artifact.usages.contains(where: { $0.kind == .boot }),
               artifact.resolverReference == bootMedia.resolverReference,
               artifact.media == bootMedia.media {
                bootBindingIsPresent = true
            }
        }
        if !bootBindingIsPresent { add("bootMedia.resolverReference") }
    }

    private func validateComponents(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        var identifiers: Set<String> = []
        for (index, component) in components.enumerated() {
            let field = "components[\(index)]"
            if !identifiers.insert(component.componentIdentifier).inserted {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .duplicateComponent,
                    field: "\(field).componentIdentifier"
                ))
            }
            if !Self.isSafeEvidenceIdentifier(component.componentIdentifier)
                || !Self.isSafeEvidenceIdentifier(component.buildIdentifier)
                || !Self.isSHA256(component.artifactSHA256) {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidComponentEvidence,
                    field: field
                ))
            }
        }
        if components.isEmpty {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidComponentEvidence,
                field: "components"
            ))
        }
        if components.map(\.componentIdentifier) != components.map(\.componentIdentifier).sorted() {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .unorderedComponents,
                field: "components"
            ))
        }
    }

    private func validateQualifications(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        if backend == .doryHypervisor, graphics != .none {
            guard let graphicsEvidence = qualificationEvidence.graphics else {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .missingGraphicsQualification,
                    field: "qualificationEvidence.graphics"
                ))
                return validateRuntimeQualification(into: &issues)
            }
            if !Self.isValid(graphicsEvidence)
                || graphicsEvidence.artifactSHA256.lowercased()
                    != bootMedia.media.artifactSHA256?.lowercased() {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidGraphicsQualification,
                    field: "qualificationEvidence.graphics"
                ))
            }
        } else if let graphicsEvidence = qualificationEvidence.graphics,
                  !Self.isValid(graphicsEvidence) {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidGraphicsQualification,
                field: "qualificationEvidence.graphics"
            ))
        }
        validateRuntimeQualification(into: &issues)
    }

    private func validateRuntimeQualification(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        guard let runtime = qualificationEvidence.runtime else {
            if supportTier == .supported {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .missingRuntimeQualification,
                    field: "qualificationEvidence.runtime"
                ))
            }
            return
        }
        let mediaMatches = runtime.immutableArtifactSHA256?.lowercased()
                == bootMedia.media.artifactSHA256?.lowercased()
            && runtime.mutableProvenance == bootMedia.media.mutableProvenance
        guard Self.isSafeEvidenceIdentifier(runtime.qualificationIdentity),
              Self.isSHA256(runtime.qualificationReportSHA256),
              Self.isSafeEvidenceIdentifier(runtime.signingKeyID),
              runtime.qualificationFormatVersion > 0,
              runtime.guest == guest,
              runtime.bootMediaKind == bootMedia.media.kind,
              mediaMatches,
              runtime.backend == backend,
              runtime.backendRuntimeBuildID == backendRuntimeBuildIdentifier,
              runtime.virtualHardwareABIVersion == virtualHardwareABIVersion,
              runtime.graphics == graphics,
              runtime.devices == devices else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .runtimeQualificationMismatch,
                field: "qualificationEvidence.runtime"
            ))
            return
        }
    }

    private func validateResourceAdmission(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        guard let admission = resourceAdmission else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidResourceAdmission,
                field: "resourceAdmission"
            ))
            return
        }
        let identifiersAreValid = Self.isSafeEvidenceIdentifier(admission.admissionIdentity)
            && Self.isSHA256(admission.admissionReportSHA256)
            && Self.isSafeEvidenceIdentifier(admission.assessorIdentifier)
            && admission.assessorVersion > 0
        let admittedValuesAreValid = admission.admittedVirtualCPUCount > 0
            && admission.admittedMemoryBytes > 0
            && admission.admittedStorageBytes > 0
        let hostValuesAreValid = admission.hostLogicalCPUCount > 0
            && admission.hostPhysicalMemoryBytes > 0
            && admission.hostFreeStorageBytes > 0
        let cpuFits = Self.sumFits(
            within: admission.hostLogicalCPUCount,
            admission.existingVirtualCPUCommitment,
            admission.hostReservedLogicalCPUCount,
            admission.admittedVirtualCPUCount
        )
        let memoryFits = Self.sumFits(
            within: admission.hostPhysicalMemoryBytes,
            admission.existingMemoryCommitmentBytes,
            admission.hostReservedMemoryBytes,
            admission.admittedMemoryBytes
        )
        let storageFits = Self.sumFits(
            within: admission.hostFreeStorageBytes,
            admission.existingStorageReservationBytes,
            admission.hostReservedStorageBytes,
            admission.admittedStorageBytes
        )
        if !identifiersAreValid || !admittedValuesAreValid || !hostValuesAreValid
            || !cpuFits || !memoryFits || !storageFits {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidResourceAdmission,
                field: "resourceAdmission"
            ))
        }
    }

    private func validateHostQualification(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        guard let host = hostQualification,
              Self.isSafeEvidenceIdentifier(host.qualificationIdentity),
              Self.isSHA256(host.qualificationReportSHA256),
              Self.isSafeEvidenceIdentifier(host.hostHardwareModelIdentifier),
              Self.isSafeEvidenceIdentifier(host.hostOperatingSystemBuild),
              Self.isSafeEvidenceIdentifier(host.qualifierIdentifier),
              host.qualifierVersion > 0,
              host.backend == backend,
              host.backendRuntimeBuildIdentifier == backendRuntimeBuildIdentifier,
              host.virtualHardwareABIVersion == virtualHardwareABIVersion else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidHostQualification,
                field: "hostQualification"
            ))
            return
        }
    }

    private func validateSupportAuthorization(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        switch supportTier {
        case .unsupported:
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .unsupportedSupportTier,
                field: "supportTier"
            ))
        case .supported:
            if experimentalAuthorization != nil {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidExperimentalAuthorization,
                    field: "experimentalAuthorization"
                ))
            }
        case .experimental:
            guard let authorization = experimentalAuthorization else {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .missingExperimentalAuthorization,
                    field: "experimentalAuthorization"
                ))
                return
            }
            if !Self.isSafeEvidenceIdentifier(authorization.authorizationIdentity)
                || authorization.definitionRevision != definitionRevision
                || authorization.backend != backend
                || authorization.authorizedAtUnixMilliseconds <= 0 {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidExperimentalAuthorization,
                    field: "experimentalAuthorization"
                ))
            }
        }
    }

    private func validateSelectionEvidence(
        into issues: inout [DoryResolvedMachinePlanValidationIssue]
    ) {
        guard let selection = selectionEvidence else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .missingSelectionEvidence,
                field: "selectionEvidence"
            ))
            return
        }
        let request = selection.plannerRequest
        guard request.guest == guest,
              request.bootMedia == bootMedia.media,
              request.devices == devices,
              request.virtualHardwareABIVersion == virtualHardwareABIVersion,
              !request.acceptableGraphics.isEmpty,
              Set(request.acceptableGraphics).count == request.acceptableGraphics.count else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidSelectionEvidence,
                field: "selectionEvidence.plannerRequest"
            ))
            return
        }

        guard let orderedCandidates = DoryResolvedMachineBackendSelectionEvidence
            .orderedCandidates(for: request) else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidSelectionEvidence,
                field: "selectionEvidence.plannerRequest"
            ))
            return
        }
        let selectedIndex = Int(selection.selectedEvaluationIndex)
        guard orderedCandidates.indices.contains(selectedIndex),
              orderedCandidates[selectedIndex].0 == backend,
              orderedCandidates[selectedIndex].1 == graphics,
              selection.rejectedCandidates.count == selectedIndex else {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidSelectionEvidence,
                field: "selectionEvidence.selectedEvaluationIndex"
            ))
            return
        }
        for (index, rejected) in selection.rejectedCandidates.enumerated() {
            let expected = orderedCandidates[index]
            let rejectionIsValid = switch rejected.rejection {
            case .unavailable:
                !rejected.availability.isUsable
            case .experimentalNotAuthorized:
                rejected.availability.isUsable
                    && rejected.availability.supportTier == .experimental
                    && !request.allowsExperimentalBackends
            }
            if rejected.backend != expected.0
                || rejected.graphics != expected.1
                || !rejectionIsValid {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidSelectionEvidence,
                    field: "selectionEvidence.rejectedCandidates[\(index)]"
                ))
            }
        }
        if supportTier == .experimental, !request.allowsExperimentalBackends {
            issues.append(DoryResolvedMachinePlanValidationIssue(
                code: .invalidSelectionEvidence,
                field: "selectionEvidence.plannerRequest.allowsExperimentalBackends"
            ))
        }

        switch selection.disposition {
        case .primary:
            if selectedIndex != 0 || !selection.rejectedCandidates.isEmpty
                || selection.fallbackAuthorization != nil {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidSelectionEvidence,
                    field: "selectionEvidence.disposition"
                ))
            }
        case .explicitAlternative:
            if request.backendPreferencePolicy != .required
                || selectedIndex == 0
                || selection.fallbackAuthorization != nil {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidSelectionEvidence,
                    field: "selectionEvidence.disposition"
                ))
            }
        case .approvedFallback:
            if request.backendPreferencePolicy == .required {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .fallbackDisallowed,
                    field: "selectionEvidence.disposition"
                ))
            }
            guard selectedIndex > 0 else {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidSelectionEvidence,
                    field: "selectionEvidence.disposition"
                ))
                return
            }
            guard let authorization = selection.fallbackAuthorization else {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .missingFallbackAuthorization,
                    field: "selectionEvidence.fallbackAuthorization"
                ))
                return
            }
            let first = selection.rejectedCandidates[0]
            if !Self.isSafeEvidenceIdentifier(authorization.authorizationIdentity)
                || authorization.definitionRevision != definitionRevision
                || authorization.fromBackend != first.backend
                || authorization.fromGraphics != first.graphics
                || authorization.toBackend != backend
                || authorization.toGraphics != graphics
                || authorization.authorizedAtUnixMilliseconds <= 0 {
                issues.append(DoryResolvedMachinePlanValidationIssue(
                    code: .invalidFallbackAuthorization,
                    field: "selectionEvidence.fallbackAuthorization"
                ))
            }
        }
    }

    private static func isValid(_ evidence: DorySignedArtifactQualificationEvidence) -> Bool {
        isSafeEvidenceIdentifier(evidence.manifestIdentity)
            && isSHA256(evidence.artifactSHA256)
            && isSHA256(evidence.manifestSHA256)
            && isSafeEvidenceIdentifier(evidence.signingKeyID)
            && evidence.manifestFormatVersion > 0
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), isAlphaNumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            isAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isSafeResolverReference(_ value: DoryVMResolverReference) -> Bool {
        isSafeEvidenceIdentifier(value.namespace) && isSafeEvidenceIdentifier(value.identifier)
    }

    private static func isSafeEvidenceIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 47
                || byte == 44 || byte == 58 || byte == 64 || byte == 95
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func sumFits(within total: UInt64, _ values: UInt64...) -> Bool {
        var remaining = total
        for value in values {
            guard value <= remaining else { return false }
            remaining -= value
        }
        return true
    }
}

/// Fresh daemon/resolver output supplied immediately before start. It deliberately duplicates the
/// launch-critical plan fields so every mismatch can be named rather than hidden behind a Bool.
public struct DoryResolvedMachineRuntimeEvidence: Codable, Sendable, Equatable, Hashable {
    public var guest: DoryGuestPlatform
    public var backend: DoryVirtualizationBackendIdentity
    public var backendImplementationIdentifier: String
    public var backendRuntimeBuildIdentifier: String
    public var virtualHardwareABIVersion: UInt16
    public var bootMedia: DoryResolvedMachineBootMedia
    public var launchArtifacts: [DoryResolvedMachineLaunchArtifact]
    public var components: [DoryResolvedBackendComponentEvidence]
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var graphics: DoryGraphicsAccelerationLevel
    public var supportTier: DoryCapabilitySupportTier
    public var selectionEvidence: DoryResolvedMachineBackendSelectionEvidence?
    public var qualificationEvidence: DoryResolvedMachineQualificationEvidence
    public var resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence?
    public var hostQualification: DoryResolvedHostQualificationEvidence?
    public var experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization?

    public init(
        guest: DoryGuestPlatform,
        backend: DoryVirtualizationBackendIdentity,
        backendImplementationIdentifier: String,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        bootMedia: DoryResolvedMachineBootMedia,
        launchArtifacts: [DoryResolvedMachineLaunchArtifact],
        components: [DoryResolvedBackendComponentEvidence],
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        graphics: DoryGraphicsAccelerationLevel,
        supportTier: DoryCapabilitySupportTier,
        selectionEvidence: DoryResolvedMachineBackendSelectionEvidence?,
        qualificationEvidence: DoryResolvedMachineQualificationEvidence,
        resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence?,
        hostQualification: DoryResolvedHostQualificationEvidence?,
        experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization?
    ) {
        self.guest = guest
        self.backend = backend
        self.backendImplementationIdentifier = backendImplementationIdentifier
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.bootMedia = bootMedia
        self.launchArtifacts = launchArtifacts
        self.components = components
        self.devices = devices
        self.graphics = graphics
        self.supportTier = supportTier
        self.selectionEvidence = selectionEvidence
        self.qualificationEvidence = qualificationEvidence
        self.resourceAdmission = resourceAdmission
        self.hostQualification = hostQualification
        self.experimentalAuthorization = experimentalAuthorization
    }

    public init(plan: DoryResolvedMachinePlan) {
        guest = plan.guest
        backend = plan.backend
        backendImplementationIdentifier = plan.backendImplementationIdentifier
        backendRuntimeBuildIdentifier = plan.backendRuntimeBuildIdentifier
        virtualHardwareABIVersion = plan.virtualHardwareABIVersion
        bootMedia = plan.bootMedia
        launchArtifacts = plan.launchArtifacts
        components = plan.components
        devices = plan.devices
        graphics = plan.graphics
        supportTier = plan.supportTier
        selectionEvidence = plan.selectionEvidence
        qualificationEvidence = plan.qualificationEvidence
        resourceAdmission = plan.resourceAdmission
        hostQualification = plan.hostQualification
        experimentalAuthorization = plan.experimentalAuthorization
    }

}

public struct DoryResolvedMachinePlanStartRevalidationInput: Codable, Sendable, Equatable, Hashable {
    public var machineID: String
    public var expectedPlanRevision: UInt64
    public var currentDefinitionRevision: UInt64
    public var currentDefinitionSHA256: String
    public var runtimeEvidence: DoryResolvedMachineRuntimeEvidence

    public init(
        machineID: String,
        expectedPlanRevision: UInt64,
        currentDefinitionRevision: UInt64,
        currentDefinitionSHA256: String,
        runtimeEvidence: DoryResolvedMachineRuntimeEvidence
    ) {
        self.machineID = machineID
        self.expectedPlanRevision = expectedPlanRevision
        self.currentDefinitionRevision = currentDefinitionRevision
        self.currentDefinitionSHA256 = currentDefinitionSHA256
        self.runtimeEvidence = runtimeEvidence
    }
}

public enum DoryResolvedMachinePlanRevalidationCode: String, Codable, Sendable, Hashable {
    case storedPlanInvalid = "stored-plan-invalid"
    case machineIdentityMismatch = "machine-identity-mismatch"
    case planRevisionMismatch = "plan-revision-mismatch"
    case definitionRevisionMismatch = "definition-revision-mismatch"
    case definitionDigestMismatch = "definition-digest-mismatch"
    case guestMismatch = "guest-mismatch"
    case backendMismatch = "backend-mismatch"
    case backendImplementationMismatch = "backend-implementation-mismatch"
    case backendRuntimeBuildMismatch = "backend-runtime-build-mismatch"
    case virtualHardwareABIMismatch = "virtual-hardware-abi-mismatch"
    case bootMediaEvidenceMismatch = "boot-media-evidence-mismatch"
    case launchArtifactEvidenceMismatch = "launch-artifact-evidence-mismatch"
    case componentEvidenceMismatch = "component-evidence-mismatch"
    case deviceContractMismatch = "device-contract-mismatch"
    case graphicsMismatch = "graphics-mismatch"
    case supportTierMismatch = "support-tier-mismatch"
    case selectionEvidenceMismatch = "selection-evidence-mismatch"
    case qualificationEvidenceMismatch = "qualification-evidence-mismatch"
    case resourceAdmissionMismatch = "resource-admission-mismatch"
    case hostQualificationMismatch = "host-qualification-mismatch"
    case experimentalAuthorizationMismatch = "experimental-authorization-mismatch"
}

public struct DoryResolvedMachinePlanRevalidationIssue: Codable, Sendable, Equatable, Hashable {
    public var code: DoryResolvedMachinePlanRevalidationCode
    public var field: String

    public init(code: DoryResolvedMachinePlanRevalidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

public enum DoryResolvedMachinePlanRevalidationState: String, Codable, Sendable, Hashable {
    case valid
    case rejected
}

public struct DoryResolvedMachinePlanRevalidationResult: Codable, Sendable, Equatable, Hashable {
    public var state: DoryResolvedMachinePlanRevalidationState
    public var issues: [DoryResolvedMachinePlanRevalidationIssue]

    public var mayStart: Bool { state == .valid && issues.isEmpty }

    public init(
        state: DoryResolvedMachinePlanRevalidationState,
        issues: [DoryResolvedMachinePlanRevalidationIssue]
    ) {
        self.state = state
        self.issues = issues
    }
}

public enum DoryResolvedMachinePlanStartValidator {
    public static func revalidate(
        _ plan: DoryResolvedMachinePlan,
        against input: DoryResolvedMachinePlanStartRevalidationInput
    ) -> DoryResolvedMachinePlanRevalidationResult {
        var issues: [DoryResolvedMachinePlanRevalidationIssue] = []
        func compare<T: Equatable>(
            _ actual: T,
            _ expected: T,
            code: DoryResolvedMachinePlanRevalidationCode,
            field: String
        ) {
            if actual != expected {
                issues.append(DoryResolvedMachinePlanRevalidationIssue(code: code, field: field))
            }
        }

        if !plan.validate().isEmpty {
            issues.append(DoryResolvedMachinePlanRevalidationIssue(
                code: .storedPlanInvalid,
                field: "plan"
            ))
        }
        compare(input.machineID, plan.machineID, code: .machineIdentityMismatch, field: "machineID")
        compare(
            input.expectedPlanRevision,
            plan.planRevision,
            code: .planRevisionMismatch,
            field: "planRevision"
        )
        compare(
            input.currentDefinitionRevision,
            plan.definitionRevision,
            code: .definitionRevisionMismatch,
            field: "definitionRevision"
        )
        compare(
            Optional(input.currentDefinitionSHA256.lowercased()),
            plan.definitionSHA256?.lowercased(),
            code: .definitionDigestMismatch,
            field: "definitionSHA256"
        )
        let runtime = input.runtimeEvidence
        compare(runtime.guest, plan.guest, code: .guestMismatch, field: "guest")
        compare(runtime.backend, plan.backend, code: .backendMismatch, field: "backend")
        compare(
            runtime.backendImplementationIdentifier,
            plan.backendImplementationIdentifier,
            code: .backendImplementationMismatch,
            field: "backendImplementationIdentifier"
        )
        compare(
            runtime.backendRuntimeBuildIdentifier,
            plan.backendRuntimeBuildIdentifier,
            code: .backendRuntimeBuildMismatch,
            field: "backendRuntimeBuildIdentifier"
        )
        compare(
            runtime.virtualHardwareABIVersion,
            plan.virtualHardwareABIVersion,
            code: .virtualHardwareABIMismatch,
            field: "virtualHardwareABIVersion"
        )
        compare(runtime.bootMedia, plan.bootMedia, code: .bootMediaEvidenceMismatch, field: "bootMedia")
        compare(
            runtime.launchArtifacts,
            plan.launchArtifacts,
            code: .launchArtifactEvidenceMismatch,
            field: "launchArtifacts"
        )
        compare(runtime.components, plan.components, code: .componentEvidenceMismatch, field: "components")
        compare(runtime.devices, plan.devices, code: .deviceContractMismatch, field: "devices")
        compare(runtime.graphics, plan.graphics, code: .graphicsMismatch, field: "graphics")
        compare(
            runtime.supportTier,
            plan.supportTier,
            code: .supportTierMismatch,
            field: "supportTier"
        )
        compare(
            runtime.selectionEvidence,
            plan.selectionEvidence,
            code: .selectionEvidenceMismatch,
            field: "selectionEvidence"
        )
        compare(
            runtime.qualificationEvidence,
            plan.qualificationEvidence,
            code: .qualificationEvidenceMismatch,
            field: "qualificationEvidence"
        )
        compare(
            runtime.resourceAdmission,
            plan.resourceAdmission,
            code: .resourceAdmissionMismatch,
            field: "resourceAdmission"
        )
        compare(
            runtime.hostQualification,
            plan.hostQualification,
            code: .hostQualificationMismatch,
            field: "hostQualification"
        )
        compare(
            runtime.experimentalAuthorization,
            plan.experimentalAuthorization,
            code: .experimentalAuthorizationMismatch,
            field: "experimentalAuthorization"
        )

        return DoryResolvedMachinePlanRevalidationResult(
            state: issues.isEmpty ? .valid : .rejected,
            issues: issues
        )
    }
}
