import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportRecoveryTests: StrictInventoryTestCase {
    @Test func retriesAnIncompleteRollbackAndUnblocksTheNextImport() async throws {
        let context = try await interruptedByVolumeRollbackFailure()
        defer { try? FileManager.default.removeItem(atPath: context.home) }

        #expect(try context.store.read(context.operationID).state.status == .needsRecovery)
        #expect(context.fixture.target.snapshotValue.volumes.map(\.name) == ["db-data"])
        context.fixture.target.failVolumeRemoval = false

        let result = try await recover(context)

        #expect(result.recoveredOperationID == context.operationID)
        #expect(result.preservedUnattributedTargetImageIDs.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        let record = try context.store.read(context.operationID)
        #expect(record.state.status == .failed)
        #expect(record.state.result == .failed)
        #expect(record.state.lastEvent.stepID == "recovery.rollback-completed")
        try MigrationImportTransaction.requireNoUnfinishedOperation(in: context.store)
        #expect(try await recover(context) == .nothingToRecover)
    }

    @Test func preservesExternallyTaggedImageUntilOwnershipIsExactAgain() async throws {
        let context = try await interruptedWithExternallyTaggedImage()
        defer { try? FileManager.default.removeItem(atPath: context.home) }

        await #expect(throws: MigrationImportRecoveryError.self) {
            _ = try await recover(context)
        }

        var record = try context.store.read(context.operationID)
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
        #expect(context.fixture.target.snapshotValue.images.first?.repository == "external")
        context.fixture.target.snapshotValue.images[0].repository = "<none>"
        context.fixture.target.snapshotValue.images[0].tag = "<none>"

        let result = try await recover(context)

        #expect(result.recoveredOperationID == context.operationID)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        record = try context.store.read(context.operationID)
        #expect(record.state.status == .failed)
        #expect(record.state.lastEvent.stepID == "recovery.rollback-completed")
    }

    @Test func crashRecoveryRemovesOnlyExactlyOwnedObjectsAndPreservesUnknownImages() async throws {
        let context = try await simulatedCrashWithOwnedObjects()
        defer { try? FileManager.default.removeItem(atPath: context.home) }

        let result = try await recover(context)

        #expect(result.recoveredOperationID == context.operationID)
        #expect(Set(result.preservedUnattributedTargetImageIDs) == Set([
            context.unattributedImageID,
            context.externalImageID
        ]))
        #expect(Set(context.fixture.target.snapshotValue.images.map(\.imageID)) == Set([
            context.unattributedImageID,
            context.externalImageID
        ]))
        #expect(context.fixture.target.snapshotValue.volumes.map(\.name) == ["external-volume"])
        #expect(context.fixture.target.snapshotValue.networks.map(\.name) == ["external-network"])
        #expect(context.fixture.target.snapshotValue.containers.map(\.name) == ["external-container"])
        #expect(context.fixture.source.snapshotValue.images.count == 1)
        #expect(context.fixture.source.snapshotValue.images[0].repository == "ghcr.io/example/app")
        #expect(try context.store.read(context.operationID).state.lastEvent.stepID
            == "recovery.rollback-completed-preserving-images")

        let retry = try await collect(context.fixture)
        let image = try #require(retry.operation.completenessPlan.objects.first {
            $0.source.kind == .image
        })
        #expect(image.collisionDecision == .reuseVerified)
    }

    @Test func refusesRecoveryWhenTheDockerAuthorityChanged() async throws {
        let context = try await cleanInterruptedStagingSession()
        defer { try? FileManager.default.removeItem(atPath: context.home) }
        context.fixture.target.info["ID"] = "replacement-target-daemon"

        await #expect(throws: MigrationImportRecoveryError.authorityChanged(
            context.operationID
        )) {
            _ = try await recover(context)
        }

        let record = try context.store.read(context.operationID)
        #expect(record.state.phase == .staging)
        #expect(record.state.status == .running)
        #expect(context.fixture.target.removedImages.isEmpty)
        #expect(context.fixture.target.removedVolumes.isEmpty)
        #expect(context.fixture.target.removedNetworks.isEmpty)
        #expect(context.fixture.target.removedContainers.isEmpty)
    }

    @Test func recoversJournalPublishedBeforeBaselinesWithoutTouchingDocker() async throws {
        let context = try await interruptedImmediatelyAfterJournalPublication()
        defer { try? FileManager.default.removeItem(atPath: context.home) }

        let result = try await recover(context)

        #expect(result.recoveredOperationID == context.operationID)
        let record = try context.store.read(context.operationID)
        #expect(record.state.phase == .planned)
        #expect(record.state.status == .failed)
        #expect(record.state.lastEvent.stepID == "recovery.no-mutations")
        #expect(context.fixture.source.removedImages.isEmpty)
        #expect(context.fixture.target.removedImages.isEmpty)
        #expect(context.fixture.target.removedVolumes.isEmpty)
        #expect(context.fixture.target.removedNetworks.isEmpty)
        #expect(context.fixture.target.removedContainers.isEmpty)
    }

    @Test func refusesToRaceAnImportThatStillHoldsTheJournalLease() async throws {
        let active = try await activeStagingSession()
        defer { try? FileManager.default.removeItem(atPath: active.context.home) }

        await #expect(throws: DoryOperationJournalError.self) {
            _ = try await recover(active.context)
        }

        let record = try active.context.store.read(active.context.operationID)
        #expect(record.state.phase == .staging)
        #expect(record.state.status == .running)
        #expect(active.context.fixture.target.removedImages.isEmpty)
        #expect(active.context.fixture.target.removedVolumes.isEmpty)
        #expect(active.context.fixture.target.removedNetworks.isEmpty)
        #expect(active.context.fixture.target.removedContainers.isEmpty)
        withExtendedLifetime(active.session) {}
    }

    @Test func restoresPreexistingDanglingHelpersAfterRemovingOperationTags() async throws {
        let helper = try recoveryTransferHelperAsset()
        let fixture = makeFixture()
        let helperImage = DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: helper.metadata.imageConfigDigest,
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024,
            labels: [
                "dev.dory.component": "transfer-helper",
                "dev.dory.helper.sha256": helper.metadata.helperSha256,
                "dev.dory.manifest.schema": "1"
            ]
        )
        fixture.source.snapshotValue.images.append(helperImage)
        fixture.target.snapshotValue.images.append(helperImage)
        fixture.source.systemDiskUsage = dockerUsage(
            images: 12_001_024,
            volumes: ["db-data": 4_096],
            containers: 1_024
        )
        fixture.target.systemDiskUsage = dockerUsage(images: 1_024)
        fixture.source.transferHelperMetadata = helper.metadata
        fixture.target.transferHelperMetadata = helper.metadata
        var active: ActiveRecoveryContext? = try await activeStagingSession(fixture)
        let context = try #require(active?.context)
        defer { try? FileManager.default.removeItem(atPath: context.home) }
        let operationRepository = "dory.internal/operation-"
            + context.operationID.uuidString.lowercased()
        for runtime in [fixture.source, fixture.target] {
            let index = try #require(runtime.snapshotValue.images.firstIndex {
                $0.imageID == helper.metadata.imageConfigDigest
            })
            runtime.snapshotValue.images[index].repository = operationRepository
            runtime.snapshotValue.images[index].tag = "transfer-helper"
        }
        active = nil

        let result = try await recover(context, helperAsset: helper)

        #expect(result.recoveredOperationID == context.operationID)
        for runtime in [fixture.source, fixture.target] {
            let image = try #require(runtime.snapshotValue.images.first {
                $0.imageID == helper.metadata.imageConfigDigest
            })
            #expect(MigrationOperationPlanBuilder.imageReferences(image).isEmpty)
            #expect(runtime.loadedTransferHelperArchives == [helper.archive])
        }
    }
}

