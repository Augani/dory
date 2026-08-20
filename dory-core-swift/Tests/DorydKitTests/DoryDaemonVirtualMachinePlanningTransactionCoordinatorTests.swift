import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Daemon VM planning publication transaction")
struct DoryDaemonVirtualMachinePlanningTransactionCoordinatorTests {
    @Test("reserve bind publish is exact and restart-idempotent")
    func successAndIdempotence() throws {
        let fixture = try TransactionFixture()
        let first = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        let second = try fixture.coordinator().resolveReserveAndPublish(fixture.request())

        #expect(first.transactionID == second.transactionID)
        #expect(first.planning.resolvedPlan == second.planning.resolvedPlan)
        #expect(try fixture.workspaces.read(id: fixture.definition.identity.id)
            == fixture.definition)
        #expect(try fixture.plans.read(id: fixture.definition.identity.id)
            == first.planning.resolvedPlan)
        let lease = try #require(try fixture.ledger.snapshot().leases.first)
        #expect(lease.state == .starting)
        #expect(lease.boundPlanSHA256 == first.planning.resolvedPlanSHA256)
    }

    @Test("crash after workspace publication resumes exact candidate bytes")
    func workspacePublicationRecovery() throws {
        let fixture = try TransactionFixture()
        let fault = TransactionFault(.workspacePublished)
        do {
            _ = try fixture.coordinator(fault: fault).resolveReserveAndPublish(fixture.request())
            Issue.record("Expected injected crash")
        } catch is TransactionInjectedFailure {}

        #expect(try fixture.workspaces.read(id: fixture.definition.identity.id)
            == fixture.definition)
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: fixture.definition.identity.id)
        }
        let recovered = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        #expect(try fixture.plans.read(id: fixture.definition.identity.id)
            == recovered.planning.resolvedPlan)
        #expect(try #require(try fixture.ledger.snapshot().leases.first).boundPlanSHA256
            == recovered.planning.resolvedPlanSHA256)
    }

    @Test("crash after bind adopts exact bound lease without a second reservation")
    func bindRecovery() throws {
        let fixture = try TransactionFixture()
        let fault = TransactionFault(.planBindingCommitted)
        do {
            _ = try fixture.coordinator(fault: fault).resolveReserveAndPublish(fixture.request())
            Issue.record("Expected injected crash")
        } catch is TransactionInjectedFailure {}
        let before = try #require(try fixture.ledger.snapshot().leases.first)
        #expect(before.boundPlanSHA256 != nil)

        let result = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        let after = try #require(try fixture.ledger.snapshot().leases.first)
        #expect(after.leaseID == before.leaseID)
        #expect(after.boundPlanSHA256 == result.planning.resolvedPlanSHA256)
        #expect(try fixture.ledger.snapshot().leases.count == 1)
    }

    @Test("bound recovery ignores volatile free-storage samples without readmission")
    func boundRecoveryWithChangedFreeStorage() throws {
        let fixture = try TransactionFixture()
        do {
            _ = try fixture.coordinator(fault: TransactionFault(.planBindingCommitted))
                .resolveReserveAndPublish(fixture.request())
            Issue.record("Expected injected crash")
        } catch is TransactionInjectedFailure {}
        let before = try #require(try fixture.ledger.snapshot().leases.first)
        fixture.trust.updateFreeStorage(before.hostFacts.freeStorageBytes / 2)

        let recovered = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        #expect(recovered.lease.leaseID == before.leaseID)
        #expect(recovered.lease.leaseRevision == before.leaseRevision)
        #expect(recovered.lease.hostFacts == before.hostFacts)
        #expect(try fixture.ledger.snapshot().leases.count == 1)
    }

    @Test("stale publication evidence retains bound capacity and publishes nothing")
    func staleTrustFailsClosed() throws {
        let fixture = try TransactionFixture(rejectPublication: true)
        do {
            _ = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
            Issue.record("Expected stale trust rejection")
        } catch let failure as DoryDaemonVirtualMachinePlanningTransactionFailure {
            #expect(failure.code == .publicationAuthorizationRejected)
        }
        let lease = try #require(try fixture.ledger.snapshot().leases.first)
        #expect(lease.state == .starting)
        #expect(lease.boundPlanSHA256 != nil)
        #expect(throws: DoryWorkspaceRepositoryError.self) {
            _ = try fixture.workspaces.read(id: fixture.definition.identity.id)
        }
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: fixture.definition.identity.id)
        }
        fixture.trust.rejectPublication = false
        let recovered = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        #expect(recovered.lease.leaseID == lease.leaseID)
        #expect(recovered.lease.boundPlanSHA256 == lease.boundPlanSHA256)
        #expect(try fixture.plans.read(id: fixture.definition.identity.id)
            == recovered.planning.resolvedPlan)
    }

    @Test("two coordinator instances serialize one workspace transaction")
    func concurrentInstances() async throws {
        let fixture = try TransactionFixture()
        let results = TransactionResultBox()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        let value = try fixture.coordinator()
                            .resolveReserveAndPublish(fixture.request())
                        results.append(.success(value.transactionID))
                    } catch {
                        results.append(.failure(error))
                    }
                }
            }
        }
        let values = results.values
        #expect(values.count == 2)
        let ids = try values.map { try $0.get() }
        #expect(Set(ids).count == 1)
        #expect(try fixture.ledger.snapshot().leases.count == 1)
    }

    @Test("stale create source is rejected before resource reservation")
    func staleSourceBeforeReserve() throws {
        let fixture = try TransactionFixture()
        try fixture.workspaces.create(fixture.definition)
        do {
            _ = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
            Issue.record("Expected create conflict")
        } catch let failure as DoryDaemonVirtualMachinePlanningTransactionFailure {
            #expect(failure.code == .transactionConflict)
        }
        #expect(try fixture.ledger.snapshot().leases.isEmpty)
    }

    @Test("changed machine authority cannot join an existing transaction")
    func changedMachineAuthority() throws {
        let fixture = try TransactionFixture()
        let fault = TransactionFault(.preparedJournalPublished)
        do {
            _ = try fixture.coordinator(fault: fault).resolveReserveAndPublish(fixture.request())
            Issue.record("Expected injected crash")
        } catch is TransactionInjectedFailure {}
        fixture.mutationAuthority.authoritySHA256 = transactionDigest("f")
        do {
            _ = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
            Issue.record("Expected transaction conflict")
        } catch let failure as DoryDaemonVirtualMachinePlanningTransactionFailure {
            #expect(failure.code == .transactionConflict)
        }
        #expect(try fixture.ledger.snapshot().leases.isEmpty)
    }

    @Test("every committed publication boundary recovers one byte-exact plan and lease")
    func publicationBoundaryMatrix() throws {
        let stages: [DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage] = [
            .preparedJournalPublished,
            .resourceReservationCommitted,
            .reservedJournalPublished,
            .candidateJournalPublished,
            .planBindingCommitted,
            .boundJournalPublished,
            .publicationAuthorized,
            .workspacePublished,
            .workspaceJournalPublished,
            .planPublished,
            .planJournalPublished,
            .completeJournalPublished,
        ]
        for stage in stages {
            let fixture = try TransactionFixture()
            let fault = TransactionFault(stage)
            do {
                _ = try fixture.coordinator(fault: fault)
                    .resolveReserveAndPublish(fixture.request())
                Issue.record("Expected injected crash at \(stage)")
            } catch is TransactionInjectedFailure {}
            let recovered = try fixture.coordinator()
                .resolveReserveAndPublish(fixture.request())
            #expect(try fixture.workspaces.read(id: fixture.definition.identity.id)
                == fixture.definition)
            #expect(try fixture.plans.read(id: fixture.definition.identity.id)
                == recovered.planning.resolvedPlan)
            let leases = try fixture.ledger.snapshot().leases
            #expect(leases.count == 1)
            #expect(leases.first?.boundPlanSHA256
                == recovered.planning.resolvedPlanSHA256)
        }
    }

    @Test("completed transaction rejects later plan authority substitution")
    func completedTamper() throws {
        let fixture = try TransactionFixture()
        let completed = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
        var replacement = completed.planning.resolvedPlan
        replacement.planRevision = 2
        replacement.updatedAtUnixMilliseconds += 1
        try fixture.plans.replace(replacement, expectedPlanRevision: 1)
        do {
            _ = try fixture.coordinator().resolveReserveAndPublish(fixture.request())
            Issue.record("Expected completed authority mismatch")
        } catch let failure as DoryDaemonVirtualMachinePlanningTransactionFailure {
            #expect(failure.code == .recoveryRequired)
        }
        #expect(try fixture.ledger.snapshot().leases.count == 1)
    }

    @Test("expired unbound and lifecycle-proven bound planning leases recover exactly")
    func expiryRecovery() throws {
        for stage in [
            DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
                .candidateJournalPublished,
            .planBindingCommitted,
        ] {
            let clock = TransactionClock(50_000)
            let fixture = try TransactionFixture(clock: clock)
            do {
                _ = try fixture.coordinator(fault: TransactionFault(stage))
                    .resolveReserveAndPublish(fixture.request(leaseDuration: 100))
                Issue.record("Expected injected crash")
            } catch is TransactionInjectedFailure {}
            clock.advance(100)
            let expired = try #require(try fixture.ledger.snapshot().leases.first)
            #expect(expired.state == (stage == .planBindingCommitted
                ? .recoveryRequired : .stopped))
            let recovered = try fixture.coordinator()
                .resolveReserveAndPublish(fixture.request(leaseDuration: 100))
            #expect(recovered.lease.leaseID == expired.leaseID)
            #expect(recovered.lease.state == .starting)
            #expect(recovered.lease.boundPlanSHA256
                == recovered.planning.resolvedPlanSHA256)
        }
    }
}

