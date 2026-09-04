import CryptoKit
import DoryCore
@testable import DorydKit
import DoryOperations
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
import Testing
import XCTest

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

    @Test("production restart preflight retains running admission and cannot authorize spawn")
    func restartPreflightPreservesProductionAdmission() throws {
        let fixture = try ProductionTrustFixture()
        defer { fixture.cleanup() }
        guard case let .ready(context) = fixture.resolve(),
              let provider = context.inventory as? any DoryDaemonVirtualMachinePreSpawnAuthorizationProviding else {
            Issue.record("Expected production pre-spawn authority")
            return
        }
        var request = try fixture.makeBoundStartRequest()
        let ledger = DoryVirtualMachineResourceAdmissionLedger(
            root: fixture.machineConfiguration.stateDirectory + "/.resource-admissions"
        )
        let lease = try #require(ledger.snapshot().leases.first)
        let running = try ledger.markRunning(
            leaseID: lease.leaseID, plan: request.resolvedPlan, hostFacts: fixture.host.resources,
            expectedLeaseRevision: lease.leaseRevision
        )
        let recordURL = URL(fileURLWithPath: ledger.root + "/resource-admissions.json")
        let before = try Data(contentsOf: recordURL)
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try context.inventory.startInventory(for: request)
        }
        request = DoryDaemonVirtualMachineStartInventoryRequest(
            resolvedPlan: request.resolvedPlan, purpose: .restartPreflight
        )
        let inventory = try context.inventory.startInventory(for: request)
        #expect(inventory.resourceAdmission == running.evidence)
        let preflight = try provider.preSpawnAuthorization(for: request)
        try preflight.authorizeRestartPreflight()
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed) {
            try preflight.authorizeRestartPreflight()
        }
        let attemptedLaunch = try provider.preSpawnAuthorization(for: request)
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed) {
            try attemptedLaunch.authorize()
        }
        #expect(try Data(contentsOf: recordURL) == before)
        _ = try ledger.markStopped(leaseID: running.leaseID, expectedLeaseRevision: running.leaseRevision)
        let stoppedBytes = try Data(contentsOf: recordURL)
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try context.inventory.startInventory(for: request)
        }
        #expect(try Data(contentsOf: recordURL) == stoppedBytes)
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

    @Test("activated production graph publishes and runs a headless create plan through XPC authority")
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
        for paused in [false, true] {
            if paused { _ = try context.machineManager.pause(id: "qualified-headless") }
            let previousPID = try #require(context.machineManager.status(id: "qualified-headless")?.pid)
            let operationID = UUID()
            let replacement = try context.machineManager.restart(id: "qualified-headless", operationID: operationID)
            #expect(replacement.state == .running)
            #expect(replacement.pid != previousPID)
            #expect(try context.planning.plans.read(id: "qualified-headless") == plan)
            let retained = try #require(context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == "qualified-headless"
            })
            #expect(retained.leaseID == plan.resourceAdmission?.admissionIdentity)
            #expect(retained.state == .running)
            let replay = try context.machineManager.restart(id: "qualified-headless", operationID: operationID)
            #expect(replay.pid == replacement.pid)
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            #expect(try journal.read(operationID).state.status == .completed)
        }
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
        // Snapshot and restore authority has dedicated resolved-plan and lifecycle-journal suites.
        // Keep this production-composition case focused on XPC planning and admission transitions;
        // hashing its policy-minimum 16 GiB disk here made an unrelated path dominate the suite.
        let restopped = try context.machineManager.stop(id: "qualified-headless")
        #expect(restopped.state == .stopped)
        #expect(try context.planning.plans.read(id: "qualified-headless").planRevision == 2)
        #expect(try context.planning.resourceLedger.snapshot().leases.first {
            $0.binding.machineID == "qualified-headless"
        }?.state == .stopped)
        try context.machineManager.delete(id: "qualified-headless")
        #expect(try context.planning.resourceLedger.snapshot().leases.contains {
            $0.binding.machineID == "qualified-headless"
        } == false)
        }
    }

    @Test("configuration update has one caller journal through stop and replacement planning", arguments: ["created", "stopped", "running", "paused"])
    func configurationUpdateOwnsPlanning(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "configuration-update"
            let service = DorydService(
                socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
                machineManager: context.machineManager,
                productionPlanningController: context.planningController
            )
            try createUpdateFixture(id: id, fixture: fixture, service: service)
            if sourceState != "created" { _ = try context.machineManager.start(id: id) }
            if sourceState == "stopped" { _ = try context.machineManager.stop(id: id) }
            if sourceState == "paused" { _ = try context.machineManager.pause(id: id) }
            let original = try context.planning.plans.read(id: id)
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let before = try journal.list().count
            let operationID = UUID()
            let request: NSDictionary = ["memoryMB": UInt64(3_072), "operationID": operationID.uuidString.lowercased()]
            let result = LockedPlanningCreateReply()
            service.machineUpdate(id, config: request) { result.set(ok: $0, body: $1, message: $2) }
            #expect(result.value.ok, Comment(rawValue: result.value.message))
            let status = try #require(context.machineManager.status(id: id))
            #expect(status.state == .stopped)
            #expect(status.pid == nil)
            #expect(status.runtimeIdentity.mode == .resolvedPlan)
            let replacement = try context.planning.plans.read(id: id)
            #expect(replacement.planRevision == original.planRevision + 1)
            #expect(replacement.definitionSHA256 != original.definitionSHA256)
            #expect(try journal.list().count == before + 1)
            #expect(try journal.read(operationID).state.status == .completed)
            do {
                let lease = try journal.acquire(operationID)
                let operation = try lease.readWorkspaceLifecycleOperation()
                #expect(operation.kind == .updating)
                #expect(operation.source.state.rawValue == sourceState)
                let update = try DoryMachineConfigurationUpdateJournal.read(from: lease)
                #expect(try update.targetConfiguration.memoryMB == 3_072)
                #expect(update.requiresResolvedPlan)
            }
            let replay = LockedPlanningCreateReply()
            service.machineUpdate(id, config: request) { replay.set(ok: $0, body: $1, message: $2) }
            #expect(replay.value.ok, Comment(rawValue: replay.value.message))
            #expect(try context.planning.plans.read(id: id) == replacement)
            #expect(try journal.list().count == before + 1)
            let collision = LockedPlanningCreateReply()
            service.machineUpdate(id, config: ["memoryMB": UInt64(4_096), "operationID": operationID.uuidString.lowercased()]) {
                collision.set(ok: $0, body: $1, message: $2)
            }
            #expect(!collision.value.ok)
            #expect(try context.planning.plans.read(id: id) == replacement)
            let lease = try #require(context.planning.resourceLedger.snapshot().leases.first { $0.binding.machineID == id })
            #expect(lease.state == .starting)
            #expect(lease.evidence == replacement.resourceAdmission)
        }
    }

    @Test("configuration update recovery finishes partial metadata and final journal publication", arguments: [
        MachineLifecycleFaultPoint.configurationUpdateBeforeStop,
        .configurationUpdateAfterMetadata, .configurationUpdateAfterWorkspace,
        .stopAfterProcessStop, .completionBeforeJournalWrite(.updating),
    ], [false, true])
    func configurationUpdateRecovers(point: MachineLifecycleFaultPoint, nativeOnly: Bool) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "update-recovery"
            let service = DorydService(
                socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
                machineManager: context.machineManager, productionPlanningController: context.planningController
            )
            try createUpdateFixture(id: id, fixture: fixture, service: service)
            if point != .configurationUpdateBeforeStop { _ = try context.machineManager.start(id: id) }
            let original = try context.planning.plans.read(id: id)
            let operationID = UUID()
            let observedFault = ConfigurationUpdateFaultObservation()
            context.machineManager.installLifecycleFaultInjectorForTesting { observed in
                if observed == point {
                    observedFault.record()
                    throw MachineLifecycleInjectedCrash()
                }
            }
            #expect(throws: (any Error).self) {
                try context.machineManager.update(
                    id: id, memoryMB: nativeOnly ? nil : 3_072,
                    typedSettingsPatch: nativeOnly ? DoryMachineTypedSettingsPatch(guestUsername: .set("builder")) : nil,
                    operationID: operationID,
                    productionPlanningController: context.planningController
                )
            }
            try #require(observedFault.wasObserved, "Fault boundary was not reached: \(point), nativeOnly=\(nativeOnly)")
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            do {
                let lease = try journal.acquire(operationID)
                let update = try DoryMachineConfigurationUpdateJournal.read(from: lease)
                if nativeOnly {
                    #expect(update.sourceConfigurationData == update.targetConfigurationData)
                    #expect(update.targetNativeDefinition != nil)
                }
            }
            #expect(try journal.read(operationID).state.status != .completed)
            // A fresh composition reads the exact private operation specification. No physical
            // guest is booted by this fixture; it verifies helper stop and daemon publication/admission recovery only.
            let recovery = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            )
            guard case let .activated(recovered) = recovery else {
                Issue.record("Expected update recovery at \(point), nativeOnly=\(nativeOnly): \(recovery)"); return
            }
            if point == .configurationUpdateBeforeStop || point == .stopAfterProcessStop {
                #expect(try journal.read(operationID).state.status == .failed)
                #expect(try recovered.planning.plans.read(id: id) == original)
            } else {
                #expect(try journal.read(operationID).state.status == .completed)
                let replacement = try recovered.planning.plans.read(id: id)
                #expect(replacement.planRevision == original.planRevision + 1)
                #expect(recovered.machineManager.status(id: id)?.runtimeIdentity.resolvedPlan == replacement)
            }
            #expect(recovered.machineManager.status(id: id)?.state == .stopped)
        }
    }

    @Test("missing planning and malformed update UUID are rejected before stopping a helper")
    func configurationUpdatePreflightRejectsWithoutStop() throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "update-preflight"
            let service = DorydService(
                socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
                machineManager: context.machineManager, productionPlanningController: context.planningController
            )
            try createUpdateFixture(id: id, fixture: fixture, service: service)
            let started = try context.machineManager.start(id: id)
            let path = fixture.machineConfiguration.stateDirectory + "/" + id + "/machine.json"
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            let missingController = DorydService(socketPath: "/unused", machineManager: context.machineManager)
            for (target, request) in [
                (missingController, ["memoryMB": 3_072] as NSDictionary),
                (service, ["memoryMB": 3_072, "operationID": "invalid"] as NSDictionary),
            ] {
                let result = LockedPlanningCreateReply()
                target.machineUpdate(id, config: request) { result.set(ok: $0, body: $1, message: $2) }
                #expect(!result.value.ok)
                #expect(context.machineManager.status(id: id)?.pid == started.pid)
                #expect(context.machineManager.status(id: id)?.state == .running)
                #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
            }
            _ = try context.machineManager.stop(id: id)
        }
    }

    @Test("rejected planning recovers or accepts a new update without stranding the workspace", arguments: [false, true])
    func configurationUpdateAbortedPlanningCanRetry(aborts: Bool) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "update-rejected"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createUpdateFixture(id: id, fixture: fixture, service: service)
            let operationID = UUID()
            let host = fixture.host
            fixture.hostState.set(DoryDaemonProductionHostObservation(
                hardwareModelIdentifier: host.hardwareModelIdentifier,
                operatingSystemBuild: host.operatingSystemBuild,
                macOSMajorVersion: host.macOSMajorVersion,
                virtualizationFrameworkAvailable: host.virtualizationFrameworkAvailable,
                hypervisorFrameworkAvailable: !aborts, metalAvailable: host.metalAvailable,
                resources: DoryVMHostResources(logicalCPUCount: 12, physicalMemoryBytes: (aborts ? 32 : 2) * 1_024 * 1_024 * 1_024,
                                              freeStorageBytes: host.resources.freeStorageBytes)
            ))
            #expect(throws: (any Error).self) {
                try context.machineManager.update(id: id, memoryMB: 3_072, operationID: operationID,
                                                   productionPlanningController: context.planningController)
            }
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            if aborts {
                #expect(try journal.read(operationID).state.status == .failed)
            } else {
                #expect(try journal.read(operationID).state.status != .failed)
                #expect(try journal.read(operationID).state.status != .completed)
            }
            #expect(context.machineManager.status(id: id)?.runtimeIdentity.mode == .requiresReplanning)
            fixture.hostState.set(host)
            let activation = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            )
            guard case let .activated(recovered) = activation else {
                Issue.record("Aborted planning blocked recovery: \(activation)"); return
            }
            let replacement = try recovered.machineManager.update(id: id, memoryMB: 4_096,
                productionPlanningController: recovered.planningController)
            #expect(replacement.runtimeIdentity.mode == .resolvedPlan)
            #expect(replacement.state == .stopped)
        }
    }

    private func createUpdateFixture(id: String, fixture: ProductionTrustFixture, service: DorydService) throws {
        let disk = fixture.root.appendingPathComponent("\(id).raw")
        FileManager.default.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 16 * 1_024 * 1_024 * 1_024)
        try handle.synchronize()
        try handle.close()
        let result = LockedPlanningCreateReply()
        service.machineCreate([
            "id": id, "kernelPath": fixture.directKernelPath, "rootfsPath": disk.path,
            "displayMode": "headless", "memoryMB": UInt64(2_048), "cpuCount": 2,
        ]) { result.set(ok: $0, body: $1, message: $2) }
        #expect(result.value.ok, Comment(rawValue: result.value.message))
    }

    @Test("desktop update preflight preserves native source authority before artifact staging", arguments: [
        "valid-source", "missing-plan", "missing-workspace", "missing-kernel", "busy-workspace", "zero-operation",
    ], ["created", "stopped", "running"])
    func desktopUpdatePreflightPreservesSource(fault: String, sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "desktop-preflight"
            let disk = fixture.root.appendingPathComponent("desktop.raw")
            FileManager.default.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: 32 * 1_024 * 1_024 * 1_024)
            try handle.synchronize()
            try handle.close()
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            let create = LockedPlanningCreateReply()
            service.machineCreate([
                "id": id, "kernelPath": fixture.directKernelPath, "rootfsPath": disk.path,
                "displayMode": "desktop", "memoryMB": UInt64(4_096), "cpuCount": 4,
                "guestIdentityIntent": ["desktop": ["distributionIdentifier": "ubuntu"]],
                "desktopGraphicsPreference": "software",
            ]) { create.set(ok: $0, body: $1, message: $2) }
            try #require(create.value.ok, Comment(rawValue: create.value.message))
            defer { try? context.machineManager.delete(id: id) }
            if sourceState != "created" {
                _ = try context.machineManager.start(id: id)
                if sourceState == "stopped" { _ = try context.machineManager.stop(id: id) }
                else {
                    _ = try context.machineManager.pause(id: id)
                    _ = try context.machineManager.resume(id: id)
                }
            }
            let source = try #require(context.machineManager.status(id: id))
            #expect(source.environment.isEmpty)
            let observed = ConfigurationUpdateFaultObservation()
            context.machineManager.installDesktopUpdateArtifactResolver(DesktopPreflightArtifactProbe(observed: observed))
            let directory = fixture.machineConfiguration.stateDirectory + "/" + id
            let path: String?
            switch fault {
            case "missing-plan": path = directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            case "missing-workspace": path = directory + "/" + DoryWorkspaceRepository.recordFileName
            case "missing-kernel": path = directory + "/kernel"
            default: path = nil
            }
            let previous = try path.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            defer {
                if let path, let previous {
                    try? previous.write(to: URL(fileURLWithPath: path))
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                }
            }
            if let path { try FileManager.default.removeItem(atPath: path) }
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let competingLock = fault == "busy-workspace" ? try EngineStateDirectoryLock(
                stateDirectory: journal.root, lockFileName: ".mutation.\(id).lock", readOnly: true
            ) : nil
            defer { withExtendedLifetime(competingLock) {} }
            let before = try installerAuthoritySnapshot(root: fixture.root.path)
            let operationID = fault == "zero-operation" ? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) : UUID()
            #expect(throws: (any Error).self) {
                try context.machineManager.updateDesktop(id: id, request: .init(
                    operationID: operationID, distro: "ubuntu", version: "next+runtime.1",
                    distributionInstallationName: "ubuntu-installation", runtimeInstallationName: "runtime-installation"
                ))
            }
            #expect(observed.wasObserved == (fault == "valid-source"), "\(fault), \(sourceState)")
            let after = try #require(context.machineManager.status(id: id))
            #expect(after.pid == source.pid)
            #expect(after.state == source.state)
            #expect(after.readiness == source.readiness)
            #expect(after.runtimeIdentity == source.runtimeIdentity)
            #expect(try installerAuthoritySnapshot(root: fixture.root.path) == before)
        }
    }

    @Test("installer preflight preserves a live generation and durable authority on rejection", arguments: [
        "missing-controller", "missing-nvram", "pending-promotion", "missing-plan",
        "corrupt-plan", "missing-workspace", "missing-installer", "missing-reattach-media", "busy-workspace",
    ], [false, true])
    func installerPreflightPreservesSource(fault: String, paused: Bool) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-preflight"
            let service = DorydService(
                socketPath: fixture.root.appendingPathComponent("doryd.sock").path,
                machineManager: context.machineManager, productionPlanningController: context.planningController
            )
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            defer { try? context.machineManager.delete(id: id) }
            _ = try context.machineManager.start(id: id)
            let directory = fixture.machineConfiguration.stateDirectory + "/" + id
            let nvram = directory + "/NVRAM.installer"
            let machineIdentifier = directory + "/MachineIdentifier"
            try Data("stable-machine-identifier".utf8).write(to: URL(fileURLWithPath: machineIdentifier))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: machineIdentifier)
            try Data("installer-recorded-efi-boot-state".utf8).write(to: URL(fileURLWithPath: nvram))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nvram)
            let attaching = fault == "missing-reattach-media"
            if attaching {
                _ = try context.machineManager.transitionInstallerMedia(
                    id: id, attached: false, productionPlanningController: context.planningController
                )
            }
            // Settle the accepted start and then establish the requested source power state.
            _ = try context.machineManager.pause(id: id)
            if !paused { _ = try context.machineManager.resume(id: id) }
            let original = try #require(context.machineManager.status(id: id))
            #expect(original.state == (paused ? .paused : .running))
            let changedPath: String?
            switch fault {
            case "missing-nvram": changedPath = nvram
            case "pending-promotion": changedPath = directory + "/.dory-nvram-promotion-pending-v1"
            case "missing-plan", "corrupt-plan":
                changedPath = directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            case "missing-workspace": changedPath = directory + "/" + DoryWorkspaceRepository.recordFileName
            case "missing-installer", "missing-reattach-media": changedPath = directory + "/installer.iso"
            default: changedPath = nil
            }
            let originalBytes = try changedPath.flatMap { path in
                FileManager.default.fileExists(atPath: path) ? try Data(contentsOf: URL(fileURLWithPath: path)) : nil
            }
            defer {
                if let changedPath {
                    if let originalBytes {
                        try? originalBytes.write(to: URL(fileURLWithPath: changedPath))
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: changedPath)
                    } else { try? FileManager.default.removeItem(atPath: changedPath) }
                }
            }
            if let changedPath {
                if fault == "pending-promotion" || fault == "corrupt-plan" {
                    let bytes = fault == "pending-promotion" ? "dory-nvram-promotion-v1\nmachine=\(id)\n" : "{}"
                    try Data(bytes.utf8).write(to: URL(fileURLWithPath: changedPath))
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: changedPath)
                } else { try FileManager.default.removeItem(atPath: changedPath) }
            }
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let operationIDs = try journal.list().map(\.plan.id)
            let competingLock = fault == "busy-workspace" ? try EngineStateDirectoryLock(
                stateDirectory: journal.root, lockFileName: ".mutation.\(id).lock", readOnly: true
            ) : nil
            defer { withExtendedLifetime(competingLock) {} }
            let before = try installerAuthoritySnapshot(root: fixture.root.path)
            let target = fault == "missing-controller"
                ? DorydService(socketPath: "/unused", machineManager: context.machineManager) : service
            let result = LockedPlanningCreateReply()
            target.machineUpdate(id, config: ["installerMediaAttached": attaching]) {
                result.set(ok: $0, body: $1, message: $2)
            }
            #expect(!result.value.ok, "Preflight must reject \(fault), paused=\(paused)")
            let after = try #require(context.machineManager.status(id: id))
            #expect(after.pid == original.pid)
            #expect(after.state == original.state)
            #expect(after.readiness == original.readiness)
            #expect(after.runtimeIdentity == original.runtimeIdentity)
            #expect(after.installerMediaAttached == original.installerMediaAttached)
            #expect(try journal.list().map(\.plan.id) == operationIDs)
            #expect(try installerAuthoritySnapshot(root: fixture.root.path) == before,
                    "Rejected \(fault) changed durable authority, paused=\(paused)")
        }
    }

    private func installerAuthoritySnapshot(root: String) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        for relative in FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [] {
            guard !relative.hasSuffix(".log") else { continue }
            let path = root + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            // Hash every byte of authority files. Sparse guest disks are sampled at both ends;
            // their inode, permissions, length and modification time are also preserved.
            var bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            if info.st_size > 1_048_576 {
                try handle.seek(toOffset: UInt64(info.st_size) - 1_048_576)
                bytes.append(try handle.read(upToCount: 1_048_576) ?? Data())
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            snapshot[relative] = "\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(digest)"
        }
        return snapshot
    }

    private func createPortableEFIFixture(id: String, fixture: ProductionTrustFixture, service: DorydService) throws {
        let installer = fixture.root.appendingPathComponent("\(id).iso").path
        try portableARM64ISO9660().write(to: URL(fileURLWithPath: installer))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installer)
        let result = LockedPlanningCreateReply()
        service.machineCreate([
            "id": id, "kernelPath": "", "rootfsPath": "", "bootMode": "efi", "installerISOPath": installer,
            "diskSizeBytes": UInt64(32 * 1_024 * 1_024 * 1_024), "displayMode": "desktop",
            "memoryMB": UInt64(4_096), "cpuCount": 4,
        ]) { result.set(ok: $0, body: $1, message: $2) }
        try #require(result.value.ok, Comment(rawValue: result.value.message))
    }

    @Test("installer publication recovers the same operation after confirmed stop", arguments: [
        MachineLifecycleFaultPoint.stopAfterProcessStop, .installerAfterFirmwareCheckpoint,
        .configurationUpdateAfterMetadata, .configurationUpdateAfterWorkspace, .installerAfterPlanning,
    ], [false, true])
    func installerPublicationRecovers(point: MachineLifecycleFaultPoint, paused: Bool) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-recovery"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            _ = try context.machineManager.start(id: id)
            if paused { _ = try context.machineManager.pause(id: id) }
            for (name, bytes) in [("NVRAM.installer", "original-installer-state"), ("MachineIdentifier", "stable-machine-id")] {
                let path = fixture.machineConfiguration.stateDirectory + "/" + id + "/" + name
                try Data(bytes.utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let before = try journal.list().count
            let operationID = UUID()
            let observed = ConfigurationUpdateFaultObservation()
            context.machineManager.installLifecycleFaultInjectorForTesting { current in
                if current == point { observed.record(); throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: context.planningController)
            }
            try #require(observed.wasObserved, "Missing fault \(point), paused=\(paused)")
            #expect(try journal.read(operationID).state.status != .completed)
            let activation = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            )
            guard case let .activated(recovered) = activation else {
                Issue.record("Installer recovery failed at \(point), paused=\(paused): \(activation)"); return
            }
            defer { try? recovered.machineManager.delete(id: id) }
            let committed = point != .stopAfterProcessStop && point != .installerAfterFirmwareCheckpoint
            #expect(try journal.read(operationID).state.status == (committed ? .completed : .failed))
            #expect(recovered.machineManager.status(id: id)?.state == (committed ? .running : .stopped))
            #expect(recovered.machineManager.status(id: id)?.installerMediaAttached == !committed)
            #expect(try journal.list().count == before + 1)
            if committed {
                #expect(recovered.machineManager.status(id: id)?.failure == nil)
                let plan = try recovered.planning.plans.read(id: id)
                #expect(plan.bootMedia.media.kind == .virtualDisk)
                #expect(recovered.machineManager.status(id: id)?.runtimeIdentity.resolvedPlan == plan)
            }
        }
    }

    @Test("installer reattachment owns publication and optional restart", arguments: ["stopped", "running", "paused"])
    func installerAttachmentOwnsRestart(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-attach"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            defer { try? context.machineManager.delete(id: id) }
            _ = try context.machineManager.start(id: id)
            let directory = fixture.machineConfiguration.stateDirectory + "/" + id
            for name in ["NVRAM.installer", "MachineIdentifier"] {
                let path = directory + "/" + name
                try Data("original-\(name)".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            _ = try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                productionPlanningController: context.planningController)
            if sourceState == "stopped" { _ = try context.machineManager.stop(id: id) }
            if sourceState == "paused" { _ = try context.machineManager.pause(id: id) }
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let before = try journal.list().count
            let operationID = UUID()
            let result = try context.machineManager.transitionInstallerMedia(id: id, attached: true,
                operationID: operationID, productionPlanningController: context.planningController)
            #expect(result.installerMediaAttached)
            #expect(result.state == (sourceState == "stopped" ? .stopped : .running))
            let plan = try context.planning.plans.read(id: id)
            #expect(plan.bootMedia.media.kind == .installerISO)
            #expect(result.runtimeIdentity.resolvedPlan == plan)
            #expect(try journal.list().count == before + 1)
            #expect(try journal.read(operationID).state.status == .completed)
            let replay = try context.machineManager.transitionInstallerMedia(id: id, attached: true,
                operationID: operationID, productionPlanningController: context.planningController)
            #expect(replay.pid == result.pid)
            #expect(replay.state == result.state)
            #expect(try context.planning.plans.read(id: id) == plan)
            #expect(try journal.list().count == before + 1)
        }
    }

    @Test("installer replay before quiescence preserves the original live helper", arguments: [false, true])
    func installerPreStopReplay(paused: Bool) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-pre-stop"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            defer { try? context.machineManager.delete(id: id) }
            _ = try context.machineManager.start(id: id)
            if paused { _ = try context.machineManager.pause(id: id) }
            let directory = fixture.machineConfiguration.stateDirectory + "/" + id
            for name in ["NVRAM.installer", "MachineIdentifier"] {
                let path = directory + "/" + name
                try Data("original-\(name)".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let original = try #require(context.machineManager.status(id: id))
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let before = try journal.list().count
            let operationID = UUID()
            let observed = ConfigurationUpdateFaultObservation()
            context.machineManager.installLifecycleFaultInjectorForTesting { point in
                if point == .configurationUpdateBeforeStop { observed.record(); throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: context.planningController)
            }
            try #require(observed.wasObserved)
            context.machineManager.installLifecycleFaultInjectorForTesting { _ in }
            #expect(throws: (any Error).self) {
                try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: context.planningController)
            }
            let result = try #require(context.machineManager.status(id: id))
            #expect(result.pid == original.pid)
            #expect(result.state == original.state)
            #expect(result.runtimeIdentity == original.runtimeIdentity)
            #expect(result.installerMediaAttached)
            #expect(result.failure?.recoveryDisposition == .rollbackCompleted)
            #expect(try journal.list().count == before + 1)
            #expect(try journal.read(operationID).state.status == .failed)
        }
    }

    @Test("installer boot failure restores firmware media and source power in the same operation",
          arguments: [MachineLifecycleFaultPoint.installerAfterPlanning, .installerAfterFirstBoot],
          0..<6)
    func installerRollbackOwnsRecovery(point: MachineLifecycleFaultPoint, scenario: Int) throws {
        let paused = scenario & 1 != 0
        let interruptRollback = scenario >= 2
        let rollbackFault: MachineLifecycleFaultPoint = scenario >= 4
            ? .configurationUpdateAfterMetadata : .installerAfterRollbackPublication
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-rollback"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            _ = try context.machineManager.start(id: id)
            if paused { _ = try context.machineManager.pause(id: id) }
            let directory = fixture.machineConfiguration.stateDirectory + "/" + id
            let originalFirmware = Data("original-installer-state".utf8)
            for (name, bytes) in [("NVRAM.installer", originalFirmware), ("MachineIdentifier", Data("stable-id".utf8))] {
                let path = directory + "/" + name
                try bytes.write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let originalMetadata = try Data(contentsOf: URL(fileURLWithPath: directory + "/machine.json"))
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let before = try journal.list().count
            let operationID = UUID()
            let failure = ConfigurationUpdateFaultObservation()
            let interruption = ConfigurationUpdateFaultObservation()
            context.machineManager.installLifecycleFaultInjectorForTesting { current in
                if current == point, failure.recordOnce() {
                    throw MachineManagerError.persistence("injected first boot failure")
                }
                if interruptRollback, failure.wasObserved, current == rollbackFault {
                    interruption.record()
                    throw MachineLifecycleInjectedCrash()
                }
            }
            #expect(throws: (any Error).self) {
                try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: context.planningController)
            }
            try #require(failure.wasObserved, "Missing failure at \(point)")
            let manager: MachineManager
            let controller: any DoryDaemonVirtualMachineProductionPlanningControlling
            if interruptRollback {
                try #require(interruption.wasObserved, "Rollback did not reach durable source publication")
                #expect(try journal.read(operationID).state.status == .rollingBack)
                // The source helper is stopped at this boundary. Fresh factory recovery therefore
                // exercises actual durable inputs without claiming live fixture-helper adoption.
                let activation = fixture.factory.activate(
                    store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                    appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
                )
                guard case let .activated(recovered) = activation else {
                    Issue.record("Installer rollback recovery failed: \(activation)"); return
                }
                manager = recovered.machineManager
                controller = recovered.planningController
            } else {
                manager = context.machineManager
                controller = context.planningController
            }
            defer { try? manager.delete(id: id) }
            let result = try #require(manager.status(id: id))
            #expect(result.state == (paused ? .paused : .running))
            #expect(result.installerMediaAttached)
            #expect(result.failure?.recoveryDisposition == .rollbackCompleted)
            let plan = try context.planning.plans.read(id: id)
            #expect(plan.bootMedia.media.kind == .installerISO)
            #expect(result.runtimeIdentity.resolvedPlan == plan)
            #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/machine.json")) == originalMetadata)
            #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/NVRAM.installer")) == originalFirmware)
            #expect(!FileManager.default.fileExists(atPath: directory + "/NVRAM"))
            #expect(!FileManager.default.fileExists(atPath: directory + "/.dory-nvram-promotion-pending-v1"))
            #expect(try journal.list().count == before + 1)
            #expect(try journal.read(operationID).state.status == .failed)
            do {
                let lease = try journal.acquire(operationID)
                let update = try DoryMachineConfigurationUpdateJournal.read(from: lease)
                let workspace = try DoryWorkspaceRepository(root: fixture.machineConfiguration.stateDirectory)
                    .readPersistedRecord(id: id)
                #expect(workspace.definition == update.installerTransition?.rollbackNativeDefinition)
            }
            let leases = try context.planning.resourceLedger.snapshot().leases.filter { $0.binding.machineID == id }
            #expect(leases.count == 1)
            #expect(leases.first?.state == .running)
            #expect(leases.first?.evidence == plan.resourceAdmission)
            #expect(throws: (any Error).self) {
                try manager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: controller)
            }
            #expect(manager.status(id: id)?.pid == result.pid)
            #expect(try journal.list().count == before + 1)
        }
    }

    @Test("installer first-boot replay finishes the existing helper and journal", arguments: [
        MachineLifecycleFaultPoint.installerAfterFirstBoot, .completionBeforeJournalWrite(.updating),
    ])
    func installerFirstBootReplay(point: MachineLifecycleFaultPoint) throws {
        try withProductionIntegrationTestStack {
            let fixture = try ProductionTrustFixture()
            defer { fixture.cleanup() }
            guard case let .activated(context) = fixture.factory.activate(
                store: fixture.store, machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
            ) else { Issue.record("Expected production activation"); return }
            let id = "installer-replay"
            let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                       productionPlanningController: context.planningController)
            try createPortableEFIFixture(id: id, fixture: fixture, service: service)
            defer { try? context.machineManager.delete(id: id) }
            _ = try context.machineManager.start(id: id)
            for name in ["NVRAM.installer", "MachineIdentifier"] {
                let path = fixture.machineConfiguration.stateDirectory + "/" + id + "/" + name
                try Data("original-\(name)".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let operationID = UUID()
            let observed = ConfigurationUpdateFaultObservation()
            context.machineManager.installLifecycleFaultInjectorForTesting { current in
                if current == point { observed.record(); throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                    operationID: operationID, productionPlanningController: context.planningController)
            }
            try #require(observed.wasObserved)
            let running = try #require(context.machineManager.status(id: id))
            #expect(running.state == .running)
            let plan = try context.planning.plans.read(id: id)
            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let count = try journal.list().count
            context.machineManager.installLifecycleFaultInjectorForTesting { _ in }
            let replay = try context.machineManager.transitionInstallerMedia(id: id, attached: false,
                operationID: operationID, productionPlanningController: context.planningController)
            #expect(replay.state == .running)
            #expect(replay.pid == running.pid)
            #expect(replay.failure == nil)
            #expect(try context.planning.plans.read(id: id) == plan)
            #expect(try journal.list().count == count)
            #expect(try journal.read(operationID).state.status == .completed)
        }
    }

    @Test("activated production graph runs the portable EFI install and cold-boot path", arguments: [false, true])
    func activatedGraphRunsPortableEFILifecycle(paused: Bool) throws {
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
            #expect(plan.backend == .doryHypervisor)
            #expect(plan.graphics == .software)
            #expect(plan.bootMedia.media.kind == .installerISO)
            #expect(plan.bootMedia.media.source == .userProvided)

            let started = try context.machineManager.start(id: "portable-efi")
            #expect(started.state == .running)
            #expect(started.installerMediaAttached)
            let installerPID = try #require(started.pid)
            if paused { _ = try context.machineManager.pause(id: "portable-efi") }
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

            let journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
            let resumesBefore = try journal.list().filter { $0.plan.kind == .workspaceResume }.map(\.plan.id)
            let operationsBefore = try journal.list().count
            let operationID = UUID()
            let eject = LockedPlanningCreateReply()
            service.machineUpdate(
                "portable-efi",
                config: ["installerMediaAttached": false, "operationID": operationID.uuidString.lowercased()]
            ) { ok, body, message in
                eject.set(ok: ok, body: body, message: message)
            }
            #expect(eject.value.ok, Comment(rawValue: eject.value.message))
            let ejected = try #require(context.machineManager.status(id: "portable-efi"))
            #expect(ejected.state == .running)
            #expect(ejected.pid != nil && ejected.pid != installerPID)
            #expect(!ejected.installerMediaAttached)
            #expect(try journal.list().filter { $0.plan.kind == .workspaceResume }.map(\.plan.id) == resumesBefore)
            #expect(try journal.list().count == operationsBefore + 1)
            #expect(try journal.read(operationID).state.status == .completed)
            do {
                let lease = try journal.acquire(operationID)
                let operation = try lease.readWorkspaceLifecycleOperation()
                let update = try DoryMachineConfigurationUpdateJournal.read(from: lease)
                #expect(update.installerTransition?.attached == false)
                #expect(operation.target.state == .running)
                #expect(operation.target.runtime == nil)
                #expect(operation.target.plannedRuntime?.configurationSHA256 == DoryMachineConfigurationUpdateJournal.sha256(update.targetConfigurationData))
                #expect(try lease.events().filter { $0.stepID.hasPrefix("installer.checkpoint.firmware.") }.count == 1)
            }
            plan = try context.planning.plans.read(id: "portable-efi")
            #expect(plan.backend == .doryHypervisor)
            #expect(plan.graphics == .software)
            #expect(plan.bootMedia.media.kind == .virtualDisk)
            #expect(plan.bootMedia.media.source == .userProvided)
            let replay = LockedPlanningCreateReply()
            service.machineUpdate("portable-efi", config: ["installerMediaAttached": false, "operationID": operationID.uuidString.lowercased()]) {
                replay.set(ok: $0, body: $1, message: $2)
            }
            #expect(replay.value.ok, Comment(rawValue: replay.value.message))
            #expect(context.machineManager.status(id: "portable-efi")?.pid == ejected.pid)
            #expect(try journal.list().count == operationsBefore + 1)
            let collision = LockedPlanningCreateReply()
            service.machineUpdate("portable-efi", config: ["installerMediaAttached": true, "operationID": operationID.uuidString.lowercased()]) {
                collision.set(ok: $0, body: $1, message: $2)
            }
            #expect(!collision.value.ok)
            #expect(context.machineManager.status(id: "portable-efi")?.pid == ejected.pid)
            #expect(try context.planning.plans.read(id: "portable-efi") == plan)

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

        #expect(snapshot.media.reference == start.resolvedPlan.bootMedia.resolverReference)
        #expect(snapshot.backendRuntimes.count == 2)
        #expect(snapshot.runtimeQualifications.count == 2)
        #expect(snapshot.backendRuntime(for: .doryHypervisor) != nil)
    }

    @Test("production trust admits only the structural ARM64 DoryARMVirt software baseline")
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
                devices: DoryVirtualMachineDeviceCapabilityRequest(networkInterface: .stable(machineID: "portable-linux")),
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
            devices: DoryVirtualMachineDeviceCapabilityRequest(networkInterface: .stable(machineID: "portable-linux")),
            backendPreferences: [.doryHypervisor],
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
        #expect(runtime.backend == .doryHypervisor)
        #expect(runtime.hostQualification == nil)
        #expect(snapshot.runtimeQualifications.isEmpty)

        let plan = try DoryResolvedMachinePlan(
            machineID: "portable-linux",
            definitionRevision: 1,
            definitionSHA256: definitionSHA256,
            planRevision: 1,
            createdAtUnixMilliseconds: 1_700_000_000_000,
            updatedAtUnixMilliseconds: 1_700_000_000_000,
            backendDescriptor: RawHVLinuxMachineBackend.backendDescriptor,
            backendRuntimeBuildIdentifier: runtime.runtimeBuildIdentifier,
            armVirtTopology: resolvedARMVirtTestTopology(devices: selected.request.devices, installerID: "installer"),
            resolverReference: reference,
            launchArtifacts: snapshot.launchArtifacts,
            components: runtime.components,
            resourceAdmission: lease.evidence,
            hostQualification: nil,
            firmware: runtime.firmware,
            persistence: snapshot.persistence,
            plannerRequest: plannerRequest,
            plannerResult: plannerResult
        )
        #expect(plan.validate().isEmpty)
        #expect(plan.firmware == runtime.firmware)
        #expect(plan.firmware != nil)
        _ = try ledger.bind(
            leaseID: lease.leaseID,
            to: plan,
            expectedLeaseRevision: lease.leaseRevision
        )
        let startRequest = DoryDaemonVirtualMachineStartInventoryRequest(
            resolvedPlan: plan
        )
        let startSnapshot = try context.inventory.startInventory(for: startRequest)
        #expect(startSnapshot.exactStartRuntimeQualification == nil)
        #expect(startSnapshot.backendRuntime(for: .doryHypervisor)?
            .hostQualification == nil)
        let authorizationProvider = try #require(context.inventory
            as? any DoryDaemonVirtualMachinePreSpawnAuthorizationProviding)
        try authorizationProvider.preSpawnAuthorization(for: startRequest).authorize()

        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try preparer.preparePlanningTrust(
                for: request(graphics: [.hostAcceleratedDisplay])
            )
        }

        let pendingPublication = try preparer.preparePlanningTrust(for: request(graphics: [.software]))
        let pendingStart = try authorizationProvider.preSpawnAuthorization(for: startRequest)
        let firmwarePath = try #require(fixture.machineConfiguration.armVirtFirmwareBundlePath)
        try FileManager.default.removeItem(atPath: firmwarePath)
        try makeARMVirtFirmwareTestBundle(at: firmwarePath, fill: 0xb6)
        #expect(throws: (any Error).self) {
            try pendingPublication.publicationAuthorization.authorize()
        }
        #expect(throws: DoryDaemonProductionTrustInventoryError.self) {
            _ = try context.inventory.startInventory(for: startRequest)
        }
        #expect(throws: (any Error).self) { try pendingStart.authorize() }
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
func withProductionIntegrationTestStack(
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

private struct DesktopPreflightArtifactProbe: DoryDesktopUpdateArtifactResolving {
    let observed: ConfigurationUpdateFaultObservation
    func resolve(_ request: DoryDesktopUpdateRequest, guestArchitecture: String) throws -> DoryDesktopUpdateArtifactAuthority {
        observed.record()
        throw MachineManagerError.persistence("desktop artifact probe reached")
    }
}

extension DoryDaemonVirtualMachineProductionTrustTests {
    @Test("public stop cancels blocked desktop apply before authenticated rollback")
    func productionDesktopControlledCancellation() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.agent.releaseControlledApply(); harness.cleanup() }
            let manager = harness.context.machineManager
            let oldStopID = try #require(harness.journal.list().first {
                $0.plan.kind == .workspaceStop && $0.plan.target.id == harness.id
            }?.plan.id)
            try harness.drive {
                _ = try manager.start(id: harness.id)
                let deadline = Date().addingTimeInterval(15)
                while manager.status(id: harness.id)?.state != .running {
                    guard manager.status(id: harness.id)?.state != .failed, Date() < deadline else {
                        throw MachineManagerError.persistence("cancellation source did not become ready")
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            _ = try manager.pause(id: harness.id)
            let before = try harness.journal.list().count
            let proof = ProductionDesktopCancellationObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .desktopAfterRollbackPublication {
                    proof.observeRollback(diskRestored: try harness.diskPrefix() == harness.sourceDiskPrefix)
                }
            }
            harness.agent.blockControlledApply()
            let update = ProductionDesktopCompletion<DoryDesktopUpdateResult>()
            let worker = Thread {
                update.finish(Result { try manager.updateDesktop(id: harness.id, request: harness.request) })
            }
            worker.stackSize = 8 * 1_024 * 1_024
            worker.start()
            let deadline = Date().addingTimeInterval(180)
            while !harness.agent.applyIsWaiting, update.result == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(harness.agent.applyIsWaiting, "update never reached controlled guest apply")
            let reconnect = try DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
                .read(machineID: harness.id)
            proof.setBlockedHelper(try #require(reconnect.processIdentity))
            #expect(try harness.diskPrefix().starts(with: Data("desktop-after".utf8)))
            #expect(throws: (any Error).self) {
                _ = try manager.stop(id: harness.id, operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            }
            #expect(throws: (any Error).self) {
                _ = try manager.stop(id: harness.id, operationID: harness.request.operationID)
            }
            #expect(!harness.agent.applyWasCancelled)
            let staleStop = ProductionDesktopCompletion<DoryMachineStatus>()
            let staleWorker = Thread {
                staleStop.finish(Result { try manager.stop(id: harness.id, operationID: oldStopID) })
            }
            staleWorker.stackSize = 8 * 1_024 * 1_024
            staleWorker.start()
            let staleDeadline = Date().addingTimeInterval(1)
            while staleStop.result == nil, Date() < staleDeadline { Thread.sleep(forTimeInterval: 0.005) }
            #expect(staleStop.result != nil, "completed stop UUID must resolve before waiting for another mutation")
            #expect(!harness.agent.applyWasCancelled, "reused stop UUID must not cancel a later desktop update")
            let stopID = UUID()
            let stopped = try harness.drive { try manager.stop(id: harness.id, operationID: stopID) }
            let finished = try #require(update.result, "cancelled desktop update did not finish")
            if case .success = finished { Issue.record("Cancelled guest apply unexpectedly succeeded") }
            #expect(harness.agent.applyWasCancelled)
            #expect(proof.rollbackWasSafe)
            #expect(stopped.state == .stopped)
            #expect(stopped.pid == nil)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            let updateRecord = try harness.journal.read(harness.request.operationID)
            #expect(updateRecord.state.status == .failed)
            #expect(updateRecord.state.result == .cancelled)
            #expect(try harness.journal.read(stopID).state.status == .completed)
            #expect(try harness.journal.list().count == before + 2)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == .stopped)
            let events = try String(contentsOf: harness.fixture.root.appendingPathComponent("runtime-events.log"), encoding: .utf8)
            #expect(events.components(separatedBy: .newlines).contains(
                harness.request.operationID.uuidString.lowercased() + " paused"),
                "rollback helper must regain the original paused power state before public stop completes")
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
        }
    }
}

