import DoryOperations
import Foundation

enum MigrationImportRecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedOperation(UUID, DoryOperationKind)
    case authorityChanged(UUID)
    case invalidJournal(UUID, String)
    case cleanupIncomplete(UUID, [String])

    var description: String {
        switch self {
        case let .unsupportedOperation(id, kind):
            return "Dory operation \(id.uuidString.lowercased()) is \(kind.rawValue) and cannot "
                + "be recovered by the competitor import executor"
        case let .authorityChanged(id):
            return "migration operation \(id.uuidString.lowercased()) belongs to a different "
                + "source or target Docker daemon"
        case let .invalidJournal(id, detail):
            return "migration operation \(id.uuidString.lowercased()) cannot be recovered safely: "
                + detail
        case let .cleanupIncomplete(id, failures):
            return "migration operation \(id.uuidString.lowercased()) still requires recovery: "
                + failures.joined(separator: "; ")
        }
    }
}

struct MigrationImportRecoveryEnvironment: Sendable {
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    let journalStore: DoryOperationJournalStore
    let helperAsset: MigrationTransferHelperAsset?
}

struct MigrationImportRecoveryResult: Sendable, Equatable {
    let recoveredOperationID: UUID?
    let preservedUnattributedTargetImageIDs: [String]

    static let nothingToRecover = MigrationImportRecoveryResult(
        recoveredOperationID: nil,
        preservedUnattributedTargetImageIDs: []
    )
}

/// Reconciles an interrupted competitor import before a new plan is collected.
///
/// Docker cannot atomically load an image and publish journal ownership. If the process dies in
/// that narrow interval, recovery deliberately preserves the unattributed content-addressed image.
/// A fresh import can verify and reuse it; recovery never guesses that an unlabelled image belongs
/// to Dory and never force-removes references created by another client.
enum MigrationImportRecovery {
    static func recoverUnfinishedOperation(
        environment: MigrationImportRecoveryEnvironment
    ) async throws -> MigrationImportRecoveryResult {
        guard let summary = try environment.journalStore.list().first(where: {
            $0.state.status != .completed && $0.state.status != .failed
        }) else {
            return .nothingToRecover
        }
        guard summary.plan.kind == .competitorImport else {
            throw MigrationImportRecoveryError.unsupportedOperation(
                summary.plan.id,
                summary.plan.kind
            )
        }

        // The lease holds the one mutation lock for the whole Dory home. If the original import is
        // still alive, acquisition fails instead of racing its executor.
        let lease = try environment.journalStore.acquire(summary.plan.id)
        let record = try lease.read()
        guard record.state.status != .completed, record.state.status != .failed else {
            return .nothingToRecover
        }
        if record.state.phase == .planned || record.state.phase == .quiescing {
            _ = try lease.transition(
                to: record.state.phase,
                status: .failed,
                expectedRevision: record.state.revision,
                stepID: "recovery.no-mutations"
            )
            return MigrationImportRecoveryResult(
                recoveredOperationID: record.plan.id,
                preservedUnattributedTargetImageIDs: []
            )
        }
        let plan = try MigrationImportRecoveryPlan(lease: lease, record: record)
        try await requireOriginalAuthorities(record: record, environment: environment)

        var state = record.state
        if state.status != .rollingBack {
            state = try lease.transition(
                to: state.phase,
                status: .rollingBack,
                expectedRevision: state.revision,
                stepID: "recovery.rollback-begin"
            )
        }

        let execution = MigrationImportRecoveryExecution(
            lease: lease,
            plan: plan,
            environment: environment
        )
        let outcome = await execution.rollback()
        state = try lease.read().state
        guard outcome.failures.isEmpty else {
            if state.status != .needsRecovery {
                _ = try lease.transition(
                    to: state.phase,
                    status: .needsRecovery,
                    expectedRevision: state.revision,
                    stepID: "recovery.rollback-incomplete",
                    recoveryAction: "rollback.retry"
                )
            }
            throw MigrationImportRecoveryError.cleanupIncomplete(
                record.plan.id,
                outcome.failures
            )
        }

        let stepID = outcome.preservedUnattributedTargetImageIDs.isEmpty
            ? "recovery.rollback-completed"
            : "recovery.rollback-completed-preserving-images"
        _ = try lease.transition(
            to: state.phase,
            status: .failed,
            expectedRevision: state.revision,
            stepID: stepID
        )
        return MigrationImportRecoveryResult(
            recoveredOperationID: record.plan.id,
            preservedUnattributedTargetImageIDs: outcome.preservedUnattributedTargetImageIDs
        )
    }