private final class TransactionFixture: @unchecked Sendable {
    let root: String
    let definition: DoryVirtualMachineDefinition
    let machine: DoryMachineConfiguration
    let media: DoryBootMedia
    let capability: DoryVirtualMachineCapabilityDescriptor
    let resources: DoryVMHostResources
    let workspaces: DoryWorkspaceRepository
    let plans: DoryResolvedMachinePlanRepository
    let ledger: DoryVirtualMachineResourceAdmissionLedger
    let registry: BackendRegistry
    let trust: TransactionTrust
    let mutationAuthority = TransactionMutationAuthority()

    init(
        rejectPublication: Bool = false,
        clock: TransactionClock? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-planning-tx-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let bootArtifact = DoryVMResolverReference(
            namespace: "artifact", identifier: "ubuntu-runtime"
        )
        let diskArtifact = DoryVMResolverReference(
            namespace: "artifact", identifier: "ubuntu-disk"
        )
        let requested = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 8 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: "transaction-linux", name: "Linux"),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system", role: .system,
                    kind: .installedLinuxBootBundle, source: .bundledByDory,
                    artifact: bootArtifact, removable: false
                )],
                order: ["system"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .required, backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.none]),
            resources: requested,
            storage: [DoryVMStorageAttachment(
                id: "system-disk", role: .system, artifact: diskArtifact,
                capacityBytes: requested.diskBytes
            )],
            audio: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            input: DoryVMInputConfiguration(keyboardEnabled: false, pointerEnabled: false),
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_700_000_000_000,
                updatedAtUnixMilliseconds: 1_700_000_000_000
            )
        )
        machine = DoryMachineConfiguration(
            id: definition.identity.id,
            kernelPath: "/fixture/direct-kernel",
            rootfsPath: "/fixture/linux.raw",
            bootMode: .linuxKernel,
            displayMode: .desktop
        )
        media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: transactionDigest("a")
        )
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let runtimeEvidence = DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: "runtime-qualification-1",
            qualificationReportSHA256: transactionDigest("b"),
            signingKeyID: "dory-runtime-1",
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
        capability = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: DoryVirtualMachineCapabilityRequest(
                guest: definition.guest, bootMedia: media,
                backend: .doryHypervisor, graphics: .none, devices: devices
            ),
            availability: DoryCapabilityAvailability(
                supportTier: .supported, state: .available
            ),
            resolvedDevices: devices,
            runtimeQualificationEvidence: runtimeEvidence
        )
        resources = DoryVMHostResources(
            logicalCPUCount: 12,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            freeStorageBytes: 512 * 1_024 * 1_024 * 1_024
        )
        let snapshot = DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: transactionHostFacts(),
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: bootArtifact, media: media
            ),
            backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: .doryHypervisor,
                runtimeBuildIdentifier: "raw-runtime-1",
                components: [DoryResolvedBackendComponentEvidence(
                    componentIdentifier: "dory-hv",
                    buildIdentifier: "raw-runtime-1",
                    artifactSHA256: transactionDigest("c")
                )],
                hostQualification: transactionHostQualification()
            )],
            resourceAdmission: transactionDummyAdmission(requested)
        )
        trust = TransactionTrust(
            hostResources: resources,
            snapshot: snapshot,
            rejectPublication: rejectPublication
        )
        workspaces = DoryWorkspaceRepository(root: root)
        plans = DoryResolvedMachinePlanRepository(root: root)
        if let clock {
            ledger = DoryVirtualMachineResourceAdmissionLedger(
                root: root + "/.resource-admissions",
                now: clock.read
            )
        } else {
            ledger = DoryVirtualMachineResourceAdmissionLedger(
                root: root + "/.resource-admissions"
            )
        }
        registry = try BackendRegistry(backends: [RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: MachineBackendCompatibilityOperations(
                start: { id in MachineBackendRuntimeObservation(machineID: id, state: .running) },
                stop: { id in MachineBackendRuntimeObservation(machineID: id, state: .stopped) }
            ),
            executableIsAvailable: { _ in true }
        )])
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func request(
        leaseDuration: Int64 = 120_000
    ) -> DoryDaemonVirtualMachinePlanningTransactionRequest {
        DoryDaemonVirtualMachinePlanningTransactionRequest(
            planning: DoryDaemonVirtualMachinePlanningRequest(
                definition: definition,
                canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(definition),
                machine: machine,
                publication: .create
            ),
            workspacePublication: .create,
            startingLeaseDurationMilliseconds: leaseDuration
        )
    }

    func coordinator(
        fault: TransactionFault? = nil
    ) -> DoryDaemonVirtualMachinePlanningTransactionCoordinator {
        if let fault {
            return DoryDaemonVirtualMachinePlanningTransactionCoordinator(
                stateDirectory: root,
                registry: registry,
                trust: trust,
                mutationAuthority: mutationAuthority,
                workspaces: workspaces,
                plans: plans,
                ledger: ledger,
                capabilityPlanner: TransactionPlanner(capability: capability),
                now: { 1_700_000_000_100 },
                faultInjector: fault.inject
            )
        }
        return DoryDaemonVirtualMachinePlanningTransactionCoordinator(
            stateDirectory: root,
            registry: registry,
            trust: trust,
            mutationAuthority: mutationAuthority,
            workspaces: workspaces,
            plans: plans,
            ledger: ledger,
            capabilityPlanner: TransactionPlanner(capability: capability),
            now: { 1_700_000_000_100 }
        )
    }
}