private final class ProductionDesktopCancellationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var helper: DoryHostProcessIdentity?
    private var safeRollback = false
    var rollbackWasSafe: Bool { lock.withLock { safeRollback } }
    func setBlockedHelper(_ identity: DoryHostProcessIdentity) { lock.withLock { helper = identity } }
    func observeRollback(diskRestored: Bool) {
        lock.withLock { safeRollback = diskRestored && helper?.matchesCurrentProcess() == false }
    }
}

extension DoryDaemonVirtualMachineProductionTrustTests {
    @Test("production desktop update keeps one root through transfer, planning and replay",
          arguments: ["stopped", "running", "paused"])
    func productionDesktopRootSuccess(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let before = try harness.journal.list().count
            let result = try harness.drive {
                try manager.updateDesktop(id: harness.id, request: harness.request)
            }
            #expect(result.operationID == harness.request.operationID.uuidString.lowercased())
            #expect(result.status.state.rawValue == sourceState)
            #expect(result.status.activeOperationID == nil)
            #expect(result.status.failure == nil)
            #expect(result.inputSHA256 == ProductionDesktopAgent.inputSHA256)
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
            #expect(harness.agent.controlledExecCount > 0)
            #expect(try harness.diskPrefix().starts(with: Data("desktop-after".utf8)))
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath))
                == Data("desktop-kernel-after".utf8))
            #expect(try harness.journal.list().count == before + 1)
            let operation = try harness.journal.read(harness.request.operationID)
            #expect(operation.plan.kind == .workspaceUpdate)
            #expect(operation.state.status == .completed)
            #expect(operation.state.result == .succeeded)
            let workspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            #expect(workspace.definition.lifecycle.revision == harness.sourceWorkspace.definition.lifecycle.revision + 1)
            #expect(result.status.shares == harness.source.shares)
            #expect(result.status.environment.isEmpty)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            #expect(plan == result.status.runtimeIdentity.resolvedPlan)
            let sourcePlan = try #require(harness.source.runtimeIdentity.resolvedPlan)
            #expect(plan.planRevision > sourcePlan.planRevision)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (sourceState == "stopped" ? .stopped : .running))
            let replay = try manager.updateDesktop(id: harness.id, request: harness.request)
            #expect(replay == result)
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
            #expect(harness.agent.controlledExecCount > 0)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(try harness.journal.list().count == before + 1)
            var conflicting = harness.request
            conflicting.version = "different+runtime.1"
            #expect(throws: (any Error).self) {
                try manager.updateDesktop(id: harness.id, request: conflicting)
            }
            #expect(manager.status(id: harness.id)?.pid == replay.status.pid)
            if sourceState == "running" {
                let stopID = UUID()
                _ = try manager.stop(id: harness.id, operationID: stopID)
                let persisted = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                    .readPersistedRecord(id: harness.id)
                let digest = try DoryMachineDesktopUpdateJournal.digest(persisted.definition)
                do {
                    let lease = try harness.journal.acquire(stopID)
                    let stopped = try lease.readWorkspaceLifecycleOperation()
                    #expect(stopped.kind == .stopping)
                    for condition in [stopped.source, stopped.target] {
                        #expect(condition.definitionRevision == persisted.definition.lifecycle.revision)
                        #expect(condition.configurationAuthority?.canonicalDefinitionSHA256 == digest)
                    }
                }
                #expect(persisted.definition == workspace.definition)
                #expect(result.status.state == .running)
                #expect(replay.status.state == .running)
                #expect(try harness.journal.list().count == before + 2)
            }
        }
    }

    @Test("production desktop apply failure restores source under its root operation",
          arguments: ["apply-failure", "duplicate-receipt"], ["stopped", "running", "paused"])
    func productionDesktopRootRollback(failureMode: String, sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState,
                failApply: failureMode == "apply-failure", duplicateReceipt: failureMode == "duplicate-receipt")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let before = try harness.journal.list().count
            #expect(throws: (any Error).self) {
                try harness.drive { try manager.updateDesktop(id: harness.id, request: harness.request) }
            }
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
            #expect(harness.agent.controlledExecCount > 0)
            #expect(harness.agent.receiptReadCount == (failureMode == "duplicate-receipt" ? 1 : 0))
            let restored = try #require(manager.status(id: harness.id))
            #expect(restored.state.rawValue == sourceState)
            #expect(restored.failure?.recoveryDisposition == .rollbackCompleted)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
                == harness.sourceConfigurationData)
            #expect(restored.shares == harness.source.shares)
            #expect(try harness.journal.list().count == before + 1)
            #expect(try harness.journal.read(harness.request.operationID).state.result == .failed)
            let workspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            #expect(workspace.definition.lifecycle.revision == harness.sourceWorkspace.definition.lifecycle.revision + 1)
            #expect(try harness.context.planning.plans.read(id: harness.id) == restored.runtimeIdentity.resolvedPlan)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (sourceState == "stopped" ? .stopped : .running))
        }
    }

    @Test("qualified desktop completion retry keeps its target plan and helper generation",
          arguments: ["stopped", "running", "paused"])
    func productionDesktopRootCompletionReplay(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let before = try harness.journal.list().count
            let observed = ConfigurationUpdateFaultObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .completionBeforeJournalWrite(.updating), observed.recordOnce() {
                    throw MachineLifecycleInjectedCrash()
                }
            }
            #expect(throws: (any Error).self) {
                try harness.drive { try manager.updateDesktop(id: harness.id, request: harness.request) }
            }
            try #require(observed.wasObserved)
            #expect(try harness.journal.read(harness.request.operationID).state.status != .completed)
            let qualified = try #require(manager.status(id: harness.id))
            let qualifiedPlan = try harness.context.planning.plans.read(id: harness.id)
            manager.installLifecycleFaultInjectorForTesting { _ in }
            let replay = try harness.drive { try manager.updateDesktop(id: harness.id, request: harness.request) }
            #expect(replay.status.state.rawValue == sourceState)
            #expect(replay.status.activeOperationID == nil)
            #expect(replay.status.failure == nil)
            #expect(replay.status.pid == qualified.pid)
            #expect(replay.inputSHA256 == ProductionDesktopAgent.inputSHA256)
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
            #expect(harness.agent.controlledExecCount > 0)
            #expect(try harness.context.planning.plans.read(id: harness.id) == qualifiedPlan)
            #expect(try harness.journal.list().count == before + 1)
            #expect(try harness.journal.read(harness.request.operationID).state.status == .completed)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (sourceState == "stopped" ? .stopped : .running))
        }
    }

    @Test("interrupted desktop compensation reuses its recorded source publication",
          arguments: [MachineLifecycleFaultPoint.desktopAfterMetadata, .desktopAfterRollbackPublication],
          ["stopped", "paused"])
    func productionDesktopRootInterruptedRollback(point: MachineLifecycleFaultPoint, sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState, failApply: true)
            defer { harness.cleanup() }
            let before = try harness.journal.list().count
            let observed = ConfigurationUpdateFaultObservation()
            harness.context.machineManager.installLifecycleFaultInjectorForTesting { current in
                if current == point, observed.recordOnce() { throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try harness.drive { try harness.context.machineManager.updateDesktop(id: harness.id, request: harness.request) }
            }
            try #require(observed.wasObserved)
            #expect(try harness.journal.read(harness.request.operationID).state.status == .rollingBack)
            let activation = harness.fixture.factory.activate(
                store: harness.fixture.store, machineConfiguration: harness.fixture.machineConfiguration,
                appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
                expectedArchitecture: "arm64")
            guard case .activated(let recovered) = activation else {
                Issue.record("Desktop compensation recovery failed: \(activation)"); return
            }
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let restored = try #require(recovered.machineManager.status(id: harness.id))
            #expect(restored.state.rawValue == sourceState)
            #expect(restored.failure?.recoveryDisposition == .rollbackCompleted)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
                == harness.sourceConfigurationData)
            let workspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            #expect(workspace.definition.lifecycle.revision == harness.sourceWorkspace.definition.lifecycle.revision + 1)
            #expect(try recovered.planning.plans.read(id: harness.id) == restored.runtimeIdentity.resolvedPlan)
            #expect(try recovered.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (sourceState == "stopped" ? .stopped : .running))
            #expect(harness.agent.applyCount == 1)
            #expect(harness.agent.controlledPushCount == 1)
            #expect(harness.agent.controlledExecCount > 0)
            #expect(try harness.journal.list().count == before + 1)
            #expect(try harness.journal.read(harness.request.operationID).state.status == .failed)
        }
    }

    @Test("fresh production activation recovers the desktop root from its durable checkpoint",
          arguments: ProductionDesktopRecoveryCase.all)
    func productionDesktopRootFaultRecovery(scenario: ProductionDesktopRecoveryCase) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: scenario.sourceState)
            defer { harness.cleanup() }
            let before = try harness.journal.list().count
            let observed = ConfigurationUpdateFaultObservation()
            harness.context.machineManager.installLifecycleFaultInjectorForTesting { point in
                if point == scenario.point, observed.recordOnce() { throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try harness.drive { try harness.context.machineManager.updateDesktop(id: harness.id, request: harness.request) }
            }
            try #require(observed.wasObserved, "Missing durable boundary \(scenario.point)")
            let activation = harness.fixture.factory.activate(
                store: harness.fixture.store, machineConfiguration: harness.fixture.machineConfiguration,
                appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
                expectedArchitecture: "arm64")
            guard case .activated(let recovered) = activation else {
                Issue.record("Desktop recovery activation failed: \(activation)"); return
            }
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let result = try #require(recovered.machineManager.status(id: harness.id))
            #expect(result.state.rawValue == scenario.sourceState)
            #expect(result.shares == harness.source.shares)
            #expect(try harness.journal.list().count == before + 1)
            let operation = try harness.journal.read(harness.request.operationID)
            #expect(operation.state.status == (scenario.qualified ? .completed : .failed))
            #expect(operation.state.result == (scenario.qualified ? .succeeded : .failed))
            #expect(try recovered.planning.plans.read(id: harness.id) == result.runtimeIdentity.resolvedPlan)
            #expect(try recovered.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (scenario.sourceState == "stopped" ? .stopped : .running))
            if scenario.qualified {
                #expect(try harness.diskPrefix().starts(with: Data("desktop-after".utf8)))
                #expect(harness.agent.applyCount == 1)
                let replay = try recovered.machineManager.updateDesktop(id: harness.id, request: harness.request)
                #expect(replay.status.pid == result.pid)
                #expect(harness.agent.applyCount == 1)
            } else {
                #expect(result.failure?.recoveryDisposition == .rollbackCompleted)
                #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
                #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
                #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
                    == harness.sourceConfigurationData)
                #expect(throws: (any Error).self) {
                    try recovered.machineManager.updateDesktop(id: harness.id, request: harness.request)
                }
            }
            if scenario.point == .snapshotAfterRootfs {
                #expect(try recovered.machineManager.listSnapshots(machineID: harness.id).isEmpty)
                let snapshotID = "du-" + harness.request.operationID.uuidString.lowercased()
                for suffix in ["ext4", "kernel", "json"] {
                    #expect(!FileManager.default.fileExists(atPath: harness.directory + "/snapshots/" + snapshotID + "." + suffix))
                }
            }
            #expect(try harness.journal.list().count == before + 1)
        }
    }

}

