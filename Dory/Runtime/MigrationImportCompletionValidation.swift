import DoryOperations
import Foundation

extension MigrationImportAssetStagingExecution {
    mutating func validateAndComplete() async throws {
        try Task.checkCancellation()
        state = try session.lease.transition(
            to: .validating,
            status: .running,
            expectedRevision: state.revision,
            stepID: "validation.begin"
        )
        try await requireExactAuthoritiesAndSourceClosure()
        let staged = Dictionary(uniqueKeysWithValues: try session.lease.readStagedObjects().map {
            ($0.source, $0)
        })
        let plan = session.prepared.operation.completenessPlan
        guard staged.count == plan.objects.count else {
            throw MigrationImportAssetStagingError.invalidSession(
                "the final staged closure is incomplete"
            )
        }
        let evidence = try await finalEvidence(staged: staged, plan: plan)
        let unselectedSourceDigest = try verifiedUnselectedSourceInventoryDigest()
        let unownedTargetDigest = try await verifiedUnownedTargetInventoryDigest(
            staged: Array(staged.values)
        )
        try publishCompletionLedger(
            evidence: evidence,
            plan: plan,
            unselectedSourceDigest: unselectedSourceDigest,
            unownedTargetDigest: unownedTargetDigest
        )
        state = try session.lease.transition(
            to: .completed,
            status: .completed,
            expectedRevision: state.revision,
            stepID: "operation.completed"
        )
    }

    private func finalEvidence(
        staged: [DoryOperationObjectKey: DoryOperationStagedObject],
        plan: DoryOperationCompletenessPlan
    ) async throws -> [DoryOperationObjectEvidence] {
        var evidence: [DoryOperationObjectEvidence] = []
        for object in plan.objects {
            try Task.checkCancellation()
            guard let stagedObject = staged[object.source] else {
                throw MigrationImportAssetStagingError.invalidSession(
                    "final evidence is missing \(object.source)"
                )
            }
            let postPublicationTarget = try await validateFinalObject(
                object,
                staged: stagedObject
            )
            evidence.append(DoryOperationObjectEvidence(
                source: object.source,
                verifiedTarget: stagedObject.verifiedTarget,
                postPublicationTarget: postPublicationTarget,
                verificationManifestDigest: stagedObject.verificationManifestDigest,
                finalState: object.acceptedFinalState
            ))
        }
        return evidence.sorted { $0.source < $1.source }
    }

    private func publishCompletionLedger(
        evidence: [DoryOperationObjectEvidence],
        plan: DoryOperationCompletenessPlan,
        unselectedSourceDigest: String,
        unownedTargetDigest: String
    ) throws {
        let orderedEvidence = evidence.sorted { $0.source < $1.source }
        for item in orderedEvidence {
            try session.lease.publishObjectEvidence(item)
        }
        guard try session.lease.readObjectEvidence() == orderedEvidence else {
            throw MigrationImportAssetStagingError.invalidSession(
                "durable final evidence changed during publication"
            )
        }
        let ledger = DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: orderedEvidence,
            unselectedSourceInventoryDigest: unselectedSourceDigest,
            unownedTargetInventoryDigest: unownedTargetDigest
        )
        try session.lease.publishCompletionLedger(ledger)
        guard try session.lease.readCompletionLedger() == ledger else {
            throw MigrationImportAssetStagingError.invalidSession(
                "durable completion ledger changed during publication"
            )
        }
    }

    private func validateFinalObject(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        switch object.source.kind {
        case .image:
            return try await validateFinalImage(object, staged: staged)
        case .volume:
            return try await validateFinalVolume(object, staged: staged)
        case .network:
            return try await validateFinalNetwork(object, staged: staged)
        case .writableLayer:
            return try await validateFinalWritableLayer(object, staged: staged)
        case .container:
            return try await validateFinalContainer(object, staged: staged)
        }
    }
}

extension MigrationImportAssetStagingExecution {
    func validateFinalImage(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        let manifest: MigrationImageVerificationManifest = try stagedManifest(staged)
        guard manifest.schemaVersion == MigrationImageVerificationManifest.schemaVersion,
              manifest.operationID == session.prepared.identity.id,
              MigrationImageTransferExecution.canonicalImageID(manifest.sourceImageID)
                == MigrationImageTransferExecution.canonicalImageID(object.source.sourceID),
              manifest.loadedTargetImageID == staged.verifiedTarget.id,
              manifest.targetImageWasPreexisting == (staged.disposition == .reusedPreexisting),
              staged.verifiedTarget.fingerprint == manifest.verifiedTarget.archiveContractSha256,
              sameImageContent(manifest.sourceBeforeTransfer, manifest.sourceDuringTransfer),
              sameImageContent(manifest.sourceBeforeTransfer, manifest.sourceAfterTransfer) else {
            throw MigrationImportAssetStagingError.invalidSession(
                "final image staging manifest changed for \(object.source)"
            )
        }
        try await requireExactSourceImageContract(object)
        try await requireExactTargetImage(staged.verifiedTarget.id, object: object)
        let readback = try await environment.transfers.verifyImage(
            MigrationImageReadbackRequest(
                sourceImageID: object.source.sourceID,
                targetImageID: staged.verifiedTarget.id
            ),
            from: environment.source,
            to: environment.target
        )
        guard let source = readback.source,
              sameImageContent(source, manifest.sourceAfterTransfer),
              sameImageContent(readback.target, manifest.verifiedTarget) else {
            throw MigrationImportAssetStagingError.invalidSession(
                "final image archive read-back changed for \(object.source)"
            )
        }
        return DoryOperationTargetIdentity(
            id: staged.verifiedTarget.id,
            fingerprint: readback.target.archiveContractSha256
        )
    }