    private static func requireOriginalAuthorities(
        record: DoryOperationRecord,
        environment: MigrationImportRecoveryEnvironment
    ) async throws {
        guard record.plan.source.kind == .dockerEngine,
              record.plan.target.kind == .dockerEngine else {
            throw MigrationImportRecoveryError.invalidJournal(
                record.plan.id,
                "the recorded authorities are not Docker engines"
            )
        }
        async let source = MigrationDockerAuthority.read(from: environment.source)
        async let target = MigrationDockerAuthority.read(from: environment.target)
        guard try await source.authorityID == record.plan.source.id,
              try await target.authorityID == record.plan.target.id else {
            throw MigrationImportRecoveryError.authorityChanged(record.plan.id)
        }
    }
}

private struct MigrationImportRecoveryNamedAsset {
    let key: DoryOperationObjectKey
    let name: String
    let labels: [String: String]
}

private struct MigrationImportRecoveryWritableLayer {
    let key: DoryOperationObjectKey
    let temporarySourceReference: String
    let labels: [String: String]
    let stagedTargetEntry: MigrationImageTargetInventory.Entry?
}

private struct MigrationImportRecoveryVolumePair: Hashable {
    let source: String
    let target: String
}

private struct MigrationImportRecoveryPlan {
    let operationID: UUID
    let ownership: MigrationOperationOwnership
    let baselineTargetImageIDs: Set<String>
    let targetImageEntries: [MigrationImageTargetInventory.Entry]
    let writableLayers: [MigrationImportRecoveryWritableLayer]
    let volumes: [MigrationImportRecoveryNamedAsset]
    let networks: [MigrationImportRecoveryNamedAsset]
    let containers: [MigrationImportRecoveryNamedAsset]
    let volumePairs: Set<MigrationImportRecoveryVolumePair>
    let sourceHelperWasDangling: Bool
    let targetHelperWasDangling: Bool

