import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Production VM planning composition")
struct DoryDaemonVirtualMachineProductionPlanningCompositionTests {
    @Test("authorizer and recovery provider are both mandatory")
    func dependenciesAreMandatory() throws {
        let fixture = try CompositionFixture(ids: [])
        for (hasAuthorizer, hasRecovery, expected) in [
            (false, true,
             DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode
                .mutationAuthorityUnavailable),
            (true, false,
             .recoveryAuthorityUnavailable),
        ] {
            let result = fixture.factory(
                hasMutationAuthority: hasAuthorizer,
                hasRecoveryProvider: hasRecovery
            ).resolve()
            guard case let .unavailable(failure) = result else {
                Issue.record("Expected unavailable planning composition")
                continue
            }
            #expect(failure.code == expected)
            #expect(!result.planningTransactionAvailable)
        }
    }

    @Test("durable recovery completes before readiness is exposed")
    func recoveryPrecedesReadiness() throws {
        let fixture = try CompositionFixture(ids: ["recover-one"])
        try fixture.interrupt("recover-one", at: .planBindingCommitted)

        let readiness = fixture.factory().resolve()
        let context = try readyContext(readiness)
        #expect(fixture.events.values.contains("recovery:recover-one"))
        #expect(fixture.events.values.contains("mutation:recover-one"))
        #expect(context.recoveredTransactionIDs.keys.sorted() == ["recover-one"])
        #expect(try context.plans.read(id: "recover-one").machineID == "recover-one")
        #expect(readiness.planningTransactionAvailable)
    }

    @Test("corrupt planning journal prevents readiness")
    func corruptJournalFailsClosed() throws {
        let fixture = try CompositionFixture(ids: ["corrupt-one"])
        let directory = fixture.root + "/corrupt-one"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("not-json\n".utf8).write(
            to: URL(fileURLWithPath: directory + "/planning-transaction-v1.json")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: directory + "/planning-transaction-v1.json"
        )

        guard case let .unavailable(failure) = fixture.factory().resolve() else {
            Issue.record("Expected corrupt recovery to fail closed")
            return
        }
        #expect(failure.code == .recoveryFailed)
        #expect(failure.machineID == "corrupt-one")
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: "corrupt-one")
        }
    }

    @Test("recovery is isolated per workspace and uses exact repository roots")
    func crossWorkspaceIsolationAndIdentity() throws {
        let ids = ["recover-a", "recover-b"]
        let fixture = try CompositionFixture(ids: ids)
        try fixture.interrupt("recover-b", at: .workspacePublished)
        try fixture.interrupt("recover-a", at: .candidateJournalPublished)

        let context = try readyContext(fixture.factory().resolve())
        #expect(context.recoveredTransactionIDs.keys.sorted() == ids)
        #expect(fixture.recovery.requestedIDs == ids)
        #expect(context.identity.stateDirectory == fixture.root)
        #expect(context.workspaces.root == context.identity.workspaceRepositoryRoot)
        #expect(context.plans.root == context.identity.resolvedPlanRepositoryRoot)
        #expect(context.artifactAuthority.root == context.identity.artifactAuthorityRoot)
        #expect(context.resourceLedger.root
            == context.identity.resourceAdmissionLedgerRoot)
        for id in ids {
            #expect(try context.workspaces.read(id: id).identity.id == id)
            #expect(try context.plans.read(id: id).machineID == id)
        }
        #expect(try context.resourceLedger.snapshot().leases.count == 2)
    }

    @Test("production recovery replays only the exact private machine authority")
    func productionRecoveryReplaysExactMachineAuthority() throws {
        let machineID = "production-recovery-a"
        let fixture = try CompositionFixture(ids: [machineID])
        try fixture.interrupt(machineID, at: .planBindingCommitted)
        try fixture.writeMachineAuthority(machineID)

        let provider = DoryDaemonVirtualMachineProductionRecoveryProvider(
            stateDirectory: fixture.root
        )
        let context = try readyContext(fixture.factory(
            recoveryProvider: provider
        ).resolve())

        #expect(context.recoveredTransactionIDs.keys.sorted() == [machineID])
        #expect(try context.plans.read(id: machineID).machineID == machineID)
    }

    @Test("stale private machine authority cannot replay a durable journal")
    func staleProductionMachineAuthorityFailsClosed() throws {
        let machineID = "stale-production-recovery-b"
        let fixture = try CompositionFixture(ids: [machineID])
        try fixture.interrupt(machineID, at: .planBindingCommitted)
        try fixture.writeMachineAuthority(machineID) { machine in
            machine.cpuCount += 1
        }

        let provider = DoryDaemonVirtualMachineProductionRecoveryProvider(
            stateDirectory: fixture.root
        )
        guard case let .unavailable(failure) = fixture.factory(
            recoveryProvider: provider
        ).resolve() else {
            Issue.record("Expected stale private authority to fail closed")
            return
        }
        #expect(failure.code == .recoveryFailed)
        #expect(failure.machineID == machineID)
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: machineID)
        }
    }

    private func readyContext(
        _ readiness: DoryDaemonVirtualMachineProductionPlanningReadiness
    ) throws -> DoryDaemonVirtualMachineProductionPlanningContext {
        guard case let .ready(context) = readiness else {
            Issue.record("Expected ready production planning composition")
            throw CompositionTestError.notReady
        }
        return context
    }
}