    func requireExactSourceImageContract(
        _ object: DoryOperationPlannedObject
    ) async throws {
        let sourceImages = try await environment.source.migrationSnapshot().images.filter {
            MigrationOperationPlanBuilder.stableImageSourceID($0) == object.source.sourceID
        }
        guard sourceImages.count == 1 else {
            throw MigrationImportAssetStagingError.invalidSession(
                "final source image identity changed for \(object.source)"
            )
        }
        let current = try MigrationOperationPlanBuilder.makeSpecification(
            MigrationImageContract(image: sourceImages[0])
        )
        guard current.digest == object.specificationDigest else {
            throw MigrationImportAssetStagingError.invalidSession(
                "final source image contract changed for \(object.source): expected "
                    + "\(object.specificationDigest), observed \(current.digest)"
            )
        }
    }

    func validateFinalWritableLayer(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        let manifest: MigrationLayerVerificationManifest = try stagedManifest(staged)
        let imageManifestData = try session.lease.readManifest(
            digest: manifest.imageVerificationManifestDigest
        )
        guard let imageManifest = try? JSONDecoder().decode(
            MigrationImageVerificationManifest.self,
            from: imageManifestData
        ), manifest.schemaVersion == MigrationLayerVerificationManifest.schemaVersion,
           manifest.operationID == session.prepared.identity.id,
           manifest.sourceContainerID == object.source.sourceID,
           manifest.loadedTargetImageID == staged.verifiedTarget.id,
           manifest.targetFingerprint == staged.verifiedTarget.fingerprint,
           imageManifest.operationID == session.prepared.identity.id,
           imageManifest.sourceImageID == manifest.committedSourceImageID,
           imageManifest.loadedTargetImageID == manifest.loadedTargetImageID,
           imageManifest.verifiedTarget.archiveContractSha256 == manifest.targetFingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        try await requireExactSourceWritableLayer(
            MigrationWritableLayerContract(
                containerID: manifest.sourceContainerID,
                logicalBytes: manifest.logicalBytes
            ),
            object: object
        )
        try await requireExactTargetImage(staged.verifiedTarget.id, object: object)
        let readback = try await environment.transfers.verifyImage(
            MigrationImageReadbackRequest(
                sourceImageID: nil,
                targetImageID: staged.verifiedTarget.id
            ),
            from: environment.source,
            to: environment.target
        )
        guard readback.source == nil,
              sameImageContent(readback.target, imageManifest.verifiedTarget) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return DoryOperationTargetIdentity(
            id: staged.verifiedTarget.id,
            fingerprint: readback.target.archiveContractSha256
        )
    }

    func validateFinalContainer(
        _ object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject
    ) async throws -> DoryOperationTargetIdentity {
        try await requireExactSourceContainer(object)
        guard let sourceSpecification = session.prepared.source.containerSpecifications[
            object.source.sourceID
        ], try MigrationOperationPlanBuilder.digest(MigrationContainerSourceContract(
            id: object.source.sourceID,
            specification: sourceSpecification
        )) == object.sourceFingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let definition = try stagedContainerDefinition(object)
        let matches = try await environment.target.migrationSnapshot().containers.filter {
            $0.name == object.normalizedTargetName
        }
        guard matches.count == 1 else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        try await verifyPublishedContainer(
            matches[0].id,
            object: object,
            definition: definition
        )
        guard definition.manifest.effectiveSpecificationDigest == staged.verifiedTarget.fingerprint else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        return DoryOperationTargetIdentity(
            id: definition.specification.name,
            fingerprint: definition.manifest.effectiveSpecificationDigest
        )
    }

    func stagedManifest<T: Decodable>(
        _ staged: DoryOperationStagedObject
    ) throws -> T {
        let data = try session.lease.readManifest(digest: staged.verificationManifestDigest)
        guard let manifest = try? JSONDecoder().decode(T.self, from: data) else {
            throw MigrationImportAssetStagingError.invalidSpecification(staged.source)
        }
        return manifest
    }

    func requireExactTargetImage(
        _ imageID: String,
        object: DoryOperationPlannedObject
    ) async throws {
        let canonical = MigrationOperationPlanBuilder.normalizedImageID(imageID)
        let matches = try await environment.target.migrationSnapshot().images.filter {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID) == canonical
        }
        guard matches.count == 1 else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func sameImageContent(
        _ lhs: MigrationImageArchiveFingerprint,
        _ rhs: MigrationImageArchiveFingerprint
    ) -> Bool {
        lhs.semanticIdentity == rhs.semanticIdentity
            && lhs.archiveContractSha256 == rhs.archiveContractSha256
    }
}