private final class TransactionTrust:
    DoryDaemonVirtualMachinePlanningTrustPreparing, @unchecked Sendable
{
    private let lock = NSLock()
    private var storedHostResources: DoryVMHostResources
    let trustedSnapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
    private var storedRejectPublication: Bool

    var rejectPublication: Bool {
        get { lock.withLock { storedRejectPublication } }
        set { lock.withLock { storedRejectPublication = newValue } }
    }

    init(
        hostResources: DoryVMHostResources,
        snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot,
        rejectPublication: Bool
    ) {
        storedHostResources = hostResources
        trustedSnapshot = snapshot
        storedRejectPublication = rejectPublication
    }

    func updateFreeStorage(_ freeStorageBytes: UInt64) {
        lock.withLock {
            storedHostResources = DoryVMHostResources(
                logicalCPUCount: storedHostResources.logicalCPUCount,
                physicalMemoryBytes: storedHostResources.physicalMemoryBytes,
                freeStorageBytes: freeStorageBytes,
                admittedVirtualCPUCount: storedHostResources.admittedVirtualCPUCount,
                admittedMemoryBytes: storedHostResources.admittedMemoryBytes,
                reservedStorageBytes: storedHostResources.reservedStorageBytes
            )
        }
    }

    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        _ = request
        let currentHostResources = lock.withLock { storedHostResources }
        return DoryDaemonVirtualMachinePlanningTrustPreparation(
            hostResources: currentHostResources,
            snapshot: { admission in
                var snapshot = self.trustedSnapshot
                snapshot.resourceAdmission = admission
                return snapshot
            },
            publicationAuthorization:
                DoryDaemonVirtualMachinePlanningPublicationAuthorization {
                    if self.rejectPublication { throw TransactionInjectedFailure() }
                }
        )
    }
}