private final class CompositionFixture: @unchecked Sendable {
    let root: String
    let events = CompositionEvents()
    let registry: BackendRegistry
    let backend: RawHVLinuxMachineBackend
    let workspaces: DoryWorkspaceRepository
    let plans: DoryResolvedMachinePlanRepository
    let ledger: DoryVirtualMachineResourceAdmissionLedger
    let trust: CompositionTrust
    let authorizer: CompositionMutationAuthority
    let recovery: CompositionRecovery
    private let requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest]

    init(ids: [String]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-production-planning-composition-\(UUID().uuidString)"
        ).standardizedFileURL.path
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        backend = RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: MachineBackendCompatibilityOperations(
                start: { id in MachineBackendRuntimeObservation(machineID: id, state: .running) },
                stop: { request in
                    MachineBackendRuntimeObservation(machineID: request.machineID, state: .stopped)
                },
                pause: { request in
                    MachineBackendRuntimeObservation(machineID: request.machineID, state: .paused)
                },
                resume: { request in
                    MachineBackendRuntimeObservation(machineID: request.machineID, state: .running)
                }
            ),
            executableIsAvailable: { _ in true }
        )
        registry = try BackendRegistry(backends: [backend])
        workspaces = DoryWorkspaceRepository(root: root)
        plans = DoryResolvedMachinePlanRepository(root: root)
        ledger = DoryVirtualMachineResourceAdmissionLedger(
            root: root + "/.resource-admissions"
        )
        var requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest] = [:]
        var snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot] = [:]
        for id in ids {
            let prepared = try Self.requestAndSnapshot(id: id, root: root)
            requests[id] = prepared.request
            snapshots[id] = prepared.snapshot
        }
        self.requests = requests
        trust = CompositionTrust(snapshots: snapshots)
        authorizer = CompositionMutationAuthority(events: events)
        recovery = CompositionRecovery(requests: requests, events: events)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func factory(
        hasMutationAuthority: Bool = true,
        hasRecoveryProvider: Bool = true,
        recoveryProvider:
            (any DoryDaemonVirtualMachinePlanningRecoveryProviding)? = nil
    ) -> DoryDaemonVirtualMachineProductionPlanningCompositionFactory {
        let selectedRecovery: (any DoryDaemonVirtualMachinePlanningRecoveryProviding)?
        if hasRecoveryProvider {
            selectedRecovery = recoveryProvider ?? recovery
        } else {
            selectedRecovery = nil
        }
        return DoryDaemonVirtualMachineProductionPlanningCompositionFactory(
            stateDirectory: root,
            backends: [backend],
            mutationAuthority: hasMutationAuthority ? authorizer : nil,
            recoveryProvider: selectedRecovery,
            capabilityPlanner: CompositionCapabilityPlanner(),
            inventoryBuilder: { [trust] artifactAuthority, resourceLedger in
                _ = artifactAuthority
                _ = resourceLedger
                return trust
            }
        )
    }

    func writeMachineAuthority(
        _ id: String,
        mutate: (inout DoryMachineConfiguration) -> Void = { _ in }
    ) throws {
        var machine = try #require(requests[id]).planning.machine
        mutate(&machine)
        let directory = root + "/" + id
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let path = directory + "/machine.json"
        try encoder.encode(machine).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    func interrupt(
        _ id: String,
        at stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
    ) throws {
        let fault = CompositionFault(stage)
        let coordinator = DoryDaemonVirtualMachinePlanningTransactionCoordinator(
            stateDirectory: root,
            registry: registry,
            trust: trust,
            mutationAuthority: authorizer,
            workspaces: workspaces,
            plans: plans,
            ledger: ledger,
            capabilityPlanner: CompositionCapabilityPlanner(),
            now: { 1_700_000_000_100 },
            faultInjector: fault.inject
        )
        do {
            _ = try coordinator.resolveReserveAndPublish(try #require(requests[id]))
            Issue.record("Expected injected transaction interruption")
        } catch is CompositionInjectedFailure {}
    }

    private static func requestAndSnapshot(
        id: String,
        root: String
    ) throws -> (
        request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) {
        let mediaReference = DoryVMResolverReference(
            namespace: "artifact", identifier: "\(id)-runtime"
        )
        let diskReference = DoryVMResolverReference(
            namespace: "artifact", identifier: "\(id)-disk"
        )
        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 4 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: id, name: id),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system", role: .system,
                    kind: .installedLinuxBootBundle,
                    source: .bundledByDory,
                    artifact: mediaReference,
                    removable: false
                )],
                order: ["system"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .required, backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.none]),
            resources: resources,
            storage: [DoryVMStorageAttachment(
                id: "system-disk", role: .system, artifact: diskReference,
                capacityBytes: resources.diskBytes
            )],
            audio: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            input: DoryVMInputConfiguration(keyboardEnabled: false, pointerEnabled: false),
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_700_000_000_000,
                updatedAtUnixMilliseconds: 1_700_000_000_000
            )
        )
        let bootBundlePath = root + "/\(id).installed-linux.boot"
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data("composition-kernel-\(id)".utf8),
                initrd: Data("composition-initrd-\(id)".utf8),
                kernelISOPath: "/boot/vmlinuz",
                initrdISOPath: "/boot/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: bootBundlePath
        )
        let machine = DoryMachineConfiguration(
            id: id,
            kernelPath: bootBundlePath,
            rootfsPath: "/fixture/\(id).raw",
            bootMode: .efi,
            displayMode: .desktop
        )
        let media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: compositionDigest(id.last ?? "a")
        )
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let evidence = DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: compositionQualificationIdentity(media),
            qualificationReportSHA256: compositionDigest("b"),
            signingKeyID: "dory-test-key",
            qualificationFormatVersion: 1,
            guest: definition.guest,
            bootMediaKind: media.kind,
            immutableArtifactSHA256: media.artifactSHA256,
            backend: .doryHypervisor,
            backendRuntimeBuildID: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            graphics: .none,
            devices: devices
        )
        let hostQualification = DoryResolvedHostQualificationEvidence(
            qualificationIdentity: evidence.qualificationIdentity,
            qualificationReportSHA256: evidence.qualificationReportSHA256,
            hostHardwareModelIdentifier: "Mac16.1",
            hostOperatingSystemBuild: "26A5406c",
            backend: .doryHypervisor,
            backendRuntimeBuildIdentifier: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            qualifierIdentifier: "dory-test-qualifier",
            qualifierVersion: 1
        )
        let snapshot = DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: compositionHostFacts(),
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: mediaReference, media: media
            ),
            launchArtifacts: [
                resolvedMutableStorageLaunchArtifact(
                    reference: diskReference,
                    source: .userProvided,
                    identifier: "system-disk"
                ),
                resolvedBootLaunchArtifacts(
                    reference: mediaReference,
                    media: media,
                    identifier: "system"
                )[0],
            ],
            backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: .doryHypervisor,
                runtimeBuildIdentifier: "raw-runtime-1",
                components: [DoryResolvedBackendComponentEvidence(
                    componentIdentifier: "dory-hv",
                    buildIdentifier: "raw-runtime-1",
                    artifactSHA256: compositionDigest("c")
                )],
                hostQualification: hostQualification
            )],
            resourceAdmission: compositionAdmission(resources)
        )
        let planning = DoryDaemonVirtualMachinePlanningRequest(
            definition: definition,
            canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                .canonicalDefinitionData(definition),
            machine: machine,
            publication: .create
        )
        return (
            DoryDaemonVirtualMachinePlanningTransactionRequest(
                planning: planning,
                workspacePublication: .create
            ),
            snapshot
        )
    }
}

