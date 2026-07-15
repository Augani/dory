import DoryOperations
import Foundation

private struct MigrationWritableLayerCapture {
    let committedID: String
    let receipt: MigrationImageTransferReceipt
    let imageManifestDigest: String
}

private struct MigrationWritableLayerSourceSnapshot {
    let reference: String
    let labels: [String: String]
    let committedID: String
}

extension MigrationImportAssetStagingExecution {
    mutating func stageWritableLayer(_ object: DoryOperationPlannedObject) async throws {
        let specification = try writableLayerSpecification(object)
        try await requireExactSourceWritableLayer(specification, object: object)
        let capture = try await captureWritableLayer(specification, object: object)
        try await requireExactSourceWritableLayer(specification, object: object)
        try publishWritableLayerEvidence(
            object: object,
            specification: specification,
            capture: capture
        )
    }

    private func writableLayerSpecification(
        _ object: DoryOperationPlannedObject
    ) throws -> MigrationWritableLayerContract {
        let specificationData = try session.lease.readSpecification(
            digest: object.specificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            MigrationWritableLayerContract.self,
            from: specificationData
        ), specification.containerID == object.source.sourceID,
           specification.logicalBytes > 0,
           object.collisionDecision == .create else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        return specification
    }

    private mutating func captureWritableLayer(
        _ specification: MigrationWritableLayerContract,
        object: DoryOperationPlannedObject
    ) async throws -> MigrationWritableLayerCapture {
        let sourceSnapshot = try await commitWritableLayer(specification, object: object)
        try await requireExactSourceWritableLayer(specification, object: object)
        let committedID = sourceSnapshot.committedID
        let receipt = try await environment.transfers.transferImage(
            MigrationImageTransferRequest(
                operationID: session.prepared.identity.id,
                sourceImageID: committedID
            ),
            from: environment.source,
            to: environment.target
        )
        if !receipt.targetImageWasPreexisting {
            created.append(.image(entry: receipt.targetInventoryEntryAfterLoad))
        }
        guard MigrationImageTransferExecution.canonicalImageID(receipt.loadedTargetImageID) != nil,
              MigrationImageTransferExecution.canonicalImageID(
                receipt.verifiedTarget.semanticIdentity
              ) == MigrationImageTransferExecution.canonicalImageID(committedID) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let imageManifestDigest = try session.lease.publishManifest(receipt.verificationManifest)
        guard imageManifestDigest == receipt.verificationManifestSha256 else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        var cleanupFailures: [String] = []
        await rollbackSourceImage(
            sourceSnapshot.reference,
            expectedLabels: sourceSnapshot.labels,
            failures: &cleanupFailures
        )
        guard cleanupFailures.isEmpty else {
            throw MigrationImportAssetStagingError.cleanup(cleanupFailures)
        }
        return MigrationWritableLayerCapture(
            committedID: committedID,
            receipt: receipt,
            imageManifestDigest: imageManifestDigest
        )
    }

    private mutating func commitWritableLayer(
        _ specification: MigrationWritableLayerContract,
        object: DoryOperationPlannedObject
    ) async throws -> MigrationWritableLayerSourceSnapshot {
        let reference = writableLayerTemporaryReference(object)
        try await requireSourceImageAbsent(reference, object: object)
        let labels = session.prepared.ownership.labels(
            existing: [:],
            kind: .writableLayer,
            sourceID: object.source.sourceID,
            targetID: object.normalizedTargetName
        )
        created.append(.sourceImage(reference: reference, expectedLabels: labels))
        let split = DockerRegistry.splitImageRef(reference)
        let committedID = try await environment.source.commit(
            containerID: specification.containerID,
            repo: split.repo,
            tag: split.tag,
            labels: labels,
            pause: false
        )
        guard MigrationImageTransferExecution.canonicalImageID(committedID) != nil else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return MigrationWritableLayerSourceSnapshot(
            reference: reference,
            labels: labels,
            committedID: committedID
        )
    }

