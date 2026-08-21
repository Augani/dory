import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Daemon virtual-machine runtime planning")
struct DoryDaemonVirtualMachineRuntimePlanningTests {
    @Test("definition networking maps exactly into capability planning")
    func definitionNetworkingMapsExactly() throws {
        let fixture = try Fixture()
        var definition = fixture.definition
        definition.networkMode = .disconnected

        let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition)

        #expect(devices.networkAttachment == .disconnected)
        #expect(devices.display == DoryVirtualMachineDisplayCapabilityRequest(
            widthPixels: definition.display.widthPixels,
            heightPixels: definition.display.heightPixels,
            backingScaleFactor: definition.display.backingScaleFactor,
            guestUIScaleFactor: definition.display.guestUIScaleFactor
        ))
        #expect(devices.audioInput == definition.audio.inputEnabled)
        #expect(devices.audioOutput == definition.audio.outputEnabled)
        #expect(devices.keyboard == definition.input.keyboardEnabled)
        #expect(devices.pointer == definition.input.pointerEnabled)

        definition.display = .disabled
        #expect(DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition).display == nil)
    }

    @Test("planning constructs persists and exposes an exact plan digest")
    func planningSuccess() throws {
        let fixture = try Fixture()
        let result = try fixture.coordinator.resolveAndPersist(fixture.planningRequest())

        #expect(result.resolvedPlan.validate().isEmpty)
        #expect(result.resolvedPlan.definitionSHA256
            == DoryDaemonVirtualMachinePlanningCoordinator.sha256(fixture.canonicalDefinition))
        #expect(result.resolvedPlanSHA256.count == 64)
        #expect(result.resolvedPlan.launchArtifacts.count == 2)
        #expect(result.resolvedPlan.launchArtifacts.flatMap(\.usages).map(\.kind)
            == [.storage, .boot])
        #expect(result.backendPlan.backend.identity == .doryHypervisor)
        #expect(try fixture.store.read(id: fixture.definition.identity.id) == result.resolvedPlan)
    }

    @Test("canonical definition bytes cannot be substituted")
    func canonicalDefinitionBinding() throws {
        let fixture = try Fixture()
        var request = fixture.planningRequest()
        request.canonicalDefinitionData = Data("not-the-definition".utf8)
        do {
            _ = try fixture.coordinator.resolveAndPersist(request)
            Issue.record("Expected canonical definition rejection")
        } catch let failure as DoryDaemonVirtualMachinePlanningFailure {
            #expect(failure.code == .definitionAuthorityMismatch)
        }
    }

    @Test("planning rejects an adapter that substitutes machine or capability")
    func substitutedBackendPlan() throws {
        let fixture = try Fixture()
        for substitution in [BackendPlanSubstitution.machine, .capability] {
            let registry = try BackendRegistry(backends: [SubstitutingBackend(substitution)])
            let coordinator = DoryDaemonVirtualMachinePlanningCoordinator(
                registry: registry,
                inventory: fixture.inventory,
                plans: FixturePlanStore(),
                capabilityPlanner: FixturePlanner(capability: fixture.capability),
                now: { 1_700_000_000_000 }
            )
            do {
                _ = try coordinator.resolveAndPersist(fixture.planningRequest())
                Issue.record("Expected substituted backend plan rejection")
            } catch let failure as DoryDaemonVirtualMachinePlanningFailure {
                #expect(failure.code == .backendPlanRejected)
            }
        }
    }

    @Test("default planner does not promote missing runtime qualification")
    func defaultPlannerFailsClosed() throws {
        let fixture = try Fixture()
        let request = fixture.plannerRequest
        let result = DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner().plan(
            request,
            inventory: fixture.inventory.snapshot
        )
        #expect(result.selectedDescriptor == nil)
        #expect(result.failure?.code == .noCandidate)
        #expect(result.evaluatedDescriptors.first?.availability.reason?.code
            == .runtimeQualificationUnavailable)
    }

    @Test("create to start maps only the persisted backend without replanning")
    func createToStart() throws {
        let fixture = try Fixture()
        let planned = try fixture.coordinator.resolveAndPersist(fixture.planningRequest())
        let collector = FixtureEvidenceCollector(collection: DoryDaemonVirtualMachineStartEvidenceCollection(
            capability: planned.plannerResult.selectedDescriptor!,
            runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: planned.resolvedPlan)
        ))
        let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
            registry: fixture.registry,
            plans: fixture.store,
            evidenceCollector: collector
        )
        let resolved = try resolver.resolve(DoryDaemonVirtualMachineLaunchPlanRequest(
            definition: fixture.definition,
            canonicalDefinitionData: fixture.canonicalDefinition,
            machine: fixture.machine,
            expectedPlanRevision: planned.resolvedPlan.planRevision
        ))

        #expect(resolved.revalidation.mayStart)
        #expect(resolved.resolvedPlan == planned.resolvedPlan)
        #expect(resolved.resolvedPlanSHA256 == planned.resolvedPlanSHA256)
        #expect(resolved.backendPlan.backend.identity == planned.resolvedPlan.backend)
        #expect(collector.collectionCount == 1)
    }

    @Test("fresh evidence mismatch rejects before backend plan mapping")
    func startEvidenceMismatch() throws {
        let fixture = try Fixture()
        let planned = try fixture.coordinator.resolveAndPersist(fixture.planningRequest())
        var evidence = DoryResolvedMachineRuntimeEvidence(plan: planned.resolvedPlan)
        evidence.backendRuntimeBuildIdentifier = "different-runtime"
        let collector = FixtureEvidenceCollector(collection: DoryDaemonVirtualMachineStartEvidenceCollection(
            capability: planned.plannerResult.selectedDescriptor!,
            runtimeEvidence: evidence
        ))
        let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
            registry: fixture.registry,
            plans: fixture.store,
            evidenceCollector: collector
        )
        do {
            _ = try resolver.resolve(DoryDaemonVirtualMachineLaunchPlanRequest(
                definition: fixture.definition,
                canonicalDefinitionData: fixture.canonicalDefinition,
                machine: fixture.machine,
                expectedPlanRevision: planned.resolvedPlan.planRevision
            ))
            Issue.record("Expected fresh evidence rejection")
        } catch let failure as DoryDaemonVirtualMachineLaunchPlanFailure {
            #expect(failure.code == .staleOrMismatchedPlan)
            #expect(failure.revalidationIssues.contains {
                $0.code == .backendRuntimeBuildMismatch
            })
        }
    }

    @Test("changed storage authority rejects start evidence")
    func storageEvidenceMismatch() throws {
        let fixture = try Fixture()
        let planned = try fixture.coordinator.resolveAndPersist(fixture.planningRequest())
        var evidence = DoryResolvedMachineRuntimeEvidence(plan: planned.resolvedPlan)
        evidence.launchArtifacts[0].authorityRevision += 1
        let collector = FixtureEvidenceCollector(collection:
            DoryDaemonVirtualMachineStartEvidenceCollection(
                capability: planned.plannerResult.selectedDescriptor!,
                runtimeEvidence: evidence
            ))
        let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
            registry: fixture.registry,
            plans: fixture.store,
            evidenceCollector: collector
        )

        #expect(throws: DoryDaemonVirtualMachineLaunchPlanFailure.self) {
            _ = try resolver.resolve(DoryDaemonVirtualMachineLaunchPlanRequest(
                definition: fixture.definition,
                canonicalDefinitionData: fixture.canonicalDefinition,
                machine: fixture.machine,
                expectedPlanRevision: planned.resolvedPlan.planRevision
            ))
        }
    }

    @Test("missing durable plan has a typed launch failure")
    func missingPlan() throws {
        let fixture = try Fixture()
        let resolver = DoryDaemonVirtualMachineLaunchPlanResolver(
            registry: fixture.registry,
            plans: fixture.store,
            evidenceCollector: FixtureEvidenceCollector(error: FixtureError.unavailable)
        )
        do {
            _ = try resolver.resolve(DoryDaemonVirtualMachineLaunchPlanRequest(
                definition: fixture.definition,
                canonicalDefinitionData: fixture.canonicalDefinition,
                machine: fixture.machine,
                expectedPlanRevision: 1
            ))
            Issue.record("Expected missing plan rejection")
        } catch let failure as DoryDaemonVirtualMachineLaunchPlanFailure {
            #expect(failure.code == .planNotFound)
        }
    }
}

