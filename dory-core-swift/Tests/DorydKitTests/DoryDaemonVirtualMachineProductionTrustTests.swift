import CryptoKit
@testable import DorydKit
import DoryOperations
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
import Testing

@Suite("Production VM trust composition")
struct DoryDaemonVirtualMachineProductionTrustTests {
    @Test("RawHV hardware3D requires candidate-bound bootstrap qualification")
    func rendererBootstrapQualificationIsRequired() throws {
        let runtimeBuild = "sha256:" + String(repeating: "a", count: 64)
        let descriptor = RawHVLinuxMachineBackend.backendDescriptor
        let component = DoryVirtualMachineQualifiedComponent(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuild,
            artifactSHA256: String(repeating: "a", count: 64)
        )
        let unqualified = DoryDaemonVerifiedBackendRuntime(
            descriptor: descriptor,
            executablePath: "/Applications/Dory.app/Contents/Helpers/dory-hv",
            runtimeBuildIdentifier: runtimeBuild,
            components: [component]
        )
        #expect(!unqualified.productionAccelerationIsAdmissible)

        let admitted = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try digest("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try digest("3")
        )
        let missingEvidenceRuntime = DoryDaemonVerifiedBackendRuntime(
            descriptor: descriptor,
            executablePath: "/Applications/Dory.app/Contents/Helpers/dory-hv",
            runtimeBuildIdentifier: runtimeBuild,
            components: [component],
            rendererAccelerationAdmission: admitted
        )
        #expect(DoryDaemonRendererAccelerationAdmission.productionTupleProvidesRequiredCapsets)
        #expect(!admitted.authorizes(runtimeBuildIdentifier: runtimeBuild))
        #expect(!missingEvidenceRuntime.productionAccelerationIsAdmissible)
        #expect(Set(admitted.qualifiedComponents.map(\.componentIdentifier)) == [
            DoryRendererProductionInventory.ComponentIdentity.candidateInventory,
            DoryRendererProductionInventory.ComponentIdentity.guestMesa,
            DoryRendererProductionInventory.ComponentIdentity.worker,
        ])

        let qualifiedAdmission = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try digest("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try digest("3"),
            bootstrapQualification: try digest("4")
        )
        let qualified = DoryDaemonVerifiedBackendRuntime(
            descriptor: descriptor,
            executablePath: "/Applications/Dory.app/Contents/Helpers/dory-hv",
            runtimeBuildIdentifier: runtimeBuild,
            components: [component] + qualifiedAdmission.qualifiedComponents,
            rendererAccelerationAdmission: qualifiedAdmission
        )
        #expect(qualifiedAdmission.authorizes(runtimeBuildIdentifier: runtimeBuild))
        #expect(qualified.productionAccelerationIsAdmissible)
        #expect(!qualifiedAdmission.releaseQualificationIsAuthenticated)
        #expect(Set(qualifiedAdmission.qualifiedComponents.map(\.componentIdentifier)) == [
            DoryRendererProductionInventory.ComponentIdentity.candidateInventory,
            DoryRendererProductionInventory.ComponentIdentity.guestMesa,
            DoryRendererProductionInventory.ComponentIdentity.worker,
            DoryDaemonRendererAccelerationAdmission
                .bootstrapQualificationComponentIdentity,
        ])

        let releaseAdmission = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try digest("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try digest("3"),
            bootstrapQualification: try digest("4"),
            bootstrapQualificationSignature: try digest("5")
        )
        #expect(releaseAdmission.releaseQualificationIsAuthenticated)
        #expect(Set(releaseAdmission.qualifiedComponents.map(\.componentIdentifier)).contains(
            DoryDaemonRendererAccelerationAdmission
                .bootstrapQualificationSignatureComponentIdentity
        ))

        #expect(!admitted.authorizes(
            runtimeBuildIdentifier: "sha256:" + String(repeating: "f", count: 64)
        ))
        let obsoleteSchema = DoryDaemonRendererAccelerationAdmission(
            schemaVersion: 1,
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try digest("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try digest("3")
        )
        #expect(!obsoleteSchema.authorizes(runtimeBuildIdentifier: runtimeBuild))
    }

    @Test("resolved renderer evidence without bootstrap qualification cannot recover authority")
    func incompleteEvidenceCannotRecoverAccelerationAuthority() throws {
        let runtimeDigest = String(repeating: "a", count: 64)
        let runtimeBuild = "sha256:\(runtimeDigest)"
        let admitted = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try digest("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try digest("2")
        )
        var components = admitted.qualifiedComponents.map {
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: $0.componentIdentifier,
                buildIdentifier: $0.buildIdentifier,
                artifactSHA256: $0.artifactSHA256
            )
        }
        components.append(DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuild,
            artifactSHA256: runtimeDigest
        ))
        #expect(throws: DoryDaemonRendererProductionAuthorityError.inventoryInvalid) {
            try DoryDaemonRendererAccelerationAdmission.recovering(
                runtimeBuildIdentifier: runtimeBuild,
                components: components
            )
        }

        components[0].buildIdentifier = "sha256:" + String(repeating: "f", count: 64)
        #expect(throws: DoryDaemonRendererProductionAuthorityError.inventoryInvalid) {
            try DoryDaemonRendererAccelerationAdmission.recovering(
                runtimeBuildIdentifier: runtimeBuild,
                components: components
            )
        }
    }

    private func digest(_ nibble: Character) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(
            lowercaseSHA256: String(repeating: nibble, count: 64),
            field: "test"
        )
    }

    @Test("missing catalog remains explicitly unavailable")
    func missingCatalog() throws {
        let fixture = try ProductionTrustFixture(installCatalog: false)
        defer { fixture.cleanup() }

        let result = fixture.factory.resolve(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        )
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .catalogUnavailable)
        #expect(reason.permitsLegacyCompatibilityMigration)
    }

    @Test("schema-v1 catalog is not promoted to resolved-plan trust")
    func schemaV1FailsClosed() throws {
        let fixture = try ProductionTrustFixture(catalogSchemaVersion: 1)
        defer { fixture.cleanup() }

        let result = fixture.resolve()
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .catalogSchemaV1Migration)
        #expect(reason.permitsLegacyCompatibilityMigration)
    }

    @Test("tampered cached signature is rejected before helper probing")
    func tamperedSignature() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        try Data("invalid-signature\n".utf8).write(
            to: URL(fileURLWithPath: fixture.store.root + "/catalog.sig")
        )

        let result = fixture.resolve()
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .qualificationAuthorityUnavailable)
    }

    @Test("tampered installed qualification manifest is rejected")
    func tamperedManifest() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        let path = try #require(fixture.store.assetPath(
            component: .linuxMachines,
            path: fixture.manifestPath
        ))
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: path))

        let result = fixture.resolve()
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .qualificationAuthorityUnavailable)
    }

    @Test("developer-signed daemon cannot enable resolved-plan production mode")
    func developerDaemonRejected() throws {
        let fixture = try ProductionTrustFixture(daemonTeamIdentifier: nil)
        defer { fixture.cleanup() }

        let result = fixture.resolve()
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .daemonSignatureUnavailable)
    }

    @Test("stale or unverified helper build blocks readiness")
    func helperBuildRejected() throws {
        let fixture = try ProductionTrustFixture(runtimeVerificationFails: true)
        defer { fixture.cleanup() }

        let result = fixture.resolve()
        guard case let .unavailable(reason) = result else {
            Issue.record("Expected unavailable readiness")
            return
        }
        #expect(reason.code == .backendRuntimeUnavailable)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("only explicit catalog migration states permit legacy compatibility")
    func legacyMigrationClassification() {
        for code in [
            DoryDaemonVirtualMachineProductionTrustReadinessCode.catalogUnavailable,
            .catalogSchemaV1Migration,
            .catalogSchemaUnsupported,
            .trustFloorViolated,
            .planningTransactionUnavailable,
            .qualificationAuthorityUnavailable,
            .daemonSignatureUnavailable,
            .hostFactsUnavailable,
            .backendRuntimeUnavailable,
            .resourceAuthorityUnavailable,
            .compositionFailed,
        ] {
            let unavailable = DoryDaemonVirtualMachineProductionTrustUnavailable(
                code: code,
                message: "fixture"
            )
            #expect(!unavailable.permitsLegacyCompatibilityMigration)
        }
    }

    @Test("verified v2 cannot activate resolved mode without production plan publication")
    func v2WithoutPlanningTransactionStaysMigrationOnly() throws {
        let fixture = try ProductionTrustFixture(planningTransactionAvailable: false)
        defer { fixture.cleanup() }
        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected unavailable production planning")
            return
        }
        #expect(reason.code == .planningTransactionUnavailable)
        #expect(reason.permitsLegacyCompatibilityMigration)
    }

    @Test("accepted production trust cannot downgrade after catalog removal")
    func trustFloorRejectsCatalogRemoval() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case .ready = fixture.resolve() else {
            Issue.record("Expected initial production activation")
            return
        }
        try FileManager.default.removeItem(atPath: fixture.store.root + "/catalog.json")
        try FileManager.default.removeItem(atPath: fixture.store.root + "/catalog.sig")
        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected trust-floor rejection")
            return
        }
        #expect(reason.code == .trustFloorViolated)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("accepted production trust rejects an older signed v2 catalog")
    func trustFloorRejectsSignedCatalogRollback() throws {
        let fixture = try ProductionTrustFixture(
            catalogReleaseVersion: "2.0.0",
            catalogGeneratedAt: "2026-08-20T12:00:00.000Z"
        )
        defer { fixture.cleanup() }
        guard case .ready = fixture.resolve() else {
            Issue.record("Expected initial production activation")
            return
        }
        try fixture.installCatalogFixture(
            schemaVersion: 2,
            releaseVersion: "1.0.0",
            generatedAt: "2026-08-19T12:00:00.000Z"
        )
        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected signed catalog rollback rejection")
            return
        }
        #expect(reason.code == .trustFloorViolated)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("trust-floor directory sync failure cannot return ready")
    func trustFloorDirectorySyncFailureFailsClosed() throws {
        let fixture = try ProductionTrustFixture(trustFloorDirectorySyncFails: true)
        defer { fixture.cleanup() }
        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected trust-floor persistence failure")
            return
        }
        #expect(reason.code == .compositionFailed)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("uninspectable VM state never permits legacy migration")
    func invalidStateDirectoryFailsClosed() throws {
        let fixture = try ProductionTrustFixture(installCatalog: false)
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(
            atPath: fixture.machineConfiguration.stateDirectory
        )
        try Data("not-a-directory".utf8).write(to: URL(
            fileURLWithPath: fixture.machineConfiguration.stateDirectory
        ))
        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected VM state inspection failure")
            return
        }
        #expect(reason.code == .trustFloorViolated)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("missing catalog cannot downgrade existing resolved-plan state")
    func resolvedPlanStateRejectsMissingCatalogDowngrade() throws {
        let fixture = try ProductionTrustFixture(installCatalog: false)
        defer { fixture.cleanup() }
        let machine = URL(fileURLWithPath: fixture.machineConfiguration.stateDirectory)
            .appendingPathComponent("resolved-machine", isDirectory: true)
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: machine.appendingPathComponent(
            DoryResolvedMachinePlanRepository.recordFileName
        ))

        guard case let .unavailable(reason) = fixture.resolve() else {
            Issue.record("Expected trust-floor rejection")
            return
        }
        #expect(reason.code == .trustFloorViolated)
        #expect(!reason.permitsLegacyCompatibilityMigration)
    }

    @Test("same-team binary with wrong signing identifier is not doryd")
    func exactDaemonSigningIdentity() {
        #expect(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: "doryd"
        ))
        #expect(!DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: "Dory"
        ))
    }

    @Test("pre-spawn authorization is single use and consumes failures")
    func preSpawnAuthorizationIsSingleUse() throws {
        let counter = ProductionCallCounter()
        let authorization = DoryDaemonVirtualMachinePreSpawnAuthorization {
            counter.increment()
        }
        try authorization.authorize()
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.self) {
            try authorization.authorize()
        }
        #expect(counter.value == 1)

        let failing = DoryDaemonVirtualMachinePreSpawnAuthorization {
            throw ProductionTrustFixtureError.runtimeRejected
        }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.self) {
            try failing.authorize()
        }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.self) {
            try failing.authorize()
        }
    }

    @Test("mutable storage changed after planning is rejected before spawn")
    func changedStorageFailsPreSpawnAuthorization() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve(),
              let provider = context.inventory
                as? any DoryDaemonVirtualMachinePreSpawnAuthorizationProviding else {
            Issue.record("Expected production pre-spawn authority")
            return
        }
        let request = try fixture.makeBoundStartRequest()
        let authorization = try provider.preSpawnAuthorization(for: request)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.storagePath))
        try handle.write(contentsOf: Data("changed-storage".utf8))
        try handle.synchronize()
        try handle.close()

        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.self) {
            try authorization.authorize()
        }
    }

    @Test("start inventory refreshes volatile host resources")
    func startInventoryRefreshesHostResources() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve() else {
            Issue.record("Expected ready test composition")
            return
        }
        let request = try fixture.makeBoundStartRequest()
        _ = try context.inventory.startInventory(for: request)

        var changed = fixture.host
        changed = DoryDaemonProductionHostObservation(
            hardwareModelIdentifier: changed.hardwareModelIdentifier,
            operatingSystemBuild: changed.operatingSystemBuild,
            macOSMajorVersion: changed.macOSMajorVersion,
            virtualizationFrameworkAvailable: changed.virtualizationFrameworkAvailable,
            hypervisorFrameworkAvailable: changed.hypervisorFrameworkAvailable,
            metalAvailable: changed.metalAvailable,
            resources: DoryVMHostResources(
                logicalCPUCount: changed.resources.logicalCPUCount,
                physicalMemoryBytes: changed.resources.physicalMemoryBytes,
                freeStorageBytes: changed.resources.freeStorageBytes - 1
            )
        )
        fixture.hostState.set(changed)
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try context.inventory.startInventory(for: request)
        }
    }

    @Test("signed v2 authority composes exact resolved-plan infrastructure")
    func signedV2Ready() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }

        let result = fixture.resolve()
        guard case let .ready(context) = result else {
            Issue.record("Expected ready production trust")
            return
        }
        #expect(context.backendRuntimeBuildIdentifiers[.doryHypervisor]
            == fixture.runtimeBuildIdentifier)
        #expect(context.backendRuntimeBuildIdentifiers[.appleVirtualizationFramework]
            == fixture.runtimeBuildIdentifier)
    }

    @Test("activation owns the exact production manager and graph")
    func activationOrderAndExactGraph() throws {
        let trustFloor = ProductionTrustFloorActivationState()
        let fixture = try ProductionTrustFixture(
            trustFloorActivationState: trustFloor
        )
        defer { fixture.cleanup() }
        let result = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        )
        guard case let .activated(context) = result else {
            if case let .unavailable(failure) = result {
                Issue.record("Expected production activation; got \(failure.code.rawValue): \(failure.message)")
            } else {
                Issue.record("Expected production activation")
            }
            return
        }
        #expect(context.machineManager.configuredLaunchPolicy == .perWorkspaceAuthority)
        #expect(context.machineManager.managedStateDirectory
            == fixture.machineConfiguration.stateDirectory)
        #expect(context.planning.identity.stateDirectory
            == context.machineManager.managedStateDirectory)
        #expect(context.planning.plans.root
            == context.machineManager.managedStateDirectory)
        #expect(context.planning.workspaces.root
            == context.machineManager.managedStateDirectory)
        #expect(context.inventory is DoryProductionDaemonVirtualMachineTrustInventory)
        #expect(context.machineImportEnvironment.backendRuntimeBuildIdentifiers[.doryHypervisor]
            == fixture.runtimeBuildIdentifier)
        #expect(context.machineImportEnvironment.backendComponents[.doryHypervisor]?.first?
            .artifactSHA256 == fixture.helperDigest)
        #expect(trustFloor.activationCount == 1)
    }

    @Test("activation rejects helpers that omit the resolved launch contract")
    func activationRequiresExactMachineArguments() throws {
        let trustFloor = ProductionTrustFloorActivationState()
        let fixture = try ProductionTrustFixture(
            trustFloorActivationState: trustFloor
        )
        defer { fixture.cleanup() }
        var configuration = fixture.machineConfiguration
        configuration.passMachineArguments = false

        guard case let .unavailable(failure) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: configuration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected exact launch-argument binding to be mandatory")
            return
        }
        #expect(failure.code == .installationRejected)
        #expect(failure.trustFailure == nil)
        #expect(trustFloor.activationCount == 0)
    }

    @Test("production activation rejects any machine-state root outside the selected drive")
    func activationRequiresSelectedDriveMachineStateRoot() throws {
        let trustFloor = ProductionTrustFloorActivationState()
        let fixture = try ProductionTrustFixture(
            trustFloorActivationState: trustFloor
        )
        defer { fixture.cleanup() }
        let override = fixture.root.appendingPathComponent("override-machine-state")
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: override.path
        )
        var configuration = fixture.machineConfiguration
        configuration.stateDirectory = override.path

        guard case let .unavailable(failure) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: configuration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected non-drive machine-state authority to be rejected")
            return
        }
        #expect(failure.code == .stateAuthorityUnavailable)
        #expect(failure.trustFailure == nil)
        #expect(trustFloor.activationCount == 0)
    }

    @Test("production activation fails closed when the selected machine-state root is not private")
    func activationRequiresHealthySelectedDriveMachineStateRoot() throws {
        let trustFloor = ProductionTrustFloorActivationState()
        let fixture = try ProductionTrustFixture(
            trustFloorActivationState: trustFloor
        )
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.drive.machinesDirectory
        )

        guard case let .unavailable(failure) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected an unsafe selected-drive state root to be rejected")
            return
        }
        #expect(failure.code == .stateAuthorityUnavailable)
        #expect(failure.trustFailure == nil)
        #expect(trustFloor.activationCount == 0)
    }

    @Test("activated production graph publishes a headless create plan through XPC authority")
    func activatedGraphPlansHeadlessCreate() throws {
        try withProductionIntegrationTestStack {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .activated(context) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected production activation")
            return
        }
        let service = DorydService(
            socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
            machineManager: context.machineManager,
            productionPlanningController: context.planningController
        )
        let qualifiedDisk = fixture.root.appendingPathComponent("qualified-headless.raw").path
        FileManager.default.createFile(
            atPath: qualifiedDisk,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let diskHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: qualifiedDisk))
        try diskHandle.truncate(atOffset: 16 * 1_024 * 1_024 * 1_024)
        try diskHandle.synchronize()
        try diskHandle.close()
        let completed = LockedPlanningCreateReply()
        service.machineCreate([
            "id": "qualified-headless",
            "kernelPath": fixture.directKernelPath,
            "rootfsPath": qualifiedDisk,
            "displayMode": "headless",
            "memoryMB": UInt64(2_048),
            "cpuCount": 2,
        ]) { ok, body, message in
            completed.set(ok: ok, body: body, message: message)
        }
        let reply = completed.value
        #expect(reply.ok, Comment(rawValue: reply.message))
        #expect(reply.body["runtimeIdentity"] != nil)
        #expect(context.machineManager.status(id: "qualified-headless")?
            .runtimeIdentity.mode == .resolvedPlan)
        let plan = try context.planning.plans.read(id: "qualified-headless")
        #expect(plan.machineID == "qualified-headless")
        #expect(plan.launchArtifacts.count == 2)
        #expect(plan.devices.clockSynchronization)
        #expect(plan.devices.gracefulShutdown)
        let started = try context.machineManager.start(id: "qualified-headless")
        #expect(started.state == .running)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .running)
        let stopped = try context.machineManager.stop(id: "qualified-headless")
        #expect(stopped.state == .stopped)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .stopped)
        let restarted = try context.machineManager.start(id: "qualified-headless")
        #expect(restarted.state == .running)
        #expect(try context.planning.plans.read(id: "qualified-headless").planRevision == 2)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .running)
        let snapshot = try context.machineManager.snapshot(
            id: "qualified-headless",
            snapshotID: "running-admission"
        )
        #expect(snapshot.machineID == "qualified-headless")
        #expect(context.machineManager.status(id: "qualified-headless")?.state == .running)
        #expect(try context.planning.plans.read(id: "qualified-headless").planRevision == 2)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .running)
        let restored = try context.machineManager.restoreSnapshot(
            machineID: "qualified-headless",
            snapshotID: snapshot.id
        )
        #expect(restored.state == .stopped)
        #expect(restored.runtimeIdentity.mode == .requiresReplanning)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .stopped)
        try context.machineManager.delete(id: "qualified-headless")
        #expect(try context.planning.resourceLedger.snapshot().leases.contains {
            $0.binding.machineID == "qualified-headless"
        } == false)
        }
    }

    @Test("activated production graph runs the portable EFI install and cold-boot path")
    func activatedGraphRunsPortableEFILifecycle() throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture(helperLifetimeSeconds: 2)
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store,
                machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion,
                publicKey: fixture.publicKey,
                expectedArchitecture: "arm64"
            ) else {
                Issue.record("Expected production activation")
                return
            }
            let service = DorydService(
                socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
                machineManager: context.machineManager,
                productionPlanningController: context.planningController
            )
            let installer = fixture.root.appendingPathComponent("portable-lifecycle.iso").path
            try portableARM64ISO9660().write(to: URL(fileURLWithPath: installer))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: installer
            )

            let create = LockedPlanningCreateReply()
            service.machineCreate([
                "id": "portable-efi",
                "kernelPath": "",
                "rootfsPath": "",
                "bootMode": "efi",
                "installerISOPath": installer,
                "diskSizeBytes": UInt64(32 * 1_024 * 1_024 * 1_024),
                "displayMode": "desktop",
                "memoryMB": UInt64(4_096),
                "cpuCount": 4,
            ]) { ok, body, message in
                create.set(ok: ok, body: body, message: message)
            }
            #expect(create.value.ok, Comment(rawValue: create.value.message))
            var plan = try context.planning.plans.read(id: "portable-efi")
            #expect(plan.backend == .appleVirtualizationFramework)
            #expect(plan.graphics == .software)
            #expect(plan.bootMedia.media.kind == .installerISO)
            #expect(plan.bootMedia.media.source == .userProvided)

            let started = try context.machineManager.start(id: "portable-efi")
            #expect(started.state == .running)
            #expect(started.installerMediaAttached)
            let installerPID = try #require(started.pid)
            let machineDirectory = fixture.machineConfiguration.stateDirectory
                + "/portable-efi"
            for (name, bytes) in [
                ("MachineIdentifier", Data("stable-machine-identifier".utf8)),
                ("NVRAM.installer", Data("installer-recorded-efi-boot-state".utf8)),
            ] {
                let path = machineDirectory + "/" + name
                try bytes.write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
            }

            let eject = LockedPlanningCreateReply()
            service.machineUpdate(
                "portable-efi",
                config: ["installerMediaAttached": false]
            ) { ok, body, message in
                eject.set(ok: ok, body: body, message: message)
            }
            #expect(eject.value.ok, Comment(rawValue: eject.value.message))
            let ejected = try #require(context.machineManager.status(id: "portable-efi"))
            #expect(ejected.state == .running)
            #expect(ejected.pid != nil && ejected.pid != installerPID)
            #expect(!ejected.installerMediaAttached)
            plan = try context.planning.plans.read(id: "portable-efi")
            #expect(plan.backend == .appleVirtualizationFramework)
            #expect(plan.graphics == .software)
            #expect(plan.bootMedia.media.kind == .virtualDisk)
            #expect(plan.bootMedia.media.source == .userProvided)

            try context.machineManager.delete(id: "portable-efi")
            #expect(try context.planning.resourceLedger.snapshot().leases.contains {
                $0.binding.machineID == "portable-efi"
            } == false)
        }
    }

    @Test("trust-floor failure exposes no manager and a fresh activation can retry")
    func activationFloorFailureIsTyped() throws {
        let trustFloor = ProductionTrustFloorActivationState(remainingFailures: 1)
        let fixture = try ProductionTrustFixture(
            trustFloorActivationState: trustFloor
        )
        defer { fixture.cleanup() }
        guard case let .unavailable(failure) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected trust-floor activation failure")
            return
        }
        #expect(failure.code == .trustFloorActivationRejected)
        #expect(trustFloor.activationCount == 1)

        guard case let .activated(context) = fixture.factory.activate(
            store: fixture.store,
            machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion,
            publicKey: fixture.publicKey,
            expectedArchitecture: "arm64"
        ) else {
            Issue.record("Expected a fresh production-owned manager to activate")
            return
        }
        #expect(context.machineManager.configuredLaunchPolicy == .perWorkspaceAuthority)
        #expect(trustFloor.activationCount == 2)
    }

    @Test("production inventory never fabricates an admission during planning")
    func planningFailsUntilAtomicAdmissionBindingExists() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve() else {
            Issue.record("Expected ready production trust")
            return
        }
        let reference = DoryVMResolverReference(
            namespace: "artifact",
            identifier: "qualified-linux-boot"
        )
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try context.inventory.planningInventory(for:
                DoryDaemonVirtualMachineInventoryRequest(
                    machineID: "qualified-linux",
                    definitionRevision: 1,
                    guest: fixture.guest,
                    bootMedia: DoryVMBootMediaReference(
                        id: "system",
                        role: .system,
                        kind: .installedLinuxBootBundle,
                        source: .bundledByDory,
                        artifact: reference,
                        removable: false
                    ),
                    launchArtifacts: [DoryDaemonVirtualMachineLaunchArtifactRequirement(
                        reference: reference,
                        kind: .installedLinuxBootBundle,
                        source: .bundledByDory,
                        mutable: false,
                        usages: [DoryResolvedMachineLaunchArtifactUsage(
                            kind: .boot, identifier: "system", readOnly: true
                        )]
                    )],
                    resources: DoryVMResourceRequest(
                        virtualCPUCount: 2,
                        memoryBytes: 2 * 1_024 * 1_024 * 1_024,
                        diskBytes: 32 * 1_024 * 1_024 * 1_024
                    ),
                    devices: .minimumBootable,
                    acceptableGraphics: [.none],
                    virtualHardwareABIVersion: 1
                )
            )
        }
    }

    @Test("production planning preparation resolves exact signed candidates before admission")
    func planningPreparationUsesQualificationAuthority() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve(),
              let preparer = context.inventory
                as? any DoryDaemonVirtualMachinePlanningTrustPreparing else {
            Issue.record("Expected production planning trust preparer")
            return
        }
        let start = try fixture.makeBoundStartRequest()
        let request = productionPlanningRequest(start)
        let preparation = try preparer.preparePlanningTrust(for: request)
        let snapshot = preparation.snapshot(start.resolvedPlan.resourceAdmission!)

        #expect(snapshot.media.reference == start.bootMediaReference)
        #expect(snapshot.backendRuntimes.count == 2)
        #expect(snapshot.runtimeQualifications.count == 2)
        #expect(snapshot.backendRuntime(for: .doryHypervisor) != nil)
    }

    @Test("production trust admits only the structural ARM64 VZ software baseline")
    func planningPreparationAdmitsPortableARM64ISO() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve(),
              let preparer = context.inventory
                as? any DoryDaemonVirtualMachinePlanningTrustPreparing else {
            Issue.record("Expected production planning trust preparer")
            return
        }

        let isoPath = fixture.root.appendingPathComponent("portable-arm64.iso").path
        try portableARM64ISO9660().write(
            to: URL(fileURLWithPath: isoPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: isoPath
        )
        let reference = DoryVMResolverReference(
            namespace: "artifact",
            identifier: "portable-arm64-iso"
        )
        _ = try DoryVirtualMachineArtifactAuthority(
            root: fixture.machineConfiguration.stateDirectory + "/.artifact-authority"
        ).publishImmutable(
            reference: reference,
            path: isoPath,
            kind: .installerISO,
            source: .userProvided
        )
        let requirement = DoryDaemonVirtualMachineLaunchArtifactRequirement(
            reference: reference,
            kind: .installerISO,
            source: .userProvided,
            mutable: false,
            usages: [DoryResolvedMachineLaunchArtifactUsage(
                kind: .boot,
                identifier: "installer",
                readOnly: true
            )]
        )
        func request(
            graphics: [DoryGraphicsAccelerationLevel]
        ) -> DoryDaemonVirtualMachineInventoryRequest {
            DoryDaemonVirtualMachineInventoryRequest(
                machineID: "portable-linux",
                definitionRevision: 1,
                guest: fixture.guest,
                bootMedia: DoryVMBootMediaReference(
                    id: "installer",
                    role: .installer,
                    kind: .installerISO,
                    source: .userProvided,
                    artifact: reference,
                    removable: true
                ),
                launchArtifacts: [requirement],
                resources: DoryVMResourceRequest(
                    virtualCPUCount: 2,
                    memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                    diskBytes: 32 * 1_024 * 1_024 * 1_024
                ),
                devices: .minimumBootable,
                acceptableGraphics: graphics,
                virtualHardwareABIVersion: 1
            )
        }

        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 4 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        let definitionSHA256 = SHA256.hash(data: Data("portable-definition".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ledger = DoryVirtualMachineResourceAdmissionLedger(
            root: fixture.machineConfiguration.stateDirectory + "/.resource-admissions"
        )
        let lease = try ledger.reserveStarting(
            binding: DoryVirtualMachineResourceAdmissionPlanBinding(
                machineID: "portable-linux",
                definitionRevision: 1,
                definitionSHA256: definitionSHA256,
                plannedPlanRevision: 1
            ),
            hostFacts: fixture.host.resources,
            workload: .desktop,
            resources: resources
        )
        let preparation = try preparer.preparePlanningTrust(
            for: request(graphics: [.software])
        )
        let snapshot = preparation.snapshot(lease.evidence)
        let plannerRequest = DoryVirtualMachineBackendPlanRequest(
            guest: fixture.guest,
            bootMedia: snapshot.media.media,
            acceptableGraphics: [.software],
            devices: .minimumBootable,
            backendPreferences: [.appleVirtualizationFramework],
            backendPreferencePolicy: .required
        )
        let plannerResult = DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner().plan(
            plannerRequest,
            inventory: snapshot
        )
        let selected = try #require(plannerResult.selectedDescriptor)
        let runtime = try #require(snapshot.backendRuntime(for: selected))

        #expect(selected.availability.supportTier == .supported)
        #expect(selected.runtimeQualificationEvidence == nil)
        #expect(selected.bootMediaInspectionEvidence?.catalogManifestEvidence == nil)
        #expect(runtime.backend == .appleVirtualizationFramework)
        #expect(runtime.hostQualification == nil)
        #expect(snapshot.runtimeQualifications.isEmpty)

        let plan = try DoryResolvedMachinePlan(
            machineID: "portable-linux",
            definitionRevision: 1,
            definitionSHA256: definitionSHA256,
            planRevision: 1,
            createdAtUnixMilliseconds: 1_700_000_000_000,
            updatedAtUnixMilliseconds: 1_700_000_000_000,
            backendDescriptor: VirtualizationFrameworkLinuxMachineBackend.backendDescriptor,
            backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
            resolverReference: reference,
            launchArtifacts: snapshot.launchArtifacts,
            components: runtime.components,
            resourceAdmission: lease.evidence,
            hostQualification: nil,
            plannerRequest: plannerRequest,
            plannerResult: plannerResult
        )
        #expect(plan.validate().isEmpty)
        _ = try ledger.bind(
            leaseID: lease.leaseID,
            to: plan,
            expectedLeaseRevision: lease.leaseRevision
        )
        let startRequest = DoryDaemonVirtualMachineStartInventoryRequest(
            machineID: plan.machineID,
            definitionRevision: plan.definitionRevision,
            planRevision: plan.planRevision,
            bootMediaReference: reference,
            exactCapabilityRequest: selected.request,
            resolvedPlan: plan
        )
        let startSnapshot = try context.inventory.startInventory(for: startRequest)
        #expect(startSnapshot.exactStartRuntimeQualification == nil)
        #expect(startSnapshot.backendRuntime(for: .appleVirtualizationFramework)?
            .hostQualification == nil)
        let authorizationProvider = try #require(context.inventory
            as? any DoryDaemonVirtualMachinePreSpawnAuthorizationProviding)
        try authorizationProvider.preSpawnAuthorization(for: startRequest).authorize()

        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try preparer.preparePlanningTrust(
                for: request(graphics: [.hostAcceleratedDisplay])
            )
        }
    }

    @Test("publication authorization refreshes immutable host identity but not volatile free bytes")
    func planningPublicationFreshness() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve(),
              let preparer = context.inventory
                as? any DoryDaemonVirtualMachinePlanningTrustPreparing else {
            Issue.record("Expected production planning trust preparer")
            return
        }
        let start = try fixture.makeBoundStartRequest()
        let freeStoragePreparation = try preparer.preparePlanningTrust(
            for: productionPlanningRequest(start)
        )
        var host = fixture.host
        host = DoryDaemonProductionHostObservation(
            hardwareModelIdentifier: host.hardwareModelIdentifier,
            operatingSystemBuild: host.operatingSystemBuild,
            macOSMajorVersion: host.macOSMajorVersion,
            virtualizationFrameworkAvailable: host.virtualizationFrameworkAvailable,
            hypervisorFrameworkAvailable: host.hypervisorFrameworkAvailable,
            metalAvailable: host.metalAvailable,
            resources: DoryVMHostResources(
                logicalCPUCount: host.resources.logicalCPUCount,
                physicalMemoryBytes: host.resources.physicalMemoryBytes,
                freeStorageBytes: host.resources.freeStorageBytes - 1
            )
        )
        fixture.hostState.set(host)
        try freeStoragePreparation.publicationAuthorization.authorize()

        let staleIdentityPreparation = try preparer.preparePlanningTrust(
            for: productionPlanningRequest(start)
        )
        host = DoryDaemonProductionHostObservation(
            hardwareModelIdentifier: host.hardwareModelIdentifier,
            operatingSystemBuild: host.operatingSystemBuild + "-changed",
            macOSMajorVersion: host.macOSMajorVersion,
            virtualizationFrameworkAvailable: host.virtualizationFrameworkAvailable,
            hypervisorFrameworkAvailable: host.hypervisorFrameworkAvailable,
            metalAvailable: host.metalAvailable,
            resources: host.resources
        )
        fixture.hostState.set(host)
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            try staleIdentityPreparation.publicationAuthorization.authorize()
        }
    }

    @Test("installed Linux boot verification hashes the embedded kernel and initrd")
    func installedBootBundleContentVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-boot-content-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("boot.bundle").path
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data("kernel-payload".utf8),
                initrd: Data("initrd-payload".utf8),
                kernelISOPath: "/boot/kernel",
                initrdISOPath: "/boot/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: path
        )
        #expect(try DoryInstalledLinuxBootBundle.verifyContents(atPath: path).rootDevice
            == "/dev/vda2")

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xff
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(throws: DoryInstalledLinuxBootBundleError.self) {
            _ = try DoryInstalledLinuxBootBundle.verifyContents(atPath: path)
        }
    }
}

