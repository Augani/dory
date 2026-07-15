import DoryOperations
import Foundation

enum MigrationImportAssetStager {
    static func stage(
        session: MigrationImportStagingSession,
        environment: MigrationImportAssetStagingEnvironment
    ) async throws -> DoryOperationState {
        var execution = try MigrationImportAssetStagingExecution(
            session: session,
            environment: environment
        )
        do {
            return try await execution.stage()
        } catch {
            let operation = error
            let rollback = await execution.rollback()
            try terminate(
                session: session,
                operation: operation,
                rollback: rollback
            )
        }
    }

    private static func terminate(
        session: MigrationImportStagingSession,
        operation: Error,
        rollback: [String]
    ) throws -> Never {
        let current: DoryOperationState
        do {
            current = try session.lease.read().state
            if rollback.isEmpty, !requiresRecovery(operation) {
                if operation is CancellationError {
                    _ = try session.lease.cancelAfterRollback(
                        expectedRevision: current.revision,
                        stepID: "staging.cancelled"
                    )
                } else {
                    _ = try session.lease.transition(
                        to: current.phase,
                        status: .failed,
                        expectedRevision: current.revision,
                        stepID: "staging.failed"
                    )
                }
            } else {
                _ = try session.lease.transition(
                    to: current.phase,
                    status: .needsRecovery,
                    expectedRevision: current.revision,
                    stepID: "staging.rollback-incomplete",
                    recoveryAction: "rollback.retry"
                )
            }
        } catch {
            throw MigrationImportAssetStagingError.operationAndJournal(
                operation: String(describing: operation),
                journal: String(describing: error)
            )
        }
        if operation is CancellationError, rollback.isEmpty { throw CancellationError() }
        if rollback.isEmpty { throw operation }
        throw MigrationImportAssetStagingError.operationAndRollback(
            operation: String(describing: operation),
            rollback: rollback
        )
    }

    private static func requiresRecovery(_ error: Error) -> Bool {
        if let error = error as? MigrationImageTransferError {
            return error.leavesOwnedArtifacts
        }
        if let error = error as? MigrationVolumeTransferError {
            return error.leavesOwnedArtifacts
        }
        return false
    }
}

enum MigrationCreatedAsset {
    case image(entry: MigrationImageTargetInventory.Entry)
    case sourceImage(reference: String, expectedLabels: [String: String])
    case volume(name: String, expectedLabels: [String: String])
    case network(name: String, expectedLabels: [String: String])
    case container(name: String, expectedLabels: [String: String])
}

struct MigrationImportAssetStagingExecution {
    let session: MigrationImportStagingSession
    let environment: MigrationImportAssetStagingEnvironment
    var state: DoryOperationState
    var created: [MigrationCreatedAsset] = []

    init(
        session: MigrationImportStagingSession,
        environment: MigrationImportAssetStagingEnvironment
    ) throws {
        let current = try session.lease.read().state
        guard current == session.state,
              current.phase == .staging,
              current.status == .running,
              try session.lease.readStagedObjects().isEmpty else {
            throw MigrationImportAssetStagingError.invalidSession(
                "the journal is not at a fresh running staging boundary"
            )
        }
        self.session = session
        self.environment = environment
        state = current
    }