struct ProductionDesktopRecoveryCase: Sendable {
    let point: MachineLifecycleFaultPoint
    let sourceState: String
    var qualified: Bool { point == .desktopAfterQualification }
    static let all: [Self] = [
        .init(point: .desktopBeforeStop, sourceState: "running"),
        .init(point: .desktopBeforeStop, sourceState: "paused"),
        .init(point: .snapshotAfterRootfs, sourceState: "stopped"),
        .init(point: .snapshotAfterRootfs, sourceState: "running"),
        .init(point: .snapshotAfterRootfs, sourceState: "paused"),
        .init(point: .desktopAfterSnapshot, sourceState: "stopped"),
        .init(point: .desktopAfterGuestApply, sourceState: "running"),
        .init(point: .desktopAfterKernel, sourceState: "paused"),
        .init(point: .desktopAfterMetadata, sourceState: "stopped"),
        .init(point: .desktopAfterWorkspace, sourceState: "running"),
        .init(point: .desktopAfterPlanning, sourceState: "paused"),
        .init(point: .desktopAfterQualification, sourceState: "stopped"),
        .init(point: .desktopAfterQualification, sourceState: "running"),
        .init(point: .desktopAfterQualification, sourceState: "paused"),
    ]
}

extension DoryDaemonVirtualMachineProductionTrustTests {
    @Test("public production snapshot restore owns publication, restart and replay",
          arguments: ["stopped", "running", "paused"])
    func productionSnapshotRestoreRootSuccess(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let snapshot = try harness.prepareRestoreSource(state: sourceState)
            let snapshots = try manager.listSnapshots(machineID: harness.id)
            #expect(snapshots == [snapshot])
            let source = try #require(manager.status(id: harness.id))
            let workspaceStore = DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
            let sourceWorkspace = try workspaceStore.readPersistedRecord(id: harness.id)
            let sourcePlan = try harness.context.planning.plans.read(id: harness.id)
            let reconnectStore = DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
            let sourceReconnect = sourceState == "stopped" ? nil : try reconnectStore.read(machineID: harness.id)
            let before = try harness.journal.list().count
            let operationID = UUID()
            let result = try harness.drive {
                try manager.restoreSnapshot(machineID: harness.id, snapshotID: snapshot.id,
                                            operationID: operationID)
            }
            #expect(result.state.rawValue == sourceState)
            #expect(result.activeOperationID == nil)
            #expect(result.failure == nil)
            #expect(result.shares == source.shares)
            #expect(result.environment.isEmpty)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            let targetWorkspace = try workspaceStore.readPersistedRecord(id: harness.id)
            #expect(targetWorkspace.definition.lifecycle.revision == sourceWorkspace.definition.lifecycle.revision + 1)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            #expect(plan == result.runtimeIdentity.resolvedPlan)
            #expect(plan.planRevision > sourcePlan.planRevision)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (sourceState == "stopped" ? .stopped : .running))
            #expect(try harness.journal.list().count == before + 1)
            let operation = try harness.journal.read(operationID)
            #expect(operation.plan.kind == .workspaceRestore)
            #expect(operation.state.status == .completed)
            #expect(operation.state.result == .succeeded)
            do {
                let lease = try harness.journal.acquire(operationID)
                let root = try lease.readWorkspaceLifecycleOperation()
                #expect(root.kind == .restoring)
                #expect(root.targetResourceID == snapshot.id)
                #expect(root.source.state.rawValue == sourceState)
                #expect(root.target.state.rawValue == sourceState)
                #expect(root.source.definitionRevision == sourceWorkspace.definition.lifecycle.revision)
                #expect(root.target.definitionRevision == targetWorkspace.definition.lifecycle.revision)
                #expect(try root.source.configurationAuthority?.canonicalDefinitionSHA256
                    == DoryMachineDesktopUpdateJournal.digest(sourceWorkspace.definition))
                #expect(try root.target.configurationAuthority?.canonicalDefinitionSHA256
                    == DoryMachineDesktopUpdateJournal.digest(targetWorkspace.definition))
                let restore = try DoryMachineSnapshotRestoreJournal.read(from: lease)
                #expect(restore.snapshot == snapshot)
                #expect(restore.operationID == operationID)
                let recordedPlan: DoryResolvedMachinePlan? = try lease.snapshotRestoreCheckpoint(.plan)
                #expect(recordedPlan == plan)
            }
            let targetReconnect = sourceState == "stopped" ? nil : try reconnectStore.read(machineID: harness.id)
            if let targetReconnect {
                #expect(targetReconnect.launchIdentity.operationID == operationID.uuidString.lowercased())
                #expect(targetReconnect.launchIdentity.resolvedPlanSHA256 == result.runtimeIdentity.resolvedPlanSHA256)
                #expect(targetReconnect.processIdentity != sourceReconnect?.processIdentity)
                #expect(targetReconnect.processIdentity?.matchesCurrentProcess() == true)
            } else {
                #expect(result.pid == nil)
            }
            let replay = try manager.restoreSnapshot(machineID: harness.id, snapshotID: snapshot.id,
                                                     operationID: operationID)
            #expect(replay == result)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(try workspaceStore.readPersistedRecord(id: harness.id) == targetWorkspace)
            #expect(try manager.listSnapshots(machineID: harness.id) == snapshots)
            #expect(try harness.journal.list().count == before + 1)
            if let targetReconnect {
                #expect(try reconnectStore.read(machineID: harness.id) == targetReconnect)
            }
            #expect(harness.agent.applyCount == 0)
            #expect(harness.agent.controlledPushCount == 0)
            #expect(source.state.rawValue == sourceState)
        }
    }

    @Test("stopped restore completion retry preserves its qualified plan")
    func productionSnapshotRestoreCompletionReplay() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let snapshot = try harness.prepareRestoreSource(state: "stopped")
            let manager = harness.context.machineManager
            let operationID = UUID()
            let before = try harness.journal.list().count
            let observed = ConfigurationUpdateFaultObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .completionBeforeJournalWrite(.restoring), observed.recordOnce() {
                    throw MachineLifecycleInjectedCrash()
                }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try manager.restoreSnapshot(machineID: harness.id, snapshotID: snapshot.id,
                                                operationID: operationID)
                }
            }
            try #require(observed.wasObserved)
            #expect(try harness.journal.read(operationID).state.status != .completed)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            let workspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            manager.installLifecycleFaultInjectorForTesting { _ in }
            let result = try harness.drive {
                try manager.restoreSnapshot(machineID: harness.id, snapshotID: snapshot.id,
                                            operationID: operationID)
            }
            #expect(result.state == .stopped)
            #expect(result.pid == nil)
            #expect(result.activeOperationID == nil)
            #expect(result.failure == nil)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(result.runtimeIdentity.resolvedPlan == plan)
            #expect(try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id) == workspace)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try harness.journal.list().count == before + 1)
            #expect(try harness.journal.read(operationID).state.status == .completed)
            #expect(try harness.context.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == .stopped)
        }
    }

    @Test("fresh production activation resumes the original snapshot restore",
          arguments: ProductionSnapshotRestoreRecoveryCase.all)
    func productionSnapshotRestoreFaultRecovery(scenario: ProductionSnapshotRestoreRecoveryCase) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let snapshot = try harness.prepareRestoreSource(state: scenario.sourceState)
            let manager = harness.context.machineManager
            let operationID = UUID()
            let before = try harness.journal.list().count
            let observed = ConfigurationUpdateFaultObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == scenario.point, observed.recordOnce() { throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try manager.restoreSnapshot(machineID: harness.id, snapshotID: snapshot.id,
                                                operationID: operationID)
                }
            }
            try #require(observed.wasObserved)
            #expect(try harness.journal.read(operationID).state.status != .completed)
            let previousPlan = try harness.context.planning.plans.read(id: harness.id)
            let reconnectStore = DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
            let qualifiedReconnect = scenario.qualified && scenario.sourceState != "stopped"
                ? try reconnectStore.read(machineID: harness.id) : nil
            let activation = harness.fixture.factory.activate(
                store: harness.fixture.store, machineConfiguration: harness.fixture.machineConfiguration,
                appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
                expectedArchitecture: "arm64")
            guard case .activated(let recovered) = activation else {
                throw MachineManagerError.persistence("Snapshot restore recovery failed: \(activation)")
            }
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let result = try #require(recovered.machineManager.status(id: harness.id))
            #expect(result.state.rawValue == scenario.sourceState)
            #expect(result.activeOperationID == nil)
            #expect(result.failure == nil)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            let workspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            #expect(workspace.definition.lifecycle.revision == harness.sourceWorkspace.definition.lifecycle.revision + 1)
            let plan = try recovered.planning.plans.read(id: harness.id)
            #expect(result.runtimeIdentity.resolvedPlan == plan)
            if scenario.qualified { #expect(plan == previousPlan) }
            #expect(try recovered.planning.resourceLedger.snapshot().leases.first {
                $0.binding.machineID == harness.id
            }?.state == (scenario.sourceState == "stopped" ? .stopped : .running))
            if let qualifiedReconnect {
                let reconnect = try reconnectStore.read(machineID: harness.id)
                #expect(reconnect.processIdentity == qualifiedReconnect.processIdentity)
                #expect(reconnect.launchIdentity == qualifiedReconnect.launchIdentity)
            }
            if scenario.sourceState != "stopped" {
                #expect(try reconnectStore.read(machineID: harness.id).launchIdentity.operationID
                    == operationID.uuidString.lowercased())
            }
            #expect(try harness.journal.list().count == before + 1)
            #expect(try harness.journal.read(operationID).state.status == .completed)
            let replay = try recovered.machineManager.restoreSnapshot(
                machineID: harness.id, snapshotID: snapshot.id, operationID: operationID)
            #expect(replay == result)
            #expect(try recovered.planning.plans.read(id: harness.id) == plan)
            #expect(try recovered.machineManager.listSnapshots(machineID: harness.id) == [snapshot])
            #expect(try FileManager.default.contentsOfDirectory(atPath: harness.directory)
                .contains { $0.hasPrefix(".restore-" + operationID.uuidString.lowercased()) } == false)
            #expect(try harness.journal.list().count == before + 1)
        }
    }
}

