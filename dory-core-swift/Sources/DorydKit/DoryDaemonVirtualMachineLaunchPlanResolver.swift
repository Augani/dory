import DoryOperations
import Foundation

public enum DoryDaemonVirtualMachinePreSpawnAuthorizationError:
    Error, Sendable, Equatable
{
    case alreadyConsumed
    case revalidationFailed
}

/// Single-use daemon authorization for the last possible trust check before MachineManager reads
/// path-derived boot arguments or starts the helper. It is non-Codable and cannot be supplied as
/// API intent.
public final class DoryDaemonVirtualMachinePreSpawnAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    private let revalidate: @Sendable () throws -> Void

    init(revalidate: @escaping @Sendable () throws -> Void) {
        self.revalidate = revalidate
    }

    public func authorize() throws {
        lock.lock()
        guard !consumed else {
            lock.unlock()
            throw DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed
        }
        consumed = true
        lock.unlock()
        do { try revalidate() }
        catch {
            throw DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed
        }
    }
}

protocol DoryDaemonVirtualMachinePreSpawnAuthorizationProviding: Sendable {
    func preSpawnAuthorization(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePreSpawnAuthorization
}

public protocol DoryDaemonVirtualMachineExactCapabilityEvaluating: Sendable {
    func evaluate(
        _ request: DoryVirtualMachineCapabilityRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineCapabilityDescriptor
}

/// Re-evaluates one exact persisted choice. It does not invoke backend selection and cannot
/// downgrade graphics, devices, or backend identity during start.
public struct DoryAppleSiliconDaemonVirtualMachineExactCapabilityEvaluator:
    DoryDaemonVirtualMachineExactCapabilityEvaluating
{
    public init() {}

    public func evaluate(
        _ request: DoryVirtualMachineCapabilityRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineCapabilityDescriptor {
        DoryAppleSiliconCapabilityEvaluator.evaluate(
            request,
            host: inventory.hostFacts,
            trustedGuestImageGraphicsQualification: inventory.media.guestGraphicsQualification,
            trustedBootMediaInspection: inventory.media.bootInspection,
            trustedMutableBootMediaProvenance: inventory.media.mutableProvenance,
            trustedRuntimeQualification: inventory.exactStartRuntimeQualification
        )
    }
}

public struct DoryDaemonVirtualMachineStartEvidenceCollection: Sendable, Equatable {
    public var capability: DoryVirtualMachineCapabilityDescriptor
    public var runtimeEvidence: DoryResolvedMachineRuntimeEvidence
    public var preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization?

    public init(
        capability: DoryVirtualMachineCapabilityDescriptor,
        runtimeEvidence: DoryResolvedMachineRuntimeEvidence,
        preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization? = nil
    ) {
        self.capability = capability
        self.runtimeEvidence = runtimeEvidence
        self.preSpawnAuthorization = preSpawnAuthorization
    }

    public static func == (
        lhs: DoryDaemonVirtualMachineStartEvidenceCollection,
        rhs: DoryDaemonVirtualMachineStartEvidenceCollection
    ) -> Bool {
        lhs.capability == rhs.capability
            && lhs.runtimeEvidence == rhs.runtimeEvidence
            && ((lhs.preSpawnAuthorization == nil)
                == (rhs.preSpawnAuthorization == nil))
    }
}

public protocol DoryDaemonVirtualMachineStartEvidenceCollecting: Sendable {
    func collectFreshEvidence(
        for plan: DoryResolvedMachinePlan
    ) throws -> DoryDaemonVirtualMachineStartEvidenceCollection
}

public enum DoryDaemonVirtualMachineStartEvidenceFailureCode: String, Sendable, Equatable {
    case mediaReferenceUnavailable = "media-reference-unavailable"
    case inventoryUnavailable = "inventory-unavailable"
    case mediaInventoryMismatch = "media-inventory-mismatch"
    case backendUnavailable = "backend-unavailable"
    case backendInventoryUnavailable = "backend-inventory-unavailable"
    case exactCapabilityUnavailable = "exact-capability-unavailable"
    case preSpawnAuthorizationUnavailable = "pre-spawn-authorization-unavailable"
}

public struct DoryDaemonVirtualMachineStartEvidenceFailure: Error, Sendable, Equatable {
    public var code: DoryDaemonVirtualMachineStartEvidenceFailureCode
    public var message: String

    public init(code: DoryDaemonVirtualMachineStartEvidenceFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Production evidence collector. Every volatile field is rebuilt from a fresh daemon inventory;
/// persisted audit references are never promoted back into trusted decisions.
public final class DoryDaemonVirtualMachineStartEvidenceCollector:
    DoryDaemonVirtualMachineStartEvidenceCollecting,
    @unchecked Sendable
{
    private let registry: BackendRegistry
    private let inventory: any DoryDaemonVirtualMachineTrustInventory
    private let evaluator: any DoryDaemonVirtualMachineExactCapabilityEvaluating

    public init(
        registry: BackendRegistry,
        inventory: any DoryDaemonVirtualMachineTrustInventory,
        evaluator: any DoryDaemonVirtualMachineExactCapabilityEvaluating =
            DoryAppleSiliconDaemonVirtualMachineExactCapabilityEvaluator()
    ) {
        self.registry = registry
        self.inventory = inventory
        self.evaluator = evaluator
    }

    public func collectFreshEvidence(
        for plan: DoryResolvedMachinePlan
    ) throws -> DoryDaemonVirtualMachineStartEvidenceCollection {
        guard let reference = plan.bootMedia.resolverReference else {
            throw failure(.mediaReferenceUnavailable, "The persisted plan has no media resolver reference.")
        }
        let persistedRequest = DoryVirtualMachineCapabilityRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            backend: plan.backend,
            graphics: plan.graphics,
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion
        )
        let inventoryRequest = DoryDaemonVirtualMachineStartInventoryRequest(
            machineID: plan.machineID,
            definitionRevision: plan.definitionRevision,
            planRevision: plan.planRevision,
            bootMediaReference: reference,
            exactCapabilityRequest: persistedRequest,
            resolvedPlan: plan
        )
        let snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
        do {
            snapshot = try inventory.startInventory(for: inventoryRequest)
        } catch {
            throw failure(.inventoryUnavailable, "Fresh trusted start inventory could not be resolved.")
        }
        guard snapshot.media.reference == reference else {
            throw failure(.mediaInventoryMismatch, "Fresh media resolved under a different identity.")
        }
        guard let backend = registry.backend(for: plan.backend),
              backend.descriptor.identity == plan.backend else {
            throw failure(.backendUnavailable, "The persisted backend is not registered.")
        }
        guard let runtime = snapshot.backendRuntime(for: plan.backend) else {
            throw failure(.backendInventoryUnavailable, "Exact backend runtime evidence is unavailable.")
        }
        let exactRequest = DoryVirtualMachineCapabilityRequest(
            guest: plan.guest,
            bootMedia: snapshot.media.media,
            backend: plan.backend,
            graphics: plan.graphics,
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion
        )
        let capability = evaluator.evaluate(exactRequest, inventory: snapshot)
        guard capability.schemaVersion
                == DoryVirtualMachineCapabilityDescriptor.currentSchemaVersion,
              capability.evaluatorVersion
                == DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
              capability.request == exactRequest,
              capability.availability.isUsable,
              capability.resolvedDevices == exactRequest.devices else {
            throw failure(.exactCapabilityUnavailable, "Fresh evidence does not authorize the exact capability.")
        }
        let runtimeEvidence = DoryResolvedMachineRuntimeEvidence(
            guest: exactRequest.guest,
            backend: exactRequest.backend,
            backendImplementationIdentifier: backend.descriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
            virtualHardwareABIVersion: exactRequest.virtualHardwareABIVersion,
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: snapshot.media.reference,
                media: exactRequest.bootMedia,
                inspectionEvidence: capability.bootMediaInspectionEvidence,
                mutableProvenanceEvidence: capability.mutableBootMediaProvenanceEvidence
            ),
            launchArtifacts: snapshot.launchArtifacts,
            components: runtime.components.sorted {
                $0.componentIdentifier < $1.componentIdentifier
            },
            devices: exactRequest.devices,
            graphics: exactRequest.graphics,
            supportTier: capability.availability.supportTier,
            selectionEvidence: plan.selectionEvidence,
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                graphics: capability.graphicsQualificationEvidence,
                runtime: capability.runtimeQualificationEvidence
            ),
            resourceAdmission: snapshot.resourceAdmission,
            hostQualification: runtime.hostQualification,
            experimentalAuthorization: plan.experimentalAuthorization
        )
        guard let authorizationProvider = inventory
                as? any DoryDaemonVirtualMachinePreSpawnAuthorizationProviding else {
            throw failure(
                .preSpawnAuthorizationUnavailable,
                "The trusted inventory cannot authorize final pre-spawn revalidation."
            )
        }
        let preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization
        do {
            preSpawnAuthorization = try authorizationProvider.preSpawnAuthorization(
                for: inventoryRequest
            )
        } catch {
            throw failure(
                .preSpawnAuthorizationUnavailable,
                "Final pre-spawn revalidation could not be prepared."
            )
        }
        return DoryDaemonVirtualMachineStartEvidenceCollection(
            capability: capability,
            runtimeEvidence: runtimeEvidence,
            preSpawnAuthorization: preSpawnAuthorization
        )
    }

    private func failure(
        _ code: DoryDaemonVirtualMachineStartEvidenceFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineStartEvidenceFailure {
        DoryDaemonVirtualMachineStartEvidenceFailure(code: code, message: message)
    }
}

public struct DoryDaemonVirtualMachineLaunchPlanRequest: Sendable {
    public var definition: DoryVirtualMachineDefinition
    /// Fresh canonical sorted-key encoding of `definition`.
    public var canonicalDefinitionData: Data
    public var machine: DoryMachineConfiguration
    public var expectedPlanRevision: UInt64

    public init(
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data,
        machine: DoryMachineConfiguration,
        expectedPlanRevision: UInt64
    ) {
        self.definition = definition
        self.canonicalDefinitionData = canonicalDefinitionData
        self.machine = machine
        self.expectedPlanRevision = expectedPlanRevision
    }
}

/// Non-Codable by design: compatibility configuration may contain paths or environment secrets.
public struct DoryDaemonVirtualMachineLaunchPlanResolution: Sendable {
    public var resolvedPlan: DoryResolvedMachinePlan
    public var resolvedPlanSHA256: String
    public var revalidation: DoryResolvedMachinePlanRevalidationResult
    public var backendPlan: MachineBackendPlan
    public var preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization?

    public init(
        resolvedPlan: DoryResolvedMachinePlan,
        resolvedPlanSHA256: String,
        revalidation: DoryResolvedMachinePlanRevalidationResult,
        backendPlan: MachineBackendPlan,
        preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization? = nil
    ) {
        self.resolvedPlan = resolvedPlan
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.revalidation = revalidation
        self.backendPlan = backendPlan
        self.preSpawnAuthorization = preSpawnAuthorization
    }
}

public enum DoryDaemonVirtualMachineLaunchPlanFailureCode: String, Sendable, Equatable {
    case invalidDefinition = "invalid-definition"
    case emptyDefinitionAuthority = "empty-definition-authority"
    case definitionAuthorityMismatch = "definition-authority-mismatch"
    case machineIdentityMismatch = "machine-identity-mismatch"
    case planNotFound = "plan-not-found"
    case planRepositoryRejected = "plan-repository-rejected"
    case freshEvidenceUnavailable = "fresh-evidence-unavailable"
    case staleOrMismatchedPlan = "stale-or-mismatched-plan"
    case backendPlanRejected = "backend-plan-rejected"
    case backendPlanIdentityMismatch = "backend-plan-identity-mismatch"
}

public struct DoryDaemonVirtualMachineLaunchPlanFailure: Error, Sendable, Equatable {
    public var code: DoryDaemonVirtualMachineLaunchPlanFailureCode
    public var message: String
    public var revalidationIssues: [DoryResolvedMachinePlanRevalidationIssue]

    public init(
        code: DoryDaemonVirtualMachineLaunchPlanFailureCode,
        message: String,
        revalidationIssues: [DoryResolvedMachinePlanRevalidationIssue] = []
    ) {
        self.code = code
        self.message = message
        self.revalidationIssues = revalidationIssues
    }
}

public protocol DoryDaemonVirtualMachineLaunchPlanResolving: Sendable {
    func resolve(
        _ request: DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution
}

/// Reads and revalidates a previously selected plan. It deliberately has no capability planner,
/// fallback authorization, or plan-writing dependency, so start cannot silently re-plan.
public final class DoryDaemonVirtualMachineLaunchPlanResolver:
    DoryDaemonVirtualMachineLaunchPlanResolving,
    @unchecked Sendable
{
    private let registry: BackendRegistry
    private let plans: any DoryResolvedMachinePlanStoring
    private let evidenceCollector: any DoryDaemonVirtualMachineStartEvidenceCollecting

    public init(
        registry: BackendRegistry,
        plans: any DoryResolvedMachinePlanStoring,
        evidenceCollector: any DoryDaemonVirtualMachineStartEvidenceCollecting
    ) {
        self.registry = registry
        self.plans = plans
        self.evidenceCollector = evidenceCollector
    }

    public func resolve(
        _ request: DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution {
        guard request.definition.validate().isEmpty else {
            throw failure(.invalidDefinition, "Workspace definition validation failed.")
        }
        guard !request.canonicalDefinitionData.isEmpty else {
            throw failure(.emptyDefinitionAuthority, "Fresh definition authority bytes are required.")
        }
        guard request.canonicalDefinitionData
                == DoryDaemonVirtualMachinePlanningCoordinator.canonicalDefinitionData(
                    request.definition
                ) else {
            throw failure(
                .definitionAuthorityMismatch,
                "Definition bytes are not the canonical encoding of the supplied workspace."
            )
        }
        guard request.machine.id == request.definition.identity.id else {
            throw failure(.machineIdentityMismatch, "Legacy machine and workspace identities differ.")
        }
        let plan: DoryResolvedMachinePlan
        do {
            plan = try plans.read(id: request.definition.identity.id)
        } catch let error as DoryResolvedMachinePlanRepositoryError {
            if case .planNotFound = error {
                throw failure(.planNotFound, "No durable resolved plan exists for this machine.")
            }
            throw failure(.planRepositoryRejected, "The durable plan record failed repository validation.")
        } catch {
            throw failure(.planRepositoryRejected, "The durable plan record could not be read.")
        }
        let fresh: DoryDaemonVirtualMachineStartEvidenceCollection
        do { fresh = try evidenceCollector.collectFreshEvidence(for: plan) }
        catch {
            throw failure(.freshEvidenceUnavailable, "Fresh trusted runtime evidence is unavailable.")
        }
        let revalidation = DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: DoryResolvedMachinePlanStartRevalidationInput(
                machineID: request.definition.identity.id,
                expectedPlanRevision: request.expectedPlanRevision,
                currentDefinitionRevision: request.definition.lifecycle.revision,
                currentDefinitionSHA256: DoryDaemonVirtualMachinePlanningCoordinator.sha256(
                    request.canonicalDefinitionData
                ),
                runtimeEvidence: fresh.runtimeEvidence
            )
        )
        guard revalidation.mayStart else {
            throw DoryDaemonVirtualMachineLaunchPlanFailure(
                code: .staleOrMismatchedPlan,
                message: "The persisted plan no longer matches current daemon evidence.",
                revalidationIssues: revalidation.issues
            )
        }
        let capabilityPlan = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: fresh.capability,
            evaluatedDescriptors: [fresh.capability],
            failure: nil
        )
        let mapped = registry.plan(MachineBackendPlanRequest(
            machine: request.machine,
            capabilityPlan: capabilityPlan,
            portForwards: plan.portForwards
        ))
        guard let backendPlan = mapped.plan, mapped.failure == nil else {
            throw failure(.backendPlanRejected, "The exact backend adapter rejected the launch plan.")
        }
        guard backendPlan.backend.identity == plan.backend,
              backendPlan.backend.implementationIdentifier
                == plan.backendImplementationIdentifier,
              backendPlan.capability == fresh.capability,
              backendPlan.machine.id == plan.machineID,
              backendPlan.portForwards == plan.portForwards else {
            throw failure(.backendPlanIdentityMismatch, "The adapter plan differs from the durable selection.")
        }
        return DoryDaemonVirtualMachineLaunchPlanResolution(
            resolvedPlan: plan,
            resolvedPlanSHA256: DoryDaemonVirtualMachinePlanningCoordinator.planSHA256(plan),
            revalidation: revalidation,
            backendPlan: backendPlan,
            preSpawnAuthorization: fresh.preSpawnAuthorization
        )
    }

    private func failure(
        _ code: DoryDaemonVirtualMachineLaunchPlanFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineLaunchPlanFailure {
        DoryDaemonVirtualMachineLaunchPlanFailure(code: code, message: message)
    }
}