    init(lease: DoryOperationLease, record: DoryOperationRecord) throws {
        operationID = record.plan.id
        ownership = MigrationOperationOwnership(
            operationID: record.plan.id,
            sourceAuthorityID: record.plan.source.id
        )
        let completeness = try lease.readCompletenessPlan()
        let staged = Dictionary(uniqueKeysWithValues: try lease.readStagedObjects().map {
            ($0.source, $0)
        })
        sourceHelperWasDangling = try Self.helperWasDangling(
            in: try lease.readManifest(digest: completeness.sourceInventoryDigest),
            expectedDigest: completeness.sourceInventoryDigest,
            lease: lease,
            operationID: record.plan.id
        )
        let baselineData = try lease.readManifest(
            digest: completeness.context.targetInventoryDigest
        )
        guard MigrationImportAssetCanonical.digest(baselineData)
                == completeness.context.targetInventoryDigest,
              let baseline = try? JSONDecoder().decode(
                MigrationTargetInventory.self,
                from: baselineData
              ) else {
            throw MigrationImportRecoveryError.invalidJournal(
                record.plan.id,
                "the target inventory baseline is invalid"
            )
        }
        baselineTargetImageIDs = Set(baseline.images.map {
            MigrationOperationPlanBuilder.normalizedImageID($0.id)
        })

        var targetEntries: [String: MigrationImageTargetInventory.Entry] = [:]
        var writable: [MigrationImportRecoveryWritableLayer] = []
        var volumeAssets: [MigrationImportRecoveryNamedAsset] = []
        var networkAssets: [MigrationImportRecoveryNamedAsset] = []
        var containerAssets: [MigrationImportRecoveryNamedAsset] = []
        var pairs = Set<MigrationImportRecoveryVolumePair>()

        for object in completeness.objects {
            let specification = try lease.readSpecification(digest: object.specificationDigest)
            switch object.source.kind {
            case .image:
                guard let contract = try? JSONDecoder().decode(
                    MigrationImageContract.self,
                    from: specification
                ), MigrationOperationPlanBuilder.normalizedImageID(contract.id)
                    == MigrationOperationPlanBuilder.normalizedImageID(object.source.sourceID) else {
                    throw Self.invalid(record.plan.id, object.source)
                }
                if let entry = try Self.createdTargetEntry(
                    for: object,
                    staged: staged[object.source],
                    lease: lease,
                    operationID: record.plan.id
                ) {
                    try Self.insert(entry, into: &targetEntries, operationID: record.plan.id)
                }
            case .volume:
                guard let contract = try? JSONDecoder().decode(
                    MigrationVolumeContract.self,
                    from: specification
                ), contract.name == object.normalizedTargetName,
                   Self.owns(
                    contract.labels,
                    expected: ownership.labels(
                        existing: [:],
                        kind: .volume,
                        sourceID: object.source.sourceID,
                        targetID: object.normalizedTargetName
                    )
                   ) else {
                    throw Self.invalid(record.plan.id, object.source)
                }
                volumeAssets.append(.init(
                    key: object.source,
                    name: contract.name,
                    labels: contract.labels
                ))
                pairs.insert(.init(source: object.source.sourceID, target: contract.name))
            case .network:
                guard let contract = try? JSONDecoder().decode(
                    MigrationNetworkContract.self,
                    from: specification
                ), contract.name == object.normalizedTargetName,
                   Self.owns(
                    contract.labels,
                    expected: ownership.labels(
                        existing: [:],
                        kind: .network,
                        sourceID: object.source.sourceID,
                        targetID: object.normalizedTargetName
                    )
                   ) else {
                    throw Self.invalid(record.plan.id, object.source)
                }
                networkAssets.append(.init(
                    key: object.source,
                    name: contract.name,
                    labels: contract.labels
                ))
            case .writableLayer:
                guard let contract = try? JSONDecoder().decode(
                    MigrationWritableLayerContract.self,
                    from: specification
                ), contract.containerID == object.source.sourceID,
                   contract.logicalBytes > 0 else {
                    throw Self.invalid(record.plan.id, object.source)
                }
                let labels = ownership.labels(
                    existing: [:],
                    kind: .writableLayer,
                    sourceID: object.source.sourceID,
                    targetID: object.normalizedTargetName
                )
                let entry = try Self.createdTargetEntry(
                    for: object,
                    staged: staged[object.source],
                    lease: lease,
                    operationID: record.plan.id
                )
                if let entry {
                    try Self.insert(entry, into: &targetEntries, operationID: record.plan.id)
                }
                writable.append(.init(
                    key: object.source,
                    temporarySourceReference: MigrationImportTemporaryAssets
                        .writableLayerReference(
                            operationID: record.plan.id,
                            sourceID: object.source.sourceID
                        ),
                    labels: labels,
                    stagedTargetEntry: entry
                ))
            case .container:
                guard let contract = try? JSONDecoder().decode(
                    ContainerSpec.self,
                    from: specification
                ), contract.name == object.normalizedTargetName,
                   Self.owns(
                    contract.labels,
                    expected: ownership.labels(
                        existing: [:],
                        kind: .container,
                        sourceID: object.source.sourceID,
                        targetID: object.normalizedTargetName
                    )
                   ) else {
                    throw Self.invalid(record.plan.id, object.source)
                }
                containerAssets.append(.init(
                    key: object.source,
                    name: contract.name,
                    labels: contract.labels
                ))
            }
        }

        targetImageEntries = targetEntries.values.sorted { $0.id < $1.id }
        writableLayers = writable
        volumes = volumeAssets
        networks = networkAssets
        containers = containerAssets
        volumePairs = pairs
        targetHelperWasDangling = baseline.images.contains {
            MigrationOperationPlanBuilder.normalizedImageID($0.id)
                == MigrationOperationPlanBuilder.normalizedImageID(
                    MigrationTransferHelperPins.appleSiliconV1.imageConfigDigest
                ) && $0.references.isEmpty
        }
    }

    private static func helperWasDangling(
        in data: Data,
        expectedDigest: String,
        lease: DoryOperationLease,
        operationID: UUID
    ) throws -> Bool {
        guard MigrationImportAssetCanonical.digest(data) == expectedDigest,
              let inventory = try? JSONDecoder().decode(
                [DoryOperationInventoryObject].self,
                from: data
              ), Set(inventory.map(\.key)).count == inventory.count else {
            throw MigrationImportRecoveryError.invalidJournal(
                operationID,
                "the source inventory baseline is invalid"
            )
        }
        let helperID = MigrationOperationPlanBuilder.normalizedImageID(
            MigrationTransferHelperPins.appleSiliconV1.imageConfigDigest
        )
        for item in inventory where item.key.kind == .image {
            let specification = try lease.readSpecification(digest: item.specificationDigest)
            guard let contract = try? JSONDecoder().decode(
                MigrationImageContract.self,
                from: specification
            ), MigrationOperationPlanBuilder.normalizedImageID(contract.id)
                == MigrationOperationPlanBuilder.normalizedImageID(item.key.sourceID) else {
                throw invalid(operationID, item.key)
            }
            if MigrationOperationPlanBuilder.normalizedImageID(contract.id) == helperID,
               contract.references.isEmpty {
                return true
            }
        }
        return false
    }