private final class CompositionTrust:
    DoryDaemonVirtualMachineTrustInventory,
    DoryDaemonVirtualMachinePlanningTrustPreparing,
    @unchecked Sendable
{
    let snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot]
    init(snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot]) {
        self.snapshots = snapshots
    }

    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        let base = try #require(snapshots[request.machineID])
        return DoryDaemonVirtualMachinePlanningTrustPreparation(
            hostResources: compositionHostResources(),
            snapshot: { admission in
                var snapshot = base
                snapshot.resourceAdmission = admission
                return snapshot
            },
            publicationAuthorization:
                DoryDaemonVirtualMachinePlanningPublicationAuthorization {}
        )
    }

    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        try #require(snapshots[request.machineID])
    }

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        try #require(snapshots[request.machineID])
    }
}

private final class CompositionRecovery:
    DoryDaemonVirtualMachinePlanningRecoveryProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest]
    private let events: CompositionEvents
    private var storage: [String] = []

    init(
        requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest],
        events: CompositionEvents
    ) {
        self.requests = requests
        self.events = events
    }

    var requestedIDs: [String] { lock.withLock { storage } }

    func recoveryRequest(
        for descriptor: DoryDaemonVirtualMachinePlanningRecoveryDescriptor
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionRequest? {
        let machineID = descriptor.machineID
        lock.withLock { storage.append(machineID) }
        events.append("recovery:\(machineID)")
        guard let request = requests[machineID], descriptor.matches(request) else {
            return nil
        }
        return request
    }
}

