import Darwin
import DoryOperations
import Foundation

/// Supplies daemon-authoritative reconstruction inputs for a durable planning journal. The
/// provider is expected to be backed by MachineManager's exact raw machine metadata, migration
/// facts, and lifecycle fence; a journal is never recovered from its persisted plan bytes alone.
public protocol DoryDaemonVirtualMachinePlanningRecoveryProviding: Sendable {
    func recoveryRequest(
        for descriptor: DoryDaemonVirtualMachinePlanningRecoveryDescriptor
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionRequest?
}

public enum DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode:
    String, Sendable, Equatable
{
    case mutationAuthorityUnavailable = "mutation-authority-unavailable"
    case recoveryAuthorityUnavailable = "recovery-authority-unavailable"
    case stateAuthorityUnavailable = "state-authority-unavailable"
    case backendRegistryUnavailable = "backend-registry-unavailable"
    case resourceAuthorityUnavailable = "resource-authority-unavailable"
    case trustInventoryUnavailable = "trust-inventory-unavailable"
    case recoveryRequestUnavailable = "recovery-request-unavailable"
    case recoveryFailed = "recovery-failed"
    case compositionFailed = "composition-failed"
}

public struct DoryDaemonVirtualMachineProductionPlanningCompositionFailure:
    Error, Sendable, Equatable
{
    public var code: DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode
    public var machineID: String?
    public var message: String

    public init(
        code: DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode,
        machineID: String? = nil,
        message: String
    ) {
        self.code = code
        self.machineID = machineID
        self.message = message
    }
}

/// Canonical durable roots shared by planning and start. These paths are diagnostic identities,
/// not persisted caller intent; construction rejects aliases and derives every child from one
/// exact state root.
public struct DoryDaemonVirtualMachineProductionPlanningAuthorityIdentity:
    Sendable, Equatable, Hashable
{
    public var stateDirectory: String
    public var workspaceRepositoryRoot: String
    public var resolvedPlanRepositoryRoot: String
    public var artifactAuthorityRoot: String
    public var resourceAdmissionLedgerRoot: String

    public init(stateDirectory: String) {
        let canonical = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        self.stateDirectory = canonical
        workspaceRepositoryRoot = canonical
        resolvedPlanRepositoryRoot = canonical
        artifactAuthorityRoot = canonical + "/.artifact-authority"
        resourceAdmissionLedgerRoot = canonical + "/.resource-admissions"
    }
}

/// Non-Codable daemon composition. All handles below are the exact instances used by recovery,
/// subsequent planning, and start-time resolution.
public struct DoryDaemonVirtualMachineProductionPlanningContext: Sendable {
    public let identity: DoryDaemonVirtualMachineProductionPlanningAuthorityIdentity
    public let artifactAuthority: DoryVirtualMachineArtifactAuthority
    public let resourceLedger: DoryVirtualMachineResourceAdmissionLedger
    public let workspaces: DoryWorkspaceRepository
    public let plans: DoryResolvedMachinePlanRepository
    public let registry: BackendRegistry
    public let inventory: any DoryDaemonVirtualMachineTrustInventory
    public let coordinator: DoryDaemonVirtualMachinePlanningTransactionCoordinator
    public let launchResolver: DoryDaemonVirtualMachineLaunchPlanResolver
    public let recoveredTransactionIDs: [String: String]

    public var planningTransactionAvailable: Bool { true }

    init(
        identity: DoryDaemonVirtualMachineProductionPlanningAuthorityIdentity,
        artifactAuthority: DoryVirtualMachineArtifactAuthority,
        resourceLedger: DoryVirtualMachineResourceAdmissionLedger,
        workspaces: DoryWorkspaceRepository,
        plans: DoryResolvedMachinePlanRepository,
        registry: BackendRegistry,
        inventory: any DoryDaemonVirtualMachineTrustInventory,
        coordinator: DoryDaemonVirtualMachinePlanningTransactionCoordinator,
        launchResolver: DoryDaemonVirtualMachineLaunchPlanResolver,
        recoveredTransactionIDs: [String: String]
    ) {
        self.identity = identity
        self.artifactAuthority = artifactAuthority
        self.resourceLedger = resourceLedger
        self.workspaces = workspaces
        self.plans = plans
        self.registry = registry
        self.inventory = inventory
        self.coordinator = coordinator
        self.launchResolver = launchResolver
        self.recoveredTransactionIDs = recoveredTransactionIDs
    }
}

public enum DoryDaemonVirtualMachineProductionPlanningReadiness: Sendable {
    case ready(DoryDaemonVirtualMachineProductionPlanningContext)
    case unavailable(DoryDaemonVirtualMachineProductionPlanningCompositionFailure)