    private static func createdTargetEntry(
        for object: DoryOperationPlannedObject,
        staged: DoryOperationStagedObject?,
        lease: DoryOperationLease,
        operationID: UUID
    ) throws -> MigrationImageTargetInventory.Entry? {
        guard let staged else { return nil }
        guard staged.source == object.source else {
            throw invalid(operationID, object.source)
        }
        if staged.disposition == .reusedPreexisting { return nil }

        let imageManifest: MigrationImageVerificationManifest
        switch object.source.kind {
        case .image:
            let data = try lease.readManifest(digest: staged.verificationManifestDigest)
            guard let decoded = try? JSONDecoder().decode(
                MigrationImageVerificationManifest.self,
                from: data
            ) else {
                throw invalid(operationID, object.source)
            }
            imageManifest = decoded
        case .writableLayer:
            let data = try lease.readManifest(digest: staged.verificationManifestDigest)
            guard let layer = try? JSONDecoder().decode(
                MigrationLayerVerificationManifest.self,
                from: data
            ), layer.schemaVersion == MigrationLayerVerificationManifest.schemaVersion,
               layer.operationID == operationID,
               layer.sourceContainerID == object.source.sourceID,
               layer.loadedTargetImageID == staged.verifiedTarget.id else {
                throw invalid(operationID, object.source)
            }
            let imageData = try lease.readManifest(
                digest: layer.imageVerificationManifestDigest
            )
            guard let decoded = try? JSONDecoder().decode(
                MigrationImageVerificationManifest.self,
                from: imageData
            ), decoded.sourceImageID == layer.committedSourceImageID else {
                throw invalid(operationID, object.source)
            }
            imageManifest = decoded
        case .volume, .network, .container:
            throw invalid(operationID, object.source)
        }
        guard imageManifest.schemaVersion == MigrationImageVerificationManifest.schemaVersion,
              imageManifest.operationID == operationID,
              imageManifest.loadedTargetImageID == staged.verifiedTarget.id,
              imageManifest.targetInventoryEntryAfterLoad.id
                == imageManifest.loadedTargetImageID,
              !imageManifest.targetImageWasPreexisting,
              imageManifest.targetInventoryEntryAfterLoad.references.isEmpty else {
            throw invalid(operationID, object.source)
        }
        return imageManifest.targetInventoryEntryAfterLoad
    }

    private static func insert(
        _ entry: MigrationImageTargetInventory.Entry,
        into entries: inout [String: MigrationImageTargetInventory.Entry],
        operationID: UUID
    ) throws {
        if let current = entries[entry.id], current != entry {
            throw MigrationImportRecoveryError.invalidJournal(
                operationID,
                "the same staged image has conflicting ownership evidence"
            )
        }
        entries[entry.id] = entry
    }

    private static func owns(
        _ labels: [String: String],
        expected: [String: String]
    ) -> Bool {
        MigrationImportRecoveryExecution.ownershipKeys.allSatisfy {
            labels[$0] != nil && labels[$0] == expected[$0]
        }
    }

    private static func invalid(
        _ operationID: UUID,
        _ key: DoryOperationObjectKey
    ) -> MigrationImportRecoveryError {
        .invalidJournal(operationID, "invalid recovery specification for \(key)")
    }
}

private struct MigrationImportRecoveryOutcome {
    var failures: [String] = []
    var preservedUnattributedTargetImageIDs: [String] = []
}

private struct MigrationImportRecoveryExecution {
    static let ownershipKeys = [
        "dev.dory.operation.id",
        "dev.dory.source.authority",
        "dev.dory.object.kind",
        "dev.dory.original.identity",
        "dev.dory.target.identity",
        "dev.dory.operation.state"
    ]