struct ProductionSnapshotRestoreRecoveryCase: Sendable {
    let point: MachineLifecycleFaultPoint
    let sourceState: String
    var qualified: Bool { point == .completionBeforeJournalWrite(.restoring) }
    static let all: [Self] = [
        .init(point: .restoreAfterBackups, sourceState: "stopped"),
        .init(point: .restoreAfterBackups, sourceState: "paused"),
        .init(point: .completionBeforeJournalWrite(.restoring), sourceState: "stopped"),
        .init(point: .completionBeforeJournalWrite(.restoring), sourceState: "running"),
    ]
}

private extension ProductionDesktopUpdateHarness {
    func prepareRestoreSource(state sourceState: String) throws -> DoryMachineSnapshot {
        let manager = context.machineManager
        let harness = self
        let snapshot = try harness.drive {
            try manager.snapshot(id: harness.id, note: "separate source snapshot",
                                 snapshotID: "restore-source")
        }
        let disk = try FileHandle(forWritingTo: URL(fileURLWithPath: harness.directory + "/rootfs.ext4"))
        try disk.write(contentsOf: Data("workload-after-snapshot".utf8))
        try disk.synchronize()
        try disk.close()
        #expect(try harness.diskPrefix() != harness.sourceDiskPrefix)
        if sourceState != "stopped" {
            try harness.drive {
                _ = try manager.start(id: harness.id)
                let deadline = Date().addingTimeInterval(15)
                while manager.status(id: harness.id)?.state != .running {
                    guard manager.status(id: harness.id)?.state != .failed, Date() < deadline else {
                        throw MachineManagerError.persistence("restore source did not become ready")
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            // A lifecycle command also waits for the asynchronous start root to settle.
            _ = try manager.pause(id: harness.id)
            if sourceState == "running" { _ = try manager.resume(id: harness.id) }
        }
        return snapshot
    }
}

final class ProductionDesktopUpdateHarness: @unchecked Sendable {
    let id = "desktop-root"
    let fixture: ProductionTrustFixture
    let context: DoryDaemonVirtualMachineProductionActivationContext
    fileprivate let agent: ProductionDesktopAgent
    let request: DoryDesktopUpdateRequest
    let journal: DoryOperationJournalStore
    let source: DoryMachineStatus
    let sourceWorkspace: DoryWorkspaceRepositoryRecord
    let sourceConfigurationData: Data
    let sourceDiskPrefix: Data
    let sourceKernel: Data
    var directory: String { fixture.machineConfiguration.stateDirectory + "/" + id }
    var managedKernelPath: String { directory + "/kernel" }
    var snapshotFreezeReceiptIDs: [String] { agent.snapshotFreezeReceiptIDs }
    var snapshotThawReceiptIDs: [String] { agent.snapshotThawReceiptIDs }

    init(sourceState: String, failApply: Bool = false, duplicateReceipt: Bool = false,
         diskByteCount: UInt64 = 32 * 1_024 * 1_024 * 1_024,
         snapshotQuiesceFailure: Bool = false) throws {
        let id = "desktop-root"
        let agent = ProductionDesktopAgent(failApply: failApply, duplicateReceipt: duplicateReceipt,
                                           snapshotQuiesceFailure: snapshotQuiesceFailure)
        self.agent = agent
        let fixture = try ProductionTrustFixture(authenticatedRuntime: true,
                                                 snapshotQuiesceFailure: snapshotQuiesceFailure,
                                                 agentConnector: { _ in agent })
        self.fixture = fixture
        var initialized = false
        var activatedManager: MachineManager?
        defer {
            if !initialized {
                activatedManager?.stopAll()
                try? activatedManager?.delete(id: id)
                fixture.cleanup()
            }
        }
        guard case .activated(let context) = fixture.factory.activate(
            store: fixture.store, machineConfiguration: fixture.machineConfiguration,
            appVersion: fixture.appVersion, publicKey: fixture.publicKey, expectedArchitecture: "arm64"
        ) else { throw MachineManagerError.persistence("desktop production fixture activation failed") }
        self.context = context
        activatedManager = context.machineManager
        let disk = fixture.root.appendingPathComponent("desktop.raw")
        try Data("desktop-before".utf8).write(to: disk)
        let diskHandle = try FileHandle(forWritingTo: disk)
        try diskHandle.truncate(atOffset: diskByteCount)
        try diskHandle.close()
        let reply = LockedPlanningCreateReply()
        let service = DorydService(socketPath: "/unused", machineManager: context.machineManager,
                                   productionPlanningController: context.planningController)
        service.machineCreate([
            "id": id, "kernelPath": fixture.directKernelPath, "rootfsPath": disk.path,
            "displayMode": "desktop", "memoryMB": UInt64(4_096), "cpuCount": 4,
            "guestIdentityIntent": ["desktop": ["distributionIdentifier": "ubuntu"]],
            "desktopGraphicsPreference": "software",
        ]) { reply.set(ok: $0, body: $1, message: $2) }
        guard reply.value.ok else { throw MachineManagerError.persistence(reply.value.message) }
        let directory = fixture.machineConfiguration.stateDirectory + "/" + id
        agent.setDiskPath(directory + "/rootfs.ext4")
        request = .init(operationID: UUID(), distro: "ubuntu", version: "next+runtime.1",
                        distributionInstallationName: "ubuntu-installation", runtimeInstallationName: "runtime-installation")
        let bundle = fixture.root.appendingPathComponent("desktop-update.tar")
        let kernel = fixture.root.appendingPathComponent("desktop-update-kernel")
        try Data("desktop-update-bundle".utf8).write(to: bundle)
        try Data("desktop-kernel-after".utf8).write(to: kernel)
        context.machineManager.installDesktopUpdateArtifactResolver(ProductionDesktopArtifactResolver(
            bundlePath: bundle.path, kernelPath: kernel.path))
        _ = try Self.drive {
            _ = try context.machineManager.start(id: "desktop-root")
            let deadline = Date().addingTimeInterval(15)
            while let status = context.machineManager.status(id: "desktop-root"), status.state != .running {
                if status.state == .failed || Date() > deadline {
                    throw MachineManagerError.persistence(status.lastError ?? "desktop source did not become ready")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // Verify the activation graph retained the supplied connector before hashing a full disk.
        _ = try context.machineManager.exec(id: id, argv: ["/usr/bin/true"])
        if sourceState == "stopped" { _ = try context.machineManager.stop(id: id) }
        else {
            _ = try context.machineManager.pause(id: id)
            if sourceState == "running" { _ = try context.machineManager.resume(id: id) }
        }
        context.machineManager.installLifecycleFaultInjectorForTesting { point in
            try? FileHandle.standardError.write(contentsOf: Data("Desktop fixture boundary: \(point)\n".utf8))
        }
        source = try #require(context.machineManager.status(id: id))
        sourceWorkspace = try DoryWorkspaceRepository(root: fixture.machineConfiguration.stateDirectory).readPersistedRecord(id: id)
        sourceConfigurationData = try Data(contentsOf: URL(fileURLWithPath: directory + "/machine.json"))
        sourceKernel = try Data(contentsOf: URL(fileURLWithPath: directory + "/kernel"))
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: directory + "/rootfs.ext4"))
        sourceDiskPrefix = try input.read(upToCount: 64) ?? Data()
        try input.close()
        journal = try DoryOperationJournalStore(home: fixture.machineConfiguration.lifecycleJournalHome)
        initialized = true
    }

    func cleanup() {
        do { try context.machineManager.delete(id: id) }
        catch { context.machineManager.stopAll() }
        fixture.cleanup()
    }

    func diskPrefix() throws -> Data {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: directory + "/rootfs.ext4"))
        defer { try? input.close() }
        return try input.read(upToCount: 64) ?? Data()
    }

    func drive<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) throws -> T {
        try Self.drive(operation)
    }

    private static func drive<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) throws -> T {
        let completion = ProductionDesktopCompletion<T>()
        let thread = Thread {
            let result = Result { try operation() }
            if case .failure(let error) = result {
                try? FileHandle.standardError.write(contentsOf: Data("Desktop fixture operation failed: \(error)\n".utf8))
            }
            completion.finish(result)
        }
        thread.stackSize = 8 * 1_024 * 1_024
        thread.start()
        let deadline = Date().addingTimeInterval(300)
        while completion.result == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try #require(completion.result, "desktop operation did not finish").get()
    }
}