private final class Fixture {
    private let root: URL
    let definition: DoryVirtualMachineDefinition
    let canonicalDefinition: Data
    let machine: DoryMachineConfiguration
    let media: DoryBootMedia
    let plannerRequest: DoryVirtualMachineBackendPlanRequest
    let capability: DoryVirtualMachineCapabilityDescriptor
    let store = FixturePlanStore()
    let inventory: FixtureInventory
    let registry: BackendRegistry
    let coordinator: DoryDaemonVirtualMachinePlanningCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-runtime-planning-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let bootBundle = root.appendingPathComponent("installed-linux.boot")
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data("kernel".utf8),
                initrd: Data("initrd".utf8),
                kernelISOPath: "/boot/kernel",
                initrdISOPath: "/boot/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: bootBundle.path
        )
        let bootArtifact = DoryVMResolverReference(
            namespace: "artifact",
            identifier: "ubuntu-runtime"
        )
        let diskArtifact = DoryVMResolverReference(
            namespace: "artifact",
            identifier: "ubuntu-disk"
        )
        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 2 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: "runtime-linux", name: "Runtime Linux"),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system",
                    role: .system,
                    kind: .installedLinuxBootBundle,
                    source: .bundledByDory,
                    artifact: bootArtifact,
                    removable: false
                )],
                order: ["system"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .required,
                backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.none]),
            resources: resources,
            storage: [DoryVMStorageAttachment(
                id: "system-disk",
                role: .system,
                artifact: diskArtifact,
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
        canonicalDefinition = DoryDaemonVirtualMachinePlanningCoordinator
            .canonicalDefinitionData(definition)
        machine = DoryMachineConfiguration(
            id: definition.identity.id,
            kernelPath: bootBundle.path,
            rootfsPath: "/fixture/linux.raw",
            bootMode: .efi,
            displayMode: .desktop
        )
        media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: digest("a")
        )
        let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition)
        plannerRequest = DoryVirtualMachineBackendPlanRequest(
            guest: definition.guest,
            bootMedia: media,
            acceptableGraphics: [.none],
            devices: devices,
            backendPreferences: [.doryHypervisor],
            backendPreferencePolicy: .required
        )
        let runtimeQualification = DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: "runtime-qualification-1",
            qualificationReportSHA256: digest("b"),
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
                guest: definition.guest,
                bootMedia: media,
                backend: .doryHypervisor,
                graphics: .none,
                devices: devices
            ),
            availability: DoryCapabilityAvailability(supportTier: .supported, state: .available),
            resolvedDevices: devices,
            runtimeQualificationEvidence: runtimeQualification
        )
        let admission = resourceAdmission(resources)
        let snapshot = DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: hostFacts(),
            media: DoryDaemonVirtualMachineResolvedMedia(reference: bootArtifact, media: media),
            launchArtifacts: [
                resolvedMutableStorageLaunchArtifact(
                    reference: diskArtifact,
                    source: .userProvided,
                    identifier: "system-disk"
                ),
                resolvedBootLaunchArtifacts(
                    reference: bootArtifact,
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
                    artifactSHA256: digest("c")
                )],
                hostQualification: hostQualification()
            )],
            resourceAdmission: admission
        )
        inventory = FixtureInventory(snapshot: snapshot)
        registry = try BackendRegistry(backends: [RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: MachineBackendCompatibilityOperations(
                start: { id in MachineBackendRuntimeObservation(machineID: id, state: .running) },
                stop: { id in MachineBackendRuntimeObservation(machineID: id, state: .stopped) },
                pause: { id in MachineBackendRuntimeObservation(machineID: id, state: .paused) },
                resume: { id in MachineBackendRuntimeObservation(machineID: id, state: .running) }
            ),
            executableIsAvailable: { _ in true }
        )])
        coordinator = DoryDaemonVirtualMachinePlanningCoordinator(
            registry: registry,
            inventory: inventory,
            plans: store,
            capabilityPlanner: FixturePlanner(capability: capability),
            now: { 1_700_000_000_000 }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func planningRequest() -> DoryDaemonVirtualMachinePlanningRequest {
        DoryDaemonVirtualMachinePlanningRequest(
            definition: definition,
            canonicalDefinitionData: canonicalDefinition,
            machine: machine,
            publication: .create
        )
    }
}