private final class CompositionMutationAuthority:
    DoryDaemonVirtualMachinePlanningMutationAuthorizing, @unchecked Sendable
{
    private let events: CompositionEvents
    init(events: CompositionEvents) { self.events = events }

    func acquirePlanningMutationFence(
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws -> DoryDaemonVirtualMachinePlanningMutationFence {
        guard machine.id == definition.identity.id, !canonicalDefinitionData.isEmpty else {
            throw CompositionTestError.invalidAuthority
        }
        events.append("mutation:\(machine.id)")
        return DoryDaemonVirtualMachinePlanningMutationFence(
            authority: DoryDaemonVirtualMachinePlanningMachineAuthority(
                machineID: machine.id,
                legacyConfigurationSHA256: compositionDigest("e"),
                migrationFactsSHA256: compositionDigest("f"),
                sourceDefinitionRevision: definition.lifecycle.revision,
                sourceDefinitionSHA256:
                    DoryDaemonVirtualMachinePlanningCoordinator.sha256(
                        canonicalDefinitionData
                    ),
                runtimeIdentitySHA256: compositionDigest("a")
            ),
            retainedAuthority: machine.id,
            validation: {}
        )
    }
}

private struct CompositionCapabilityPlanner: DoryDaemonVirtualMachineCapabilityPlanning {
    func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult {
        let capabilityRequest = DoryVirtualMachineCapabilityRequest(
            guest: request.guest,
            bootMedia: request.bootMedia,
            backend: .doryHypervisor,
            graphics: request.acceptableGraphics.first ?? .none,
            devices: request.devices,
            virtualHardwareABIVersion: request.virtualHardwareABIVersion
        )
        let descriptor = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion:
                DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: capabilityRequest,
            availability: DoryCapabilityAvailability(
                supportTier: .supported, state: .available
            ),
            resolvedDevices: request.devices,
            runtimeQualificationEvidence: DoryVirtualMachineRuntimeQualificationEvidence(
                qualificationIdentity: compositionQualificationIdentity(request.bootMedia),
                qualificationReportSHA256: compositionDigest("b"),
                signingKeyID: "dory-test-key",
                qualificationFormatVersion: 1,
                guest: request.guest,
                bootMediaKind: request.bootMedia.kind,
                immutableArtifactSHA256: request.bootMedia.artifactSHA256,
                backend: .doryHypervisor,
                backendRuntimeBuildID: "raw-runtime-1",
                virtualHardwareABIVersion: request.virtualHardwareABIVersion,
                graphics: capabilityRequest.graphics,
                devices: request.devices
            )
        )
        _ = inventory
        return DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: descriptor,
            evaluatedDescriptors: [descriptor],
            failure: nil
        )
    }
}

