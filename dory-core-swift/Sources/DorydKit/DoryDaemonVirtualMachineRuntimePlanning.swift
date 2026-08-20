import CryptoKit
import DoryOperations
import Foundation

/// Inventory output stays daemon-local and non-Codable. The opaque trusted records can only be
/// created by DoryOperations resolvers, so API/UI intent cannot manufacture qualification facts.
public struct DoryDaemonVirtualMachineResolvedMedia: Sendable {
    public var reference: DoryVMResolverReference
    public var media: DoryBootMedia
    public var guestGraphicsQualification: DoryTrustedGuestImageGraphicsQualification?
    public var bootInspection: DoryTrustedBootMediaInspection?
    public var mutableProvenance: DoryTrustedMutableBootMediaProvenance?

    public init(
        reference: DoryVMResolverReference,
        media: DoryBootMedia,
        guestGraphicsQualification: DoryTrustedGuestImageGraphicsQualification? = nil,
        bootInspection: DoryTrustedBootMediaInspection? = nil,
        mutableProvenance: DoryTrustedMutableBootMediaProvenance? = nil
    ) {
        self.reference = reference
        self.media = media
        self.guestGraphicsQualification = guestGraphicsQualification
        self.bootInspection = bootInspection
        self.mutableProvenance = mutableProvenance
    }
}

public struct DoryDaemonVirtualMachineBackendRuntimeInventory: Sendable, Equatable {
    public var backend: DoryVirtualizationBackendIdentity
    public var runtimeBuildIdentifier: String
    public var components: [DoryResolvedBackendComponentEvidence]
    public var hostQualification: DoryResolvedHostQualificationEvidence

    public init(
        backend: DoryVirtualizationBackendIdentity,
        runtimeBuildIdentifier: String,
        components: [DoryResolvedBackendComponentEvidence],
        hostQualification: DoryResolvedHostQualificationEvidence
    ) {
        self.backend = backend
        self.runtimeBuildIdentifier = runtimeBuildIdentifier
        self.components = components
        self.hostQualification = hostQualification
    }
}

