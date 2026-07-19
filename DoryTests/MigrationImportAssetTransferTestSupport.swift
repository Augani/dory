import DoryOperations
import Foundation
import Testing
@testable import Dory

@MainActor
final class AssetStagingTransfers: MigrationImportAssetTransfers {
    enum Failure: Error { case volume }
    enum VolumeOutcome { case success, failure, cancelled }

    var volumeOutcome = VolumeOutcome.success
    var mutateTargetVolume = false
    var mutateFinalImageReadback = false
    var mutateFinalVolumeReadback = false
    var failFinalVolumeCleanup = false
    var addExternalTargetImageReferenceBeforeVolumeFailure = false
    var removeTargetImageBeforeVolumeFailure = false
    var addExternalSourceSnapshotReferenceAfterTransfer = false
    var mutateOmittedSourceVolumeAfterImageTransfer = false
    var imageReadbackRequests: [MigrationImageReadbackRequest] = []
    var volumeReadbackRequests: [MigrationVolumeTransferRequest] = []
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
        let targetEntry = try #require(
            MigrationImageTransferExecution.targetInventory(
                images: runtime.snapshotValue.images
            ).entries.first(where: { $0.id == imageID })
        )
        let responseDigest = String(repeating: "c", count: 64)
        if addExternalSourceSnapshotReferenceAfterTransfer,
           let sourceRuntime = source as? StrictMigrationRuntime,
           let index = sourceRuntime.snapshotValue.images.firstIndex(where: {
               MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == digest
                   && $0.labels["dev.dory.object.kind"] == "writableLayer"
           }) {
            sourceRuntime.snapshotValue.images[index].additionalReferences.append(
                "external:latest"
            )
        }
        if mutateOmittedSourceVolumeAfterImageTransfer,
           let sourceRuntime = source as? StrictMigrationRuntime,
           !sourceRuntime.snapshotValue.volumes.isEmpty {
            sourceRuntime.snapshotValue.volumes[0].labels["external.drift"] = "true"
        }
        let manifest = try MigrationImportAssetCanonical.data(MigrationImageVerificationManifest(
            operationID: request.operationID,
            sourceImageID: imageID,
            loadedTargetImageID: imageID,
            targetInventoryEntryAfterLoad: targetEntry,
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
            targetInventoryEntryAfterLoad: targetEntry,
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
        if addExternalTargetImageReferenceBeforeVolumeFailure,
           let runtime = target as? StrictMigrationRuntime,
           !runtime.snapshotValue.images.isEmpty {
            runtime.snapshotValue.images[0].repository = "external"
            runtime.snapshotValue.images[0].tag = "latest"
        }
        if removeTargetImageBeforeVolumeFailure,
           let runtime = target as? StrictMigrationRuntime {
            runtime.snapshotValue.images.removeAll()
        }
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

    func verifyImage(
        _ request: MigrationImageReadbackRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageReadbackReceipt {
        imageReadbackRequests.append(request)
        let targetID = try #require(
            MigrationImageTransferExecution.canonicalImageID(request.targetImageID)
        )
        let targetDigest = String(targetID.dropFirst("sha256:".count))
        let sourceFingerprint = try request.sourceImageID.map { sourceID in
            let canonical = try #require(
                MigrationImageTransferExecution.canonicalImageID(sourceID)
            )
            return try fingerprint(digest: String(canonical.dropFirst("sha256:".count)))
        }
        return MigrationImageReadbackReceipt(
            source: sourceFingerprint,
            target: try fingerprint(digest: mutateFinalImageReadback
                ? String(repeating: "e", count: 64)
                : targetDigest)
        )
    }

    func verifyVolume(
        _ request: MigrationVolumeTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationVolumeTransferReceipt {
        volumeReadbackRequests.append(request)
        if failFinalVolumeCleanup {
            throw MigrationVolumeTransferError.cleanup(["injected helper cleanup failure"])
        }
        let targetManifest = mutateFinalVolumeReadback
            ? Data("changed-target-volume-manifest".utf8)
            : self.targetVolumeManifest
        return MigrationVolumeTransferReceipt(
            sourceManifest: sourceVolumeManifest,
            targetManifest: targetManifest,
            sourceManifestSha256: MigrationImportAssetCanonical.digest(sourceVolumeManifest),
            targetManifestSha256: MigrationImportAssetCanonical.digest(targetManifest),
            sourceEntryCount: 2,
            verifiedTargetEntryCount: 2,
            excludedSocketCount: 0,
            containsDeviceNodes: false
        )
    }
}