private final class CompositionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class CompositionFault: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage?
    init(_ stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage) {
        self.stage = stage
    }
    func inject(
        _ current: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
    ) throws {
        try lock.withLock {
            if stage == current {
                stage = nil
                throw CompositionInjectedFailure()
            }
        }
    }
}

private enum CompositionTestError: Error { case notReady, invalidAuthority }
private struct CompositionInjectedFailure: Error {}

private func compositionHostResources() -> DoryVMHostResources {
    DoryVMHostResources(
        logicalCPUCount: 12,
        physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        freeStorageBytes: 512 * 1_024 * 1_024 * 1_024
    )
}

private func compositionHostFacts() -> DoryAppleSiliconHostFacts {
    DoryAppleSiliconHostFacts(
        macOSMajorVersion: 26,
        virtualizationFrameworkAvailable: true,
        hypervisorFrameworkAvailable: true,
        doryHypervisorAvailable: true,
        qemuHypervisorFrameworkAvailable: false,
        windowsUEFIFirmwareAvailable: false,
        windowsSecureBootAvailable: false,
        windowsSBSADeviceModelAvailable: false,
        virtualTPM20Available: false,
        windowsGuestDrivers: DoryWindowsGuestDriverFacts(
            storageAvailable: false, networkAvailable: false,
            displayAvailable: false, inputAvailable: false
        ),
        macOSGuestVirtualizationSupported: false,
        macOSRestoreImageInstallationSupported: false,
        doryMacOSBackendAvailable: false,
        doryMacOSBackendQualified: false,
        metalAvailable: true,
        doryAcceleratedRendererAvailable: true,
        runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext(
            virtualHardwareABIVersion: 1,
            doryHypervisorRuntimeBuildID: "raw-runtime-1",
            virtualizationFrameworkAdapterBuildID: "vz-runtime-1",
            qemuRuntimeBuildID: ""
        )
    )
}

private func compositionAdmission(
    _ resources: DoryVMResourceRequest
) -> DoryResolvedMachineResourceAdmissionEvidence {
    DoryResolvedMachineResourceAdmissionEvidence(
        admittedVirtualCPUCount: resources.virtualCPUCount,
        admittedMemoryBytes: resources.memoryBytes,
        admittedStorageBytes: resources.diskBytes,
        hostLogicalCPUCount: 12,
        hostPhysicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        hostFreeStorageBytes: 512 * 1_024 * 1_024 * 1_024,
        existingVirtualCPUCommitment: 0,
        existingMemoryCommitmentBytes: 0,
        existingStorageReservationBytes: 0,
        hostReservedLogicalCPUCount: 2,
        hostReservedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        hostReservedStorageBytes: 32 * 1_024 * 1_024 * 1_024,
        admissionIdentity: "composition-dummy-admission",
        admissionReportSHA256: compositionDigest("d"),
        assessorIdentifier: DoryVirtualMachineResourceAdmissionLedger.assessorIdentifier,
        assessorVersion: DoryVirtualMachineResourceAdmissionLedger.assessorVersion
    )
}

private func compositionDigest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}

private func compositionQualificationIdentity(_ media: DoryBootMedia) -> String {
    "qualification-\((media.artifactSHA256 ?? "missing").prefix(12))"
}
