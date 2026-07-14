import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
extension MigrationImportAssetStagerTests {
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

    func makeContext(
        name: String,
        configure: (StrictInventoryFixture) -> Void = { _ in }
    ) async throws -> Context {
        let fixture = makeFixture()
        configure(fixture)
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
                transfers: transfers,
                sharedHome: "/Users/test"
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

    func verifyCompletedStateAndTargets(
        _ state: DoryOperationState,
        context: Context
    ) throws -> [DoryOperationStagedObject] {
        #expect(state.phase == .completed)
        #expect(state.status == .completed)
        #expect(state.result == .succeeded)
        #expect(state.revision == 14)
        let staged = try context.session.lease.readStagedObjects()
        #expect(staged.map(\.source.kind) == [
            .container, .image, .network, .volume, .writableLayer
        ])
        #expect(staged.allSatisfy { $0.disposition == .createdOperationOwned })
        #expect(context.fixture.target.snapshotValue.images.count == 2)
        let volume = try #require(context.fixture.target.snapshotValue.volumes.first)
        #expect(volume.name == "db-data")
        #expect(volume.labels["dev.dory.operation.state"] == "published")
        let network = try #require(context.fixture.target.snapshotValue.networks.first)
        #expect(network.name == "backend")
        #expect(network.labels["dev.dory.operation.state"] == "published")
        #expect(try context.session.lease.events().map(\.stepID).suffix(7) == [
            "staging.container-definition-verified",
            "verifying.staged-closure",
            "publication.ready",
            "publication.begin",
            "publication.container-verified",
            "validation.begin",
            "operation.completed"
        ])
        #expect(context.fixture.source.commitRequests.count == 1)
        #expect(context.fixture.source.commitRequests[0].pause == false)
        #expect(context.fixture.source.snapshotValue.images.count == 1)
        #expect(context.fixture.source.removedImages.count == 1)
        return staged
    }

    func verifyVolumeEvidence(
        _ staged: [DoryOperationStagedObject],
        context: Context
    ) throws {
        let evidence = try #require(staged.first { $0.source.kind == .volume })
        let manifestData = try context.session.lease.readManifest(
            digest: evidence.verificationManifestDigest
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
    }

    func verifyFinalEvidence(_ context: Context) throws {
        let evidence = try context.session.lease.readObjectEvidence()
        #expect(evidence.map(\.source.kind) == [
            .container, .image, .network, .volume, .writableLayer
        ])
        #expect(evidence.allSatisfy { $0.verifiedTarget == $0.postPublicationTarget })
        #expect(try context.session.lease.readCompletionLedger().evidence == evidence)
        #expect(context.transfers.imageReadbackRequests.count == 2)
        #expect(context.transfers.volumeReadbackRequests.count == 1)
    }

    func verifyWritableLayerEvidence(
        _ staged: [DoryOperationStagedObject],
        context: Context
    ) throws {
        let evidence = try #require(staged.first { $0.source.kind == .writableLayer })
        let manifestData = try context.session.lease.readManifest(
            digest: evidence.verificationManifestDigest
        )
        let manifest = try JSONDecoder().decode(
            MigrationLayerVerificationManifest.self,
            from: manifestData
        )
        #expect(manifest.operationID == context.fixture.identity.id)
        #expect(manifest.sourceContainerID == "container-id")
        #expect(manifest.logicalBytes == 1_024)
        #expect(manifest.committedSourceImageID == manifest.loadedTargetImageID)
        _ = try context.session.lease.readManifest(
            digest: manifest.imageVerificationManifestDigest
        )
    }

    func verifyContainerDefinition(
        _ staged: [DoryOperationStagedObject],
        context: Context
    ) throws {
        let evidence = try #require(staged.first { $0.source.kind == .container })
        let manifestData = try context.session.lease.readManifest(
            digest: evidence.verificationManifestDigest
        )
        let manifest = try JSONDecoder().decode(
            MigrationContainerDefinitionManifest.self,
            from: manifestData
        )
        let specificationData = try context.session.lease.readManifest(
            digest: manifest.effectiveSpecificationDigest
        )
        let specification = try JSONDecoder().decode(ContainerSpec.self, from: specificationData)
        let layer = try #require(staged.first { $0.source.kind == .writableLayer })
        #expect(specification.image == layer.verifiedTarget.id)
        #expect(specification.labels["dev.dory.operation.state"] == "published")
        let target = try #require(context.fixture.target.snapshotValue.containers.first)
        #expect(target.name == "app")
        #expect(target.status == .stopped)
        #expect(context.fixture.target.createdContainers.count == 1)
    }

}