    let lease: DoryOperationLease
    let plan: MigrationImportRecoveryPlan
    let environment: MigrationImportRecoveryEnvironment

    func rollback() async -> MigrationImportRecoveryOutcome {
        var outcome = MigrationImportRecoveryOutcome()
        await removeHelperContainers(from: environment.target, side: "target", outcome: &outcome)
        await removeHelperContainers(from: environment.source, side: "source", outcome: &outcome)
        for asset in plan.containers.reversed() {
            await removeContainer(asset, outcome: &outcome)
        }
        for asset in plan.networks.reversed() {
            await removeNetwork(asset, outcome: &outcome)
        }
        for asset in plan.volumes.reversed() {
            await removeVolume(asset, outcome: &outcome)
        }
        for layer in plan.writableLayers.reversed() {
            await removeSourceWritableLayer(layer, outcome: &outcome)
        }
        for entry in plan.targetImageEntries.reversed() {
            await removeTargetImage(entry, outcome: &outcome)
        }
        for layer in plan.writableLayers.reversed() where layer.stagedTargetEntry == nil {
            await removeUnstagedTargetWritableLayer(layer, outcome: &outcome)
        }
        if !plan.volumePairs.isEmpty {
            await removeHelperImageTag(
                from: environment.target,
                side: "target",
                restoreDangling: plan.targetHelperWasDangling,
                outcome: &outcome
            )
            await removeHelperImageTag(
                from: environment.source,
                side: "source",
                restoreDangling: plan.sourceHelperWasDangling,
                outcome: &outcome
            )
        }
        await reportRemainingOwnedObjects(
            in: environment.target,
            side: "target",
            outcome: &outcome
        )
        await reportRemainingOwnedObjects(
            in: environment.source,
            side: "source",
            outcome: &outcome
        )
        await recordPreservedUnattributedImages(outcome: &outcome)
        outcome.failures = Array(Set(outcome.failures)).sorted()
        outcome.preservedUnattributedTargetImageIDs = Array(Set(
            outcome.preservedUnattributedTargetImageIDs
        )).sorted()
        return outcome
    }