public struct DoryDaemonVirtualMachineTrustedInventorySnapshot: Sendable {
    public var hostFacts: DoryAppleSiliconHostFacts
    public var media: DoryDaemonVirtualMachineResolvedMedia
    public var backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory]
    public var resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence
    public var runtimeQualifications: [DoryTrustedVirtualMachineRuntimeQualification]
    public var capabilityQualifications:
        [DoryTrustedVirtualMachineCapabilityQualification]
    /// Resolver-selected record for one exact start request. The evaluator still verifies every
    /// media, backend-build, ABI, graphics, and device binding before treating it as authority.
    public var exactStartRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification?

    public init(
        hostFacts: DoryAppleSiliconHostFacts,
        media: DoryDaemonVirtualMachineResolvedMedia,
        backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory],
        resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence,
        runtimeQualifications: [DoryTrustedVirtualMachineRuntimeQualification] = [],
        capabilityQualifications:
            [DoryTrustedVirtualMachineCapabilityQualification] = [],
        exactStartRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification? = nil
    ) {
        self.hostFacts = hostFacts
        self.media = media
        self.backendRuntimes = backendRuntimes
        self.resourceAdmission = resourceAdmission
        self.runtimeQualifications = runtimeQualifications
        self.capabilityQualifications = capabilityQualifications
        self.exactStartRuntimeQualification = exactStartRuntimeQualification
    }

    public func backendRuntime(
        for backend: DoryVirtualizationBackendIdentity
    ) -> DoryDaemonVirtualMachineBackendRuntimeInventory? {
        let matches = backendRuntimes.filter { $0.backend == backend }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Selects the runtime record bound to the exact qualification chosen by the planner. A
    /// backend may have several signed media/graphics qualifications; array order is not trust.
    public func backendRuntime(
        for descriptor: DoryVirtualMachineCapabilityDescriptor
    ) -> DoryDaemonVirtualMachineBackendRuntimeInventory? {
        let candidates = backendRuntimes.filter { runtime in
            guard runtime.backend == descriptor.request.backend else { return false }
            guard let evidence = descriptor.runtimeQualificationEvidence else { return true }
            return runtime.runtimeBuildIdentifier == evidence.backendRuntimeBuildID
                && runtime.hostQualification.qualificationIdentity
                    == evidence.qualificationIdentity
                && runtime.hostQualification.qualificationReportSHA256
                    == evidence.qualificationReportSHA256
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

public struct DoryDaemonVirtualMachineInventoryRequest: Sendable, Equatable {
    public var machineID: String
    public var definitionRevision: UInt64
    public var guest: DoryGuestPlatform
    public var bootMedia: DoryVMBootMediaReference
    public var resources: DoryVMResourceRequest
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var acceptableGraphics: [DoryGraphicsAccelerationLevel]
    public var virtualHardwareABIVersion: UInt16

    public init(
        machineID: String,
        definitionRevision: UInt64,
        guest: DoryGuestPlatform,
        bootMedia: DoryVMBootMediaReference,
        resources: DoryVMResourceRequest,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        acceptableGraphics: [DoryGraphicsAccelerationLevel],
        virtualHardwareABIVersion: UInt16
    ) {
        self.machineID = machineID
        self.definitionRevision = definitionRevision
        self.guest = guest
        self.bootMedia = bootMedia
        self.resources = resources
        self.devices = devices
        self.acceptableGraphics = acceptableGraphics
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
    }
}

public struct DoryDaemonVirtualMachineStartInventoryRequest: Sendable, Equatable {
    public var machineID: String
    public var definitionRevision: UInt64
    public var planRevision: UInt64
    public var bootMediaReference: DoryVMResolverReference
    public var exactCapabilityRequest: DoryVirtualMachineCapabilityRequest
    /// Exact already-persisted plan. This request is daemon-local and non-Codable; carrying the
    /// plan lets the resource authority verify its one-shot plan binding rather than trusting a
    /// caller-supplied digest or merely matching resource numbers.
    public var resolvedPlan: DoryResolvedMachinePlan

    public init(
        machineID: String,
        definitionRevision: UInt64,
        planRevision: UInt64,
        bootMediaReference: DoryVMResolverReference,
        exactCapabilityRequest: DoryVirtualMachineCapabilityRequest,
        resolvedPlan: DoryResolvedMachinePlan
    ) {
        self.machineID = machineID
        self.definitionRevision = definitionRevision
        self.planRevision = planRevision
        self.bootMediaReference = bootMediaReference
        self.exactCapabilityRequest = exactCapabilityRequest
        self.resolvedPlan = resolvedPlan
    }
}

/// Implemented only by daemon-owned resolvers. Callers provide intent; they never provide trusted
/// booleans or signed-evidence decisions.
public protocol DoryDaemonVirtualMachineTrustInventory: Sendable {
    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot
}

public protocol DoryDaemonVirtualMachineCapabilityPlanning: Sendable {
    func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult
}

public struct DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner:
    DoryDaemonVirtualMachineCapabilityPlanning
{
    public init() {}

    public func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult {
        DoryAppleSiliconVirtualMachineBackendPlanner.plan(
            request,
            host: inventory.hostFacts,
            trustedGuestImageGraphicsQualification: inventory.media.guestGraphicsQualification,
            trustedBootMediaInspection: inventory.media.bootInspection,
            trustedMutableBootMediaProvenance: inventory.media.mutableProvenance,
            trustedRuntimeQualifications: inventory.runtimeQualifications,
            trustedCapabilityQualifications: inventory.capabilityQualifications
        )
    }
}

public protocol DoryResolvedMachinePlanStoring: Sendable {
    func create(_ plan: DoryResolvedMachinePlan) throws
    func replace(_ plan: DoryResolvedMachinePlan, expectedPlanRevision: UInt64) throws
    func read(id: String) throws -> DoryResolvedMachinePlan
}

extension DoryResolvedMachinePlanRepository: DoryResolvedMachinePlanStoring {}

public enum DoryDaemonVirtualMachinePlanPublication: Sendable, Equatable {
    case create
    case replace(expectedPlanRevision: UInt64)
}

public struct DoryDaemonVirtualMachinePlanningRequest: Sendable {
    public var definition: DoryVirtualMachineDefinition
    /// Canonical sorted-key encoding of `definition`. Only its digest is persisted.
    public var canonicalDefinitionData: Data
    public var machine: DoryMachineConfiguration
    public var publication: DoryDaemonVirtualMachinePlanPublication
    public var fallbackAuthorization: DoryResolvedMachineFallbackAuthorization?
    public var experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization?

    public init(
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data,
        machine: DoryMachineConfiguration,
        publication: DoryDaemonVirtualMachinePlanPublication,
        fallbackAuthorization: DoryResolvedMachineFallbackAuthorization? = nil,
        experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization? = nil
    ) {
        self.definition = definition
        self.canonicalDefinitionData = canonicalDefinitionData
        self.machine = machine
        self.publication = publication
        self.fallbackAuthorization = fallbackAuthorization
        self.experimentalAuthorization = experimentalAuthorization
    }
}

public struct DoryDaemonVirtualMachinePlanningResult: Sendable {
    public var plannerRequest: DoryVirtualMachineBackendPlanRequest
    public var plannerResult: DoryVirtualMachineBackendPlanResult
    public var resolvedPlan: DoryResolvedMachinePlan
    public var resolvedPlanSHA256: String
    public var backendPlan: MachineBackendPlan

    public init(
        plannerRequest: DoryVirtualMachineBackendPlanRequest,
        plannerResult: DoryVirtualMachineBackendPlanResult,
        resolvedPlan: DoryResolvedMachinePlan,
        resolvedPlanSHA256: String,
        backendPlan: MachineBackendPlan
    ) {
        self.plannerRequest = plannerRequest
        self.plannerResult = plannerResult
        self.resolvedPlan = resolvedPlan
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.backendPlan = backendPlan
    }
}

public enum DoryDaemonVirtualMachinePlanningFailureCode: String, Sendable, Equatable {
    case invalidDefinition = "invalid-definition"
    case emptyDefinitionAuthority = "empty-definition-authority"
    case definitionAuthorityMismatch = "definition-authority-mismatch"
    case machineIdentityMismatch = "machine-identity-mismatch"
    case bootMediaUnavailable = "boot-media-unavailable"
    case mediaInventoryMismatch = "media-inventory-mismatch"
    case capabilityUnavailable = "capability-unavailable"
    case backendUnavailable = "backend-unavailable"
    case backendInventoryUnavailable = "backend-inventory-unavailable"
    case resourceAdmissionMismatch = "resource-admission-mismatch"
    case planConstructionRejected = "plan-construction-rejected"
    case backendPlanRejected = "backend-plan-rejected"
    case persistenceRejected = "persistence-rejected"
}

public struct DoryDaemonVirtualMachinePlanningFailure: Error, Sendable, Equatable {
    public var code: DoryDaemonVirtualMachinePlanningFailureCode
    public var message: String

    public init(code: DoryDaemonVirtualMachinePlanningFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

public final class DoryDaemonVirtualMachinePlanningCoordinator: @unchecked Sendable {
    private let registry: BackendRegistry
    private let inventory: any DoryDaemonVirtualMachineTrustInventory
    private let capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning
    private let plans: any DoryResolvedMachinePlanStoring
    private let now: @Sendable () -> Int64

    public init(
        registry: BackendRegistry,
        inventory: any DoryDaemonVirtualMachineTrustInventory,
        plans: any DoryResolvedMachinePlanStoring,
        capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning =
            DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner(),
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero))
        }
    ) {
        self.registry = registry
        self.inventory = inventory
        self.plans = plans
        self.capabilityPlanner = capabilityPlanner
        self.now = now
    }

    public func resolveAndPersist(
        _ input: DoryDaemonVirtualMachinePlanningRequest
    ) throws -> DoryDaemonVirtualMachinePlanningResult {
        let definition = input.definition
        let definitionIssues = definition.validate()
        guard definitionIssues.isEmpty else {
            throw failure(.invalidDefinition, "Workspace definition validation failed.")
        }
        guard !input.canonicalDefinitionData.isEmpty else {
            throw failure(.emptyDefinitionAuthority, "Definition authority bytes are required.")
        }
        guard input.canonicalDefinitionData == Self.canonicalDefinitionData(definition) else {
            throw failure(
                .definitionAuthorityMismatch,
                "Definition bytes are not the canonical encoding of the supplied workspace."
            )
        }
        guard input.machine.id == definition.identity.id else {
            throw failure(.machineIdentityMismatch, "Legacy machine and workspace identities differ.")
        }
        guard let bootReference = Self.primaryBootMedia(in: definition) else {
            throw failure(.bootMediaUnavailable, "The workspace has no primary boot device.")
        }
        let devices = Self.devices(for: definition)
        let inventoryRequest = DoryDaemonVirtualMachineInventoryRequest(
            machineID: definition.identity.id,
            definitionRevision: definition.lifecycle.revision,
            guest: definition.guest,
            bootMedia: bootReference,
            resources: definition.resources,
            devices: devices,
            acceptableGraphics: definition.graphics.acceptableLevels,
            virtualHardwareABIVersion: definition.virtualHardwareABIVersion
        )
        let snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
        do {
            snapshot = try inventory.planningInventory(for: inventoryRequest)
        } catch {
            throw failure(.capabilityUnavailable, "Trusted planning inventory could not be resolved.")
        }
        guard snapshot.media.reference == bootReference.artifact,
              snapshot.media.media.kind == bootReference.kind,
              snapshot.media.media.source == bootReference.source else {
            throw failure(.mediaInventoryMismatch, "Resolved media does not match the boot reference.")
        }
        guard snapshot.resourceAdmission.admittedVirtualCPUCount
                == definition.resources.virtualCPUCount,
              snapshot.resourceAdmission.admittedMemoryBytes == definition.resources.memoryBytes,
              snapshot.resourceAdmission.admittedStorageBytes == definition.resources.diskBytes else {
            throw failure(.resourceAdmissionMismatch, "Resource admission does not match requested resources.")
        }

        let plannerRequest = Self.plannerRequest(
            definition: definition,
            media: snapshot.media.media,
            devices: devices,
            allowsExperimental: input.experimentalAuthorization != nil
        )
        let plannerResult = capabilityPlanner.plan(plannerRequest, inventory: snapshot)
        guard plannerResult.failure == nil, let selected = plannerResult.selectedDescriptor else {
            throw failure(.capabilityUnavailable, "No trusted runnable capability was selected.")
        }
        guard let backend = registry.backend(for: selected.request.backend) else {
            throw failure(.backendUnavailable, "The selected backend is not registered.")
        }
        guard let runtime = snapshot.backendRuntime(for: selected) else {
            throw failure(.backendInventoryUnavailable, "Exact backend runtime evidence is unavailable.")
        }
        let backendResult = registry.plan(MachineBackendPlanRequest(
            machine: input.machine,
            capabilityPlan: plannerResult
        ))
        guard let backendPlan = backendResult.plan, backendResult.failure == nil,
              backendPlan.backend == backend.descriptor,
              backendPlan.machine == input.machine,
              backendPlan.capability == selected else {
            throw failure(.backendPlanRejected, "The selected adapter rejected the machine plan.")
        }

        let timing: (revision: UInt64, created: Int64, updated: Int64)
        switch input.publication {
        case .create:
            let timestamp = now()
            timing = (1, timestamp, timestamp)
        case let .replace(expected):
            let current: DoryResolvedMachinePlan
            do { current = try plans.read(id: definition.identity.id) }
            catch { throw failure(.persistenceRejected, "The current resolved plan could not be read.") }
            guard expected < UInt64.max else {
                throw failure(.persistenceRejected, "The resolved plan revision is exhausted.")
            }
            timing = (expected + 1, current.createdAtUnixMilliseconds,
                      max(now(), current.createdAtUnixMilliseconds))
        }

        let plan: DoryResolvedMachinePlan
        do {
            plan = try DoryResolvedMachinePlan(
                machineID: definition.identity.id,
                definitionRevision: definition.lifecycle.revision,
                definitionSHA256: Self.sha256(input.canonicalDefinitionData),
                planRevision: timing.revision,
                createdAtUnixMilliseconds: timing.created,
                updatedAtUnixMilliseconds: timing.updated,
                backendDescriptor: backend.descriptor,
                backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
                resolverReference: snapshot.media.reference,
                components: runtime.components.sorted {
                    $0.componentIdentifier < $1.componentIdentifier
                },
                resourceAdmission: snapshot.resourceAdmission,
                hostQualification: runtime.hostQualification,
                experimentalAuthorization: input.experimentalAuthorization,
                plannerRequest: plannerRequest,
                plannerResult: plannerResult,
                fallbackAuthorization: input.fallbackAuthorization
            )
        } catch {
            throw failure(.planConstructionRejected, "Trusted evidence did not form a valid durable plan.")
        }
        do {
            switch input.publication {
            case .create: try plans.create(plan)
            case let .replace(expected):
                try plans.replace(plan, expectedPlanRevision: expected)
            }
        } catch {
            throw failure(.persistenceRejected, "The durable plan could not be published.")
        }
        return DoryDaemonVirtualMachinePlanningResult(
            plannerRequest: plannerRequest,
            plannerResult: plannerResult,
            resolvedPlan: plan,
            resolvedPlanSHA256: Self.planSHA256(plan),
            backendPlan: backendPlan
        )
    }

    static func primaryBootMedia(
        in definition: DoryVirtualMachineDefinition
    ) -> DoryVMBootMediaReference? {
        guard let id = definition.boot.order.first else { return nil }
        return definition.boot.devices.first { $0.id == id }
    }

    static func devices(
        for definition: DoryVirtualMachineDefinition
    ) -> DoryVirtualMachineDeviceCapabilityRequest {
        let networkAttachment: DoryVirtualMachineNetworkAttachmentMode
        switch definition.networkMode {
        case .sharedNAT: networkAttachment = .sharedNAT
        case .bridged: networkAttachment = .bridged
        case .isolated: networkAttachment = .isolated
        }
        return DoryVirtualMachineDeviceCapabilityRequest(
            networkAttachment: networkAttachment,
            audioInput: definition.audio.inputEnabled,
            audioOutput: definition.audio.outputEnabled,
            keyboard: definition.input.keyboardEnabled,
            pointer: definition.input.pointerEnabled,
            directorySharing: !definition.shares.isEmpty,
            clipboard: definition.integrations.contains(.clipboard),
            clockSynchronization: definition.integrations.contains(.clockSynchronization),
            dynamicDisplay: definition.integrations.contains(.dynamicDisplay),
            gracefulShutdown: definition.integrations.contains(.gracefulShutdown)
        )
    }

    private static func plannerRequest(
        definition: DoryVirtualMachineDefinition,
        media: DoryBootMedia,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        allowsExperimental: Bool
    ) -> DoryVirtualMachineBackendPlanRequest {
        let preferences = definition.backendPreference.backend.map { [$0] }
        let policy: DoryVirtualMachineBackendPreferencePolicy =
            definition.backendPreference.mode == .required ? .required : .preferred
        return DoryVirtualMachineBackendPlanRequest(
            guest: definition.guest,
            bootMedia: media,
            acceptableGraphics: definition.graphics.acceptableLevels,
            devices: devices,
            virtualHardwareABIVersion: definition.virtualHardwareABIVersion,
            backendPreferences: preferences,
            backendPreferencePolicy: policy,
            allowsExperimentalBackends: allowsExperimental
        )
    }

    static func planSHA256(_ plan: DoryResolvedMachinePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(plan) else { return "" }
        return sha256(bytes)
    }

    public static func canonicalDefinitionData(
        _ definition: DoryVirtualMachineDefinition
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(definition)) ?? Data()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func failure(
        _ code: DoryDaemonVirtualMachinePlanningFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachinePlanningFailure {
        DoryDaemonVirtualMachinePlanningFailure(code: code, message: message)
    }
}