private enum ProductionTrustFixtureError: Error {
    case runtimeRejected
    case integrationTestDidNotComplete
}

private final class ProductionIntegrationTestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else {
            throw ProductionTrustFixtureError.integrationTestDidNotComplete
        }
        try result.get()
    }
}

/// Swift Testing runs synchronous cases on a bounded cooperative stack. This end-to-end case
/// deliberately nests the complete production planning and lifecycle transaction, whose Debug
/// frames exceed that test-only stack even though normal daemon threads and release builds do not.
private func withProductionIntegrationTestStack(
    _ operation: @escaping @Sendable () throws -> Void
) throws {
    let completion = ProductionIntegrationTestCompletion()
    let thread = Thread {
        do {
            try operation()
            completion.finish(.success(()))
        } catch {
            completion.finish(.failure(error))
        }
    }
    thread.stackSize = 8 * 1_024 * 1_024
    thread.start()
    try completion.wait()
}

private final class LockedPlanningCreateReply: @unchecked Sendable {
    struct Value {
        var ok = false
        var body: NSDictionary = [:]
        var message = "callback was not invoked"
    }

    private let lock = NSLock()
    private var stored = Value()

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(ok: Bool, body: NSDictionary, message: String) {
        lock.lock()
        stored = Value(ok: ok, body: body, message: message)
        lock.unlock()
    }
}

