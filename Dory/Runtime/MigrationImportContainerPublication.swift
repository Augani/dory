import DoryOperations
import Foundation

struct MigrationStagedContainerDefinition {
    let staged: DoryOperationStagedObject
    let manifest: MigrationContainerDefinitionManifest
    let specification: ContainerSpec
}

extension MigrationImportAssetStagingExecution {
    mutating func publishContainers() async throws {
        try Task.checkCancellation()
        state = try session.lease.transition(
            to: .verifying,
            status: .running,
            expectedRevision: state.revision,
            stepID: "verifying.staged-closure"
        )
        try await verifyPublicationBoundary()
        state = try session.lease.transition(
            to: .readyToPublish,
            status: .running,
            expectedRevision: state.revision,
            stepID: "publication.ready"
        )
        try Task.checkCancellation()
        state = try session.lease.transition(
            to: .publishing,
            status: .running,
            expectedRevision: state.revision,
            stepID: "publication.begin"
        )
        for object in session.prepared.operation.completenessPlan.objects
            where object.source.kind == .container {
            try await publishContainer(object)
        }
    }

    func verifyPublicationBoundary() async throws {
        let plan = session.prepared.operation.completenessPlan
        let staged = try session.lease.readStagedObjects()
        guard staged.map(\.source) == plan.selectedObjectKeys else {
            throw MigrationImportAssetStagingError.invalidSession(
                "the durable staged closure is incomplete"
            )
        }
        let stagedByKey = Dictionary(uniqueKeysWithValues: staged.map { ($0.source, $0) })
        let target = try await environment.target.migrationSnapshot()
        for object in plan.objects {
            switch object.source.kind {
            case .image, .writableLayer:
                guard let identity = stagedByKey[object.source]?.verifiedTarget.id,
                      target.images.contains(where: {
                          MigrationOperationPlanBuilder.normalizedImageID($0.imageID)
                              == MigrationOperationPlanBuilder.normalizedImageID(identity)
                      }) else {
                    throw MigrationImportAssetStagingError.targetDrift(object.source)
                }
            case .volume:
                try await verifyStagedVolume(object)
            case .network:
                try await verifyStagedNetwork(object)
            case .container:
                try await requireExactSourceContainer(object)
                try await requireTargetContainerAbsent(object)
            }
        }
    }

    private func verifyStagedVolume(_ object: DoryOperationPlannedObject) async throws {
        let data = try session.lease.readSpecification(digest: object.specificationDigest)
        guard let specification = try? JSONDecoder().decode(
            MigrationVolumeContract.self,
            from: data
        ) else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        try await requireExactTargetVolume(specification, object: object)
    }

    private func verifyStagedNetwork(_ object: DoryOperationPlannedObject) async throws {
        let data = try session.lease.readSpecification(digest: object.specificationDigest)
        guard let specification = try? JSONDecoder().decode(
            MigrationNetworkContract.self,
            from: data
        ) else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        _ = try await requireExactTargetNetwork(specification, object: object)
    }

    mutating func publishContainer(_ object: DoryOperationPlannedObject) async throws {
        let definition = try stagedContainerDefinition(object)
        try await requireTargetContainerAbsent(object)
        created.append(.container(
            name: definition.specification.name,
            expectedLabels: definition.specification.labels
        ))
        let containerID = try await environment.target.create(definition.specification)
        guard !containerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        try Task.checkCancellation()
        try await restoreContainerState(
            containerID,
            finalState: object.acceptedFinalState
        )
        try await verifyPublishedContainer(
            containerID,
            object: object,
            definition: definition
        )
        state = try session.lease.transition(
            to: .publishing,
            status: .running,
            expectedRevision: state.revision,
            stepID: "publication.container-verified"
        )
    }