    private func removeHelperContainers(
        from runtime: any ContainerRuntime,
        side: String,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let snapshot = try await runtime.migrationSnapshot()
            let operation = plan.operationID.uuidString.lowercased()
            let candidates = snapshot.containers.filter {
                $0.labels["dev.dory.operation.id"] == operation
                    && $0.labels["dev.dory.object.kind"] == "volume-transfer-helper"
            }
            for container in candidates {
                let labels = container.labels
                guard let sourceVolume = labels["dev.dory.original.identity"],
                      let targetVolume = labels["dev.dory.target.identity"],
                      let role = labels["dev.dory.operation.role"],
                      plan.volumePairs.contains(.init(
                        source: sourceVolume,
                        target: targetVolume
                      )), labels["dev.dory.source.authority"]
                        == plan.ownership.sourceAuthorityHash,
                      labels["dev.dory.operation.state"] == "staging",
                      Self.helperRoles(for: side).contains(role),
                      container.name == Self.helperContainerName(
                        operationID: plan.operationID,
                        volume: side == "source" ? sourceVolume : targetVolume,
                        role: role
                      ) else {
                    outcome.failures.append(
                        "preserve \(side) helper container \(container.id): ownership changed"
                    )
                    continue
                }
                do {
                    try await runtime.remove(containerID: container.id)
                } catch {
                    outcome.failures.append(
                        "remove \(side) helper container \(container.id): \(error)"
                    )
                }
            }
        } catch {
            outcome.failures.append("read \(side) helper containers: \(error)")
        }
    }

    private func removeContainer(
        _ asset: MigrationImportRecoveryNamedAsset,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let matches = try await environment.target.migrationSnapshot().containers.filter {
                $0.name == asset.name
            }
            guard matches.count <= 1 else { throw RecoveryDrift.multiple(asset.key) }
            if let container = matches.first {
                guard owns(container.labels, expected: asset.labels) else {
                    throw RecoveryDrift.ownership(asset.key)
                }
                try await environment.target.remove(containerID: container.id)
            }
            guard try await !environment.target.migrationSnapshot().containers.contains(where: {
                $0.name == asset.name
            }) else { throw RecoveryDrift.survived(asset.key) }
        } catch {
            outcome.failures.append("remove container \(asset.name): \(error)")
        }
    }

    private func removeNetwork(
        _ asset: MigrationImportRecoveryNamedAsset,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let matches = try await environment.target.migrationSnapshot().networks.filter {
                $0.name == asset.name
            }
            guard matches.count <= 1 else { throw RecoveryDrift.multiple(asset.key) }
            if let network = matches.first {
                guard owns(network.labels, expected: asset.labels) else {
                    throw RecoveryDrift.ownership(asset.key)
                }
                try await environment.target.removeNetwork(name: asset.name)
            }
            guard try await !environment.target.migrationSnapshot().networks.contains(where: {
                $0.name == asset.name
            }) else { throw RecoveryDrift.survived(asset.key) }
        } catch {
            outcome.failures.append("remove network \(asset.name): \(error)")
        }
    }

    private func removeVolume(
        _ asset: MigrationImportRecoveryNamedAsset,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let matches = try await environment.target.migrationSnapshot().volumes.filter {
                $0.name == asset.name
            }
            guard matches.count <= 1 else { throw RecoveryDrift.multiple(asset.key) }
            if let volume = matches.first {
                guard owns(volume.labels, expected: asset.labels) else {
                    throw RecoveryDrift.ownership(asset.key)
                }
                try await environment.target.removeVolumeForRollback(name: asset.name)
            }
            guard try await !environment.target.migrationSnapshot().volumes.contains(where: {
                $0.name == asset.name
            }) else { throw RecoveryDrift.survived(asset.key) }
        } catch {
            outcome.failures.append("remove volume \(asset.name): \(error)")
        }
    }

    private func removeTargetImage(
        _ expected: MigrationImageTargetInventory.Entry,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let inventory = try MigrationImageTransferExecution.targetInventory(
                images: try await environment.target.migrationSnapshot().images
            )
            guard let current = inventory.entries.first(where: { $0.id == expected.id }) else {
                return
            }
            guard current == expected, current.references.isEmpty else {
                throw RecoveryDrift.image(expected.id)
            }
            try await environment.target.removeImageForRollback(id: expected.id)
            let after = try MigrationImageTransferExecution.targetInventory(
                images: try await environment.target.migrationSnapshot().images
            )
            guard !after.entries.contains(where: { $0.id == expected.id }) else {
                throw RecoveryDrift.image(expected.id)
            }
        } catch {
            outcome.failures.append("remove target image \(expected.id): \(error)")
        }
    }

    private func removeUnstagedTargetWritableLayer(
        _ layer: MigrationImportRecoveryWritableLayer,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let images = try await environment.target.migrationSnapshot().images.filter {
                owns($0.labels, expected: layer.labels)
            }
            guard images.count <= 1 else { throw RecoveryDrift.multiple(layer.key) }
            guard let image = images.first else { return }
            let inventory = try MigrationImageTransferExecution.targetInventory(images: [image])
            guard let entry = inventory.entries.first, entry.references.isEmpty else {
                throw RecoveryDrift.image(image.imageID)
            }
            try await environment.target.removeImageForRollback(id: entry.id)
        } catch {
            outcome.failures.append(
                "remove unstaged target writable layer \(layer.key.sourceID): \(error)"
            )
        }
    }

    private func removeSourceWritableLayer(
        _ layer: MigrationImportRecoveryWritableLayer,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            var images = try await environment.source.migrationSnapshot().images.filter {
                MigrationOperationPlanBuilder.imageReferences($0).contains(
                    layer.temporarySourceReference
                ) || owns($0.labels, expected: layer.labels)
            }
            guard images.count <= 1 else { throw RecoveryDrift.multiple(layer.key) }
            guard let image = images.first else { return }
            guard owns(image.labels, expected: layer.labels) else {
                throw RecoveryDrift.ownership(layer.key)
            }
            if MigrationOperationPlanBuilder.imageReferences(image).contains(
                layer.temporarySourceReference
            ) {
                try await environment.source.removeImageForRollback(
                    id: layer.temporarySourceReference
                )
            }
            images = try await environment.source.migrationSnapshot().images.filter {
                MigrationOperationPlanBuilder.normalizedImageID($0.imageID)
                    == MigrationOperationPlanBuilder.normalizedImageID(image.imageID)
            }
            guard images.count <= 1 else { throw RecoveryDrift.multiple(layer.key) }
            if let remaining = images.first {
                guard owns(remaining.labels, expected: layer.labels),
                      MigrationOperationPlanBuilder.imageReferences(remaining).isEmpty else {
                    throw RecoveryDrift.ownership(layer.key)
                }
                try await environment.source.removeImageForRollback(id: remaining.imageID)
            }
        } catch {
            outcome.failures.append(
                "remove source writable layer \(layer.key.sourceID): \(error)"
            )
        }
    }

    private func removeHelperImageTag(
        from runtime: any ContainerRuntime,
        side: String,
        restoreDangling: Bool,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        let reference = "dory.internal/operation-\(plan.operationID.uuidString.lowercased())"
            + ":transfer-helper"
        do {
            let inventory = try MigrationImageTransferExecution.targetInventory(
                images: try await runtime.migrationSnapshot().images
            )
            let matches = inventory.entries.filter {
                $0.references.contains(reference)
            }
            guard matches.count <= 1 else { throw RecoveryDrift.helperTag(side) }
            guard let match = matches.first else { return }
            guard match.id == MigrationTransferHelperPins.appleSiliconV1.imageConfigDigest,
                  let helperAsset = environment.helperAsset else {
                throw RecoveryDrift.helperTag(side)
            }
            try await helperAsset.removeInstallation(
                MigrationTransferHelperInstallation(
                    imageID: match.id,
                    ownershipReference: reference,
                    restoreDanglingImageAfterCleanup: restoreDangling
                ),
                from: runtime
            )
        } catch {
            outcome.failures.append("remove \(side) helper image tag: \(error)")
        }
    }

    private func reportRemainingOwnedObjects(
        in runtime: any ContainerRuntime,
        side: String,
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let snapshot = try await runtime.migrationSnapshot()
            let operation = plan.operationID.uuidString.lowercased()
            let remaining = snapshot.containers.map { ("container", $0.id, $0.labels) }
                + snapshot.images.map { ("image", $0.imageID, $0.labels) }
                + snapshot.volumes.map { ("volume", $0.name, $0.labels) }
                + snapshot.networks.map { ("network", $0.name, $0.labels) }
            for (kind, id, labels) in remaining
                where labels["dev.dory.operation.id"] == operation {
                outcome.failures.append("preserve \(side) \(kind) \(id): operation ownership remains")
            }
        } catch {
            outcome.failures.append("verify \(side) recovery cleanup: \(error)")
        }
    }

    private func recordPreservedUnattributedImages(
        outcome: inout MigrationImportRecoveryOutcome
    ) async {
        do {
            let images = try await environment.target.migrationSnapshot().images
            outcome.preservedUnattributedTargetImageIDs += images.compactMap { image in
                let normalized = MigrationOperationPlanBuilder.normalizedImageID(image.imageID)
                guard !plan.baselineTargetImageIDs.contains(normalized),
                      image.labels["dev.dory.operation.id"] == nil,
                      !MigrationOperationPlanBuilder.imageReferences(image).contains(where: {
                          $0.hasPrefix("dory.internal/operation-")
                      }) else { return nil }
                return image.imageID
            }
        } catch {
            outcome.failures.append("record preserved target images: \(error)")
        }
    }

    private func owns(_ labels: [String: String], expected: [String: String]) -> Bool {
        Self.ownershipKeys.allSatisfy {
            labels[$0] != nil && labels[$0] == expected[$0]
        }
    }

    private static func helperRoles(for side: String) -> Set<String> {
        side == "source"
            ? ["source-scan", "source-rescan"]
            : ["target-carrier", "target-repair", "target-scan"]
    }

    private static func helperContainerName(
        operationID: UUID,
        volume: String,
        role: String
    ) -> String {
        let identity = MigrationTransferHelperAsset.sha256(Data(volume.utf8))
        let operation = operationID.uuidString.lowercased()
        return "dory-op-\(operation.prefix(12))-\(identity.prefix(12))-\(role)"
    }

    private enum RecoveryDrift: Error, CustomStringConvertible {
        case multiple(DoryOperationObjectKey)
        case ownership(DoryOperationObjectKey)
        case survived(DoryOperationObjectKey)
        case image(String)
        case helperTag(String)

        var description: String {
            switch self {
            case let .multiple(key): "multiple objects match \(key)"
            case let .ownership(key): "ownership changed for \(key)"
            case let .survived(key): "\(key) survived non-forced rollback"
            case let .image(id): "image ownership changed for \(id)"
            case let .helperTag(side): "\(side) helper tag ownership changed"
            }
        }
    }
}