private final class TransactionMutationAuthority:
    DoryDaemonVirtualMachinePlanningMutationAuthorizing, @unchecked Sendable
{
    private let lock = NSLock()
    private var storedAuthoritySHA256 = transactionDigest("e")
    var authoritySHA256: String {
        get { lock.withLock { storedAuthoritySHA256 } }
        set { lock.withLock { storedAuthoritySHA256 = newValue } }
    }

    func acquirePlanningMutationFence(
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws -> DoryDaemonVirtualMachinePlanningMutationFence {
        guard machine.id == definition.identity.id, !canonicalDefinitionData.isEmpty else {
            throw TransactionInjectedFailure()
        }
        let digest = authoritySHA256
        return DoryDaemonVirtualMachinePlanningMutationFence(
            authoritySHA256: digest,
            retainedAuthority: digest,
            validation: {}
        )
    }
}

private struct TransactionPlanner: DoryDaemonVirtualMachineCapabilityPlanning {
    let capability: DoryVirtualMachineCapabilityDescriptor
    func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult {
        _ = request
        _ = inventory
        return DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: capability,
            evaluatedDescriptors: [capability],
            failure: nil
        )
    }
}

private final class TransactionFault: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage?
    init(_ stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage) {
        self.stage = stage
    }
    func inject(
        _ value: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
    ) throws {
        try lock.withLock {
            if stage == value {
                stage = nil
                throw TransactionInjectedFailure()
            }
        }
    }
}