/// A subprocess fixture for production trust tests. It authenticates the inherited launch
/// identity and sends real lifecycle receipts; it does not boot or qualify a physical guest.
final class DoryProductionDesktopRuntimeTests: XCTestCase {
    func testAuthenticatedDesktopRuntimeServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let controlSocket = environment["DORY_DESKTOP_TEST_CONTROL_SOCKET"] else { return }
        let handoffSocket = try XCTUnwrap(environment["DORY_DESKTOP_TEST_HANDOFF_SOCKET"])
        let identity = try DoryRuntimeReconnectLaunchIdentity.decode(
            fileDescriptor: DoryRuntimeReconnectContract.childFileDescriptor)
        let operationID = try XCTUnwrap(UUID(uuidString: identity.operationID))
        let state = ProductionDesktopExecutionState(
            auditPath: URL(fileURLWithPath: controlSocket).deletingLastPathComponent()
                .appendingPathComponent("runtime-events.log").path,
            operationID: identity.operationID)
        let server = VmmLifecycleReceiptServer(
            socketPath: controlSocket, reconnectIdentity: identity,
            executionStateProvider: { state.current }, executionLifecycleHandler: { state.apply($0) })
        try server.start()
        defer { server.stop() }
        try sendVmmHandoff(path: handoffSocket, ready: .init(
            machineID: identity.machineID, operationID: identity.operationID,
            agentBuild: ProductionDesktopAgent.build, agentProtocolVersion: DoryCore.protocolVersion(),
            agentCapabilities: ProductionDesktopAgent.capabilities(
                snapshotQuiesceFailure: environment["DORY_DESKTOP_TEST_SNAPSHOT_QUIESCE_FAILURE"] == "1"),
            agentSocketPath: "/run/dory-desktop-agent.sock", controlSocketPath: controlSocket,
            graphicsSelection: .resolvedSoftware(operationID: operationID,
                resolvedPlanSHA256: identity.resolvedPlanSHA256, planRevision: identity.planRevision),
            guestBooted: true, toolsConnected: true
        ), fileDescriptors: [])
        _ = signal(SIGTERM, SIG_DFL)
        while true { pause() }
    }
}