private struct FixturePlanner: DoryDaemonVirtualMachineCapabilityPlanning {
    let capability: DoryVirtualMachineCapabilityDescriptor

    func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult {
        DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: capability,
            evaluatedDescriptors: [capability],
            failure: nil
        )
    }
}

private enum BackendPlanSubstitution { case machine, capability }

private struct SubstitutingBackend: MachineBackend {
    let substitution: BackendPlanSubstitution
    let descriptor = RawHVLinuxMachineBackend.backendDescriptor

    init(_ substitution: BackendPlanSubstitution) {
        self.substitution = substitution
    }

    func probe() -> MachineBackendProbeResult {
        MachineBackendProbeResult(descriptor: descriptor, state: .available)
    }

    func plan(_ request: MachineBackendPlanRequest) -> MachineBackendPlanResult {
        guard var capability = request.capabilityPlan.selectedDescriptor else {
            return MachineBackendPlanResult(
                plan: nil,
                probe: probe(),
                failure: MachineBackendFailure(
                    code: .capabilityPlanRejected,
                    backend: descriptor.identity,
                    message: "Fixture planner did not select a capability."
                )
            )
        }
        var machine = request.machine
        switch substitution {
        case .machine:
            machine.id = "substituted-machine"
        case .capability:
            capability.request.bootMedia.artifactSHA256 = digest("9")
        }
        return MachineBackendPlanResult(
            plan: MachineBackendPlan(
                backend: descriptor,
                machine: machine,
                capability: capability
            ),
            probe: probe(),
            failure: nil
        )
    }

