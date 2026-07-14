import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportAssetStagerTests: StrictInventoryTestCase {
    @Test func stagesAssetsWithDurableVerificationEvidence() async throws {
        let context = try await makeContext(name: "success")
        defer { context.cleanup() }

        let state = try await MigrationImportAssetStager.stage(
            session: context.session,
            environment: context.environment
        )

        #expect(state.phase == .publishing)
        #expect(state.status == .running)
        #expect(state.revision == 12)
        let staged = try context.session.lease.readStagedObjects()
        #expect(staged.map(\.source.kind) == [
            .container, .image, .network, .volume, .writableLayer
        ])
        #expect(staged.allSatisfy { $0.disposition == .createdOperationOwned })
        #expect(context.fixture.target.snapshotValue.images.count == 2)
        let volume = try #require(context.fixture.target.snapshotValue.volumes.first)
        #expect(volume.name == "db-data")
        #expect(volume.labels["dev.dory.operation.state"] == "staging")
        let network = try #require(context.fixture.target.snapshotValue.networks.first)
        #expect(network.name == "backend")
        #expect(network.labels["dev.dory.operation.state"] == "staging")
        #expect(try context.session.lease.events().map(\.stepID).suffix(5) == [
            "staging.container-definition-verified",
            "verifying.staged-closure",
            "publication.ready",
            "publication.begin",
            "publication.container-verified"
        ])
        #expect(context.fixture.source.commitRequests.count == 1)
        #expect(context.fixture.source.commitRequests[0].pause == false)
        #expect(context.fixture.source.snapshotValue.images.count == 1)
        #expect(context.fixture.source.removedImages.count == 1)

        let volumeEvidence = try #require(staged.first { $0.source.kind == .volume })
        let manifestData = try context.session.lease.readManifest(
            digest: volumeEvidence.verificationManifestDigest
        )
        let manifest = try JSONDecoder().decode(
            MigrationVolumeVerificationManifest.self,
            from: manifestData
        )
        #expect(manifest.operationID == context.fixture.identity.id)
        #expect(manifest.sourceVolume == "db-data")
        #expect(manifest.targetVolume == "db-data")
        #expect(try context.session.lease.readManifest(digest: manifest.sourceManifestDigest)
            == context.transfers.sourceVolumeManifest)
        #expect(try context.session.lease.readManifest(digest: manifest.targetManifestDigest)
            == context.transfers.targetVolumeManifest)

        try verifyNetworkEvidence(staged, context: context)
        try verifyWritableLayerEvidence(staged, context: context)
        try verifyContainerDefinition(staged, context: context)
    }

    @Test func laterAssetFailureRollsBackEveryCreatedTargetAndFailsTerminally() async throws {
        let context = try await makeContext(name: "rollback")
        defer { context.cleanup() }
        context.transfers.volumeOutcome = .failure

        await #expect(throws: AssetStagingTransfers.Failure.volume) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(context.fixture.target.removedVolumes == ["db-data"])
        #expect(context.fixture.target.removedNetworks == ["backend"])
        #expect(context.fixture.target.removedImages.count == 1)
        let record = try context.session.lease.read()
        #expect(record.state.phase == .staging)
        #expect(record.state.status == .failed)
        #expect(record.state.result == .failed)
    }

    @Test func cancellationRollsBackBeforeRecordingTheCancelledResult() async throws {
        let context = try await makeContext(name: "cancel")
        defer { context.cleanup() }
        context.transfers.volumeOutcome = .cancelled

        await #expect(throws: CancellationError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.status == .failed)
        #expect(record.state.result == .cancelled)
    }

    @Test func incompleteRollbackEntersNeedsRecoveryAndPreservesTheOwnedTarget() async throws {
        let context = try await makeContext(name: "recovery")
        defer { context.cleanup() }
        context.transfers.volumeOutcome = .failure
        context.fixture.target.failImageRemoval = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.count == 1)
        let record = try context.session.lease.read()
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
    }

    @Test func independentlyIntroducedImageIsTargetDriftAndIsNeverDeleted() async throws {
        let context = try await makeContext(name: "image-race")
        defer { context.cleanup() }
        let object = try #require(
            context.session.prepared.operation.completenessPlan.objects.first {
                $0.source.kind == .image
            }
        )
        let imageID = "sha256:\(object.source.sourceID)"
        context.fixture.target.snapshotValue.images.append(DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: imageID,
            size: "1 B",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1
        ))

        await #expect(throws: MigrationImportAssetStagingError.targetDrift(object.source)) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.map(\.imageID) == [imageID])
        #expect(context.fixture.target.removedImages.isEmpty)
        #expect(try context.session.lease.read().state.status == .failed)
    }

    @Test func independentlyIntroducedNetworkIsTargetDriftAndIsNeverDeleted() async throws {
        let context = try await makeContext(name: "network-race")
        defer { context.cleanup() }
        let object = try #require(
            context.session.prepared.operation.completenessPlan.objects.first {
                $0.source.kind == .network
            }
        )
        context.fixture.target.snapshotValue.networks.append(DoryNetwork(
            name: "backend",
            driver: "bridge",
            scope: "local",
            subnet: "172.31.0.0/24",
            containerCount: 0,
            labels: ["external.owner": "true"]
        ))

        await #expect(throws: MigrationImportAssetStagingError.targetDrift(object.source)) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.networks[0].labels == ["external.owner": "true"])
        #expect(context.fixture.target.removedNetworks.isEmpty)
    }

    @Test func volumeContractDriftAfterTransferRollsBackAllOwnedAssets() async throws {
        let context = try await makeContext(name: "volume-drift")
        defer { context.cleanup() }
        context.transfers.mutateTargetVolume = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(try context.session.lease.read().state.status == .failed)
    }

    @Test func networkContractDriftAfterCreationRollsBackAllOwnedAssets() async throws {
        let context = try await makeContext(name: "network-drift")
        defer { context.cleanup() }
        context.fixture.target.mutateCreatedNetworkContract = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(context.fixture.target.removedNetworks == ["backend"])
        #expect(try context.session.lease.read().state.status == .failed)
    }

    @Test func incompleteNetworkRollbackEntersNeedsRecovery() async throws {
        let context = try await makeContext(name: "network-recovery")
        defer { context.cleanup() }
        context.fixture.target.mutateCreatedNetworkContract = true
        context.fixture.target.failNetworkRemoval = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.map(\.name) == ["backend"])
        let record = try context.session.lease.read()
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
    }

    @Test func sourceWritableLayerDriftRollsBackPreviouslyStagedAssets() async throws {
        let context = try await makeContext(name: "writable-layer-drift")
        defer { context.cleanup() }
        context.fixture.source.writableSizes["container-id"] = 2_048

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.source.commitRequests.isEmpty)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        #expect(try context.session.lease.read().state.status == .failed)
    }

    @Test func incompleteSourceSnapshotCleanupEntersNeedsRecovery() async throws {
        let context = try await makeContext(name: "writable-layer-recovery")
        defer { context.cleanup() }
        context.fixture.source.failImageRemoval = true

        await #expect(throws: MigrationImportAssetStagingError.self) {
            _ = try await MigrationImportAssetStager.stage(
                session: context.session,
                environment: context.environment
            )
        }

        #expect(context.fixture.source.snapshotValue.images.count == 2)
        #expect(context.fixture.target.snapshotValue.images.isEmpty)
        #expect(context.fixture.target.snapshotValue.volumes.isEmpty)
        #expect(context.fixture.target.snapshotValue.networks.isEmpty)
        let record = try context.session.lease.read()
        #expect(record.state.status == .needsRecovery)
        #expect(record.state.lastEvent.recoveryAction == "rollback.retry")
    }

}
