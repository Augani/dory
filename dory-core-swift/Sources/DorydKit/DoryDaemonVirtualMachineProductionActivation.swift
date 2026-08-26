import DoryOperations
import Foundation

public enum DoryDaemonVirtualMachineProductionActivationFailureCode:
    String, Sendable, Equatable
{
    case trustUnavailable = "trust-unavailable"
    case stateAuthorityUnavailable = "state-authority-unavailable"
    case backendCompositionUnavailable = "backend-composition-unavailable"
    case planningUnavailable = "planning-unavailable"
    case installationRejected = "installation-rejected"
    case trustFloorActivationRejected = "trust-floor-activation-rejected"
}

public struct DoryDaemonVirtualMachineProductionActivationFailure:
    Error, Sendable, Equatable
{
    public var code: DoryDaemonVirtualMachineProductionActivationFailureCode
    public var message: String
    public var trustFailure: DoryDaemonVirtualMachineProductionTrustUnavailable?
    public var planningFailure:
        DoryDaemonVirtualMachineProductionPlanningCompositionFailure?

    public init(
        code: DoryDaemonVirtualMachineProductionActivationFailureCode,
        message: String,
        trustFailure: DoryDaemonVirtualMachineProductionTrustUnavailable? = nil,
        planningFailure:
            DoryDaemonVirtualMachineProductionPlanningCompositionFailure? = nil
    ) {
        self.code = code
        self.message = message
        self.trustFailure = trustFailure
        self.planningFailure = planningFailure
    }
}

/// The successfully installed production graph. This is deliberately non-Codable: every member
/// is live daemon authority, not caller intent or a persisted assertion of trust.
public struct DoryDaemonVirtualMachineProductionActivationContext: Sendable {
    public let machineManager: MachineManager
    public let planning: DoryDaemonVirtualMachineProductionPlanningContext
    public let planningController:
        DoryDaemonVirtualMachineProductionPlanningController
    public let backendRuntimeBuildIdentifiers: [
        DoryVirtualizationBackendIdentity: String
    ]
    public let machineImportEnvironment: DoryMachineImportEnvironment

    public var inventory: any DoryDaemonVirtualMachineTrustInventory {
        planning.inventory
    }

    init(
        machineManager: MachineManager,
        planning: DoryDaemonVirtualMachineProductionPlanningContext,
        planningController:
            DoryDaemonVirtualMachineProductionPlanningController,
        backendRuntimeBuildIdentifiers: [
            DoryVirtualizationBackendIdentity: String
        ],
        machineImportEnvironment: DoryMachineImportEnvironment
    ) {
        self.machineManager = machineManager
        self.planning = planning
        self.planningController = planningController
        self.backendRuntimeBuildIdentifiers = backendRuntimeBuildIdentifiers
        self.machineImportEnvironment = machineImportEnvironment
    }
}

public enum DoryDaemonVirtualMachineProductionActivationResult: Sendable {
    case activated(DoryDaemonVirtualMachineProductionActivationContext)
    case unavailable(DoryDaemonVirtualMachineProductionActivationFailure)

    public var isActivated: Bool {
        if case .activated = self { return true }
        return false
    }
}

extension DoryDaemonVirtualMachineProductionTrustFactory {
    /// Verifies production trust, recovers durable planning transactions, installs the exact
    /// recovered launch graph into a production-owned manager, and only then advances the trust
    /// floor. No manager is returned on failure, so partially installed in-memory authority cannot
    /// escape this boundary or poison a retry.
    public func activate(
        store: DoryComponentStore,
        machineConfiguration: MachineManagerConfiguration
    ) -> DoryDaemonVirtualMachineProductionActivationResult {
        activate(
            store: store,
            machineConfiguration: machineConfiguration,
            appVersion: Self.compiledDaemonVersion,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: DoryComponentDefaults.architecture
        )
    }