    public var planningTransactionAvailable: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Constructs the exact production planning/start authorities and recovers every discovered
/// transaction before returning readiness. The public production trust factory will own this
/// boundary; its dependency-injected initializer remains internal so callers cannot provide a
/// fabricated trust inventory.
public final class DoryDaemonVirtualMachineProductionPlanningCompositionFactory:
    @unchecked Sendable
{
    typealias TrustedInventory = any DoryDaemonVirtualMachineTrustInventory
        & DoryDaemonVirtualMachinePlanningTrustPreparing
    typealias InventoryBuilder = @Sendable (
        DoryVirtualMachineArtifactAuthority,
        DoryVirtualMachineResourceAdmissionLedger
    ) throws -> TrustedInventory

    private static let journalFileName = "planning-transaction-v1.json"
    private static let compositionLockFileName = ".planning-composition.lock"

    private let identity: DoryDaemonVirtualMachineProductionPlanningAuthorityIdentity
    private let backends: [any MachineBackend]
    private let mutationAuthority: (any DoryDaemonVirtualMachinePlanningMutationAuthorizing)?
    private let recoveryProvider: (any DoryDaemonVirtualMachinePlanningRecoveryProviding)?
    private let inventoryBuilder: InventoryBuilder
    private let capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning
    private let verifiedBackendDescriptors: [MachineBackendDescriptor]?

    init(
        stateDirectory: String,
        backends: [any MachineBackend],
        mutationAuthority: (any DoryDaemonVirtualMachinePlanningMutationAuthorizing)?,
        recoveryProvider: (any DoryDaemonVirtualMachinePlanningRecoveryProviding)?,
        capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning =
            DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner(),
        verifiedBackendDescriptors: [MachineBackendDescriptor]? = nil,
        inventoryBuilder: @escaping InventoryBuilder
    ) {
        identity = DoryDaemonVirtualMachineProductionPlanningAuthorityIdentity(
            stateDirectory: stateDirectory
        )
        self.backends = backends
        self.mutationAuthority = mutationAuthority
        self.recoveryProvider = recoveryProvider
        self.capabilityPlanner = capabilityPlanner
        self.verifiedBackendDescriptors = verifiedBackendDescriptors?.sorted {
            $0.identity.rawValue < $1.identity.rawValue
        }
        self.inventoryBuilder = inventoryBuilder
    }

    convenience init(
        stateDirectory: String,
        backends: [any MachineBackend],
        qualificationAuthority: DoryVerifiedVirtualMachineQualificationAuthority,
        runtimes: [DoryDaemonVerifiedBackendRuntime],
        runtimeVerifier: @escaping DoryDaemonVirtualMachineProductionTrustFactory.RuntimeVerifier,
        hostProbe: @escaping DoryDaemonVirtualMachineProductionTrustFactory.HostProbe,
        rendererReleaseIdentityProvider:
            any DoryRendererReleaseIdentityProviding,
        rendererCrashSuppressionStore:
            DoryRendererCrashSuppressionStore? = nil,
        mutationAuthority: (any DoryDaemonVirtualMachinePlanningMutationAuthorizing)?,
        recoveryProvider: (any DoryDaemonVirtualMachinePlanningRecoveryProviding)?
    ) {
        let specifications = runtimes.compactMap { runtime
            -> DoryDaemonBackendRuntimeSpecification? in
            guard let component = runtime.components.first else { return nil }
            return DoryDaemonBackendRuntimeSpecification(
                descriptor: runtime.descriptor,
                executablePath: runtime.executablePath,
                componentIdentifier: component.componentIdentifier
            )
        }
        self.init(
            stateDirectory: stateDirectory,
            backends: backends,
            mutationAuthority: mutationAuthority,
            recoveryProvider: recoveryProvider,
            verifiedBackendDescriptors: runtimes.map(\.descriptor),
            inventoryBuilder: { artifactAuthority, resourceLedger in
                guard specifications.count == runtimes.count else {
                    throw DoryDaemonProductionTrustInventoryError.backendUnavailable
                }
                return DoryProductionDaemonVirtualMachineTrustInventory(
                    qualificationAuthority: qualificationAuthority,
                    artifactAuthority: artifactAuthority,
                    resourceLedger: resourceLedger,
                    stateDirectory: stateDirectory,
                    runtimeSpecifications: specifications,
                    runtimeVerifier: runtimeVerifier,
                    hostProbe: hostProbe,
                    rendererReleaseIdentityProvider:
                        rendererReleaseIdentityProvider,
                    rendererCrashSuppressionStore:
                        rendererCrashSuppressionStore
                )
            }
        )
    }

    public func resolve() -> DoryDaemonVirtualMachineProductionPlanningReadiness {
        guard let mutationAuthority else {
            return unavailable(
                .mutationAuthorityUnavailable,
                "Production planning has no lifecycle-bound mutation authority."
            )
        }
        guard let recoveryProvider else {
            return unavailable(
                .recoveryAuthorityUnavailable,
                "Production planning has no authoritative journal recovery provider."
            )
        }
        guard identity.stateDirectory
                == URL(fileURLWithPath: identity.stateDirectory).standardizedFileURL.path else {
            return unavailable(.stateAuthorityUnavailable, "VM state root is not canonical.")
        }

        do {
            return try withCompositionLock {
                let registry: BackendRegistry
                do { registry = try BackendRegistry(backends: backends) }
                catch {
                    throw failure(
                        .backendRegistryUnavailable,
                        "Production backend registry cannot be constructed."
                    )
                }
                if let verifiedBackendDescriptors,
                   registry.descriptors.sorted(by: {
                       $0.identity.rawValue < $1.identity.rawValue
                   }) != verifiedBackendDescriptors {
                    throw failure(
                        .backendRegistryUnavailable,
                        "Backend adapters do not exactly match verified runtime descriptors."
                    )
                }
                let artifactAuthority = DoryVirtualMachineArtifactAuthority(
                    root: identity.artifactAuthorityRoot
                )
                let resourceLedger = DoryVirtualMachineResourceAdmissionLedger(
                    root: identity.resourceAdmissionLedgerRoot
                )
                do { _ = try resourceLedger.snapshot() }
                catch {
                    throw failure(
                        .resourceAuthorityUnavailable,
                        "Resource admission authority is corrupt or unavailable."
                    )
                }
                let workspaces = DoryWorkspaceRepository(
                    root: identity.workspaceRepositoryRoot
                )
                let plans = DoryResolvedMachinePlanRepository(
                    root: identity.resolvedPlanRepositoryRoot
                )
                let inventory: TrustedInventory
                do { inventory = try inventoryBuilder(artifactAuthority, resourceLedger) }
                catch {
                    throw failure(
                        .trustInventoryUnavailable,
                        "Verified production planning trust cannot be constructed."
                    )
                }
                let coordinator = DoryDaemonVirtualMachinePlanningTransactionCoordinator(
                    stateDirectory: identity.stateDirectory,
                    registry: registry,
                    trust: inventory,
                    mutationAuthority: mutationAuthority,
                    workspaces: workspaces,
                    plans: plans,
                    ledger: resourceLedger,
                    capabilityPlanner: capabilityPlanner
                )

                let pending = try pendingTransactionMachineIDs()
                var recovered: [String: String] = [:]
                for machineID in pending {
                    let descriptor: DoryDaemonVirtualMachinePlanningRecoveryDescriptor
                    do {
                        guard let recoveredDescriptor = try coordinator.recoveryDescriptor(
                            for: machineID
                        ), recoveredDescriptor.machineID == machineID else {
                            throw failure(
                                .recoveryRequestUnavailable,
                                machineID: machineID,
                                "The durable planning recovery descriptor is unavailable."
                            )
                        }
                        descriptor = recoveredDescriptor
                    } catch {
                        throw failure(
                            .recoveryFailed,
                            machineID: machineID,
                            "The durable planning recovery descriptor failed validation."
                        )
                    }
                    let request: DoryDaemonVirtualMachinePlanningTransactionRequest
                    do {
                        guard let recoveredRequest = try recoveryProvider.recoveryRequest(
                            for: descriptor
                        ) else {
                            throw failure(
                                .recoveryRequestUnavailable,
                                machineID: machineID,
                                "Exact authoritative recovery input is unavailable."
                            )
                        }
                        request = recoveredRequest
                    } catch {
                        throw failure(
                            .recoveryFailed,
                            machineID: machineID,
                            "Authoritative recovery input failed validation."
                        )
                    }
                    guard request.planning.definition.identity.id == machineID,
                          request.planning.machine.id == machineID,
                          descriptor.matches(request) else {
                        throw failure(
                            .recoveryRequestUnavailable,
                            machineID: machineID,
                            "Exact authoritative recovery input is unavailable."
                        )
                    }
                    do {
                        let result = try coordinator.resolveReserveAndPublish(request)
                        recovered[machineID] = result.transactionID
                    } catch {
                        throw failure(
                            .recoveryFailed,
                            machineID: machineID,
                            "Durable planning recovery failed closed."
                        )
                    }
                }

                // A second discovery prevents a concurrent writer from being silently omitted
                // during startup composition. Existing complete journals remain in the set.
                guard try pendingTransactionMachineIDs() == pending else {
                    throw failure(
                        .recoveryFailed,
                        "Planning journal inventory changed during recovery."
                    )
                }
                let collector = DoryDaemonVirtualMachineStartEvidenceCollector(
                    registry: registry,
                    inventory: inventory
                )
                let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
                    registry: registry,
                    plans: plans,
                    evidenceCollector: collector
                )
                return .ready(DoryDaemonVirtualMachineProductionPlanningContext(
                    identity: identity,
                    artifactAuthority: artifactAuthority,
                    resourceLedger: resourceLedger,
                    workspaces: workspaces,
                    plans: plans,
                    registry: registry,
                    inventory: inventory,
                    coordinator: coordinator,
                    launchResolver: resolver,
                    recoveredTransactionIDs: recovered
                ))
            }
        } catch let failure as DoryDaemonVirtualMachineProductionPlanningCompositionFailure {
            return .unavailable(failure)
        } catch {
            return unavailable(.compositionFailed, "Production planning composition failed.")
        }
    }

