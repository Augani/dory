import CryptoKit
import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("MachineManager resolved-plan launch integration", .serialized)
struct MachineManagerResolvedPlanIntegrationTests {
    @Test("validated persisted plan dispatches once without public-start recursion")
    func exactPlanDispatchesThroughRegistry() throws {
        try withHarness("success") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            #expect(throws: (any Error).self) {
                _ = try operations.start("dev")
            }
            #expect(starter.count == 0)

            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let status = try manager.start(id: "dev")
            #expect(status.state == .running)
            #expect(starter.count == 1)
            #expect(resolver.callCount == 1)
            let identity = try #require(manager.resolvedLaunchIdentity(id: "dev"))
            #expect(identity.planRevision == 1)
            #expect(identity.backend == .doryHypervisor)
            #expect(identity.planSHA256.count == 64)
            #expect(status.runtimeIdentity.mode == .resolvedPlan)
            #expect(status.runtimeIdentity.planRevision == 1)
            #expect(status.runtimeIdentity.definitionSHA256?.count == 64)
            #expect(
                status.runtimeIdentity.backendImplementationIdentifier
                    == RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier
            )
            #expect(status.runtimeIdentity.virtualHardwareABIVersion == 1)
            #expect(status.runtimeIdentity.components.count == 1)
            let service = DorydService(
                socketPath: state + "/service.sock",
                machineManager: manager
            )
            var xpcRows: NSArray = []
            service.machineList { rows, message in
                #expect(message.isEmpty)
                xpcRows = rows
            }
            let xpcStatus = try #require(xpcRows.firstObject as? NSDictionary)
            let xpcIdentity = try #require(
                xpcStatus["runtimeIdentity"] as? NSDictionary
            )
            #expect(xpcIdentity["mode"] as? String == "resolved-plan")
            #expect(xpcIdentity["planSHA256"] as? String == identity.planSHA256)
            #expect(xpcIdentity["backend"] as? String == "dory-hypervisor")
            #expect(xpcIdentity["resolvedPlan"] == nil)
            let encodedXPC = try JSONSerialization.data(withJSONObject: xpcIdentity)
            let xpcText = String(decoding: encodedXPC, as: UTF8.self)
            #expect(!xpcText.contains("/bin/sleep"))
            #expect(!xpcText.contains(state))
            #expect(FileManager.default.fileExists(atPath: state + "/dev/machine.json"))
            _ = try manager.stop(id: "dev")
            let snapshot = try manager.snapshot(id: "dev", snapshotID: "evidence")
            #expect(snapshot.runtimeIdentity == status.runtimeIdentity)
            #expect(snapshot.artifactEvidence?.rootfs.sha256.count == 64)
            #expect(snapshot.artifactEvidence?.kernel.sha256.count == 64)
            var tamperedIdentity = snapshot.runtimeIdentity
            tamperedIdentity.resolvedPlanSHA256 = String(repeating: "0", count: 64)
            #expect(tamperedIdentity.validate().contains { $0.code == .planDigestMismatch })

            let restored = try manager.restoreSnapshot(
                machineID: "dev",
                snapshotID: "evidence"
            )
            #expect(restored.state == .stopped)
            #expect(restored.runtimeIdentity.mode == .requiresReplanning)
            #expect(restored.runtimeIdentity.invalidationReason == .restoredSnapshot)
        }
    }

    @Test("resolved snapshot disk capacity is bound to resource admission")
    func resolvedSnapshotRejectsSelfConsistentDifferentCapacityDisk() throws {
        try withHarness("snapshot-storage-evidence") { manager, _, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            _ = try manager.start(id: "dev")
            _ = try manager.stop(id: "dev")
            var snapshot = try manager.snapshot(id: "dev", snapshotID: "capacity")

            let rootfsURL = URL(fileURLWithPath: snapshot.rootfsPath)
            let handle = try FileHandle(forWritingTo: rootfsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let rootfsData = try Data(contentsOf: rootfsURL)
            let rootfsSHA256 = SHA256.hash(data: rootfsData)
                .map { String(format: "%02x", $0) }.joined()
            snapshot.sizeBytes = Int64(rootfsData.count)
            snapshot.artifactEvidence?.rootfs = DoryMachineSnapshotArtifact(
                byteCount: UInt64(rootfsData.count),
                sha256: rootfsSHA256
            )

            let metadataPath = state + "/dev/snapshots/capacity.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(
                to: URL(fileURLWithPath: metadataPath),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadataPath
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.restoreSnapshot(machineID: "dev", snapshotID: "capacity")
            }
        }
    }

    @Test("daemon restart recovers exact plan identity and definition changes invalidate it")
    func restartRecoveryAndConfigurationInvalidation() throws {
        try withHarness("restart-recovery") { manager, _, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            _ = try manager.start(id: "dev")
            _ = try manager.stop(id: "dev")

            let restarted = MachineManager(
                configuration: MachineManagerConfiguration(
                    vmmExecutablePath: "/bin/sleep",
                    acceleratedDesktopExecutablePath: "/bin/sleep",
                    stateDirectory: state,
                    baseArguments: ["30"],
                    acceleratedDesktopBaseArguments: ["30"],
                    passMachineArguments: false,
                    requiresReadyHandoff: false
                ),
                launchPolicy: .requireResolvedPlan
            )
            #expect(restarted.status(id: "dev")?.runtimeIdentity.mode == .requiresReplanning)
            let restartedOperations = restarted.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            try restarted.installResolvedLaunchInfrastructure(
                registry: rawRegistry(operations: restartedOperations),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            #expect(restarted.status(id: "dev")?.runtimeIdentity.mode == .resolvedPlan)
            let updated = try restarted.update(id: "dev", memoryMB: 4_096)
            #expect(updated.runtimeIdentity.mode == .requiresReplanning)
            #expect(updated.runtimeIdentity.invalidationReason == .definitionChanged)
        }
    }

    @Test("missing stale tampered and rejected plans never reach process starter")
    func rejectedPlansFailBeforeSpawn() throws {
        enum Scenario: CaseIterable {
            case missing
            case staleDefinition
            case tamperedDigest
            case rejectedEvidence
            case adapterPlanMismatch
        }

        for scenario in Scenario.allCases {
            try withHarness("reject-\(scenario)") { manager, starter, _ in
                let plans = MutablePlanStore()
                let operations = manager.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
                let registry = try rawRegistry(operations: operations)
                let resolver = ClosureLaunchResolver { request in
                    switch scenario {
                    case .missing:
                        throw DoryDaemonVirtualMachineLaunchPlanFailure(
                            code: .planNotFound,
                            message: "fixture missing plan"
                        )
                    case .staleDefinition:
                        var resolution = try exactResolution(request: request)
                        resolution.resolvedPlan.definitionRevision += 1
                        resolution.resolvedPlanSHA256 = try planSHA256(
                            resolution.resolvedPlan
                        )
                        return resolution
                    case .tamperedDigest:
                        var resolution = try exactResolution(request: request)
                        resolution.resolvedPlanSHA256 = digest("9")
                        return resolution
                    case .rejectedEvidence:
                        var resolution = try exactResolution(request: request)
                        resolution.revalidation = DoryResolvedMachinePlanRevalidationResult(
                            state: .rejected,
                            issues: [DoryResolvedMachinePlanRevalidationIssue(
                                code: .componentEvidenceMismatch,
                                field: "components"
                            )]
                        )
                        return resolution
                    case .adapterPlanMismatch:
                        var resolution = try exactResolution(request: request)
                        resolution.backendPlan.machine.memoryMB += 1_024
                        return resolution
                    }
                }
                try manager.installResolvedLaunchInfrastructure(
                    registry: registry,
                    resolver: resolver,
                    plans: plans,
                    expectedPlanRevision: { _ in 1 }
                )

                #expect(throws: MachineManagerError.self) {
                    _ = try manager.start(id: "dev")
                }
                #expect(starter.count == 0)
                #expect(manager.status(id: "dev")?.state == .created)
                #expect(manager.resolvedLaunchIdentity(id: "dev") == nil)
            }
        }
    }

    @Test("machine metadata mutation during evidence collection is rejected before spawn")
    func authorityTOCTOUIsRejected() throws {
        try withHarness("authority-toctou") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                var changed = request.machine
                changed.memoryMB += 1_024
                let path = state + "/dev/machine.json"
                try DoryMachineConfigurationMigrationBridge.encodeLegacy(changed).write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
                return try exactResolution(request: request)
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("missing pinned plan revision fails without invoking resolver or process")
    func missingPinnedRevisionFailsClosed() throws {
        try withHarness("missing-revision") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                try exactResolution(request: request)
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in nil }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(resolver.callCount == 0)
            #expect(starter.count == 0)
        }
    }

    @Test("resolved plan replacement during evidence collection is rejected before spawn")
    func planAuthorityTOCTOUIsRejected() throws {
        try withHarness("plan-toctou") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                var replacement = resolution.resolvedPlan
                replacement.planRevision += 1
                replacement.updatedAtUnixMilliseconds += 1
                plans.set(replacement)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("same-path runtime replacement is rejected before process starter")
    func swappedRuntimeArtifactIsRejected() throws {
        try withHarness("runtime-swap") { manager, starter, state in
            let runtimePath = state + "/adapter-runtime"
            try writeExecutable("#!/bin/sh\nexec /bin/sleep \"$@\"\n", path: runtimePath)
            let qualifiedSHA256 = try fileSHA256(path: runtimePath)
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(
                operations: operations,
                executablePath: runtimePath
            )
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(
                    request: request,
                    componentSHA256: qualifiedSHA256
                )
                plans.set(resolution.resolvedPlan)
                try writeExecutable("#!/bin/sh\nexit 0\n", path: runtimePath)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("final media mutation is rejected by single-use authorization before process starter")
    func preSpawnArtifactMutationIsRejected() throws {
        try withHarness("pre-spawn-media-mutation") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let mediaPath = state + "/resolved-media"
                try Data("qualified-media".utf8).write(
                    to: URL(fileURLWithPath: mediaPath),
                    options: .atomic
                )
                let expectedSHA256 = SHA256.hash(
                    data: try Data(contentsOf: URL(fileURLWithPath: mediaPath))
                ).map { String(format: "%02x", $0) }.joined()
                let resolution = try exactResolution(
                    request: request,
                    preSpawnRevalidation: {
                        let current = try Data(contentsOf: URL(fileURLWithPath: mediaPath))
                        let currentSHA256 = SHA256.hash(data: current)
                            .map { String(format: "%02x", $0) }.joined()
                        guard currentSHA256 == expectedSHA256 else {
                            throw DoryDaemonVirtualMachinePreSpawnAuthorizationError
                                .revalidationFailed
                        }
                    }
                )
                plans.set(resolution.resolvedPlan)
                try Data("mutated-after-evidence".utf8).write(
                    to: URL(fileURLWithPath: mediaPath),
                    options: .atomic
                )
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("required resolved launch rejects a missing pre-spawn authorization")
    func missingPreSpawnAuthorizationFailsClosed() throws {
        try withHarness("missing-pre-spawn") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let resolver = ClosureLaunchResolver { request in
                var resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                resolution.preSpawnAuthorization = nil
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: operations),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("adapter-issued executable is launched instead of manager backend lookup")
    func adapterExecutableBindingIsUsed() throws {
        try withHarness(
            "adapter-binding",
            acceleratedExecutablePath: nil
        ) { manager, starter, state in
            let runtimePath = state + "/adapter-runtime"
            try writeExecutable("#!/bin/sh\nexec /bin/sleep \"$@\"\n", path: runtimePath)
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(
                operations: operations,
                executablePath: runtimePath
            )
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(
                    request: request,
                    componentSHA256: try fileSHA256(path: runtimePath)
                )
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let status = try manager.start(id: "dev")
            #expect(status.state == .running)
            #expect(starter.count == 1)
        }
    }

    @Test("launch policy explicitly gates compatibility and resolved starts")
    func launchPolicyIsExplicit() throws {
        try withHarness("required-no-infra") { manager, starter, _ in
            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
        try withHarness("legacy", launchPolicy: .legacyCompatibility) {
            manager, starter, _ in
            let status = try manager.start(id: "dev")
            #expect(status.state == .running)
            #expect(starter.count == 1)
        }
    }

    private func withHarness(
        _ label: String,
        launchPolicy: DoryMachineLaunchPolicy = .requireResolvedPlan,
        acceleratedExecutablePath: String? = "/bin/sleep",
        _ body: (MachineManager, CountingProcessStarter, String) throws -> Void
    ) throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-resolved-start-\(label)-\(UUID().uuidString)")
            .path
        let starter = CountingProcessStarter()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                acceleratedDesktopExecutablePath: acceleratedExecutablePath,
                stateDirectory: state,
                baseArguments: ["30"],
                acceleratedDesktopBaseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            launchPolicy: launchPolicy,
            processStarter: { process in try starter.start(process) }
        )
        defer {
            _ = try? manager.stop(id: "dev")
            _ = try? manager.delete(id: "dev")
            _ = try? FileManager.default.removeItem(atPath: state)
        }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2_048,
            cpuCount: 2,
            displayMode: .desktop
        ))
        try body(manager, starter, state)
    }

    private func rawRegistry(
        operations: MachineBackendCompatibilityOperations,
        executablePath: String = "/bin/sleep"
    ) throws -> BackendRegistry {
        try BackendRegistry(backends: [RawHVLinuxMachineBackend(
            executablePath: executablePath,
            operations: operations
        )])
    }

    private func exactResolution(
        request: DoryDaemonVirtualMachineLaunchPlanRequest,
        componentSHA256: String? = nil,
        preSpawnRevalidation: @escaping @Sendable () throws -> Void = {}
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution {
        let definitionDigest = SHA256.hash(data: request.canonicalDefinitionData)
            .map { String(format: "%02x", $0) }.joined()
        let artifact = digest("a")
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .userProvided,
            artifactSHA256: artifact
        )
        let runtime = "raw-runtime-1"
        let launcherSHA256: String
        if let componentSHA256 {
            launcherSHA256 = componentSHA256
        } else {
            launcherSHA256 = try fileSHA256(path: "/bin/sleep")
        }
        let plan = DoryResolvedMachinePlan(
            machineID: request.machine.id,
            definitionRevision: request.definition.lifecycle.revision,
            definitionSHA256: definitionDigest,
            planRevision: request.expectedPlanRevision,
            createdAtUnixMilliseconds: request.definition.lifecycle.createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: request.definition.lifecycle.updatedAtUnixMilliseconds,
            guest: request.definition.guest,
            backend: .doryHypervisor,
            backendImplementationIdentifier:
                RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtime,
            virtualHardwareABIVersion: request.definition.virtualHardwareABIVersion,
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: DoryVMResolverReference(
                    namespace: "machine",
                    identifier: "dev-kernel"
                ),
                media: media
            ),
            components: [DoryResolvedBackendComponentEvidence(
                componentIdentifier: "dory-hv",
                buildIdentifier: runtime,
                artifactSHA256: launcherSHA256
            )],
            devices: devices,
            graphics: .hostAcceleratedDisplay,
            supportTier: .supported,
            selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: DoryVirtualMachineBackendPlanRequest(
                    guest: request.definition.guest,
                    bootMedia: media,
                    acceptableGraphics: [.hostAcceleratedDisplay],
                    devices: devices,
                    virtualHardwareABIVersion:
                        request.definition.virtualHardwareABIVersion,
                    backendPreferences: [.doryHypervisor],
                    backendPreferencePolicy: .required
                ),
                selectedEvaluationIndex: 0,
                rejectedCandidates: []
            ),
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                graphics: DorySignedArtifactQualificationEvidence(
                    manifestIdentity: "graphics-qualification-1",
                    artifactSHA256: artifact,
                    manifestSHA256: digest("b"),
                    signingKeyID: "dory-release-1",
                    manifestFormatVersion: 1
                ),
                runtime: runtimeQualification(
                    guest: request.definition.guest,
                    media: media,
                    runtimeBuild: runtime,
                    devices: devices,
                    virtualHardwareABIVersion:
                        request.definition.virtualHardwareABIVersion
                )
            ),
            resourceAdmission: resourceAdmission(
                machine: request.machine,
                diskBytes: request.definition.resources.diskBytes
            ),
            hostQualification: DoryResolvedHostQualificationEvidence(
                qualificationIdentity: "host-qualification-1",
                qualificationReportSHA256: digest("6"),
                hostHardwareModelIdentifier: "Mac16.1",
                hostOperatingSystemBuild: "26A5406c",
                backend: .doryHypervisor,
                backendRuntimeBuildIdentifier: runtime,
                virtualHardwareABIVersion: request.definition.virtualHardwareABIVersion,
                qualifierIdentifier: "dory-host-qualifier",
                qualifierVersion: 1
            )
        )
        guard plan.validate().isEmpty else {
            throw MachineManagerError.persistence("fixture plan is invalid")
        }
        let capability = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: DoryVirtualMachineCapabilityRequest(
                guest: plan.guest,
                bootMedia: media,
                backend: .doryHypervisor,
                graphics: plan.graphics,
                devices: devices,
                virtualHardwareABIVersion: plan.virtualHardwareABIVersion
            ),
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            ),
            resolvedDevices: devices,
            graphicsQualificationEvidence: plan.qualificationEvidence.graphics,
            runtimeQualificationEvidence: plan.qualificationEvidence.runtime
        )
        return DoryDaemonVirtualMachineLaunchPlanResolution(
            resolvedPlan: plan,
            resolvedPlanSHA256: try planSHA256(plan),
            revalidation: DoryResolvedMachinePlanStartValidator.revalidate(
                plan,
                against: DoryResolvedMachinePlanStartRevalidationInput(
                    machineID: plan.machineID,
                    expectedPlanRevision: plan.planRevision,
                    currentDefinitionRevision: plan.definitionRevision,
                    currentDefinitionSHA256: definitionDigest,
                    runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: plan)
                )
            ),
            backendPlan: MachineBackendPlan(
                backend: RawHVLinuxMachineBackend.backendDescriptor,
                machine: request.machine,
                capability: capability
            ),
            preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization(
                revalidate: preSpawnRevalidation
            )
        )
    }

    private func runtimeQualification(
        guest: DoryGuestPlatform,
        media: DoryBootMedia,
        runtimeBuild: String,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        virtualHardwareABIVersion: UInt16
    ) -> DoryVirtualMachineRuntimeQualificationEvidence {
        DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: "runtime-qualification-1",
            qualificationReportSHA256: digest("c"),
            signingKeyID: "dory-runtime-1",
            qualificationFormatVersion: 1,
            guest: guest,
            bootMediaKind: media.kind,
            immutableArtifactSHA256: media.artifactSHA256,
            backend: .doryHypervisor,
            backendRuntimeBuildID: runtimeBuild,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            graphics: .hostAcceleratedDisplay,
            devices: devices
        )
    }

    private func resourceAdmission(
        machine: DoryMachineConfiguration,
        diskBytes: UInt64
    ) -> DoryResolvedMachineResourceAdmissionEvidence {
        DoryResolvedMachineResourceAdmissionEvidence(
            admittedVirtualCPUCount: UInt64(machine.cpuCount),
            admittedMemoryBytes: machine.memoryMB * 1_048_576,
            admittedStorageBytes: diskBytes,
            hostLogicalCPUCount: 12,
            hostPhysicalMemoryBytes: 32 * 1_073_741_824,
            hostFreeStorageBytes: 512 * 1_073_741_824,
            existingVirtualCPUCommitment: 0,
            existingMemoryCommitmentBytes: 0,
            existingStorageReservationBytes: 0,
            hostReservedLogicalCPUCount: 2,
            hostReservedMemoryBytes: 8 * 1_073_741_824,
            hostReservedStorageBytes: 32 * 1_073_741_824,
            admissionIdentity: "resource-admission-1",
            admissionReportSHA256: digest("f"),
            assessorIdentifier: "dory-resource-policy",
            assessorVersion: 1
        )
    }

    private func planSHA256(_ plan: DoryResolvedMachinePlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(plan))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func fileSHA256(path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func writeExecutable(_ contents: String, path: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

private final class ClosureLaunchResolver:
    DoryDaemonVirtualMachineLaunchPlanResolving,
    @unchecked Sendable
{
    typealias Handler = @Sendable (
        DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution

    private let lock = NSLock()
    private var calls = 0
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var callCount: Int { lock.withLock { calls } }

    func resolve(
        _ request: DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution {
        lock.withLock { calls += 1 }
        return try handler(request)
    }
}

private final class CountingProcessStarter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    var count: Int { lock.withLock { starts } }

    func start(_ process: HvProcess) throws {
        lock.withLock { starts += 1 }
        try process.start()
    }
}

private final class MutablePlanStore: DoryResolvedMachinePlanStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var plan: DoryResolvedMachinePlan?

    func set(_ plan: DoryResolvedMachinePlan?) {
        lock.withLock { self.plan = plan }
    }

    func create(_ plan: DoryResolvedMachinePlan) throws { set(plan) }

    func replace(
        _ plan: DoryResolvedMachinePlan,
        expectedPlanRevision: UInt64
    ) throws {
        lock.withLock { self.plan = plan }
    }

    func read(id: String) throws -> DoryResolvedMachinePlan {
        guard let plan = lock.withLock({ self.plan }), plan.machineID == id else {
            throw DoryResolvedMachinePlanRepositoryError.planNotFound(id)
        }
        return plan
    }
}