    func stagedContainerDefinition(
        _ object: DoryOperationPlannedObject
    ) throws -> MigrationStagedContainerDefinition {
        let staged = try session.lease.readStagedObjects().first { $0.source == object.source }
        guard let staged else {
            throw MigrationImportAssetStagingError.invalidSession(
                "container definition is not staged"
            )
        }
        let manifestData = try session.lease.readManifest(
            digest: staged.verificationManifestDigest
        )
        let dependencyTargets = Dictionary(uniqueKeysWithValues: try stagedDependencies(object).map {
            ($0.key.description, $0.value.verifiedTarget.id)
        })
        guard let manifest = try? JSONDecoder().decode(
            MigrationContainerDefinitionManifest.self,
            from: manifestData
        ), manifest.schemaVersion == MigrationContainerDefinitionManifest.schemaVersion,
           manifest.operationID == session.prepared.identity.id,
           manifest.sourceContainerID == object.source.sourceID,
           manifest.targetName == object.normalizedTargetName,
           manifest.plannedSpecificationDigest == object.specificationDigest,
           manifest.acceptedFinalState == object.acceptedFinalState,
           manifest.dependencyTargets == dependencyTargets,
           staged.verifiedTarget.id == object.normalizedTargetName,
           staged.verifiedTarget.fingerprint == manifest.effectiveSpecificationDigest else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        let specificationData = try session.lease.readManifest(
            digest: manifest.effectiveSpecificationDigest
        )
        guard let specification = try? JSONDecoder().decode(
            ContainerSpec.self,
            from: specificationData
        ), specification.name == object.normalizedTargetName else {
            throw MigrationImportAssetStagingError.invalidSpecification(object.source)
        }
        return MigrationStagedContainerDefinition(
            staged: staged,
            manifest: manifest,
            specification: specification
        )
    }

    private func restoreContainerState(
        _ containerID: String,
        finalState: DoryOperationAcceptedFinalState
    ) async throws {
        switch finalState {
        case .running:
            try await environment.target.start(containerID: containerID)
        case .paused:
            try await environment.target.start(containerID: containerID)
            try await environment.target.pause(containerID: containerID)
        case .created, .exited, .createdStoppedAwaitingPort:
            break
        case .present, .applied:
            throw MigrationImportAssetStagingError.invalidSession(
                "container final state is invalid"
            )
        }
    }

    func verifyPublishedContainer(
        _ containerID: String,
        object: DoryOperationPlannedObject,
        definition: MigrationStagedContainerDefinition
    ) async throws {
        let matches = try await environment.target.migrationSnapshot().containers.filter {
            $0.name == definition.specification.name
        }
        guard matches.count == 1,
              matches[0].id == containerID,
              matches[0].labels == definition.specification.labels,
              matches[0].status == object.acceptedFinalState.runtimeState else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
        let inspected = try await MigrationContainerInspector.inspect(
            matches[0],
            on: environment.target,
            sharedHome: environment.sharedHome,
            validatePortability: false
        )
        guard try MigrationImportAssetCanonical.data(inspected)
                == MigrationImportAssetCanonical.data(definition.specification) else {
            throw MigrationImportAssetStagingError.targetDrift(object.source)
        }
    }

    func rollbackContainer(
        _ name: String,
        expectedLabels: [String: String],
        failures: inout [String]
    ) async {
        do {
            let before = try await environment.target.migrationSnapshot().containers.filter {
                $0.name == name
            }
            guard before.count <= 1 else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .container, sourceID: name)
                )
            }
            if let container = before.first {
                guard owns(container.labels, expected: expectedLabels) else {
                    throw MigrationImportAssetStagingError.targetDrift(
                        .init(kind: .container, sourceID: name)
                    )
                }
                try await environment.target.remove(containerID: container.id)
            }
            let after = try await environment.target.migrationSnapshot()
            guard !after.containers.contains(where: { $0.name == name }) else {
                throw MigrationImportAssetStagingError.targetDrift(
                    .init(kind: .container, sourceID: name)
                )
            }
        } catch {
            failures.append("remove published container \(name): \(error)")
        }
    }
}

extension DoryOperationAcceptedFinalState {
    var runtimeState: RunState {
        switch self {
        case .running: return .running
        case .paused: return .paused
        case .created, .exited, .createdStoppedAwaitingPort: return .stopped
        case .present, .applied: return .stopped
        }
    }
}