private extension MigrationImportRecoveryTests {
    struct RecoveryContext {
        let fixture: StrictInventoryFixture
        let store: DoryOperationJournalStore
        let home: String
        let operationID: UUID
        var unattributedImageID = ""
        var externalImageID = ""
    }

    struct ActiveRecoveryContext {
        let context: RecoveryContext
        let session: MigrationImportStagingSession
    }

    func recover(
        _ context: RecoveryContext,
        helperAsset: MigrationTransferHelperAsset? = nil
    ) async throws -> MigrationImportRecoveryResult {
        try await MigrationImportRecovery.recoverUnfinishedOperation(
            environment: MigrationImportRecoveryEnvironment(
                source: context.fixture.source,
                target: context.fixture.target,
                journalStore: context.store,
                helperAsset: helperAsset
            )
        )
    }

    func recoveryTransferHelperAsset() throws -> MigrationTransferHelperAsset {
        let archive = Data("deterministic-recovery-helper".utf8)
        let pins = MigrationTransferHelperPins(
            archiveBytes: archive.count,
            archiveSha256: MigrationTransferHelperAsset.sha256(archive),
            helperBytes: 23,
            helperSha256: String(repeating: "b", count: 64),
            imageConfigDigest: MigrationTransferHelperPins.appleSiliconV1.imageConfigDigest,
            layerDiffId: "sha256:" + String(repeating: "c", count: 64)
        )
        let metadata = MigrationTransferHelperMetadata(
            archiveBytes: pins.archiveBytes,
            archiveSha256: pins.archiveSha256,
            helperBytes: pins.helperBytes,
            helperSha256: pins.helperSha256,
            imageConfigDigest: pins.imageConfigDigest,
            layerDiffId: pins.layerDiffId,
            platform: "linux/arm64",
            schemaVersion: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var metadataData = try encoder.encode(metadata)
        metadataData.append(0x0A)
        return try MigrationTransferHelperAsset(
            archive: archive,
            metadataData: metadataData,
            pins: pins
        )
    }

    func interruptedByVolumeRollbackFailure() async throws -> RecoveryContext {
        let active = try await activeStagingSession()
        let context = active.context
        let transfers = AssetStagingTransfers()
        transfers.volumeOutcome = .failure
        context.fixture.target.failVolumeRemoval = true
        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: active.session,
                environment: MigrationImportAssetStagingEnvironment(
                    source: context.fixture.source,
                    target: context.fixture.target,
                    transfers: transfers,
                    sharedHome: "/Users/test"
                )
            )
        }
        return context
    }

    func interruptedWithExternallyTaggedImage() async throws -> RecoveryContext {
        let active = try await activeStagingSession()
        let context = active.context
        let transfers = AssetStagingTransfers()
        transfers.volumeOutcome = .failure
        transfers.addExternalTargetImageReferenceBeforeVolumeFailure = true
        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: active.session,
                environment: MigrationImportAssetStagingEnvironment(
                    source: context.fixture.source,
                    target: context.fixture.target,
                    transfers: transfers,
                    sharedHome: "/Users/test"
                )
            )
        }
        return context
    }

    func simulatedCrashWithOwnedObjects() async throws -> RecoveryContext {
        let active = try await activeStagingSession()
        let context = active.context
        let prepared = active.session.prepared
        let ownership = prepared.ownership

        let volume: MigrationVolumeContract = try specification(
            kind: .volume,
            in: prepared,
            as: MigrationVolumeContract.self
        )
        try await context.fixture.target.createVolume(
            name: volume.name,
            driver: volume.driver,
            labels: volume.labels,
            driverOptions: volume.options
        )

        let network: MigrationNetworkContract = try specification(
            kind: .network,
            in: prepared,
            as: MigrationNetworkContract.self
        )
        _ = await context.fixture.target.proxyRequest(
            method: "POST",
            path: "/networks/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: try MigrationImportAssetCanonical.networkCreateBody(network)
        )

        let container: ContainerSpec = try specification(
            kind: .container,
            in: prepared,
            as: ContainerSpec.self
        )
        _ = try await context.fixture.target.create(container)

        let layer = try #require(prepared.operation.completenessPlan.objects.first {
            $0.source.kind == .writableLayer
        })
        let layerLabels = ownership.labels(
            existing: [:],
            kind: .writableLayer,
            sourceID: layer.source.sourceID,
            targetID: layer.normalizedTargetName
        )
        let temporaryReference = MigrationImportTemporaryAssets.writableLayerReference(
            operationID: context.operationID,
            sourceID: layer.source.sourceID
        )
        let split = DockerRegistry.splitImageRef(temporaryReference)
        context.fixture.source.snapshotValue.images.append(DockerImage(
            repository: split.repo,
            tag: split.tag,
            imageID: "sha256:" + String(repeating: "d", count: 64),
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024,
            labels: layerLabels
        ))
        context.fixture.target.snapshotValue.images.append(DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: "sha256:" + String(repeating: "d", count: 64),
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024,
            labels: layerLabels
        ))

        let image = try #require(prepared.operation.completenessPlan.objects.first {
            $0.source.kind == .image
        })
        let unattributed = "sha256:" + MigrationOperationPlanBuilder.normalizedImageID(
            image.source.sourceID
        )
        let external = "sha256:" + String(repeating: "e", count: 64)
        context.fixture.target.snapshotValue.images.append(DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: unattributed,
            size: "12 MB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 12_000_000
        ))
        context.fixture.target.snapshotValue.images.append(DockerImage(
            repository: "external",
            tag: "latest",
            imageID: external,
            size: "2 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 2_048
        ))
        context.fixture.target.snapshotValue.volumes.append(Volume(
            name: "external-volume",
            size: "0 B",
            driver: "local",
            usedBy: "",
            created: "now",
            labels: ["external.owner": "true"]
        ))
        context.fixture.target.snapshotValue.networks.append(DoryNetwork(
            name: "external-network",
            driver: "bridge",
            scope: "local",
            subnet: "172.31.0.0/24",
            containerCount: 0,
            labels: ["external.owner": "true"]
        ))
        var externalNetworkInspection = networkInspection()
        externalNetworkInspection["Name"] = "external-network"
        context.fixture.target.networkInspections["external-network"] = externalNetworkInspection
        _ = try await context.fixture.target.create(ContainerSpec(
            name: "external-container",
            image: external,
            labels: ["external.owner": "true"]
        ))
        return RecoveryContext(
            fixture: context.fixture,
            store: context.store,
            home: context.home,
            operationID: context.operationID,
            unattributedImageID: unattributed,
            externalImageID: external
        )
    }

    func cleanInterruptedStagingSession() async throws -> RecoveryContext {
        try await activeStagingSession().context
    }

    func interruptedImmediatelyAfterJournalPublication() async throws -> RecoveryContext {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        let home = NSTemporaryDirectory() + "dory-import-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try DoryOperationJournalStore(home: home)
        do {
            let lease = try prepared.operation.begin(in: store)
            #expect(try lease.read().state.phase == .planned)
            withExtendedLifetime(lease) {}
        }
        return RecoveryContext(
            fixture: fixture,
            store: store,
            home: home,
            operationID: prepared.identity.id
        )
    }

    func activeStagingSession(
        _ suppliedFixture: StrictInventoryFixture? = nil
    ) async throws -> ActiveRecoveryContext {
        let fixture = suppliedFixture ?? makeFixture()
        let prepared = try await collect(fixture)
        let home = NSTemporaryDirectory() + "dory-import-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try DoryOperationJournalStore(home: home)
        let session = try await MigrationImportTransaction.openStagingSession(
            prepared: prepared,
            environment: MigrationImportTransactionEnvironment(
                source: fixture.source,
                target: fixture.target,
                journalStore: store,
                currentAvailableHostBytes: prepared.capacity.availableHostBytes,
                transferHelper: .appleSiliconV1,
                sharedHome: "/Users/test",
                hostArchitecture: "arm64"
            )
        )
        return ActiveRecoveryContext(
            context: RecoveryContext(
                fixture: fixture,
                store: store,
                home: home,
                operationID: prepared.identity.id
            ),
            session: session
        )
    }
}
