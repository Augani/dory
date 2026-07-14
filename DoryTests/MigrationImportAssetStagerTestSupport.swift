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