private final class ProductionCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class ProductionTrustFloorActivationState: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var count = 0

    init(remainingFailures: Int = 0) {
        self.remainingFailures = remainingFailures
    }

    var activationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func activate() throws {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw ProductionTrustFixtureError.runtimeRejected
        }
    }
}

private final class ProductionHostState: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: DoryDaemonProductionHostObservation

    init(_ observation: DoryDaemonProductionHostObservation) {
        self.observation = observation
    }

    func get() -> DoryDaemonProductionHostObservation {
        lock.lock()
        defer { lock.unlock() }
        return observation
    }

    func set(_ observation: DoryDaemonProductionHostObservation) {
        lock.lock()
        self.observation = observation
        lock.unlock()
    }
}

private func productionPlanningRequest(
    _ start: DoryDaemonVirtualMachineStartInventoryRequest
) -> DoryDaemonVirtualMachineInventoryRequest {
    let plan = start.resolvedPlan
    return DoryDaemonVirtualMachineInventoryRequest(
        machineID: plan.machineID,
        definitionRevision: plan.definitionRevision,
        guest: plan.guest,
        bootMedia: DoryVMBootMediaReference(
            id: "system",
            role: .system,
            kind: plan.bootMedia.media.kind,
            source: plan.bootMedia.media.source,
            artifact: plan.bootMedia.resolverReference!,
            removable: false
        ),
        launchArtifacts: plan.launchArtifacts.map { artifact in
            DoryDaemonVirtualMachineLaunchArtifactRequirement(
                reference: artifact.resolverReference,
                kind: artifact.media.kind,
                source: artifact.media.source,
                mutable: artifact.media.mutableProvenance != nil,
                usages: artifact.usages
            )
        },
        resources: DoryVMResourceRequest(
            virtualCPUCount: plan.resourceAdmission!.admittedVirtualCPUCount,
            memoryBytes: plan.resourceAdmission!.admittedMemoryBytes,
            diskBytes: plan.resourceAdmission!.admittedStorageBytes
        ),
        devices: plan.devices,
        acceptableGraphics: [plan.graphics],
        virtualHardwareABIVersion: plan.virtualHardwareABIVersion
    )
}