private final class ProductionDesktopExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: DoryVirtualMachineState = .running
    private let auditPath: String
    private let operationID: String
    init(auditPath: String, operationID: String) {
        self.auditPath = auditPath
        self.operationID = operationID
    }
    var current: DoryVirtualMachineState { lock.withLock { state } }
    func apply(_ action: DoryLifecycleReceiptAction) {
        lock.withLock {
            state = action == .preparePause ? .paused : .running
            guard let stream = fopen(auditPath, "a") else { return }
            defer { fclose(stream) }
            fputs("\(operationID) \(state.rawValue)\n", stream)
            fflush(stream)
        }
    }
}

private final class ProductionDesktopCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    var result: Result<T, Error>? { lock.withLock { value } }
    func finish(_ value: Result<T, Error>) { lock.withLock { self.value = value } }
}

private final class ProductionDesktopAgent: AgentControlClient, @unchecked Sendable {
    static let build = "dory-agent/production-desktop-test"
    static let inputSHA256 = String(repeating: "a", count: 64)
    static func capabilities(snapshotQuiesceFailure: Bool) -> [DoryAgentCapability] {
        let base = [
            DoryAgentCapability(id: "clock-sync", version: 1),
            DoryAgentCapability(id: "exec", version: 1),
            DoryAgentCapability(id: "sync-push", version: 2),
        ]
        let capabilities = snapshotQuiesceFailure
            ? base + [DoryAgentCapability(id: "snapshot-quiesce", version: 2)] : base
        return capabilities.sorted { $0.id < $1.id }
    }
    private let lock = NSLock()
    private let failApply: Bool
    private let duplicateReceipt: Bool
    private let snapshotQuiesceFailure: Bool
    private var freezeReceiptIDs: [String] = []
    private var thawReceiptIDs: [String] = []
    var snapshotFreezeReceiptIDs: [String] { lock.withLock { freezeReceiptIDs } }
    var snapshotThawReceiptIDs: [String] { lock.withLock { thawReceiptIDs } }
    private var diskPath = ""
    private var transferredSHA256 = ""
    private var applications = 0
    private var pushes = 0
    private var receiptReads = 0
    private var controlledExecutions = 0
    private var blockApply = false
    private var blockedControl: DoryExecControl?
    private var releaseApply = false
    var applyCount: Int { lock.withLock { applications } }
    var controlledPushCount: Int { lock.withLock { pushes } }
    var receiptReadCount: Int { lock.withLock { receiptReads } }
    var controlledExecCount: Int { lock.withLock { controlledExecutions } }
    var applyIsWaiting: Bool { lock.withLock { blockedControl != nil } }
    var applyWasCancelled: Bool { lock.withLock { blockedControl?.isCancelled == true } }
    func blockControlledApply() { lock.withLock { blockApply = true } }
    func releaseControlledApply() { lock.withLock { releaseApply = true } }
    init(failApply: Bool, duplicateReceipt: Bool, snapshotQuiesceFailure: Bool) {
        self.failApply = failApply
        self.duplicateReceipt = duplicateReceipt
        self.snapshotQuiesceFailure = snapshotQuiesceFailure
    }
    func setDiskPath(_ path: String) { lock.withLock { diskPath = path } }
    func info() throws -> DoryAgentInfo {
        .init(protocolVersion: DoryCore.protocolVersion(), kernel: "Linux desktop fixture",
              agentBuild: Self.build, uptimeSeconds: 1,
              capabilities: Self.capabilities(snapshotQuiesceFailure: snapshotQuiesceFailure))
    }
    func snapshotFreeze(receiptID: String) throws -> String {
        guard snapshotQuiesceFailure else { throw AgentControlError.capabilityUnavailable("snapshot-quiesce") }
        lock.withLock { freezeReceiptIDs.append(receiptID) }
        throw MachineManagerError.persistence("injected guest snapshot freeze failure")
    }
    func snapshotThaw(receiptID: String) throws {
        guard snapshotQuiesceFailure else { throw AgentControlError.capabilityUnavailable("snapshot-quiesce") }
        lock.withLock { thawReceiptIDs.append(receiptID) }
        throw MachineManagerError.persistence("injected guest snapshot thaw failure")
    }
    func clockSync(hostEpochNs: Int64) throws -> Bool { true }
    func portsWatch() throws -> DoryPortsSnapshot { .init(ports: [], added: [], removed: []) }
    func telemetry() throws -> DoryTelemetry {
        .init(memTotalKB: 4_194_304, memAvailableKB: 2_097_152, psiSomeAvg10: 0, psiFullAvg10: 0)
    }
    func push(localRoot: String, remoteRoot: String, control: DoryPushControl) throws -> DoryPushStats {
        let payload = try Data(contentsOf: URL(fileURLWithPath: localRoot + "/payload.tar"))
        lock.withLock {
            pushes += 1
            transferredSHA256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        }
        return .init(filesSent: 1, bytesSent: UInt64(payload.count), filesDeleted: 0)
    }
    func exec(argv: [String], cwd: String, env: [DoryExecEnvironment],
              timeoutMs: UInt64, outputLimitBytes: UInt64, control: DoryExecControl) throws -> DoryExecResult {
        lock.withLock { controlledExecutions += 1 }
        guard !control.isCancelled else { throw DoryExecControlError.cancelledGuestStateUnknown }
        let result = try exec(argv: argv, cwd: cwd, env: env, timeoutMs: timeoutMs,
                              outputLimitBytes: outputLimitBytes)
        if argv.first?.hasSuffix("/apply.sh") == true, lock.withLock({ blockApply }) {
            lock.withLock { blockedControl = control }
            let deadline = Date().addingTimeInterval(60)
            while !control.isCancelled, !lock.withLock({ releaseApply }) {
                guard Date() < deadline else {
                    throw MachineManagerError.persistence("controlled apply was never cancelled")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        guard !control.isCancelled else { throw DoryExecControlError.cancelledGuestStateUnknown }
        return result
    }

    func exec(argv: [String], cwd: String, env: [DoryExecEnvironment],
              timeoutMs: UInt64, outputLimitBytes: UInt64) throws -> DoryExecResult {
        try? FileHandle.standardError.write(contentsOf: Data("Desktop fixture exec: \(argv.joined(separator: " "))\n".utf8))
        var output = "ok\n"
        var code: Int32 = 0
        if argv.first == "/usr/bin/sha256sum" {
            output = lock.withLock { transferredSHA256 } + "  payload.tar\n"
        } else if argv == ["/bin/cat", "/var/lib/dory/desktop-update.env"] {
            lock.withLock { receiptReads += 1 }
            output = "schema=1\ndistro=ubuntu\nversion=next+runtime.1\nversion=conflicting\ninput_sha256=\(Self.inputSHA256)\n"
        } else if argv.first?.hasSuffix("/apply.sh") == true {
            let path = lock.withLock { applications += 1; return diskPath }
            let disk = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try disk.write(contentsOf: Data("desktop-after".utf8))
            try disk.synchronize()
            try disk.close()
            if failApply { code = 42 }
            output = duplicateReceipt ? "package output without final fingerprint\n"
                : "Dory desktop update applied: ubuntu next+runtime.1 \(Self.inputSHA256)\n"
        }
        return .init(exitCode: code, stdout: Data(output.utf8), stderr: Data(),
                     timedOut: false, stdoutTruncated: false, stderrTruncated: false)
    }
    func close() {}
}

private struct ProductionDesktopArtifactResolver: DoryDesktopUpdateArtifactResolving {
    let bundlePath: String
    let kernelPath: String
    func resolve(_ request: DoryDesktopUpdateRequest, guestArchitecture: String) throws -> DoryDesktopUpdateArtifactAuthority {
        guard guestArchitecture == "arm64" else { throw MachineManagerError.persistence("desktop fixture ISA differs") }
        let bundle = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
        let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return .init(receipt: .verifiedUpdate(
            distributionIdentifier: request.distro, releaseVersion: request.version,
            inputSHA256: String(repeating: "0", count: 64), bundleSHA256: digest(bundle),
            distributionComponentIdentifier: "desktop-ubuntu", distributionInstallationName: request.distributionInstallationName,
            distributionCatalogSHA256: String(repeating: "b", count: 64),
            bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop", runtimeInstallationName: request.runtimeInstallationName,
            runtimeCatalogSHA256: String(repeating: "c", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse", kernelSHA256: digest(kernel)
        ), bundlePath: bundlePath, bundleByteCount: UInt64(bundle.count), kernelPath: kernelPath, kernelByteCount: UInt64(kernel.count))
    }
}

private final class ConfigurationUpdateFaultObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    func record() { lock.withLock { observed = true } }
    func recordOnce() -> Bool {
        lock.withLock {
            guard !observed else { return false }
            observed = true
            return true
        }
    }
    var wasObserved: Bool { lock.withLock { observed } }
}

final class LockedPlanningCreateReply: @unchecked Sendable {
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

final class ProductionTrustFixture: @unchecked Sendable {
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
    let desktopUpdateKernelDigest: String?
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
    fileprivate let hostState: ProductionHostState
    var factory: DoryDaemonVirtualMachineProductionTrustFactory!
    var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    fileprivate init(
        catalogSchemaVersion: Int = 2,
        catalogReleaseVersion: String = "1.0.0",
        catalogGeneratedAt: String = "2026-08-20T12:00:00.000Z",
        installCatalog: Bool = true,
        daemonTeamIdentifier: String? = DorydXPCSecurity.productionTeamID,
        runtimeVerificationFails: Bool = false,
        planningTransactionAvailable: Bool = true,
        trustFloorDirectorySyncFails: Bool = false,
        trustFloorActivationState: ProductionTrustFloorActivationState? = nil,
        helperLifetimeSeconds: UInt = 30,
        authenticatedRuntime: Bool = false,
        snapshotQuiesceFailure: Bool = false,
        agentConnector: @escaping MachineManager.AgentConnector = {
            try LocalAgentControl.connect(socketPath: $0)
        }
    ) throws {
        let fixtureRoot = URL(fileURLWithPath: "/Users/Shared", isDirectory: true).appendingPathComponent(
            "\(authenticatedRuntime ? "dory-du" : "dory-production-trust")-\(UUID().uuidString)", isDirectory: true
        )
        let helperData: Data
        if authenticatedRuntime {
            func quote(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
                .map { "export DEVELOPER_DIR=" + quote($0) + "\n" } ?? ""
            helperData = Data(("""
            #!/bin/sh
            \(developer)export DORY_DESKTOP_TEST_CONTROL_SOCKET=\(quote(fixtureRoot.appendingPathComponent("control.sock").path))
            export DORY_DESKTOP_TEST_SNAPSHOT_QUIESCE_FAILURE=\(snapshotQuiesceFailure ? "1" : "0")
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --handoff-sock) shift; export DORY_DESKTOP_TEST_HANDOFF_SOCKET="$1" ;;
                esac
                shift
            done
            exec /usr/bin/xcrun xctest -XCTest DorydKitTests.DoryProductionDesktopRuntimeTests/testAuthenticatedDesktopRuntimeServer \(quote(Bundle(for: DoryProductionDesktopRuntimeTests.self).bundlePath))

            """).utf8)
        } else {
            helperData = Data("#!/bin/sh\nexec /bin/sleep \(helperLifetimeSeconds)\n".utf8)
        }
        helperDigest = Self.digest(helperData)
        hostState = ProductionHostState(host)
        // The production broker deliberately rejects symlinked ancestors and group/world-
        // writable user-owned ancestors. `/Users/Shared` is a root-owned sticky directory, which
        // is the primitive's explicit safe temporary-fixture exception.
        root = fixtureRoot
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
        let firmwarePath = root.appendingPathComponent("armvirt-firmware").path
        try makeARMVirtFirmwareTestBundle(at: firmwarePath)
        machineConfiguration = MachineManagerConfiguration(
            vmmExecutablePath: vz,
            acceleratedDesktopExecutablePath: raw,
            armVirtFirmwareBundlePath: firmwarePath,
            stateDirectory: state.path,
            runtimeDirectory: root.appendingPathComponent("runtime").path,
            requiresReadyHandoff: authenticatedRuntime
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
        desktopUpdateKernelDigest = authenticatedRuntime
            ? Self.digest(Data("desktop-kernel-after".utf8)) : nil
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
            trustFloorActivator: floorActivator,
            agentConnector: agentConnector
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
            armVirtTopology: productionTrustRawHVTopology(),
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
            ),
            persistence: try DoryResolvedMachinePersistence(
                stateDirectory: machineConfiguration.stateDirectory, machineID: binding.machineID
            )
        )
        #expect(plan.validate().isEmpty)
        _ = try ledger.bind(
            leaseID: lease.leaseID,
            to: plan,
            expectedLeaseRevision: lease.leaseRevision
        )
        return DoryDaemonVirtualMachineStartInventoryRequest(
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
        let managedDesktopDevices = DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .stable(machineID: "desktop-preflight"),
            displays: [.init(widthPixels: 1_920, heightPixels: 1_080)],
            audioInput: true, audioOutput: true, keyboard: true, pointer: true,
            clipboard: true, clipboardPolicy: .legacyDesktop(.bidirectional),
            clockSynchronization: true, dynamicDisplay: true, gracefulShutdown: true
        )
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
        var media = [
            (DoryBootMediaKind.installedLinuxBootBundle, mediaDigest, "bundle"),
            (DoryBootMediaKind.linuxKernel, directKernelDigest, "kernel"),
        ]
        if let desktopUpdateKernelDigest {
            media.append((.linuxKernel, desktopUpdateKernelDigest, "desktop-update-kernel"))
        }
        let candidateBinding = DoryVirtualMachineQualificationCandidateBinding(
            componentCandidateInventorySHA256: String(repeating: "c", count: 64),
            sbomSHA256: String(repeating: "3", count: 64)
        )
        var records = [DoryVirtualMachineQualificationRecord]()
        var performanceFiles = [(path: String, data: Data)]()
        for (backend, implementation, component) in backends {
            for (mediaKind, mediaDigest, mediaSuffix) in media {
                for (suffix, deviceRequest, graphics) in [
                    ("minimum", devices, DoryGraphicsAccelerationLevel.none),
                    ("headless", headlessDevices, DoryGraphicsAccelerationLevel.none),
                    ("desktop", desktopDevices, .software),
                    ("managed-desktop", managedDesktopDevices, .software),
                ] {
                    let qualificationIdentity =
                        "\(component)-\(mediaSuffix)-\(suffix)-qualification"
                    let matrixCellID = Self.digest(Data(qualificationIdentity.utf8))
                    let receiptPath = matrixCellID
                        + ".linux-vm-performance-verification.json"
                    let receiptData = try Self.performanceReceiptData(
                        backend: backend == .doryHypervisor ? "rawhv" : "vz",
                        candidateBinding: candidateBinding,
                        installerSHA256: mediaDigest,
                        matrixCellID: matrixCellID,
                        signingKeyID: signingKeyID
                    )
                    let signatureData = Data(
                        (try privateKey.signature(for: receiptData).base64EncodedString()
                            + "\n").utf8
                    )
                    performanceFiles.append((receiptPath, receiptData))
                    performanceFiles.append((receiptPath + ".sig", signatureData))
                    records.append(DoryVirtualMachineQualificationRecord(
                        qualificationIdentity: qualificationIdentity,
                        guest: guest,
                        bootMediaKind: mediaKind,
                        bootMediaSource: .bundledByDory,
                        immutableArtifactSHA256: mediaDigest,
                        backend: backend,
                        backendImplementationIdentifier: implementation,
                        backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
                        virtualHardwareABIVersion: 1,
                        graphics: graphics,
                        devices: deviceRequest,
                        hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                        hostOperatingSystemBuild: host.operatingSystemBuild,
                        components: [components.first { $0.componentIdentifier == component }!],
                        virtioGPUKernelAndDeviceSupportQualified: graphics != .none,
                        producerFenceBeforeFlushQualified: graphics != .none,
                        venusVulkanGuestRuntimeQualified: false,
                        performanceQualification:
                            DoryVirtualMachinePerformanceQualificationEvidence(
                                bundleInventorySHA256: Self.digest(
                                    Data("bundle-\(matrixCellID)".utf8)
                                ),
                                graphicsImplementation: "software",
                                matrixCellID: matrixCellID,
                                signaturePublicKeyID: signingKeyID,
                                verificationReceiptPath: receiptPath,
                                verificationReceiptSHA256: Self.digest(receiptData)
                            )
                    ))
                }
            }
        }
        let manifest = DoryVirtualMachineQualificationManifest(
            manifestIdentity: "production-vm-qualification-1",
            catalogReleaseVersion: releaseVersion,
            architecture: "arm64",
            signingKeyID: signingKeyID,
            candidateBinding: candidateBinding,
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
        let manifestAsset = DoryComponentAsset(
            path: manifestPath,
            url: "https://example.invalid/qualification.json",
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            sha256: Self.digest(manifestData),
            installedSHA256: Self.digest(manifestData),
            role: isVersionTwo ? .qualificationEvidence : nil
        )
        let performanceAssets = performanceFiles.map { file in
            DoryComponentAsset(
                path: file.path,
                url: "https://example.invalid/\(file.path)",
                downloadBytes: UInt64(file.data.count),
                installedBytes: UInt64(file.data.count),
                sha256: Self.digest(file.data),
                installedSHA256: Self.digest(file.data),
                role: isVersionTwo ? .qualificationEvidence : nil
            )
        }
        let qualificationAssets = [manifestAsset] + performanceAssets
        let qualificationBytes = qualificationAssets.reduce(UInt64(0)) {
            $0 + $1.downloadBytes
        }
        let release = DoryComponentRelease(
            id: .linuxMachines,
            version: releaseVersion,
            displayName: "Linux Machines",
            summary: "Qualified VM runtime",
            dependencies: [.dockerCore],
            downloadBytes: qualificationBytes,
            installedBytes: qualificationBytes,
            assets: qualificationAssets,
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
        var downloadedAssets = [manifestPath: source.path]
        for file in performanceFiles {
            let fileSource = root.appendingPathComponent(file.path)
            try file.data.write(to: fileSource)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileSource.path
            )
            downloadedAssets[file.path] = fileSource.path
        }
        _ = try store.install(
            release,
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: downloadedAssets
        )
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func performanceReceiptData(
        backend: String,
        candidateBinding: DoryVirtualMachineQualificationCandidateBinding,
        installerSHA256: String,
        matrixCellID: String,
        signingKeyID: String
    ) throws -> Data {
        let value: [String: Any] = [
            "bundleInventorySHA256": digest(Data("bundle-\(matrixCellID)".utf8)),
            "candidate": [
                "applicationSHA256": String(repeating: "1", count: 64),
                "budgetSetSHA256": String(repeating: "2", count: 64),
                "componentCandidateInventorySHA256":
                    candidateBinding.componentCandidateInventorySHA256,
                "runtimePlanSHA256": String(repeating: "4", count: 64),
                "sbomSHA256": candidateBinding.sbomSHA256,
                "virtualHardwareABIVersion": "1",
            ],
            "kind": "dev.dory.linux-vm-performance-verification-receipt",
            "releaseQualified": true,
            "schemaVersion": 1,
            "signaturePublicKeyID": signingKeyID,
            "supportCell": [
                "backend": backend,
                "graphicsImplementation": "software",
                "hostIdentitySHA256": String(repeating: "5", count: 64),
                "installedSystemIdentitySHA256": String(repeating: "6", count: 64),
                "installerSHA256": installerSHA256,
                "matrixCellID": matrixCellID,
                "requestedGraphicsQuality": "software",
                "selectedGraphicsQuality": "software",
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
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

private func productionTrustRawHVTopology() -> DoryARMVirtV1Topology {
    try! DoryARMVirtV1Topology(occupiedSlots: [
        DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .systemDisk,
                stableID: "qualified-linux-system-disk"
            ),
            role: .systemDisk,
            mmioSlot: 0
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-graphics",
            role: .graphics,
            mmioSlot: 1
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-entropy",
            role: .entropy,
            mmioSlot: 2
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-balloon",
            role: .balloon,
            mmioSlot: 3
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-vsock",
            role: .vsock,
            mmioSlot: 4
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: "nic0"
            ),
            role: .network,
            mmioSlot: 8
        ),
    ])
}