    /// Internal deterministic seam for signed-catalog and failure-order tests. Production callers
    /// cannot replace the compiled version, pinned catalog key, or architecture.
    func activate(
        store: DoryComponentStore,
        machineConfiguration: MachineManagerConfiguration,
        appVersion: String,
        publicKey: String,
        expectedArchitecture: String
    ) -> DoryDaemonVirtualMachineProductionActivationResult {
        let canonicalStateDirectory = store.drive.machinesDirectory
        guard machineConfiguration.stateDirectory == canonicalStateDirectory else {
            return unavailableActivation(
                .stateAuthorityUnavailable,
                "Production VM state must be the selected data drive's exact machines root."
            )
        }
        guard machineConfiguration.passMachineArguments else {
            return unavailableActivation(
                .installationRejected,
                "Production resolved launches require exact machine argument binding."
            )
        }
        let machineStateBroker: DoryMachineStateBroker
        do {
            machineStateBroker = try DoryMachineStateBroker(
                canonicalStateRootPath: canonicalStateDirectory
            )
        } catch {
            return unavailableActivation(
                .stateAuthorityUnavailable,
                "Production machine-state authority could not be acquired."
            )
        }

        let material: DoryDaemonVirtualMachineVerifiedTrustMaterial
        switch verifiedTrustMaterial(
            store: store,
            machineConfiguration: machineConfiguration,
            appVersion: appVersion,
            publicKey: publicKey,
            expectedArchitecture: expectedArchitecture
        ) {
        case let .success(verified):
            material = verified
        case let .failure(reason):
            return .unavailable(DoryDaemonVirtualMachineProductionActivationFailure(
                code: .trustUnavailable,
                message: "Production VM trust preparation failed.",
                trustFailure: reason
            ))
        }

        let rendererCrashSuppressionStore = DoryRendererCrashSuppressionStore(
            stateDirectory: canonicalStateDirectory
        )

        // This is the only manager admitted to the activated context. Public activation has no
        // manager/dependency injection point: executable paths, runtime/log roots, lifecycle
        // services, process launching, and guest architecture all come from the verified
        // production configuration and MachineManager's production defaults.
        let machineManager = MachineManager(
            configuration: machineConfiguration,
            launchPolicy: .perWorkspaceAuthority,
            machineStateBroker: machineStateBroker
        )
        do {
            try machineManager.installRendererCrashSuppressionStore(
                rendererCrashSuppressionStore
            )
        } catch {
            return unavailableActivation(
                .installationRejected,
                "MachineManager rejected renderer runtime-health authority."
            )
        }

        let backends: [any MachineBackend]
        do {
            backends = try material.runtimes.map { runtime -> any MachineBackend in
                switch runtime.descriptor.identity {
                case .appleVirtualizationFramework:
                    return VirtualizationFrameworkLinuxMachineBackend(
                        executablePath: runtime.executablePath,
                        operations: machineManager.resolvedLaunchCompatibilityOperations(
                            for: runtime.descriptor.identity
                        )
                    )
                case .doryHypervisor:
                    return RawHVLinuxMachineBackend(
                        executablePath: runtime.executablePath,
                        operations: machineManager.resolvedLaunchCompatibilityOperations(
                            for: runtime.descriptor.identity
                        )
                    )
                case .qemuHypervisorFramework:
                    throw DoryDaemonVirtualMachineProductionActivationFailure(
                        code: .backendCompositionUnavailable,
                        message: "No verified production adapter exists for the runtime."
                    )
                }
            }
        } catch let failure as DoryDaemonVirtualMachineProductionActivationFailure {
            return .unavailable(failure)
        } catch {
            return unavailableActivation(
                .backendCompositionUnavailable,
                "Verified backend adapters could not be composed."
            )
        }

        let composition = DoryDaemonVirtualMachineProductionPlanningCompositionFactory(
            stateDirectory: canonicalStateDirectory,
            backends: backends,
            qualificationAuthority: material.authority,
            runtimes: material.runtimes,
            runtimeVerifier: material.runtimeVerifier,
            hostProbe: material.hostProbe,
            rendererReleaseIdentityProvider:
                material.rendererReleaseIdentityProvider,
            rendererCrashSuppressionStore:
                rendererCrashSuppressionStore,
            mutationAuthority: machineManager,
            recoveryProvider: DoryDaemonVirtualMachineProductionRecoveryProvider(
                stateDirectory: canonicalStateDirectory
            )
        )
        let planning: DoryDaemonVirtualMachineProductionPlanningContext
        switch composition.resolve() {
        case let .ready(context):
            planning = context
        case let .unavailable(reason):
            return .unavailable(DoryDaemonVirtualMachineProductionActivationFailure(
                code: .planningUnavailable,
                message: "Production planning recovery or composition failed.",
                planningFailure: reason
            ))
        }

        let planningController = DoryDaemonVirtualMachineProductionPlanningController(
            planning: planning
        )
        do {
            try machineManager.installResolvedLaunchInfrastructure(
                registry: planning.registry,
                resolver: planning.launchResolver,
                plans: planning.plans,
                expectedPlanRevision: { machineID in
                    try? planning.plans.read(id: machineID).planRevision
                },
                productionPlanningController: planningController,
                resourceAdmissionLedger: planning.resourceLedger
            )
        } catch {
            return unavailableActivation(
                .installationRejected,
                "MachineManager rejected the exact recovered launch infrastructure."
            )
        }

        do {
            try activateVerifiedTrustFloor(
                stateDirectory: canonicalStateDirectory,
                material: material
            )
        } catch {
            return unavailableActivation(
                .trustFloorActivationRejected,
                "Recovered launch infrastructure was installed, but the trust floor could not be durably advanced."
            )
        }

        let backendRuntimeBuildIdentifiers = Dictionary(
            uniqueKeysWithValues: material.runtimes.map {
                ($0.descriptor.identity, $0.runtimeBuildIdentifier)
            }
        )
        return .activated(DoryDaemonVirtualMachineProductionActivationContext(
            machineManager: machineManager,
            planning: planning,
            planningController: planningController,
            backendRuntimeBuildIdentifiers: backendRuntimeBuildIdentifiers,
            machineImportEnvironment: DoryMachineImportEnvironment(
                backendRuntimeBuildIdentifiers: backendRuntimeBuildIdentifiers,
                backendComponents: Dictionary(
                    uniqueKeysWithValues: material.runtimes.map {
                        ($0.descriptor.identity, $0.componentEvidence)
                    }
                )
            )
        ))
    }

    private func unavailableActivation(
        _ code: DoryDaemonVirtualMachineProductionActivationFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachineProductionActivationResult {
        .unavailable(DoryDaemonVirtualMachineProductionActivationFailure(
            code: code,
            message: message
        ))
    }
}