private func portableARM64ISO9660() -> Data {
    let blockSize = 2_048
    let partitionStartSector = 512
    let partitionSectors = 2_880
    var image = Data(
        repeating: 0,
        count: (partitionStartSector + partitionSectors) * 512
    )

    func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
    func record(_ name: Data, extent: UInt32, bytes: UInt32, directory: Bool) -> Data {
        var value = Data(
            repeating: 0,
            count: 33 + name.count + (name.count.isMultiple(of: 2) ? 1 : 0)
        )
        value[0] = UInt8(value.count)
        put32(extent, into: &value, at: 2)
        put32(bytes, into: &value, at: 10)
        value[25] = directory ? 0x02 : 0
        put16(1, into: &value, at: 28)
        value[32] = UInt8(name.count)
        value.replaceSubrange(33..<(33 + name.count), with: name)
        return value
    }
    func writeDirectory(_ records: [Data], lba: Int) {
        var block = Data(repeating: 0, count: blockSize)
        var offset = 0
        for record in records {
            block.replaceSubrange(offset..<(offset + record.count), with: record)
            offset += record.count
        }
        image.replaceSubrange((lba * blockSize)..<((lba + 1) * blockSize), with: block)
    }
    var loader = Data(repeating: 0, count: 512)
    loader[0] = 0x4D
    loader[1] = 0x5A
    put32(0x80, into: &loader, at: 0x3C)
    loader.replaceSubrange(0x80..<0x84, with: Data([0x50, 0x45, 0, 0]))
    put16(0xAA64, into: &loader, at: 0x84)
    put16(1, into: &loader, at: 0x86)
    put16(0xF0, into: &loader, at: 0x94)
    put16(0x0002, into: &loader, at: 0x96)
    put16(0x020B, into: &loader, at: 0x98)
    put32(64, into: &loader, at: 0x98 + 4)
    put32(0x1C0, into: &loader, at: 0x98 + 16)
    put32(0x1C0, into: &loader, at: 0x98 + 20)
    put32(0x20, into: &loader, at: 0x98 + 32)
    put32(0x20, into: &loader, at: 0x98 + 36)
    put32(0x200, into: &loader, at: 0x98 + 56)
    put32(0x1C0, into: &loader, at: 0x98 + 60)
    put16(10, into: &loader, at: 0x98 + 68)
    put32(16, into: &loader, at: 0x98 + 108)
    let section = 0x80 + 24 + 0xF0
    loader.replaceSubrange(section..<(section + 5), with: Data(".text".utf8))
    put32(64, into: &loader, at: section + 8)
    put32(0x1C0, into: &loader, at: section + 12)
    put32(64, into: &loader, at: section + 16)
    put32(0x1C0, into: &loader, at: section + 20)
    put32(0x6000_0020, into: &loader, at: section + 36)
    loader[0x1C0] = 0xC3

    var primary = Data(repeating: 0, count: blockSize)
    primary[0] = 1
    primary.replaceSubrange(1..<6, with: Data("CD001".utf8))
    primary[6] = 1
    let root = record(Data([0]), extent: 20, bytes: UInt32(blockSize), directory: true)
    primary.replaceSubrange(156..<(156 + root.count), with: root)
    image.replaceSubrange((16 * blockSize)..<(17 * blockSize), with: primary)
    var terminator = Data(repeating: 0, count: blockSize)
    terminator[0] = 255
    terminator.replaceSubrange(1..<6, with: Data("CD001".utf8))
    terminator[6] = 1
    image.replaceSubrange((17 * blockSize)..<(18 * blockSize), with: terminator)

    writeDirectory([
        record(Data([0]), extent: 20, bytes: UInt32(blockSize), directory: true),
        record(Data([1]), extent: 20, bytes: UInt32(blockSize), directory: true),
        record(Data("EFI".utf8), extent: 21, bytes: UInt32(blockSize), directory: true),
    ], lba: 20)
    writeDirectory([
        record(Data([0]), extent: 21, bytes: UInt32(blockSize), directory: true),
        record(Data([1]), extent: 20, bytes: UInt32(blockSize), directory: true),
        record(Data("BOOT".utf8), extent: 22, bytes: UInt32(blockSize), directory: true),
    ], lba: 21)
    writeDirectory([
        record(Data([0]), extent: 22, bytes: UInt32(blockSize), directory: true),
        record(Data([1]), extent: 21, bytes: UInt32(blockSize), directory: true),
        record(
            Data("BOOTAA64.EFI".utf8),
            extent: 23,
            bytes: UInt32(loader.count),
            directory: false
        ),
    ], lba: 22)
    image.replaceSubrange(
        (23 * blockSize)..<(23 * blockSize + loader.count),
        with: loader
    )

    func putFAT12(_ value: UInt16, cluster: UInt16, into fat: inout Data) {
        let offset = Int(cluster) + Int(cluster / 2)
        if cluster & 1 == 0 {
            fat[offset] = UInt8(truncatingIfNeeded: value)
            fat[offset + 1] = (fat[offset + 1] & 0xF0)
                | UInt8(truncatingIfNeeded: value >> 8) & 0x0F
        } else {
            fat[offset] = (fat[offset] & 0x0F)
                | UInt8(truncatingIfNeeded: value << 4) & 0xF0
            fat[offset + 1] = UInt8(truncatingIfNeeded: value >> 4)
        }
    }
    func shortEntry(
        base: String,
        ext: String = "",
        attributes: UInt8,
        cluster: UInt16,
        bytes: UInt32
    ) -> Data {
        var entry = Data(repeating: 0, count: 32)
        let baseBytes = Array(base.utf8.prefix(8))
        let extBytes = Array(ext.utf8.prefix(3))
        entry.replaceSubrange(0..<8, with: Data(
            baseBytes + Array(repeating: 0x20, count: 8 - baseBytes.count)
        ))
        entry.replaceSubrange(8..<11, with: Data(
            extBytes + Array(repeating: 0x20, count: 3 - extBytes.count)
        ))
        entry[11] = attributes
        put16(cluster, into: &entry, at: 26)
        put32(bytes, into: &entry, at: 28)
        return entry
    }

    image[446 + 4] = 0xEF
    put32(UInt32(partitionStartSector), into: &image, at: 446 + 8)
    put32(UInt32(partitionSectors), into: &image, at: 446 + 12)
    image[510] = 0x55
    image[511] = 0xAA
    let partitionOffset = partitionStartSector * 512
    var fatBoot = Data(repeating: 0, count: 512)
    fatBoot.replaceSubrange(0..<3, with: Data([0xEB, 0x3C, 0x90]))
    put16(512, into: &fatBoot, at: 11)
    fatBoot[13] = 1
    put16(1, into: &fatBoot, at: 14)
    fatBoot[16] = 2
    put16(224, into: &fatBoot, at: 17)
    put16(UInt16(partitionSectors), into: &fatBoot, at: 19)
    fatBoot[21] = 0xF0
    put16(9, into: &fatBoot, at: 22)
    fatBoot[510] = 0x55
    fatBoot[511] = 0xAA
    image.replaceSubrange(partitionOffset..<(partitionOffset + 512), with: fatBoot)
    var fat = Data(repeating: 0, count: 9 * 512)
    fat[0] = 0xF0
    fat[1] = 0xFF
    fat[2] = 0xFF
    for cluster: UInt16 in [2, 3, 4] {
        putFAT12(0x0FFF, cluster: cluster, into: &fat)
    }
    let firstFAT = partitionOffset + 512
    image.replaceSubrange(firstFAT..<(firstFAT + fat.count), with: fat)
    image.replaceSubrange((firstFAT + fat.count)..<(firstFAT + fat.count * 2), with: fat)
    let rootOffset = partitionOffset + 19 * 512
    let rootEntry = shortEntry(
        base: "EFI",
        attributes: 0x10,
        cluster: 2,
        bytes: 0
    )
    image.replaceSubrange(rootOffset..<(rootOffset + rootEntry.count), with: rootEntry)
    let dataOffset = partitionOffset + 33 * 512
    let efiEntry = shortEntry(
        base: "BOOT",
        attributes: 0x10,
        cluster: 3,
        bytes: 0
    )
    image.replaceSubrange(dataOffset..<(dataOffset + efiEntry.count), with: efiEntry)
    let loaderEntry = shortEntry(
        base: "BOOTAA64",
        ext: "EFI",
        attributes: 0x20,
        cluster: 4,
        bytes: UInt32(loader.count)
    )
    image.replaceSubrange(
        (dataOffset + 512)..<(dataOffset + 512 + loaderEntry.count),
        with: loaderEntry
    )
    image.replaceSubrange(
        (dataOffset + 1_024)..<(dataOffset + 1_024 + loader.count),
        with: loader
    )
    return image
}

