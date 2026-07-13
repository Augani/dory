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

        #expect(state.phase == .staging)
        #expect(state.status == .running)
        #expect(state.revision == 6)
        let staged = try context.session.lease.readStagedObjects()
        #expect(staged.map(\.source.kind) == [.image, .network, .volume])
        #expect(staged.allSatisfy { $0.disposition == .createdOperationOwned })
        #expect(context.fixture.target.snapshotValue.images.count == 1)
        let volume = try #require(context.fixture.target.snapshotValue.volumes.first)
        #expect(volume.name == "db-data")
        #expect(volume.labels["dev.dory.operation.state"] == "staging")
        let network = try #require(context.fixture.target.snapshotValue.networks.first)
        #expect(network.name == "backend")
        #expect(network.labels["dev.dory.operation.state"] == "staging")
        #expect(try context.session.lease.events().map(\.stepID).suffix(3) == [
            "staging.image-verified",
            "staging.network-verified",
            "staging.volume-verified"
        ])

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
}

@MainActor
private extension MigrationImportAssetStagerTests {
    struct Context {
        let fixture: StrictInventoryFixture
        let session: MigrationImportStagingSession
        let environment: MigrationImportAssetStagingEnvironment
        let transfers: AssetStagingTransfers
        let home: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func makeContext(name: String) async throws -> Context {
        let fixture = makeFixture()
        let prepared = try await collect(fixture)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-asset-stager-\(name)-\(UUID().uuidString)")
        let store = try DoryOperationJournalStore(home: home.path)
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
        let transfers = AssetStagingTransfers()
        return Context(
            fixture: fixture,
            session: session,
            environment: MigrationImportAssetStagingEnvironment(
                source: fixture.source,
                target: fixture.target,
                transfers: transfers
            ),
            transfers: transfers,
            home: home
        )
    }

    func verifyNetworkEvidence(
        _ staged: [DoryOperationStagedObject],
        context: Context
    ) throws {
        let evidence = try #require(staged.first { $0.source.kind == .network })
        let manifestData = try context.session.lease.readManifest(
            digest: evidence.verificationManifestDigest
        )
        let manifest = try JSONDecoder().decode(
            MigrationNetworkVerificationManifest.self,
            from: manifestData
        )
        #expect(manifest.operationID == context.fixture.identity.id)
        #expect(manifest.sourceNetwork == "backend")
        let inspectedContract = try context.session.lease.readManifest(
            digest: manifest.inspectedContractDigest
        )
        let inspected = try #require(
            JSONSerialization.jsonObject(with: inspectedContract) as? [String: Any]
        )
        #expect(inspected["Driver"] as? String == "bridge")
        #expect((inspected["IPAM"] as? [String: Any])?["Driver"] as? String == "default")
    }
}
