import CryptoKit
@testable import DorydKit
import DoryOperations
import Foundation
import Testing

@Suite("Production VM trust composition")
struct DoryDaemonVirtualMachineProductionTrustTests {
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
            Issue.record("Expected production activation")
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
        #expect(trustFloor.activationCount == 1)
    }

    @Test("activated production graph publishes a headless create plan through XPC authority")
    func activatedGraphPlansHeadlessCreate() throws {
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
            "kernelPath": fixture.mediaPath,
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
        trustFloorActivationState: ProductionTrustFloorActivationState? = nil
    ) throws {
        helperDigest = Self.digest(Data("verified-helper".utf8))
        hostState = ProductionHostState(host)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-production-trust-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        drive = try DoryDataDrive(home: root.path)
        try drive.prepare()
        store = DoryComponentStore(drive: drive)
        try store.prepare()
        let state = root.appendingPathComponent("machine-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        let vz = root.appendingPathComponent("dory-vmm").path
        let raw = root.appendingPathComponent("dory-hv").path
        for path in [vz, raw] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
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
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: mediaDigest
        )
        let capabilityRequest = DoryVirtualMachineCapabilityRequest(
            guest: guest,
            bootMedia: media,
            backend: .doryHypervisor,
            graphics: .none,
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
            graphics: .none,
            supportTier: .supported,
            selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: DoryVirtualMachineBackendPlanRequest(
                    guest: guest,
                    bootMedia: media,
                    acceptableGraphics: [.none],
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
        let headlessDevices = DoryVirtualMachineDeviceCapabilityRequest(
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
        let records = backends.flatMap { backend, implementation, component in
            [("minimum", devices), ("headless", headlessDevices)].map { suffix, devices in
                DoryVirtualMachineQualificationRecord(
                    qualificationIdentity: "\(component)-\(suffix)-qualification",
                    guest: guest,
                    bootMediaKind: .installedLinuxBootBundle,
                    bootMediaSource: .bundledByDory,
                    immutableArtifactSHA256: mediaDigest,
                    backend: backend,
                    backendImplementationIdentifier: implementation,
                    backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
                    virtualHardwareABIVersion: 1,
                    graphics: .none,
                    devices: devices,
                    hostHardwareModelIdentifier: host.hardwareModelIdentifier,
                    hostOperatingSystemBuild: host.operatingSystemBuild,
                    components: [components.first { $0.componentIdentifier == component }!]
                )
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
        let asset = DoryComponentAsset(
            path: manifestPath,
            url: "https://example.invalid/qualification.json",
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            sha256: Self.digest(manifestData),
            installedSHA256: Self.digest(manifestData)
        )
        let release = DoryComponentRelease(
            id: .linuxMachines,
            version: releaseVersion,
            displayName: "Linux Machines",
            summary: "Qualified VM runtime",
            dependencies: [.dockerCore],
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            assets: [asset]
        )
        let core = DoryComponentRelease(
            id: .dockerCore,
            version: releaseVersion,
            displayName: "Docker Core",
            summary: "Bundled core",
            dependencies: [],
            downloadBytes: 1,
            installedBytes: 1,
            assets: []
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