private final class ProductionTrustFixture: @unchecked Sendable {
    let root: URL
    let drive: DoryDataDrive
    let store: DoryComponentStore
    let machineConfiguration: MachineManagerConfiguration
    let appVersion = "1.0.0"
    let manifestPath = "vm-qualifications.json"
    let privateKey = Curve25519.Signing.PrivateKey()
    let helperDigest: String
    let runtimeBuildIdentifier: String
    let mediaPath: String
    let mediaDigest: String
    let directKernelPath: String
    let directKernelDigest: String
    let mediaReference = DoryVMResolverReference(
        namespace: "artifact",
        identifier: "qualified-linux-boot"
    )
    let storagePath: String
    let storageReference = DoryVMResolverReference(
        namespace: "artifact",
        identifier: "qualified-linux-disk"
    )
    let guest = DoryGuestPlatform(family: .linux, architecture: .arm64)
    let host = DoryDaemonProductionHostObservation(
        hardwareModelIdentifier: "Mac16,1",
        operatingSystemBuild: "26A5406c",
        macOSMajorVersion: 26,
        virtualizationFrameworkAvailable: true,
        hypervisorFrameworkAvailable: true,
        metalAvailable: true,
        resources: DoryVMHostResources(
            logicalCPUCount: 12,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            freeStorageBytes: 512 * 1_024 * 1_024 * 1_024
        )
    )
    let hostState: ProductionHostState
    var factory: DoryDaemonVirtualMachineProductionTrustFactory!
    var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    init(
        catalogSchemaVersion: Int = 2,
        catalogReleaseVersion: String = "1.0.0",
        catalogGeneratedAt: String = "2026-08-20T12:00:00.000Z",
        installCatalog: Bool = true,
        daemonTeamIdentifier: String? = DorydXPCSecurity.productionTeamID,
        runtimeVerificationFails: Bool = false,
        planningTransactionAvailable: Bool = true,
        trustFloorDirectorySyncFails: Bool = false,
        trustFloorActivationState: ProductionTrustFloorActivationState? = nil,
        helperLifetimeSeconds: UInt = 30
    ) throws {
        let helperData = Data("#!/bin/sh\nexec /bin/sleep \(helperLifetimeSeconds)\n".utf8)
        helperDigest = Self.digest(helperData)
        hostState = ProductionHostState(host)
        // The production broker deliberately rejects symlinked ancestors and group/world-
        // writable user-owned ancestors. `/Users/Shared` is a root-owned sticky directory, which
        // is the primitive's explicit safe temporary-fixture exception.
        root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true).appendingPathComponent(
            "dory-production-trust-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        drive = try DoryDataDrive(home: root.path)
        try drive.prepare()
        store = DoryComponentStore(drive: drive)
        try store.prepare()
        let state = URL(fileURLWithPath: drive.machinesDirectory, isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        let vz = root.appendingPathComponent("dory-vmm").path
        let raw = root.appendingPathComponent("dory-hv").path
        for path in [vz, raw] {
            try helperData.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        machineConfiguration = MachineManagerConfiguration(
            vmmExecutablePath: vz,
            acceleratedDesktopExecutablePath: raw,
            stateDirectory: state.path,
            runtimeDirectory: root.appendingPathComponent("runtime").path,
            requiresReadyHandoff: false
        )
        runtimeBuildIdentifier = "sha256:\(helperDigest)"
        mediaPath = root.appendingPathComponent("qualified-linux.boot").path
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data("qualified-kernel".utf8),
                initrd: Data("qualified-initrd".utf8),
                kernelISOPath: "/boot/kernel",
                initrdISOPath: "/boot/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: mediaPath
        )
        mediaDigest = try DoryComponentCatalogVerifier.fileDigest(mediaPath)
        directKernelPath = root.appendingPathComponent("qualified-direct-kernel").path
        try Data("qualified-direct-kernel".utf8).write(
            to: URL(fileURLWithPath: directKernelPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: directKernelPath
        )
        directKernelDigest = try DoryComponentCatalogVerifier.fileDigest(directKernelPath)
        storagePath = root.appendingPathComponent("qualified-linux.raw").path
        try Data(repeating: 0x5a, count: 4_096).write(
            to: URL(fileURLWithPath: storagePath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storagePath
        )
        let artifactAuthority = DoryVirtualMachineArtifactAuthority(
            root: state.path + "/.artifact-authority"
        )
        _ = try artifactAuthority.publishImmutable(
            reference: mediaReference,
            path: mediaPath,
            kind: .installedLinuxBootBundle,
            source: .bundledByDory
        )
        _ = try artifactAuthority.publishMutable(
            reference: storageReference,
            path: storagePath,
            source: .userProvided
        )

        if installCatalog {
            try installCatalogFixture(
                schemaVersion: catalogSchemaVersion,
                releaseVersion: catalogReleaseVersion,
                generatedAt: catalogGeneratedAt
            )
        }
        let digest = helperDigest
        let build = runtimeBuildIdentifier
        let observedHostState = hostState
        let floorActivator:
            DoryDaemonVirtualMachineProductionTrustFactory.TrustFloorActivator?
        if let trustFloorActivationState {
            floorActivator = { _, _, _ in
                try trustFloorActivationState.activate()
            }
        } else {
            floorActivator = nil
        }
        factory = DoryDaemonVirtualMachineProductionTrustFactory(
            authorityResolver: { store, key, architecture, appVersion in
                try DoryVirtualMachineQualificationAuthorityResolver.resolve(
                    store: store,
                    publicKey: key,
                    expectedArchitecture: architecture,
                    appVersion: appVersion
                )
            },
            runtimeVerifier: { path, descriptor, component in
                if runtimeVerificationFails { throw ProductionTrustFixtureError.runtimeRejected }
                return DoryDaemonVerifiedBackendRuntime(
                    descriptor: descriptor,
                    executablePath: path,
                    runtimeBuildIdentifier: build,
                    components: [DoryVirtualMachineQualifiedComponent(
                        componentIdentifier: component,
                        buildIdentifier: build,
                        artifactSHA256: digest
                    )]
                )
            },
            hostProbe: { _ in observedHostState.get() },
            daemonIdentityVerifier: {
                daemonTeamIdentifier == DorydXPCSecurity.productionTeamID
            },
            planningTransactionAvailable: { planningTransactionAvailable },
            synchronizeTrustFloorDirectory: { descriptor in
                !trustFloorDirectorySyncFails && fsync(descriptor) == 0
            },
            trustFloorActivator: floorActivator
        )
    }

    func resolve() -> DoryDaemonVirtualMachineProductionTrustReadiness {
        factory.resolve(
            store: store,
            machineConfiguration: machineConfiguration,
            appVersion: appVersion,
            publicKey: publicKey,
            expectedArchitecture: "arm64"
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func makeBoundStartRequest() throws -> DoryDaemonVirtualMachineStartInventoryRequest {
        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 4 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        let definitionSHA = Self.digest(Data("definition".utf8))
        let binding = DoryVirtualMachineResourceAdmissionPlanBinding(
            machineID: "qualified-linux",
            definitionRevision: 1,
            definitionSHA256: definitionSHA,
            plannedPlanRevision: 1
        )
        let ledger = DoryVirtualMachineResourceAdmissionLedger(
            root: machineConfiguration.stateDirectory + "/.resource-admissions"
        )
        let lease = try ledger.reserveStarting(
            binding: binding,
            hostFacts: host.resources,
            workload: .desktop,
            resources: resources
        )
        let devices = productionTrustDesktopDevices()
        let media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: mediaDigest
        )
        let capabilityRequest = DoryVirtualMachineCapabilityRequest(
            guest: guest,
            bootMedia: media,
            backend: .doryHypervisor,
            graphics: .software,
            devices: devices
        )
        let authority = try DoryVirtualMachineQualificationAuthorityResolver.resolve(
            store: store,
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: appVersion
        )
        let runtimeComponent = DoryVirtualMachineQualifiedComponent(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuildIdentifier,
            artifactSHA256: helperDigest
        )
        let qualification = try authority.resolve(
            request: capabilityRequest,
            backendImplementationIdentifier:
                RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
            hostHardwareModelIdentifier: host.hardwareModelIdentifier,
            hostOperatingSystemBuild: host.operatingSystemBuild,
            installedComponents: [runtimeComponent]
        )
        let hostFacts = DoryAppleSiliconHostFacts(
            macOSMajorVersion: host.macOSMajorVersion,
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
                doryHypervisorRuntimeBuildID: runtimeBuildIdentifier,
                virtualizationFrameworkAdapterBuildID: "",
                qemuRuntimeBuildID: ""
            )
        )
        let descriptor = DoryAppleSiliconCapabilityEvaluator.evaluate(
            capabilityRequest,
            host: hostFacts,
            trustedGuestImageGraphicsQualification: qualification.graphics,
            trustedRuntimeQualification: qualification.runtime
        )
        #expect(descriptor.availability.isUsable)
        let storageArtifact = try DoryVirtualMachineArtifactAuthority(
            root: machineConfiguration.stateDirectory + "/.artifact-authority"
        ).resolve(
            reference: storageReference,
            kind: .virtualDisk,
            source: .userProvided
        )
        let plan = DoryResolvedMachinePlan(
            machineID: binding.machineID,
            definitionRevision: binding.definitionRevision,
            definitionSHA256: definitionSHA,
            planRevision: binding.plannedPlanRevision,
            createdAtUnixMilliseconds: 1_700_000_000_000,
            updatedAtUnixMilliseconds: 1_700_000_000_000,
            guest: guest,
            backend: .doryHypervisor,
            backendImplementationIdentifier:
                RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
            virtualHardwareABIVersion: 1,
            rawHVVirtualHardwareTopology: productionTrustRawHVTopology(),
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: mediaReference,
                media: media
            ),
            launchArtifacts: resolvedBootLaunchArtifacts(
                reference: mediaReference, media: media, identifier: "system"
            ) + [DoryResolvedMachineLaunchArtifact(
                resolverReference: storageArtifact.reference,
                media: storageArtifact.media,
                authorityRevision: storageArtifact.authorityRevision,
                usages: [DoryResolvedMachineLaunchArtifactUsage(
                    kind: .storage, identifier: "system-disk", readOnly: false
                )],
                mutableProvenanceEvidence:
                    storageArtifact.mutableProvenance?.persistedAuditEvidence
            )],
            components: [DoryResolvedBackendComponentEvidence(
                componentIdentifier: "dory-hv",
                buildIdentifier: runtimeBuildIdentifier,
                artifactSHA256: helperDigest
            )],
            devices: devices,
            graphics: .software,
            supportTier: .supported,
            selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: DoryVirtualMachineBackendPlanRequest(
                    guest: guest,
                    bootMedia: media,
                    acceptableGraphics: [.software],
                    devices: devices,
                    backendPreferences: [.doryHypervisor],
                    backendPreferencePolicy: .required
                ),
                selectedEvaluationIndex: 0,
                rejectedCandidates: []
            ),
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                graphics: descriptor.graphicsQualificationEvidence,
                runtime: descriptor.runtimeQualificationEvidence
            ),
            resourceAdmission: lease.evidence,
            hostQualification: DoryResolvedHostQualificationEvidence(
                qualificationIdentity: qualification.record.qualificationIdentity,
                qualificationReportSHA256: Self.digest(
                    try Self.canonicalData(qualification.record)
                ),
                hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                hostOperatingSystemBuild: host.operatingSystemBuild,
                backend: .doryHypervisor,
                backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
                virtualHardwareABIVersion: 1,
                qualifierIdentifier: "dory.catalog-v2.virtual-machine-qualification",
                qualifierVersion: 1
            )
        )
        #expect(plan.validate().isEmpty)
        _ = try ledger.bind(
            leaseID: lease.leaseID,
            to: plan,
            expectedLeaseRevision: lease.leaseRevision
        )
        return DoryDaemonVirtualMachineStartInventoryRequest(
            machineID: plan.machineID,
            definitionRevision: plan.definitionRevision,
            planRevision: plan.planRevision,
            bootMediaReference: mediaReference,
            exactCapabilityRequest: capabilityRequest,
            resolvedPlan: plan
        )
    }

