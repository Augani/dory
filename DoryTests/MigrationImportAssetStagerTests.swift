import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationImportAssetStagerTests: StrictInventoryTestCase {
    @Test func stagesImagesAndVolumesWithDurableVerificationEvidence() async throws {
        let context = try await makeContext(name: "success")
        defer { context.cleanup() }

        let state = try await MigrationImportAssetStager.stage(
            session: context.session,
            environment: context.environment
        )

        #expect(state.phase == .staging)
        #expect(state.status == .running)
        #expect(state.revision == 5)
        let staged = try context.session.lease.readStagedObjects()
        #expect(staged.map(\.source.kind) == [.image, .volume])
        #expect(staged.map(\.disposition) == [.createdOperationOwned, .createdOperationOwned])
        #expect(context.fixture.target.snapshotValue.images.count == 1)
        let volume = try #require(context.fixture.target.snapshotValue.volumes.first)
        #expect(volume.name == "db-data")
        #expect(volume.labels["dev.dory.operation.state"] == "staging")
        #expect(try context.session.lease.events().map(\.stepID).suffix(2) == [
            "staging.image-verified",
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
        #expect(context.fixture.target.removedVolumes == ["db-data"])
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
        #expect(try context.session.lease.read().state.status == .failed)
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
}

@MainActor
private final class AssetStagingTransfers: MigrationImportAssetTransfers {
    enum Failure: Error { case volume }
    enum VolumeOutcome { case success, failure, cancelled }

    var volumeOutcome = VolumeOutcome.success
    var mutateTargetVolume = false
    let sourceVolumeManifest = Data("source-volume-manifest".utf8)
    let targetVolumeManifest = Data("target-volume-manifest".utf8)

    func transferImage(
        _ request: MigrationImageTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageTransferReceipt {
        let imageID = try #require(
            MigrationImageTransferExecution.canonicalImageID(request.sourceImageID)
        )
        let digest = String(imageID.dropFirst("sha256:".count))
        let fingerprint = try fingerprint(digest: digest)
        let runtime = try #require(target as? StrictMigrationRuntime)
        let preexisting = installImage(imageID, digest: digest, on: runtime)
        let responseDigest = String(repeating: "c", count: 64)
        let manifest = try MigrationImportAssetCanonical.data(MigrationImageVerificationManifest(
            operationID: request.operationID,
            sourceImageID: imageID,
            loadedTargetImageID: imageID,
            targetImageWasPreexisting: preexisting,
            loadResponseSha256: responseDigest,
            sourceBeforeTransfer: fingerprint,
            sourceDuringTransfer: fingerprint,
            sourceAfterTransfer: fingerprint,
            verifiedTarget: fingerprint
        ))
        return MigrationImageTransferReceipt(
            sourceBeforeTransfer: fingerprint,
            sourceDuringTransfer: fingerprint,
            sourceAfterTransfer: fingerprint,
            verifiedTarget: fingerprint,
            loadedTargetImageID: imageID,
            targetImageWasPreexisting: preexisting,
            loadResponseSha256: responseDigest,
            verificationManifest: manifest,
            verificationManifestSha256: MigrationImportAssetCanonical.digest(manifest)
        )
    }

    private func fingerprint(digest: String) throws -> MigrationImageArchiveFingerprint {
        try MigrationImageArchiveFingerprint(
            configArchivePath: "config.json",
            configBytes: 1,
            configSha256: digest,
            layers: [],
            archiveBytes: 1,
            archiveEntryCount: 1,
            archiveSha256: String(repeating: "b", count: 64)
        )
    }

    private func installImage(
        _ imageID: String,
        digest: String,
        on runtime: StrictMigrationRuntime
    ) -> Bool {
        let preexisting = runtime.snapshotValue.images.contains {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == digest
        }
        guard !preexisting else { return true }
        runtime.snapshotValue.images.append(DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: imageID,
            size: "1 B",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1
        ))
        return false
    }

    func transferVolume(
        _ request: MigrationVolumeTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationVolumeTransferReceipt {
        switch volumeOutcome {
        case .failure: throw Failure.volume
        case .cancelled: throw CancellationError()
        case .success: break
        }
        if mutateTargetVolume,
           let runtime = target as? StrictMigrationRuntime,
           !runtime.snapshotValue.volumes.isEmpty {
            runtime.snapshotValue.volumes[0].options["external.drift"] = "true"
        }
        return MigrationVolumeTransferReceipt(
            sourceManifest: sourceVolumeManifest,
            targetManifest: targetVolumeManifest,
            sourceManifestSha256: MigrationImportAssetCanonical.digest(sourceVolumeManifest),
            targetManifestSha256: MigrationImportAssetCanonical.digest(targetVolumeManifest),
            sourceEntryCount: 2,
            verifiedTargetEntryCount: 2,
            excludedSocketCount: 0,
            containsDeviceNodes: false
        )
    }
}