    func start(_ plan: MachineBackendPlan) -> MachineBackendOperationResult {
        unsupported(.start)
    }

    func stop(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        unsupported(.stop)
    }

    func pause(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        unsupported(.pause)
    }

    func resume(_ request: MachineBackendRuntimeRequest) -> MachineBackendOperationResult {
        unsupported(.resume)
    }

    private func unsupported(
        _ operation: MachineBackendLifecycleOperation
    ) -> MachineBackendOperationResult {
        MachineBackendOperationResult(
            operation: operation,
            backend: descriptor.identity,
            observation: nil,
            failure: MachineBackendFailure(
                code: .lifecycleOperationUnsupported,
                backend: descriptor.identity,
                message: "Fixture backend does not launch machines."
            )
        )
    }
}

private struct FixtureInventory: DoryDaemonVirtualMachineTrustInventory {
    let snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot

    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot { snapshot }

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot { snapshot }
}

private final class FixturePlanStore: DoryResolvedMachinePlanStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var plan: DoryResolvedMachinePlan?

    func create(_ plan: DoryResolvedMachinePlan) throws {
        lock.withLock { self.plan = plan }
    }

    func replace(_ plan: DoryResolvedMachinePlan, expectedPlanRevision: UInt64) throws {
        lock.withLock { self.plan = plan }
    }

    func read(id: String) throws -> DoryResolvedMachinePlan {
        try lock.withLock {
            guard let plan, plan.machineID == id else {
                throw DoryResolvedMachinePlanRepositoryError.planNotFound(id)
            }
            return plan
        }
    }
}

private final class FixtureEvidenceCollector:
    DoryDaemonVirtualMachineStartEvidenceCollecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Result<DoryDaemonVirtualMachineStartEvidenceCollection, FixtureError>
    private var count = 0

    init(collection: DoryDaemonVirtualMachineStartEvidenceCollection) {
        result = .success(collection)
    }

    init(error: FixtureError) {
        result = .failure(error)
    }

    var collectionCount: Int { lock.withLock { count } }

    func collectFreshEvidence(
        for plan: DoryResolvedMachinePlan
    ) throws -> DoryDaemonVirtualMachineStartEvidenceCollection {
        try lock.withLock {
            count += 1
            return try result.get()
        }
    }
}

private enum FixtureError: Error { case unavailable }

private func hostFacts() -> DoryAppleSiliconHostFacts {
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
            storageAvailable: false,
            networkAvailable: false,
            displayAvailable: false,
            inputAvailable: false
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
            qemuRuntimeBuildID: "qemu-runtime-1"
        )
    )
}

private func resourceAdmission(
    _ resources: DoryVMResourceRequest
) -> DoryResolvedMachineResourceAdmissionEvidence {
    DoryResolvedMachineResourceAdmissionEvidence(
        admittedVirtualCPUCount: resources.virtualCPUCount,
        admittedMemoryBytes: resources.memoryBytes,
        admittedStorageBytes: resources.diskBytes,
        hostLogicalCPUCount: 12,
        hostPhysicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        hostFreeStorageBytes: 512 * 1_024 * 1_024 * 1_024,
        existingVirtualCPUCommitment: 2,
        existingMemoryCommitmentBytes: 2 * 1_024 * 1_024 * 1_024,
        existingStorageReservationBytes: 16 * 1_024 * 1_024 * 1_024,
        hostReservedLogicalCPUCount: 2,
        hostReservedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        hostReservedStorageBytes: 32 * 1_024 * 1_024 * 1_024,
        admissionIdentity: "resource-admission-1",
        admissionReportSHA256: digest("d"),
        assessorIdentifier: "dory-resource-policy",
        assessorVersion: 1
    )
}

private func hostQualification() -> DoryResolvedHostQualificationEvidence {
    DoryResolvedHostQualificationEvidence(
        qualificationIdentity: "runtime-qualification-1",
        qualificationReportSHA256: digest("b"),
        hostHardwareModelIdentifier: "Mac16.1",
        hostOperatingSystemBuild: "26A5406c",
        backend: .doryHypervisor,
        backendRuntimeBuildIdentifier: "raw-runtime-1",
        virtualHardwareABIVersion: 1,
        qualifierIdentifier: "dory-host-qualifier",
        qualifierVersion: 1
    )
}

private func digest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}