    private func pendingTransactionMachineIDs() throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: identity.stateDirectory
            )
        } catch {
            throw failure(.stateAuthorityUnavailable, "VM state root cannot be enumerated.")
        }
        var pending: [String] = []
        for name in names {
            let journal = identity.stateDirectory + "/" + name + "/" + Self.journalFileName
            var info = stat()
            if lstat(journal, &info) != 0 {
                if errno == ENOENT || errno == ENOTDIR { continue }
                throw failure(.stateAuthorityUnavailable, "Planning journal cannot be inspected.")
            }
            guard Self.isValidMachineID(name) else {
                throw failure(.stateAuthorityUnavailable, "Planning journal has an unsafe workspace identity.")
            }
            pending.append(name)
        }
        return pending.sorted()
    }

    private func withCompositionLock<T>(_ operation: () throws -> T) throws -> T {
        try ensurePrivateStateDirectory()
        let path = identity.stateDirectory + "/" + Self.compositionLockFileName
        let descriptor = open(
            path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw failure(.stateAuthorityUnavailable, "Planning composition lock cannot be opened.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw failure(.stateAuthorityUnavailable, "Planning composition lock is insecure.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func ensurePrivateStateDirectory() throws {
        var info = stat()
        guard lstat(identity.stateDirectory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw failure(.stateAuthorityUnavailable, "VM state root is missing or insecure.")
        }
    }

    private func unavailable(
        _ code: DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineProductionPlanningReadiness {
        .unavailable(failure(code, message))
    }

    private func failure(
        _ code: DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode,
        machineID: String? = nil,
        _ message: String
    ) -> DoryDaemonVirtualMachineProductionPlanningCompositionFailure {
        DoryDaemonVirtualMachineProductionPlanningCompositionFailure(
            code: code,
            machineID: machineID,
            message: message
        )
    }

    private static func isValidMachineID(_ value: String) -> Bool {
        value.utf8.count <= 63 && value.wholeMatch(
            of: /[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?/
        ) != nil
    }
}