    func installCatalogFixture(
        schemaVersion: Int,
        releaseVersion: String,
        generatedAt: String
    ) throws {
        let signingKeyID = Self.digest(privateKey.publicKey.rawRepresentation)
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let desktopDevices = productionTrustDesktopDevices()
        let headlessDevices = DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .init(macAddress: "02:00:00:00:00:01"),
            clipboardPolicy: .disabled,
            clockSynchronization: true,
            gracefulShutdown: true
        )
        let components = ["dory-hv", "dory-vmm"].map {
            DoryVirtualMachineQualifiedComponent(
                componentIdentifier: $0,
                buildIdentifier: runtimeBuildIdentifier,
                artifactSHA256: helperDigest
            )
        }
        let backends = [
            (DoryVirtualizationBackendIdentity.doryHypervisor,
             RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier,
             "dory-hv"),
            (DoryVirtualizationBackendIdentity.appleVirtualizationFramework,
             VirtualizationFrameworkLinuxMachineBackend.backendDescriptor.implementationIdentifier,
             "dory-vmm"),
        ]
        let media = [
            (DoryBootMediaKind.installedLinuxBootBundle, mediaDigest, "bundle"),
            (DoryBootMediaKind.linuxKernel, directKernelDigest, "kernel"),
        ]
        let records = backends.flatMap { backend, implementation, component in
            media.flatMap { mediaKind, mediaDigest, mediaSuffix in
                [
                    ("minimum", devices, DoryGraphicsAccelerationLevel.none),
                    ("headless", headlessDevices, DoryGraphicsAccelerationLevel.none),
                    ("desktop", desktopDevices, .software),
                ].map { suffix, devices, graphics in
                    DoryVirtualMachineQualificationRecord(
                        qualificationIdentity: "\(component)-\(mediaSuffix)-\(suffix)-qualification",
                        guest: guest,
                        bootMediaKind: mediaKind,
                        bootMediaSource: .bundledByDory,
                        immutableArtifactSHA256: mediaDigest,
                        backend: backend,
                        backendImplementationIdentifier: implementation,
                        backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
                        virtualHardwareABIVersion: 1,
                        graphics: graphics,
                        devices: devices,
                        hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                        hostOperatingSystemBuild: host.operatingSystemBuild,
                        components: [components.first { $0.componentIdentifier == component }!],
                        virtioGPUKernelAndDeviceSupportQualified: graphics != .none,
                        producerFenceBeforeFlushQualified: graphics != .none,
                        venusVulkanGuestRuntimeQualified: false
                    )
                }
            }
        }
        let manifest = DoryVirtualMachineQualificationManifest(
            manifestIdentity: "production-vm-qualification-1",
            catalogReleaseVersion: releaseVersion,
            architecture: "arm64",
            signingKeyID: signingKeyID,
            records: records
        )
        let manifestData = try Self.encoded(manifest)
        let isVersionTwo = schemaVersion == DoryComponentCatalog.schemaVersion
        let provenance = isVersionTwo ? DoryComponentProvenance(
            sourceCommit: String(repeating: "1", count: 40),
            builder: "dory.production-trust.fixture",
            recipeDigest: String(repeating: "2", count: 64),
            sbomDigest: String(repeating: "3", count: 64),
            attestationDigest: Self.digest(manifestData)
        ) : nil
        let hostRequirements = isVersionTwo
            ? DoryComponentHostRequirements(platform: "macos", minimumVersion: "14.0")
            : nil
        let asset = DoryComponentAsset(
            path: manifestPath,
            url: "https://example.invalid/qualification.json",
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            sha256: Self.digest(manifestData),
            installedSHA256: Self.digest(manifestData),
            role: isVersionTwo ? .qualificationEvidence : nil
        )
        let release = DoryComponentRelease(
            id: .linuxMachines,
            version: releaseVersion,
            displayName: "Linux Machines",
            summary: "Qualified VM runtime",
            dependencies: [.dockerCore],
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            assets: [asset],
            architectures: isVersionTwo ? ["arm64"] : nil,
            hostRequirements: hostRequirements,
            provides: isVersionTwo ? ["guest.linux-headless.arm64@1"] : nil,
            requires: isVersionTwo ? ["app.dory-core>=\(appVersion)"] : nil,
            provenance: provenance,
            qualification: isVersionTwo ? records.map(\.qualificationIdentity) : nil
        )
        let core = DoryComponentRelease(
            id: .dockerCore,
            version: releaseVersion,
            displayName: "Docker Core",
            summary: "Bundled core",
            dependencies: [],
            downloadBytes: 1,
            installedBytes: 1,
            assets: [],
            architectures: isVersionTwo ? ["arm64"] : nil,
            hostRequirements: hostRequirements,
            provides: isVersionTwo ? ["app.dory-core@\(releaseVersion)"] : nil,
            requires: isVersionTwo ? [] : nil,
            provenance: provenance,
            qualification: isVersionTwo ? [] : nil
        )
        let catalog = DoryComponentCatalog(
            schemaVersion: schemaVersion,
            releaseVersion: releaseVersion,
            generatedAt: generatedAt,
            minimumAppVersion: appVersion,
            architecture: "arm64",
            components: [core, release],
            virtualMachineQualification: schemaVersion == 2
                ? DoryComponentVirtualMachineQualificationAsset(
                    component: .linuxMachines,
                    path: manifestPath,
                    manifestIdentity: manifest.manifestIdentity,
                    manifestFormatVersion: manifest.schemaVersion,
                    signingKeyID: signingKeyID
                ) : nil
        )
        let catalogData = try Self.encoded(catalog)
        let signature = try privateKey.signature(for: catalogData).base64EncodedString()
        _ = try store.cacheCatalog(
            data: catalogData,
            signature: signature,
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: appVersion
        )
        let source = root.appendingPathComponent("qualification.json")
        try manifestData.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        _ = try store.install(
            release,
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: [manifestPath: source.path]
        )
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func productionTrustDesktopDevices()
    -> DoryVirtualMachineDeviceCapabilityRequest {
    DoryVirtualMachineDeviceCapabilityRequest(
        networkInterface: .stable(machineID: "qualified-linux"),
        display: DoryVirtualMachineDisplayCapabilityRequest(
            widthPixels: 1_920,
            heightPixels: 1_080
        )
    )
}

private func productionTrustRawHVTopology() -> DoryRawHVVirtualHardwareTopology {
    try! DoryRawHVVirtualHardwareTopology(occupiedSlots: [
        DoryRawHVVirtualDeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .systemDisk,
                stableID: "qualified-linux-system-disk"
            ),
            role: .systemDisk,
            mmioSlot: 0
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-graphics",
            role: .graphics,
            mmioSlot: 1
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-entropy",
            role: .entropy,
            mmioSlot: 2
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-balloon",
            role: .balloon,
            mmioSlot: 3
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-vsock",
            role: .vsock,
            mmioSlot: 4
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: "nic0"
            ),
            role: .network,
            mmioSlot: 8
        ),
    ])
}