    private mutating func publishWritableLayerEvidence(
        object: DoryOperationPlannedObject,
        specification: MigrationWritableLayerContract,
        capture: MigrationWritableLayerCapture
    ) throws {
        let manifest = try MigrationImportAssetCanonical.data(
            MigrationLayerVerificationManifest(
                operationID: session.prepared.identity.id,
                specification: specification,
                committedSourceImageID: capture.committedID,
                receipt: capture.receipt,
                imageVerificationManifestDigest: capture.imageManifestDigest
            )
        )
        let manifestDigest = try session.lease.publishManifest(manifest)
        try session.lease.publishStagedObject(DoryOperationStagedObject(
            source: object.source,
            verifiedTarget: DoryOperationTargetIdentity(
                id: capture.receipt.loadedTargetImageID,
                fingerprint: capture.receipt.verifiedTarget.archiveContractSha256
            ),
            verificationManifestDigest: manifestDigest,
            disposition: capture.receipt.targetImageWasPreexisting
                ? .reusedPreexisting
                : .createdOperationOwned
        ))
        state = try session.lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: state.revision,
            stepID: "staging.writable-layer-verified"
        )
    }

    func requireExactSourceWritableLayer(
        _ specification: MigrationWritableLayerContract,
        object: DoryOperationPlannedObject
    ) async throws {
        let snapshot = try await environment.source.migrationSnapshot()
        let current = snapshot.containers.filter { $0.id == specification.containerID }
        let baseline = session.prepared.source.snapshot.containers.filter {
            $0.id == specification.containerID
        }
        guard current.count == 1,
              baseline.count == 1,
              current[0].status == baseline[0].status,
              current[0].status != .running,
              let planned = session.prepared.source.containerSpecifications[
                specification.containerID
              ] else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let inspected = try await MigrationContainerInspector.inspect(
            current[0],
            on: environment.source,
            sharedHome: environment.sharedHome
        )
        guard try MigrationImportAssetCanonical.data(inspected)
                == MigrationImportAssetCanonical.data(planned),
              try await environment.source.migrationContainerWritableSizes()[
                specification.containerID
              ] == specification.logicalBytes else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func requireSourceImageAbsent(
        _ reference: String,
        object: DoryOperationPlannedObject
    ) async throws {
        let images = try await environment.source.migrationSnapshot().images
        guard !images.contains(where: {
            MigrationOperationPlanBuilder.imageReferences($0).contains(reference)
        }) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func writableLayerTemporaryReference(_ object: DoryOperationPlannedObject) -> String {
        let operation = session.prepared.identity.id.uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        let objectDigest = MigrationImportAssetCanonical.digest(
            Data(object.source.sourceID.utf8)
        )
        return "dory-migration/staging:\(operation)-\(objectDigest.prefix(12))"
    }

    func rollbackSourceImage(
        _ reference: String,
        expectedLabels: [String: String],
        failures: inout [String]
    ) async {
        do {
            let before = try await environment.source.migrationSnapshot().images.filter {
                MigrationOperationPlanBuilder.imageReferences($0).contains(reference)
                    || owns($0.labels, expected: expectedLabels)
            }
            guard before.count <= 1 else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .writableLayer, sourceID: reference)
                )
            }
            if let image = before.first {
                guard owns(image.labels, expected: expectedLabels) else {
                    throw MigrationImportAssetStagingError.targetDrift(
                        .init(kind: .writableLayer, sourceID: reference)
                    )
                }
                if MigrationOperationPlanBuilder.imageReferences(image).contains(reference) {
                    try await environment.source.removeImageForRollback(id: reference)
                }
                try await removeUntaggedSourceImageIfNeeded(
                    image.imageID,
                    expectedLabels: expectedLabels
                )
            }
            let after = try await environment.source.migrationSnapshot().images
            guard !after.contains(where: {
                MigrationOperationPlanBuilder.imageReferences($0).contains(reference)
                    || owns($0.labels, expected: expectedLabels)
            }) else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .writableLayer, sourceID: reference)
                )
            }
        } catch {
            failures.append("remove source writable-layer snapshot \(reference): \(error)")
        }
    }

    func removeUntaggedSourceImageIfNeeded(
        _ imageID: String,
        expectedLabels: [String: String]
    ) async throws {
        let canonical = MigrationOperationPlanBuilder.normalizedImageID(imageID)
        let remaining = try await environment.source.migrationSnapshot().images.filter {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == canonical
        }
        guard remaining.count <= 1 else {
            throw MigrationImportAssetStagingError.targetDrift(
                .init(kind: .writableLayer, sourceID: imageID)
            )
        }
        if let image = remaining.first {
            guard owns(image.labels, expected: expectedLabels) else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .writableLayer, sourceID: imageID)
                )
            }
            guard MigrationOperationPlanBuilder.imageReferences(image).isEmpty else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .writableLayer, sourceID: imageID)
                )
            }
            try await environment.source.removeImageForRollback(id: imageID)
        }
        let after = try await environment.source.migrationSnapshot().images
        guard !after.contains(where: {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == canonical
        }) else {
            throw MigrationImportAssetStagingError.targetDrift(
                .init(kind: .writableLayer, sourceID: imageID)
            )
        }
    }
}