private final class TransactionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<String, Error>] = []
    var values: [Result<String, Error>] { lock.withLock { storage } }
    func append(_ value: Result<String, Error>) { lock.withLock { storage.append(value) } }
}

private struct TransactionInjectedFailure: Error {}

private final class TransactionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var read: @Sendable () -> Int64 { { [self] in lock.withLock { value } } }
    func advance(_ milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

private func transactionHostFacts() -> DoryAppleSiliconHostFacts {
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

private func transactionHostQualification() -> DoryResolvedHostQualificationEvidence {
    DoryResolvedHostQualificationEvidence(
        qualificationIdentity: "runtime-qualification-1",
        qualificationReportSHA256: transactionDigest("b"),
        hostHardwareModelIdentifier: "Mac16.1",
        hostOperatingSystemBuild: "26A5406c",
        backend: .doryHypervisor,
        backendRuntimeBuildIdentifier: "raw-runtime-1",
        virtualHardwareABIVersion: 1,
        qualifierIdentifier: "dory-host-qualifier",
        qualifierVersion: 1
    )
}

private func transactionDummyAdmission(
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
        admissionIdentity: "dummy-admission",
        admissionReportSHA256: transactionDigest("d"),
        assessorIdentifier: "dory.resource-admission-ledger",
        assessorVersion: 1
    )
}

private func transactionDigest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}