    mutating func stageImage(_ object: DoryOperationPlannedObject) async throws {
        let expectedPreexisting = try expectedImageWasPreexisting(object)
        let receipt = try await environment.transfers.transferImage(
            MigrationImageTransferRequest(
                operationID: session.prepared.identity.id,
                sourceImageID: object.source.sourceID
            ),
            from: environment.source,
            to: environment.target
        )
        if !receipt.targetImageWasPreexisting {
            created.append(.image(entry: receipt.targetInventoryEntryAfterLoad))
        }
        // Docker's classic and containerd image stores expose different immutable IDs for the
        // same archive (config digest versus OCI manifest digest). The independently re-saved
        // archive fingerprint is the cross-engine identity proof. A planned reuse must remain a
        // reuse; a planned create may safely discover already-present, byte-verified content.
        guard (!expectedPreexisting || receipt.targetImageWasPreexisting),
              MigrationImageTransferExecution.canonicalImageID(receipt.loadedTargetImageID) != nil,
              MigrationImageTransferExecution.canonicalImageID(
                receipt.verifiedTarget.semanticIdentity
              ) == MigrationImageTransferExecution.canonicalImageID(object.source.sourceID) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let manifestDigest = try session.lease.publishManifest(receipt.verificationManifest)
        guard manifestDigest == receipt.verificationManifestSha256 else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        try session.lease.publishStagedObject(DoryOperationStagedObject(
            source: object.source,
            verifiedTarget: DoryOperationTargetIdentity(
                id: receipt.loadedTargetImageID,
                fingerprint: receipt.verifiedTarget.archiveContractSha256
            ),
            verificationManifestDigest: manifestDigest,
            disposition: receipt.targetImageWasPreexisting
                ? .reusedPreexisting
                : .createdOperationOwned
        ))
        state = try session.lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: state.revision,
            stepID: "staging.image-verified"
        )
    }

    mutating func stageVolume(_ object: DoryOperationPlannedObject) async throws {
        let specificationData = try session.lease.readSpecification(
            digest: object.specificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            MigrationVolumeContract.self,
            from: specificationData
        ), specification.name == object.normalizedTargetName,
           object.collisionDecision == .create else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        try await requireVolumeAbsent(object)
        created.append(.volume(name: specification.name, expectedLabels: specification.labels))
        try await environment.target.createVolume(
            name: specification.name,
            driver: specification.driver,
            labels: specification.labels,
            driverOptions: specification.options
        )
        try await requireExactTargetVolume(specification, object: object)
        let receipt = try await environment.transfers.transferVolume(
            MigrationVolumeTransferRequest(
                operationID: session.prepared.identity.id,
                sourceAuthorityHash: session.prepared.ownership.sourceAuthorityHash,
                sourceVolume: object.source.sourceID,
                targetVolume: specification.name
            ),
            from: environment.source,
            to: environment.target
        )
        try await requireExactTargetVolume(specification, object: object)
        try publishVolumeEvidence(
            receipt,
            object: object,
            specification: specification
        )
    }

    mutating func publishVolumeEvidence(
        _ receipt: MigrationVolumeTransferReceipt,
        object: DoryOperationPlannedObject,
        specification: MigrationVolumeContract
    ) throws {
        guard try session.lease.publishManifest(receipt.sourceManifest)
                == receipt.sourceManifestSha256,
              try session.lease.publishManifest(receipt.targetManifest)
                == receipt.targetManifestSha256 else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let targetFingerprint = try MigrationImportAssetCanonical.targetFingerprint(
            specificationDigest: object.specificationDigest,
            targetManifestDigest: receipt.targetManifestSha256
        )
        let manifest = try MigrationImportAssetCanonical.data(MigrationVolumeVerificationManifest(
            operationID: session.prepared.identity.id,
            object: object,
            receipt: receipt,
            targetFingerprint: targetFingerprint
        ))
        let manifestDigest = try session.lease.publishManifest(manifest)
        try session.lease.publishStagedObject(DoryOperationStagedObject(
            source: object.source,
            verifiedTarget: DoryOperationTargetIdentity(
                id: specification.name,
                fingerprint: targetFingerprint
            ),
            verificationManifestDigest: manifestDigest,
            disposition: .createdOperationOwned
        ))
        state = try session.lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: state.revision,
            stepID: "staging.volume-verified"
        )
    }

    func expectedImageWasPreexisting(_ object: DoryOperationPlannedObject) throws -> Bool {
        switch object.collisionDecision {
        case .create: return false
        case .reuseVerified: return true
        case .resumeOperationOwned:
            throw MigrationImportAssetStagingError.invalidSession(
                "operation-owned image recovery requires the recovery executor"
            )
        }
    }

    func requireVolumeAbsent(_ object: DoryOperationPlannedObject) async throws {
        let snapshot = try await environment.target.migrationSnapshot()
        guard !snapshot.volumes.contains(where: { $0.name == object.normalizedTargetName }) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func requireExactTargetVolume(
        _ specification: MigrationVolumeContract,
        object: DoryOperationPlannedObject
    ) async throws {
        let matches = try await environment.target.migrationSnapshot().volumes.filter {
            $0.name == specification.name
        }
        guard matches.count == 1,
              MigrationVolumeContract(volume: matches[0]) == specification else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    mutating func rollback() async -> [String] {
        var failures: [String] = []
        for asset in created.reversed() {
            switch asset {
            case let .image(entry):
                await rollbackImage(entry, failures: &failures)
            case let .sourceImage(reference, expectedLabels):
                await rollbackSourceImage(reference, expectedLabels: expectedLabels, failures: &failures)
            case let .volume(name, expectedLabels):
                await rollbackVolume(name, expectedLabels: expectedLabels, failures: &failures)
            case let .network(name, expectedLabels):
                await rollbackNetwork(name, expectedLabels: expectedLabels, failures: &failures)
            case let .container(name, expectedLabels):
                await rollbackContainer(name, expectedLabels: expectedLabels, failures: &failures)
            }
        }
        return failures
    }

    func rollbackImage(
        _ expected: MigrationImageTargetInventory.Entry,
        failures: inout [String]
    ) async {
        do {
            let before = try MigrationImageTransferExecution.targetInventory(
                images: try await environment.target.migrationSnapshot().images
            )
            guard let current = before.entries.first(where: { $0.id == expected.id }) else {
                return
            }
            guard current == expected, current.references.isEmpty else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .image, sourceID: expected.id)
                )
            }
            try await environment.target.removeImageForRollback(id: expected.id)
            let after = try MigrationImageTransferExecution.targetInventory(
                images: try await environment.target.migrationSnapshot().images
            )
            guard !after.entries.contains(where: { $0.id == expected.id }) else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .image, sourceID: expected.id)
                )
            }
        } catch {
            failures.append("remove staged image \(expected.id): \(error)")
        }
    }

    func rollbackVolume(
        _ name: String,
        expectedLabels: [String: String],
        failures: inout [String]
    ) async {
        do {
            let before = try await environment.target.migrationSnapshot().volumes.filter {
                $0.name == name
            }
            guard before.count <= 1 else {
                throw MigrationImportAssetStagingError.targetDrift(.init(kind: .volume, sourceID: name))
            }
            if let volume = before.first {
                guard owns(volume.labels, expected: expectedLabels) else {
                    throw MigrationImportAssetStagingError.targetDrift(.init(kind: .volume, sourceID: name))
                }
                try await environment.target.removeVolumeForRollback(name: name)
            }
            let after = try await environment.target.migrationSnapshot()
            guard !after.volumes.contains(where: { $0.name == name }) else {
                throw MigrationImportAssetStagingError.targetDrift(.init(kind: .volume, sourceID: name))
            }
        } catch {
            failures.append("remove staged volume \(name): \(error)")
        }
    }

    func owns(_ labels: [String: String], expected: [String: String]) -> Bool {
        let keys = [
            "dev.dory.operation.id",
            "dev.dory.source.authority",
            "dev.dory.object.kind",
            "dev.dory.original.identity",
            "dev.dory.target.identity",
            "dev.dory.operation.state"
        ]
        return keys.allSatisfy { labels[$0] != nil && labels[$0] == expected[$0] }
    }
}

extension MigrationImportAssetStagingExecution {
    mutating func stage() async throws -> DoryOperationState {
        // The staging session can sit open while another actor mutates either daemon. Recheck the
        // complete source closure and unowned target baseline immediately before the first write.
        try await requireExactAuthoritiesAndSourceClosure()
        _ = try verifiedUnselectedSourceInventoryDigest()
        _ = try await verifiedUnownedTargetInventoryDigest(staged: [])
        for object in session.prepared.operation.completenessPlan.objects {
            try Task.checkCancellation()
            switch object.source.kind {
            case .image:
                try await stageImage(object)
            case .volume:
                try await stageVolume(object)
            case .network:
                try await stageNetwork(object)
            case .writableLayer:
                try await stageWritableLayer(object)
            case .container:
                try await stageContainerDefinition(object)
            }
        }
        try await publishContainers()
        try await validateAndComplete()
        return state
    }
}
